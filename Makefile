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
	vaportpm-zk=$(GITHUB_BASEURL)/vaportpm-zk.git

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

# Whole-chain self-test across the CURRENT checkouts of the sibling repos (whatever branch each is
# on), so a cross-repo changeset is tested together before any of it merges. Per arch, in chain
# order (each stage boots the previous stage's artifacts): build stage0 + stage1, then each repo's
# own `selftest-<arch>` (stage0 boot matrix; stage1 chain modes + smoke-args; stage2 pivot + grow).
# `selftest` also runs vaportpm's arch-independent `make ci` once, then both arches.
# x86_64 boots under KVM; aarch64 is TCG-emulated on an x86_64 host -- slow, but the same tests.
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
# no linear-history, per-repo CI gate) so branch protection can't drift like it did before. The
# policy lives in tools/rulesets.sh (no JSON on disk); needs `gh` with admin + `jq`.
.PHONY: sync-rulesets
sync-rulesets: ## Apply the canonical branch ruleset to every governed repo (needs gh admin)
	@tools/rulesets.sh sync

.PHONY: check-rulesets
check-rulesets: ## Fail if any governed repo's branch ruleset drifted from the policy
	@tools/rulesets.sh check

.PHONY: clean-cache
clean-cache: ## Delete the shared cargo registry/git cache, rustup toolchains and stray target dirs
	rm -rf .cargo/registry .cargo/git .cargo/bin .cargo/.package-cache .rustup target
	@echo ">> shared caches removed (.cargo/config.toml kept)"

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
