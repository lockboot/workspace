# Reproducible builds

Lock.Boot is a **measured** boot chain: stage0 and the stage1 UKI are hashed into TPM PCRs, and an
attestation is checked against expected values. That only means anything if the same source produces
the same bytes: a verifier (or an auditor rebuilding from source) must be able to reproduce the exact
`stage0.efi` and `linux.efi` that CI published, and get the same PCRs. This file explains what makes
the builds bit-for-bit reproducible, the two non-obvious traps that broke it, and how to verify it.

Scope: the chain repos `stage0` and `stage1`. Both build inside the shared `lockboot:build` image
(`stage0/Dockerfile.build`, identical in stage1) via their Makefiles.

## What guarantees reproducibility

1. **Pinned, aligned toolchain.** Every repo's `rust-toolchain.toml` pins the *same* channel
   (currently `1.91.1`), so `rustc`/`std` are identical everywhere. rustup installs the pinned
   toolchain regardless of what the base image ships. Keep stage0 and stage1 on the same channel --
   they must produce byte-compatible signature framing, and `std`/sysroot paths are
   toolchain-version-specific.
2. **`SOURCE_DATE_EPOCH=0`.** Set in both `Dockerfile.build`s and in `stage1/tools/build-uki/build.sh`,
   so any timestamp baked into an artifact is fixed. FAT timestamps in the boot disk are separately
   normalized (`stage0/tools/normalize-fat-timestamps.py`); the UKI is assembled deterministically by
   `mkuki`.
3. **Locked dependencies.** `Cargo.lock` is committed in every crate, and the build recipes pass
   `--locked` so a build can never silently resolve newer transitive deps.
4. **Deterministic linking.** Static musl / UEFI builds use `rust-lld` + `+crt-static` via per-target
   `rustflags` in each repo's `.cargo/config.toml` (not a global `RUSTFLAGS`, which would also hit the
   host and break proc-macros). The shared workspace `/.cargo/config.toml` carries only `[env]`; each
   repo owns its rustflags (CI checks out each repo alone, so it must be self-sufficient).
5. **Path canonicalization** -- the subtle part, below.

## The two path traps

rustc embeds absolute **source paths** into binaries (panic `Location` strings, some debuginfo). If
those paths depend on the build environment, two environments building identical source produce
different bytes -- and a different measured `linux.efi` / PCR. Two such paths leaked between CI and a
local dev build; both are neutralized with `--remap-path-prefix` in the per-target `rustflags`.

### 1. `CARGO_HOME` (dependency registry paths)

CI runs with `CARGO_HOME=/tmp/.cargo` (the Makefile's `CACHE_ENV` redirect keeps caches ephemeral and
out of the bind-mounted tree under `gh act`), while a local build uses `/src/.cargo`. So dependency
sources embed as `/tmp/.cargo/registry/...` vs `/src/.cargo/registry/...`. Fix:

```toml
"--remap-path-prefix=/src/.cargo=/cargo",
"--remap-path-prefix=/tmp/.cargo=/cargo",
```

Both collapse to `/cargo`, so the build no longer depends on where `CARGO_HOME` is.

### 2. `rust-src` (std sysroot paths)

If the `rust-src` component is installed, rustc emits `std` panic-location paths from the *sysroot*
(`$RUSTUP_HOME/toolchains/<tc>/lib/rustlib/src/rust/library/core/...`) instead of the `/rustc/<hash>`
that a clean toolchain bakes in. **rust-analyzer installs `rust-src` into the shared local
`/src/.rustup`**, but CI's fresh `/tmp/.rustup` has only the pinned `rustfmt`+`clippy` -- so a local
build emitted the sysroot path where CI emitted `/rustc/<hash>`. Fix: remap the sysroot rust-src path
to that same `/rustc/<hash>`:

```toml
"--remap-path-prefix=/src/.rustup/toolchains/1.91.1-x86_64-unknown-linux-gnu/lib/rustlib/src/rust=/rustc/ed61e7d7e242494fb7057f2657300d9e77bb4fcb",
```

This is a **no-op in CI** (no rust-src there), so it only pulls a local build onto CI's existing
output. The host triple in the FROM path is always `x86_64-unknown-linux-gnu` (the build host), so one
remap covers every target arch.

> `trim-paths` (the Cargo profile option) would replace all of this cleanly, but it is still
> nightly-only as of Rust 1.91, so we use the stable `--remap-path-prefix`.

## Bumping the toolchain (READ THIS)

The rust-src remap hardcodes **the toolchain version** (FROM path) and **the rustc commit-hash** (TO).
A stale value silently becomes a no-op and reproducibility quietly regresses. On any toolchain bump:

1. Update `channel` in **every** `rust-toolchain.toml` (stage0, stage1, workspace) to the same value.
2. Get the new commit-hash: `rustc -Vv | grep commit-hash` (or grep a freshly built binary for
   `/rustc/<hash>`).
3. Update the version + hash in the rust-src `--remap-path-prefix` in **both** `stage0/.cargo/config.toml`
   and `stage1/.cargo/config.toml`.
4. Re-run the CI==local verification below -- it catches a stale hash.

## Verifying CI == local

CI uploads build artifacts on every push to `main` and on PRs (`stage0/.github/workflows/build.yml`,
`stage1/.github/workflows/build.yml`), so no merge or tag is needed.

```sh
# 1. Build locally (same repo, same commit) and note the hashes:
#    stage1:  make x86_64 stage2-x86_64   -> tools/build-uki/x86_64/{linux.efi,stage2}
#    stage0:  make build/x86_64/stage0.efi
# 2. Grab the CI artifacts from the run for that commit:
gh run download <run-id> -R lockboot/stage1 -n uki-x86_64   -D ci-s1
gh run download <run-id> -R lockboot/stage0 -n stage0-x86_64 -D ci-s0
# 3. Compare.
```

- **stage1** uploads the unsigned `linux.efi` and `stage2`: compare `sha256` directly -- they must be
  identical. (`linux.efi` matching is the acceptance test: it is the measured UKI.)
- **stage0** uploads the **db-signed** `BOOTX64.EFI` (and `boot.disk`). The Secure Boot db/PK/KEK keys
  are ephemeral snakeoil regenerated per build, so the raw bytes differ between any two builds.
  Compare the **Authenticode** hash (which excludes the signature) against a local `stage0.efi`, or --
  lacking Authenticode tooling -- grep the binary and confirm it is path-canonical (only `/cargo` and
  `/rustc/<hash>`, no `/tmp` or `/src`).

A mismatch means an environment-dependent input leaked (most likely a stale rust-src hash after a
toolchain bump, or a new dependency embedding a path the remaps don't cover).

## Known limitations

- The rust-src remap is toolchain-hash-specific (see the bump procedure).
- A definitive stage0 raw-hash comparison needs Authenticode tooling (`osslsigncode` / `pesign` /
  `sbverify`), which is not required for the path-canonical check.
- Reproducibility is relative to the pinned toolchain + the `lockboot:build` image; reproduce in that
  environment, not on an arbitrary host.
