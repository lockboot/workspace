# Lock.Boot workspace conventions

Working conventions for the Lock.Boot repos. This workspace clones the sub-repos as siblings (see
`README.md`); these conventions apply across all of them. Loaded by Claude Code via `CLAUDE.md`
(`@AGENTS.md`) and readable by any agent that reads `AGENTS.md`. Personal, per-user settings live in
`CLAUDE.local.md` (gitignored), not here.

## Memory & preferences

Record durable knowledge in this repo, not in machine-local per-project agent memory (that store is
opaque, unversioned, and does not travel with a checkout):

- **A shared convention or project fact** -> add it here in `AGENTS.md`. It is tracked, so the change
  shows up in the diff and is reviewed when committed -- keep entries terse and factual, and update or
  remove stale ones rather than piling on.
- **A per-user preference or personal fact** (identity, how an individual likes to work) -> put it in
  `CLAUDE.local.md` (gitignored). It may not exist on a fresh checkout -- create it if you need it.
- Prefer both of these over the global auto-memory so the knowledge stays auditable and shared.

## Repos

Measured secure-boot chain: **stage0** (UEFI netboot root of trust) -> **stage1** (netboot UKI, PID-1
loader) -> **stage2** (the payload; the reference stage2 is a payload-agnostic loader -- see its own
`README.md`). Plus **vaportpm** / **vaportpm-zk** (from-scratch TPM 2.0), **workspace** (this repo),
and **.github** (org profile, cloned here as `dotgithub`).

Out of scope -- do not fold into the chain or org overviews: **os402** (dormant prior project) and
**wavebend.org** (the commercial arm, under `HarryR/`, not the `lockboot` org).

## Building & testing

- **Only through the Makefile.** The build/run environment is a specific docker orchestration (shared
  `lockboot:build` / `lockboot:harness` images, `/src` mounts, shared `CARGO_HOME`/`RUSTUP_HOME`,
  same-user, KVM/iptables) driven by each repo's Makefile plus the shared `build.mk` (canonical copy
  in stage0, vendored via `make sync-harness`). Never hand-roll `docker run` or bare `cargo`/`docker`
  builds -- the host has no C toolchain outside the image. If a needed check has no Makefile target,
  ask rather than improvise.
- **gnu-host vs musl.** Everything compiles inside `lockboot:build` (gcc + glibc). `rust-lld` cannot
  link glibc *executables* (only self-contained musl/uefi), so gnu-host repos (vaportpm) leave the
  host linker as `cc` and use `rust-lld` + `crt-static` only for musl targets.

## Reproducibility (CI == local, byte-identical)

- `rustflags` live in each repo's **per-target `.cargo/config.toml`**, never a global `ENV RUSTFLAGS`.
  Cargo **concatenates** `rustflags` across config files, so never duplicate a target's flags in both
  the workspace and a sub-repo config (it doubles `-Cmetadata` -> different bytes).
- Byte-parity relies on `--remap-path-prefix` (CARGO_HOME + the rust-src sysroot). **The rust-src
  remap hardcodes the toolchain version and the rustc commit-hash -- update it in stage0 AND stage1
  on every `rust-toolchain.toml` bump**, and keep both repos on the same channel. `SOURCE_DATE_EPOCH=0`.
  Detail in `REPRODUCIBLE-BUILDS.md`; verify a change by sha256-comparing a PR-run artifact against a
  local build.

## CI & branch governance

- Every code repo has a **`ci`** workflow job = `make ci` (fmt-check + `clippy -D warnings` + tests).
  Arch build jobs are named **`build-x86_64` / `build-aarch64`** (clean check contexts, no
  spaces/parens).
- One canonical branch ruleset, **`lockboot-main`**, is applied to every repo by **`tools/rulesets.sh`**
  (`make sync-rulesets` / `make check-rulesets`): PR required (0 approvals), no force-push, no branch
  deletion, **no linear history** (merge commits allowed), admin bypass; required checks =
  `ci build-x86_64 build-aarch64` (stage0/1/2), `ci` (vaportpm), none (.github / workspace). `sync`
  also deletes any legacy differently-named ruleset. `make check-rulesets` catches drift and is the
  source of truth for branch protection -- change the policy in the script, not the GitHub UI.

## Git & PR workflow

- **Commit identity:** use your own GitHub noreply identity (name from `gh api user`, email
  `{id}+{login}@users.noreply.github.com`), set per-repo (`git config`, not `--global`). Never commit
  with the agent/session contact email.
- **Commit messages and PR bodies are plain ASCII** -- no em dashes or smart punctuation; use `-`,
  `--`, `->`, straight quotes. (`git log -1 --format=%B | grep -nP '[^\x00-\x7F]'` should print nothing.)
- **Open PRs as draft** (`gh pr create --draft`); the author marks them ready.
- **Merge with a merge commit** (`gh pr merge <n> --merge --delete-branch`), not squash (squash is
  disabled; the ruleset allows merge commits on every repo, workspace included).
- **After a merge, `git checkout main && git pull --ff-only` before new work** -- never keep committing
  on a merged branch (its remote is deleted on merge, so new commits diverge and need re-branching).

## Audience & framing

Assume security-literate contributors. Be explicit about threat models, trust boundaries, and
adversarial thinking rather than hand-waving them, and assume fluency in the domains this project
touches -- TPM / measured boot, UEFI, the Linux kernel, `no_std`, syscalls, and cryptography. Skip
introductory framing; be precise.

## Working norms

Implement the literal ask, minimally. No unrequested scope: no invented guards, validation, struct
fields, or "nice to have" constraints. On non-trivial changes, show the diff and wait for approval
rather than applying autonomously; surface a risk (e.g. an unbounded loop) as a question instead of
silently adding a fix. When answering a question, answer only that.

## Ops

Bump stage1's UKI kernel + systemd-boot stub with `make update-fedora-deps FCOS=<ver> [SYSTEMD=<nvr>]`
(regenerates the generated `tools/build-uki/fedora-deps.mk` -- do not hand-edit). koji's `packages/`
path serves **unsigned** RPMs; the tooling uses `data/signed/` and GPG-verifies against the per-release
key in `tools/build-uki/keys/` (the trust anchor -- commit and fingerprint-verify a new `fNN` key
before bumping the Fedora major).
