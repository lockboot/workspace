# Lock.Boot workspace

The reproducible dev environment for the multi-repo [Lock.Boot](https://github.com/lockboot)
project. Clone this one repo, open it in VS Code, "Reopen in Container", and you have every
sub-project checked out with a **single shared Cargo/rustup home and registry cache** — no
per-repo toolchain copies, and **no Docker volumes** (everything is a bind mount).

## Quick start

```bash
git clone https://github.com/lockboot/workspace.git
cd workspace
make clone          # clone the sub-repos (with their submodules)
make image          # build the local lockboot:build + lockboot:harness images (needs Docker)
code .              # open in VS Code, then: "Reopen in Container"
# inside the container:
cd stage0 && make build-x86_64
```

## Layout

```
workspace/                (= /src inside the devcontainer)
├── .cargo/config.toml    # shared, reproducible cargo config (tracked)
├── .cargo/registry ...   # shared crate cache (generated, gitignored)
├── .rustup/              # shared toolchains, incl. risc0 (generated, gitignored)
├── rust-toolchain.toml   # default toolchain; each repo's own file wins by nearest
├── Makefile              # clone / pull / status / image / clean-cache
├── .devcontainer/        # the lean "driver" container (see below)
├── dotgithub/  os402/  stage0/  stage1/  vaportpm/  vaportpm-zk/  wavebend.org/   # plain clones
```

The sub-repos are **plain clones, not git submodules** of this workspace — they're managed by
the `Makefile`. (Some of them have their *own* submodules; `make clone`/`make pull` recurse
those for you.)

`CARGO_HOME=/src/.cargo` and `RUSTUP_HOME=/src/.rustup` point at the workspace root, so all
sub-repos share one registry download cache and one set of toolchains. Each repo still keeps its
own `target/` (we share the registry, not build outputs).

## The three images (don't conflate them)

| Image | Purpose | Where it's defined | Builds Rust? |
|-------|---------|--------------------|:---:|
| `lockboot:build` | Reproducible Rust builds: pinned toolchain, identical `/src/.cargo`+`/src/.rustup` paths, static-musl RUSTFLAGS. | `Dockerfile.build`, kept **byte-identical in each project** (canonical copy in `stage0`) so CI can build each repo standalone. | ✅ |
| `lockboot:harness` | Lean QEMU runner for stage0's boot tests (boots a disk, mocks EC2 metadata). Entrypoint-baked. | `stage0/Dockerfile.harness` | ❌ |
| **workspace devcontainer** | The environment you **edit in and drive builds from**: bind `/src`, host network, docker-outside-of-docker, `/dev/kvm`. | `.devcontainer/Dockerfile` (this repo, lean) | ❌ |

**Builds do not happen in the devcontainer.** You run `make` in the devcontainer; the Makefiles
`docker run` the `lockboot:build` / `lockboot:harness` images against the host daemon. This is
deliberate: a slim host or CI runner (e.g. `act`) may lack `rpm2cpio`/`cpio`/`curl`/`xz`, and
under nested docker the build's `target/` only exists inside the build container — so the tools
and extraction must live in the build image, which also guarantees the reproducible environment.

The devcontainer carries no Rust build toolchain of its own; it installs `rustup` with the
proxies on `PATH` but **no** toolchain baked, so `rust-analyzer` resolves `cargo`/`rustc` lazily
into the shared `/src/.rustup` (same toolchains the build image uses).

**Nothing machine-specific is hardcoded.** The devcontainer uses the docker-compose form so that
`user:` and `group_add:` come from a generated override,
[`docker-compose.host.yml`](.devcontainer/prepare-env.sh), which
[`prepare-env.sh`](.devcontainer/prepare-env.sh) regenerates on every start (an
`initializeCommand`) from *your* `id -u`/`id -g` and the gids that actually own
`/var/run/docker.sock` and `/dev/kvm` on this host. So the container runs as your uid:gid (correct
bind-mount ownership) and can reach docker + KVM regardless of what those gids are on a given
machine. The generated override is gitignored (and is a `.yml`, not a `.env`, so editor tooling
leaves it alone). Requires the **Dev Containers** VS Code extension
(`ms-vscode-remote.remote-containers`), Docker Compose **v2**, and a running host Docker daemon.

The `lockboot:*` images are **built locally and never published** — `make image` builds them
from `stage0` (the canonical/reference project).

## Make targets

| Target | What it does |
|--------|--------------|
| `make clone` | Clone any missing sub-repos (with submodules). Default target. |
| `make pull` | Fast-forward every sub-repo and refresh its submodules. |
| `make status` | Short `git status` + branch for each sub-repo. |
| `make image` | Build `lockboot:build` + `lockboot:harness` from `stage0` (needs Docker). |
| `make clean-cache` | Remove the shared cargo/rustup caches + stray `target/` (keeps `.cargo/config.toml`). |

## Toolchain & target policy

- `rust-toolchain.toml` here pins a **default** (`1.91.1`); each sub-repo's own
  `rust-toolchain.toml` wins by nearest-file (e.g. stage1 `1.91.0`, stage0 `1.91.1`). The
  risc0 guest in `vaportpm-zk` uses its own `rzup`-managed toolchain. All install once into the
  shared `.rustup`.
- `.cargo/config.toml` sets `SOURCE_DATE_EPOCH=0` and static-musl link flags that **only bind
  when a musl target is opted into**. It deliberately sets **no** global `[build] target` and
  **no** gnu-host linker override, so the gnu-host repos (`vaportpm`, the risc0 host crate) and
  the Python site (`wavebend.org`) are never forced into musl/`rust-lld`. Repos that want
  musl-by-default (stage1, os402) set it in their own config.

## Known follow-ups

- The per-repo `.devcontainer/` dirs in `os402` and `vaportpm` are now redundant (the workspace
  devcontainer is authoritative); they can be removed in each of those repos when convenient.
  (`stage1` already dropped its own as part of the lockboot → stage1 conversion.)
