# Releasing

How a lockboot repo cuts a release. The governance (who may tag, immutability) is enforced by
`tools/rulesets.sh`; this is the procedure on top of it.

## Common to every release repo

Release repos: stage0, stage1, stage2, vaportpm. Release tags are plain `v*`.

- **A release is a `v*` tag on `main`**, pushed by a repo admin (the
  `lockboot-release-tags` ruleset lets only admins create one; nobody can move or delete one).
  The tag push runs the repo's workflow, which builds, attests and publishes the release. Nothing
  is uploaded by hand.
- **Releases are immutable** once published: assets and tag are locked, and GitHub signs a release
  attestation. Title, notes and the prerelease/latest flags stay editable. A bad release is
  deprecated in its notes (or deleted; its tag name can never be reused), never changed.
- **Only a merged, tested changeset is tagged.** The tag goes on the merge commit on `main`, after
  every repo in the changeset has merged (see `AGENTS.md`, Git & PR workflow).

Steps:

1. The version bump is part of the changeset's PR, not a separate one.
2. After the merge: `git checkout main && git pull --ff-only`, then
   `git tag vX.Y.Z` and `git push origin vX.Y.Z`.
3. Wait for the workflow's release job; it publishes the release.
4. Verify (below), then edit the notes: what changed and the pin line consumers use.
5. Repin the consumers (below) in their own PRs.

Verify a release:

```
gh release view vX.Y.Z -R lockboot/<repo> --json isImmutable,assets
gh release download vX.Y.Z -R lockboot/<repo> -D <empty dir>
gh attestation verify <asset> --repo lockboot/<repo>      # each asset
```

Then check that the assets are byte-identical to a local build of the tag: check out the tag and
build with the repo's Makefile release targets (`REPRODUCIBLE-BUILDS.md`), then sha256-compare.

## vaportpm

- **Version:** `vaportpm-attest` and `vaportpm-verify` share one version, bumped together in
  their `Cargo.toml`s. Pre-1.0, an API or attestation-format change bumps the minor version.
- **Assets:** static musl `vaportpm-attest` and `vaportpm-verify` for x86_64 and aarch64
  (`vaportpm-{attest,verify}-{x86_64,aarch64}-linux-musl`), all four covered by one build-provenance
  attestation. Local equivalents: `make release-x86`, `make release-aarch64`
  (`target/<arch>-unknown-linux-musl/release/`). Downloaded assets lose the executable bit.
- **Consumers** use it as a git dependency, not crates.io, pinned by commit with a version guard:
  `vaportpm-attest = { git = "https://github.com/lockboot/vaportpm", rev = "<tag's commit>", version = "=X.Y.Z" }`.
  The release notes carry this line.
  - stage1 (root `Cargo.toml`): bump `rev` and `version`, then `make update-vaportpm`.
  - stage2 (`crates/tpm-derive/Cargo.toml`): bump `rev` and `version`, then
    `make update-vaportpm`.
  - vaportpm-zk follows `branch = "main"` for now.
