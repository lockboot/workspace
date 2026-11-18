# WIP release TODO

Outstanding items for the current release. Resolved items are removed, not ticked; git history
has them. Every cloud-platform claim cites the doc or the observed behaviour it rests on.

## This release: GCP x86_64

Scope: GCP Confidential VMs: n2d SEV / SEV-SNP and c3 TDX. EC2 and GCP Arm are out of scope
(blocked, below) and do not hold the release.

The changeset is merged (2026-11-18): lockboot/stage0#14, lockboot/stage1#22, lockboot/stage2#5
and lockboot/workspace#6, on vaportpm v0.4.1, which stage1 and stage2 pin.

In order:

- [x] **stage1 kernel bump** to Fedora CoreOS stable 44.20261023.3.1: kernel 7.2.11-200.fc44
      (from 7.0.12-201), systemd-boot stub 259.10-1.fc44 (from 259.6-1). Kernel 7.2 has no
      `hkdf` module (nvme-auth no longer needs it), so `init` and `build.sh` drop it. `build.sh`
      extracts exactly the RPMs `fedora-deps.mk` pins, and `update-fedora-deps` removes the
      previous ones: before, a bump without a clean silently rebuilt the old kernel.
- [x] **Local `make selftest`, both arches** (2026-11-18): ALL PASS on the final trees (stage0
      without the debug record, commit-date `os-release` in stage0 and stage1, Fedora tag from
      the pinned kernel). UKI sha256: x86_64 `fecbe639b4bb9fa0`, aarch64 `fef50d8d91a5510f`;
      unsigned `stage0.efi`: x86_64 `888872691851329e`, aarch64 `d025bcc8739882e3`. CI's builds
      of the same heads are byte-identical on both arches (stage0 through PCR4 and the unsigned
      body; every file in stage1's artifact).
- [x] **GCP gate on the final heads** (2026-11-18, cloudtest `be236c1f6330`,
      `tools/cloudtest/`): n2d SEV, n2d SEV-SNP and c3 TDX each GATE PASS. Per VM, on both payload
      boots: stage1's attestation verifies (vaportpm-verify v0.4.1), its nonce is sha256(stage2),
      the quoted PCRs replay against the golden platform file with the attested GPT digest, the
      final PCRs replay with stage2's file (unsigned; covers PCR14 / PCR15), and `/data` survives
      the reboot after the provisioning reboot. stage0 `stage0-45bb278f8fed` (stage0#14 head),
      UKI `e0bc2bbc860aa046` (= CI's build of stage1#22's head), stage2#5 head plus the
      pivot-init evidence printout. Shielded (non-confidential) VMs are not tested: no AK
      certificate, so the chain stops at stage1. The run predates two byte changes: stage0 without
      the linker's debug record, and the UKI's `os-release` version string. Not re-run (decided
      2026-11-18): the mechanisms are unchanged and the replay is reproducible end to end.
- [ ] **Tag stage0, stage1, stage2** (`RELEASING.md`). Not yet: the user decides when, and the
      versions (a crate version bump changes the UKI bytes; the release is what the tag builds).
      These are the first tags under the release workflows, so confirm: the draft-then-publish
      release (proven only on vaportpm), the attestation subject names (`gh attestation verify
      --format json`), the release-notes edits made by later jobs, the first ghcr package push
      (org package-creation policy unknown), stage1's multi-arch `release-docker` build with
      `docker/setup-qemu-action`, and `stage0/tools/publish/{ec2,gcp}/create.sh <arch> <tag>`
      against the new stage0 release (its `--source-ref refs/tags/<tag>` and `gh release
      verify-asset` checks are tested only against vaportpm v0.4.1).

## Open

Which of these block the release is undecided.

- [ ] `CONSOLE-OUTPUT.md` matrix is out of date: local aarch64 UEFI ConOut is captured now
      (`stage0/build/aarch64/boot-*.log` carry the `stage0:` lines), and GCP x86_64 captured all
      three paths (2026-11-09/10). The EC2 rows wait on AWS (below).
- [ ] `REPRODUCIBLE-BUILDS.md` says nothing about the varstores.
- [ ] No Makefile target for the verbose gvnic build: `STAGE0_FEATURES=verbose` enables stage0's
      own feature, which does not forward to the `gvnic` crate's.
- [ ] `pcr-replay` cannot reproduce PCR14 in stage1's attestation: stage1 quotes before it extends
      PCR14 with stage2 (stage2 is bound through the nonce).

## Blocked on AWS

- [ ] **EC2 cells** (`c6i.large`, `c7g.medium`): platform replay files
      (`tools/pcr-replay/EC2-NOTES.md`); recreate the AMI (`ami-04abef7162f90706e` predates the
      PCR7 owner-GUID fix; expected PCR7 `ee5f65dc`, as on GCP); the full chain and the reboot
      test on both arches. Per cell: image attributes applied (BootMode, TpmSupport, ImdsSupport),
      console lines from every stage, admission at both hops, `PIVOT_TEST=PASS` across a reboot,
      `[attest] stage1=... stage2=present`.
- [ ] **Console capture on EC2 aarch64** (`CONSOLE-OUTPUT.md`): whether stage0's UEFI ConOut
      reaches the captured serial there is the open question; x86_64 is a confirmation pass.
- [ ] **Nitro PCR5.** NitroTPM's profile defines PCR5 as "Boot Manager Code Configuration and
      Data and GPT". The data key binds PCR5, so capture an EC2 event log and confirm what else
      lands there.
- [ ] **ENA ExitBootServices quiesce.** `ena.efi` never resets the device at ExitBootServices, so
      RX DMA stays posted into boot-services memory the OS reuses until Linux's driver resets it
      at probe. gvnic does the full teardown from an EBS event; port the same to ena.
- [ ] ENA logging / `[S.mmm]` timestamps.
- [ ] `ec2/launch.sh` has no root-volume size option and no argument passthrough (needed for any
      grow test; the AMI's root volume is 1 GiB).
- [ ] The `lockboot-deploy` IAM role (`tools/deploy/aws-iam.sh`) is verified except for launches.

## Deferred

- [ ] **GCP Arm (t2a):** the firmware has no network stack above SNP (no MNP / IP4 / DHCP4 /
      TCP4); stage0 would have to embed one. No t2a PCRs until then. Also unrun: whether any Arm
      series accepts `--confidential-compute-type=CCA`.
- [ ] **`init_on_free=1` kills the TD on GCE TDX** (silent reset; dropped, `init_on_alloc=1`
      kept). Root cause unknown. A triple fault and a TD kill look the same from inside; a #DF
      handler that dumps state first would tell them apart.
- [ ] gVNIC DQO: offered on c3 next to GQI_QPL and not needed. Revisit only if a series stops
      offering GQI_QPL.
- [ ] vaportpm-zk's `Cargo.lock` pins vaportpm 0.1.0 (785438f) though its manifest follows
      `branch = "main"`; re-lock and re-run its tests when it is next touched.
- [ ] After the release: a TDX quote / SNP report as supplementary attestation (like Nitro's NSM
      document), binding the vTPM attestation to hardware evidence.

## Notes not recorded elsewhere

- Do not run any `make -C stage0` target that depends on the keys (`build-*`, `boot-*`,
  `smoke-boot-*`, `selftest-*`) while a cloud image built from the current keys is in use: it
  re-mints PK / KEK / db, re-signs `BOOT*.EFI` and rewrites the varstores.
  `HAZMAT_WARNING_NO_REGEN_KEYS_DEV_ONLY=1` reuses `build/keys` for dev loops only.
- GCP project `lockboot`: the org policy `iam.allowedPolicyMemberDomains` is overridden on this
  project only, so `gs://lockboot-test` can be a public-read payload mirror. Buckets `lockboot`
  and `lockboot-test` are kept empty between runs.
- Stopping the host `docker exec` does not stop the in-container process: run console followers
  under an in-container `timeout`.
- Decided 2026-11-18, pre-release software: no per-release cloud image IDs are published, images
  are published to one region, and there is no image deprecation step. stage1's `v0.1.0` /
  `v0.2.0` are pre-releases and stay as they are.
- `lockboot-deploy create --args` applies to `_stage2` only. `_stage1.args` would become the UKI's
  LoadOptions, which it ignores under Secure Boot, so this is left as is.
