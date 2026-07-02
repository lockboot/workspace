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
REPOS := \
	lockboot=$(GITHUB_BASEURL)/lockboot.git \
	os402=$(GITHUB_BASEURL)/os402.git \
	stage0=$(GITHUB_BASEURL)/stage0.git \
	vaportpm=$(GITHUB_BASEURL)/vaportpm.git \
	vaportpm-zk=$(GITHUB_BASEURL)/vaportpm-zk.git

# The canonical build Dockerfiles live in stage0 (the reference project; the copy
# in lockboot is kept byte-identical). Build the shared "lockboot family" images
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

.PHONY: clean-cache
clean-cache: ## Delete the shared cargo registry/git cache, rustup toolchains and stray target dirs
	rm -rf .cargo/registry .cargo/git .cargo/bin .cargo/.package-cache .rustup target
	@echo ">> shared caches removed (.cargo/config.toml kept)"

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
