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
- **The workflow creates the release as a draft with its assets, then publishes it** (`gh release
  edit --draft=false`). A published release takes no uploads, so publishing first ships it empty
  (vaportpm v0.4.0).
- **Only a merged, tested changeset is tagged.** The tag goes on the merge commit on `main`, after
  every repo in the changeset has merged (see `AGENTS.md`, Git & PR workflow).
- **Every release is created as a prerelease** (`prerelease: true` in each workflow).

Steps:

1. A version bump is part of the changeset's PR, not a separate one.
2. After the merge: `git checkout main && git pull --ff-only`, then
   `git tag vX.Y.Z` and `git push origin vX.Y.Z`.
3. Wait for the workflow's release jobs. The first publishes the release; the others push the
   container images, and in stage0 and stage2 append the image digest to the release notes.
4. Verify (below), then edit the notes: what changed and what consumers pin.
5. vaportpm only: repin the consumers in their own PRs. The stages do not pin each other.

Verify a release. The provenance must come from a build of the release's own tag (only admins
create `v*` tags, and none can be moved), and each file must be an asset of the immutable release:

```
gh release view vX.Y.Z -R lockboot/<repo> --json isImmutable,isDraft,assets
gh release download vX.Y.Z -R lockboot/<repo> -D <empty dir>
# each asset:
gh attestation verify <asset> --repo lockboot/<repo> --source-ref refs/tags/vX.Y.Z
gh release verify-asset vX.Y.Z <asset> -R lockboot/<repo>
# each container image, by the digest in the release notes:
gh attestation verify oci://ghcr.io/lockboot/<image>@sha256:<digest> --repo lockboot/<repo> \
    --source-ref refs/tags/vX.Y.Z
```

Then compare with a local build of the tag: check out the tag, build with the Makefile targets the
repo's section names, and sha256-compare (`REPRODUCIBLE-BUILDS.md`).

## stage0

- **Assets:** `stage0-x86_64.zip`, `stage0-aarch64.zip` and `qemu-test.sh`. A zip holds, flat:
  `boot.disk`, the db-signed `BOOT*.EFI`, `efi-vars.{ovmf,aws}`, `dbx.esl`, `dbx.auth.bin`, the
  `PK` / `KEK` / `db` certificates and owner GUIDs, `pcrs.json`, `stage0.replay.json` and
  `os-release`. One build-provenance attestation covers the zips, every file inside them
  (subjects named `<arch>/<file>`) and `qemu-test.sh`, so an extracted file verifies on its own.
- **Secure Boot keys:** the build job mints PK / KEK / db and uploads only the certificates, so
  every release has its own keys and the signed files differ between any two builds.
- **Version:** `crates/stage0`'s crate version is printed at boot (`stage0: version: ...`) and so
  is part of the measured binary.
- **Image:** `ghcr.io/lockboot/stage0-harness:<tag>` (multi-arch QEMU test harness), attested.
  `release-harness` appends its digest to the release notes; consumers pin the digest.
- **Local equivalents:** `make build-x86_64`, `make build-aarch64` (`build/<arch>/`). The signed
  files cannot match; compare PCR4 in `pcrs.json`, which follows from the Authenticode hash of
  `BOOT*.EFI` and does not depend on the keys.
- **After the release:** a cloud image is made from the release, never from a local build. In the
  deploy shell (`make deploy-shell-gcp`): `stage0/tools/publish/gcp/create.sh <arch> vX.Y.Z`. It
  downloads the zip, runs the two checks above on it, and creates the image
  `lockboot-<arch>-<VERSION_ID>-<BUILD_ID>` from the zip's `os-release`. EC2 is the same with
  `ec2/create.sh`. One region; image IDs are not published; no deprecation step.

## stage1

- **Assets:** `uki-x86_64.zip` and `uki-aarch64.zip`. A zip holds, flat: `linux.efi`,
  `linux.efi.sha256`, `stage1.replay.json`, `os-release`, `busybox`, `stage1` and `stage2` (the
  example stage2). One build-provenance attestation covers the zips and every file inside them
  (subjects named `<arch>/<file>`).
- **`linux.efi`** is the UKI stage0 admits by sha256 and the firmware measures. It is unsigned.
- **Image:** `ghcr.io/lockboot/stage1:<tag>` (multi-arch, busybox + `stage1`), attested by
  `release-docker`. Its digest is not written to the release notes.
- **Version:** the `os-release` embedded in the UKI carries `yy.mm`, taken from the committer
  date (UTC) of the commit being built, so the tag's commit fixes it.
- **Local equivalents:** `make x86_64 stage2-x86_64`, `make aarch64 stage2-aarch64`
  (`tools/build-uki/<arch>/`, and `build/<arch>/stage2`); compare sha256 directly.
- The kernel and systemd-boot stub are pinned in `tools/build-uki/fedora-deps.mk` (`AGENTS.md`,
  Ops).

## stage2

- **Assets:** `stage2-loader-x86_64`, `stage2-loader-aarch64` and `stage2.replay.json`, covered by
  one build-provenance attestation.
- **Image:** `ghcr.io/lockboot/stage2-erofs-builder:<tag>` (multi-arch, both loaders baked in),
  attested. `release-erofs-builder` appends its digest and the loaders' sha256 to the release
  notes; consumers pin the digest (stage2 `README.md`).
- **Local equivalents:** `make pack-x86_64`, `make pack-aarch64`.
  `target/<arch>-unknown-linux-musl/release/bootstrap` is `stage2-loader-<arch>`, and
  `tools/stage2.replay.json` is the replay file.

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
