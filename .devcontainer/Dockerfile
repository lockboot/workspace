# Lock.Boot workspace devcontainer - the environment you EDIT and DRIVE builds from.
#
# It deliberately does NOT contain the Rust build toolchain, qemu, swtpm, etc.
# Reproducible builds run in the `lockboot:build` image and stage0's boot tests in
# `lockboot:harness`, both spawned via `docker run` from each repo's Makefile
# (docker-outside-of-docker over the bind-mounted host socket). This image's only
# jobs are: give you a shell + the docker CLI to launch those, and give
# rust-analyzer a cargo/rustc that resolves into the shared /src/.rustup.
#
# Built by VS Code on "Reopen in Container" (see devcontainer.json). Lean on purpose.
FROM debian:trixie-slim

# Prerequisites for fetching the GitHub CLI apt key over https - the slim base
# has neither curl nor ca-certificates, so this must come BEFORE we reach out.
RUN apt-get -qq update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	ca-certificates curl gnupg && \
	rm -rf /var/lib/apt/lists/*

# GitHub CLI apt repo (same approach as lockboot's Dockerfile.dev, via curl).
RUN mkdir -p -m 755 /etc/apt/keyrings /etc/apt/sources.list.d \
	&& curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
		-o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
		> /etc/apt/sources.list.d/github-cli.list

# Interactive/driver tooling only. docker-cli = just the CLI that talks to the
# HOST daemon via the mounted socket (Trixie split the client out of docker.io,
# which now ships only dockerd - we don't want a daemon in here). docker-buildx =
# the `docker buildx` CLI plugin (separate package); BuildKit itself runs in the
# HOST daemon, so this is client-side only. python3-venv is for wavebend.org's site.
RUN DEBIAN_FRONTEND=noninteractive apt-get -qq update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	wget git gh jq make \
	docker-cli docker-buildx \
	bash-completion less nano procps iproute2 openssh-client \
	python3 python3-venv && \
	rm -rf /var/lib/apt/lists/*

# rustup, os402-style: install the proxies to a throwaway home, move them onto
# PATH (/usr/local/bin), then discard rustup's own dirs. No toolchain is baked
# (--default-toolchain none); cargo/rustc/rustup proxies resolve the real
# toolchain lazily into the SHARED /src/.rustup per each repo's rust-toolchain.toml.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
	RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo \
	sh -s -- -y --no-modify-path --profile minimal --default-toolchain none && \
	mv /usr/local/cargo/bin/* /usr/local/bin/ && \
	rm -rf /usr/local/rustup /usr/local/cargo

# dev user whose HOME is the bind-mounted workspace (= /src). uid/gid default to
# 1000 but are overridden per-host at BUILD time via build args from the generated
# docker-compose.host.yml, so the baked passwd/group entry matches the RUNTIME
# `user:` (compose) on any machine. Without this, a host uid != 1000 runs as a uid
# with no /etc/passwd entry ("I have no name!", broken getpwuid/git/ssh lookups).
# NOTE: we never `USER dev` - the image stays root and compose's `user:` sets the
# runtime uid; this entry exists purely so that uid resolves to a name. The docker
# (134)/kvm (120) group memberships are supplied at RUNTIME via compose group_add,
# so they are intentionally not created here.
ARG USER_UID=1000
ARG USER_GID=1000
RUN if ! getent group ${USER_GID} >/dev/null; then groupadd -g ${USER_GID} dev; fi && \
	useradd -u ${USER_UID} -g ${USER_GID} -d /src -s /bin/bash dev

# Shared homes + reproducible defaults, matching lockboot:build so the caches and
# toolchains rust-analyzer touches are exactly the ones the build image uses.
ENV HOME=/src \
	CARGO_HOME=/src/.cargo \
	RUSTUP_HOME=/src/.rustup \
	PATH=/src/.cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
	SOURCE_DATE_EPOCH=0 \
	HISTFILE=/dev/null

WORKDIR /src
