# Lock.Boot workspace
#
# This repo is the reproducible dev environment for the multi-repo Lock.Boot
# project. Sub-repos are plain clones (NOT submodules of this repo) managed by
# this Makefile. Cargo/rustup homes and the registry cache are shared across all
# of them via the workspace root - see .cargo/config.toml, rust-toolchain.toml
# and .devcontainer/. No Docker volumes: everything is a bind mount.
#
#   make            # clone any missing sub-repos (same as `make clone`)
#   make pull       # fast-forward every sub-repo + refresh its submodules
#   make status     # short git status of every sub-repo
#   make image      # build the lockboot:build + lockboot:harness images (needs Docker)
#   make clean-cache# remove the shared cargo/rustup caches + stray target dirs
#   make help       # list targets
#
# NOTE: the sub-repos are NOT submodules of the workspace, but SOME of them have
# their OWN git submodules (os402 -> reqwest, lockboot; vaportpm-zk -> rustcrypto
# elliptic-curves). `clone`/`pull` therefore recurse submodules, else those repos
# will not build.

GITHUB_BASEURL := https://github.com/lockboot
# dotgithub = the org meta repo (github.com/lockboot/.github): org profile README
# (profile/README.md) + default community-health files. Cloned under a non-dot name
# so it is not mistaken for this workspace's own .github/ dir.
REPOS := \
	dotgithub=$(GITHUB_BASEURL)/.github.git \
	os402=$(GITHUB_BASEURL)/os402.git \
	stage0=$(GITHUB_BASEURL)/stage0.git \
	stage1=$(GITHUB_BASEURL)/stage1.git \
	vaportpm=$(GITHUB_BASEURL)/vaportpm.git \
	stage2=$(GITHUB_BASEURL)/stage2.git \
	vaportpm-zk=$(GITHUB_BASEURL)/vaportpm-zk.git \
	DudeFS=$(GITHUB_BASEURL)/DudeFS.git

# The canonical build Dockerfiles live in stage0 (the reference project; the copy
# in stage1 is kept byte-identical). Build the shared "lockboot family" images
# from there. These images are built locally and never published.
CANON := stage0

.DEFAULT_GOAL := clone

