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

.PHONY: sync-harness
sync-harness: ## Copy the canonical build.mk + Dockerfile.build from stage0 into stage1 + vaportpm
	@for r in $(HARNESS_REPOS); do \
		for f in $(HARNESS_FILES); do \
			cp -v $(CANON)/$$f "$$r/$$f"; \
		done; \
	done

.PHONY: check-harness
check-harness: ## Fail if any repo's build.mk / Dockerfile.build drifted from stage0's canonical copy
	@drift=0; \
	for r in $(HARNESS_REPOS); do \
		for f in $(HARNESS_FILES); do \
			if ! cmp -s $(CANON)/$$f "$$r/$$f"; then \
				echo "DRIFT: $$r/$$f differs from $(CANON)/$$f"; drift=1; \
			fi; \
		done; \
	done; \
	if [ $$drift -eq 0 ]; then \
		echo "harness OK: build.mk + Dockerfile.build identical across $(CANON) $(HARNESS_REPOS)"; \
	else \
		echo ">> run 'make sync-harness' (or reconcile the canonical $(CANON) copy)"; exit 1; \
	fi

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