.PHONY: clone
clone: ## Clone any sub-repos that are not present yet (with their submodules)
	@for entry in $(REPOS); do \
		name=$${entry%%=*}; url=$${entry#*=}; \
		if [ -d "$$name/.git" ]; then \
			echo ">> $$name: present"; \
		else \
			echo ">> $$name: cloning from $$url"; \
			git clone --recurse-submodules "$$url" "$$name"; \
		fi; \
	done

.PHONY: pull
pull: ## Fast-forward every sub-repo and refresh its submodules
	@for entry in $(REPOS); do \
		name=$${entry%%=*}; \
		if [ -d "$$name/.git" ]; then \
			echo ">> $$name: pulling"; \
			git -C "$$name" pull --ff-only || echo "   (skipped: not a fast-forward)"; \
			git -C "$$name" submodule update --init --recursive; \
		else \
			echo ">> $$name: missing (run 'make clone')"; \
		fi; \
	done

.PHONY: status
status: ## Show short git status + current branch for every sub-repo
	@for entry in $(REPOS); do \
		name=$${entry%%=*}; \
		if [ -d "$$name/.git" ]; then \
			branch=$$(git -C "$$name" branch --show-current); \
			echo "== $$name ($$branch) =="; \
			git -C "$$name" status --short; \
		else \
			echo "== $$name == (missing)"; \
		fi; \
	done

# The build system runs Rust builds inside lockboot:build (via each repo's own
# Makefile), and stage0's QEMU boot tests inside lockboot:harness. The devcontainer
# is a SEPARATE, lean image built by VS Code from .devcontainer/Dockerfile on
# "Reopen in Container" - it only drives these builds, it does not compile anything.
.PHONY: image
image: ## Build the shared lockboot:build + lockboot:harness images from stage0 (needs Docker + stage0 cloned)
	@test -d $(CANON)/.git || { echo "$(CANON) repo missing - run 'make clone'"; exit 1; }
	docker build -t lockboot:build   -f $(CANON)/Dockerfile.build   $(CANON)
	docker build -t lockboot:harness -f $(CANON)/Dockerfile.harness $(CANON)
	@echo ">> Built lockboot:build and lockboot:harness. The devcontainer image is built"
	@echo ">> separately by VS Code from .devcontainer/Dockerfile on 'Reopen in Container'."

# The shared build harness (build.mk + Dockerfile.build) has ONE canonical source in $(CANON) and is
# vendored byte-identically into each participating repo, because CI checks out each repo ALONE (no
# workspace parent) so the harness cannot be a cross-repo include. `sync-harness` re-propagates it;
# `check-harness` fails on drift, replacing the old manual "keep identical" discipline. vaportpm-zk is
# excluded (risc0/rzup toolchain, not lockboot:build); os402 is not yet normalized.
HARNESS_REPOS := stage1 vaportpm
HARNESS_FILES := build.mk Dockerfile.build
# stage2 vendors Dockerfile.build only (its Makefile has its own DOCKER_RUN, no build.mk).
HARNESS_DOCKERFILE_REPOS := stage2
HARNESS_PATHS := $(foreach r,$(HARNESS_REPOS),$(addprefix $(r)/,$(HARNESS_FILES))) \
                 $(addsuffix /Dockerfile.build,$(HARNESS_DOCKERFILE_REPOS))

.PHONY: sync-harness
sync-harness: ## Copy the canonical build.mk + Dockerfile.build from stage0 into stage1 + vaportpm (+ Dockerfile.build into stage2)
	@for p in $(HARNESS_PATHS); do \
		cp -v $(CANON)/$${p#*/} "$$p"; \
	done

.PHONY: check-harness
check-harness: ## Fail if any repo's build.mk / Dockerfile.build drifted from stage0's canonical copy
	@drift=0; \
	for p in $(HARNESS_PATHS); do \
		if ! cmp -s $(CANON)/$${p#*/} "$$p"; then \
			echo "DRIFT: $$p differs from $(CANON)/$${p#*/}"; drift=1; \
		fi; \
	done; \
	if [ $$drift -eq 0 ]; then \
		echo "harness OK: $(HARNESS_PATHS) identical to $(CANON)"; \
	else \
		echo ">> run 'make sync-harness' (or reconcile the canonical $(CANON) copy)"; exit 1; \
	fi

# Cloud publish/launch tooling (aws + coldsnap + gcloud + gh) for stage0/tools/publish, in a local-only
# image (tools/deploy/). Lives here, not in stage0, so using it never risks a stage0 make target
# (which would re-mint the Secure Boot keys).
#
# Credentials: browser sign-in (passkey/MFA at the IdP) at shell start, to ONLY the clouds named by
# LOGIN; sign-out/revoke on exit (tools/deploy/entry.sh). Tokens live only in the container's tmpfs
# $HOME -- never on disk, never under /src (which every lockboot:build container can read). Don't run
# builds while a logged-in shell is open: the builders are --privileged.
#   make deploy-shell LOGIN=aws|gcp|both       # sign in, interactive shell, sign out on exit
#   make deploy-shell                          # tools only, no login
#   make deploy-shell LOGIN=gcp CMD='gcloud compute images list --no-standard-images'
#   make deploy-exec CMD='aws sts get-caller-identity'   # run inside the OPEN shell (its login)
DEPLOY_IMAGE := lockboot:deploy
# Fixed container name: one deploy session at a time, reachable by `make deploy-exec`.
DEPLOY_NAME  := lockboot-deploy
# Defaults match stage0/tools/publish (ec2/*.sh ap-southeast-1, gcp/create.sh asia-southeast1).
DEPLOY_AWS_REGION  ?= ap-southeast-1
DEPLOY_GCP_REGION  ?= asia-southeast1
# -b: t2a (aarch64) is not offered in asia-southeast1-a; n2d SEV-SNP is in a/b/c.
DEPLOY_GCP_ZONE    ?= $(DEPLOY_GCP_REGION)-b
DEPLOY_GCP_PROJECT ?= lockboot
# AWS sign-in is as IAM user `lockboot` (tools/deploy/aws-iam.sh), which then assumes this role for
# all AWS calls. Set it empty to use the signed-in identity directly (root/admin, e.g. to run
# aws-iam.sh: root cannot assume roles): make deploy-shell LOGIN=aws DEPLOY_AWS_ROLE=
DEPLOY_AWS_ROLE    ?= arn:aws:iam::182712153326:role/lockboot-deploy
DEPLOY_ENV := -e AWS_REGION=$(DEPLOY_AWS_REGION) -e AWS_DEFAULT_REGION=$(DEPLOY_AWS_REGION) \
              -e CLOUDSDK_COMPUTE_REGION=$(DEPLOY_GCP_REGION) -e CLOUDSDK_COMPUTE_ZONE=$(DEPLOY_GCP_ZONE) \
              -e CLOUDSDK_CORE_PROJECT=$(DEPLOY_GCP_PROJECT) -e DEPLOY_AWS_ROLE=$(DEPLOY_AWS_ROLE)
# docker-in-devcontainer: the host daemon needs the HOST path of the /src bind (as build.mk does).
DEPLOY_HOST_WS := $(CURDIR)
ifneq ($(filter /src /src/%,$(CURDIR)),)
  DEPLOY_SRC_BIND := $(shell findmnt -fnro SOURCE --target /src 2>/dev/null | sed -n 's/.*\[\(.*\)\]$$/\1/p')
  ifneq ($(DEPLOY_SRC_BIND),)
    DEPLOY_HOST_WS := $(DEPLOY_SRC_BIND)$(CURDIR:/src%=%)
  endif
endif

.PHONY: deploy-image
deploy-image: ## Build the local lockboot:deploy image (aws CLI, coldsnap, gcloud, gh; all pinned)
	docker build -t $(DEPLOY_IMAGE) -f tools/deploy/Dockerfile tools/deploy

.PHONY: deploy-shell
# CMD is handed over verbatim via the environment ($(value) = no make expansion), so `$VAR` in it
# expands inside the container, not in make. A TTY is used whenever there is a login or no CMD.
deploy-shell: export DEPLOY_CMD := $(value CMD)
deploy-shell: deploy-image ## Shell (or CMD='...') in lockboot:deploy; LOGIN=aws|gcp|both signs in at start, out at exit
	docker run --rm --init --name $(DEPLOY_NAME) $(if $(or $(LOGIN),$(if $(CMD),,tty)),-it) -u $$(id -u):$$(id -g) \
		--tmpfs /home/deploy:rw,mode=0700,uid=$$(id -u),gid=$$(id -g) \
		-v $(DEPLOY_HOST_WS):/src $(DEPLOY_ENV) -e DEPLOY_LOGIN=$(LOGIN) -e DEPLOY_CMD -e GH_TOKEN \
		-w /src $(DEPLOY_IMAGE)

.PHONY: deploy-exec
# Run CMD inside the RUNNING deploy-shell (same tmpfs $HOME, so the same live login). Fails if no
# shell is open; the session's lifetime stays with whoever holds the interactive deploy-shell.
deploy-exec: export DEPLOY_CMD := $(value CMD)
deploy-exec: ## Run CMD='...' inside the running deploy-shell container (uses its login)
	@test -n "$$DEPLOY_CMD" || { echo "usage: make deploy-exec CMD='...'" >&2; exit 2; }
	docker exec -e DEPLOY_CMD -w /src $(DEPLOY_NAME) bash -c 'eval "$$DEPLOY_CMD"'

# Whole-chain self-test across the CURRENT checkouts of the sibling repos (whatever branch each is
# on), so a cross-repo changeset is tested together before any of it merges. Per arch, in chain
# order (each stage boots the previous stage's artifacts): build stage0 + stage1, then each repo's
# own `selftest-<arch>` (stage0 boot matrix; stage1 chain modes + smoke-args; stage2 pivot + grow).
# `selftest` also runs vaportpm's arch-independent `make ci` once, then both arches.
# x86_64 boots under KVM; aarch64 is TCG-emulated on an x86_64 host -- the same tests, and the
# boot phase takes ~12 min per arch either way.
# Logs land in each repo's build/<arch>/; the summary is printed at the end.
SELFTEST_ARCHS := x86_64 aarch64

.PHONY: selftest
selftest: ## Self-test the whole chain on both arches (+ vaportpm ci); PASS/FAIL summary
	@sum=$$(mktemp); fail=0; \
	if $(MAKE) --no-print-directory -C vaportpm ci; then echo "PASS  vaportpm  ci" >> "$$sum"; \
	else echo "FAIL  vaportpm  ci" >> "$$sum"; fail=1; fi; \
	for a in $(SELFTEST_ARCHS); do \
		$(MAKE) --no-print-directory selftest-$$a SELFTEST_SUMMARY="$$sum" || fail=1; \
	done; \
	echo "==================== workspace self-test summary"; cat "$$sum"; rm -f -- "$$sum"; \
	if [ "$$fail" = 0 ]; then echo "ALL SELF-TESTS PASSED"; else echo "SOME SELF-TESTS FAILED"; exit 1; fi

.PHONY: selftest-x86_64 selftest-aarch64
selftest-x86_64 selftest-aarch64: selftest-%:
	@sum="$${SELFTEST_SUMMARY:-/dev/null}"; fail=0; \
	step() { label="$$1"; shift; echo ">> [$*] $$label"; \
		if "$$@"; then echo "PASS  $$label" >> "$$sum"; else echo "FAIL  $$label" >> "$$sum"; return 1; fi; }; \
	step "stage0  $* build"    $(MAKE) --no-print-directory -C stage0 build-$* \
	&& step "stage1  $* build" $(MAKE) --no-print-directory -C stage1 build-$* \
	|| fail=1; \
	if [ "$$fail" = 0 ]; then \
		step "stage0  $* selftest" $(MAKE) --no-print-directory -C stage0 selftest-$* || fail=1; \
		step "stage1  $* selftest" $(MAKE) --no-print-directory -C stage1 selftest-$* || fail=1; \
		step "stage2  $* selftest" $(MAKE) --no-print-directory -C stage2 selftest-$* || fail=1; \
	fi; \
	[ "$$fail" = 0 ]

# One canonical branch ruleset applied to every governed repo (PR-gated, no force-push/deletion,
# no linear-history, per-repo CI gate) so branch protection can't drift like it did before -- plus,
# on release repos, a release-tag ruleset and immutable releases. The
# policy lives in tools/rulesets.sh (no JSON on disk); needs `gh` with admin + `jq`.
.PHONY: sync-rulesets
sync-rulesets: ## Apply the branch ruleset (+ release-tag ruleset, immutable releases) to every governed repo (needs gh admin)
	@tools/rulesets.sh sync

.PHONY: check-rulesets
check-rulesets: ## Fail if any governed repo's rulesets or immutable-releases setting drifted from the policy
	@tools/rulesets.sh check

.PHONY: clean-cache
clean-cache: ## Delete the shared cargo registry/git cache, rustup toolchains and stray target dirs
	rm -rf .cargo/registry .cargo/git .cargo/bin .cargo/.package-cache .rustup target
	@echo ">> shared caches removed (.cargo/config.toml kept)"

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
