# WIP release TODO

Outstanding items for the current release. Resolved items are removed, not ticked; git history
has them. Every cloud-platform claim cites the doc or the observed behaviour it rests on.

## This release: GCP x86_64

Scope: GCP Confidential VMs: n2d SEV / SEV-SNP and c3 TDX. EC2 and GCP Arm are out of scope
(blocked, below) and do not hold the release.

| Repo | PR | Branch |
|---|---|---|
| stage0 | lockboot/stage0#14 | `gpt-digest` |
| stage1 | lockboot/stage1#22 | `gpt-digest` |
| stage2 | lockboot/stage2#5 | `grow-then-reboot` |
| workspace | lockboot/workspace#6 | `pcr-replay-gpt-digest` |

vaportpm v0.4.1 is released; stage1 and stage2 pin it. All four PRs are draft with CI green.

In order:

- [x] **stage1 kernel bump** to Fedora CoreOS stable 44.20261023.3.1: kernel 7.2.11-200.fc44
      (from 7.0.12-201), systemd-boot stub 259.10-1.fc44 (from 259.6-1). Kernel 7.2 has no
      `hkdf` module (nvme-auth no longer needs it), so `init` and `build.sh` drop it. `build.sh`
      extracts exactly the RPMs `fedora-deps.mk` pins, and `update-fedora-deps` removes the
      previous ones: before, a bump without a clean silently rebuilt the old kernel.
      Working tree, uncommitted.
- [x] **Local `make selftest`, both arches** (2026-11-18): ALL PASS on the working trees, with
      7.2.11 confirmed in the boot logs. UKI sha256: x86_64 `e0bc2bbc860aa046`, aarch64
      `8c09afca2f37aebd`.
- [x] **GCP gate on the final heads** (2026-11-18, cloudtest `be236c1f6330`,
      `tools/cloudtest/`): n2d SEV, n2d SEV-SNP and c3 TDX each GATE PASS. Per VM, on both payload
      boots: stage1's attestation verifies (vaportpm-verify v0.4.1), its nonce is sha256(stage2),
      the quoted PCRs replay against the golden platform file with the attested GPT digest, the
      final PCRs replay with stage2's file (unsigned; covers PCR14 / PCR15), and `/data` survives
      the reboot after the provisioning reboot. stage0 `stage0-45bb278f8fed` (stage0#14 head),
      UKI `e0bc2bbc860aa046` (= CI's build of stage1#22's head), stage2#5 head plus the
      pivot-init evidence printout. Shielded (non-confidential) VMs are not tested: no AK
      certificate, so the chain stops at stage1.
- [ ] **Release tooling fixes** (working trees, uncommitted): `stage0/tools/publish/{ec2,gcp}/
      create.sh` verify with `--source-ref refs/tags/$VERSION` and `gh release verify-asset`, and
      read `os-release` as data instead of sourcing it; `stage1/tools/publish.sh` deleted
      (`lockboot-deploy create` replaces it); stage1 `release-docker` gains
      `docker/setup-qemu-action`. Tested: the two `gh` checks against vaportpm v0.4.1, the
      `os-release` parser on good, hostile and incomplete input. NOT tested: `create.sh`'s release
      path end to end and the docker job, which need a stage0 release and a stage1 tag.
- [ ] Merge the four PRs together.
- [ ] **Tag stage0, stage1, stage2** (`RELEASING.md`). These are the first tags in those repos, so
      confirm: the draft-then-publish release (proven only on vaportpm), the attestation subject
      names (`gh attestation verify --format json`), the release-notes edits made by later jobs,
      the first ghcr package push (org package-creation policy unknown), stage1's multi-arch
      `release-docker` build, and `create.sh <arch> <tag>` against the new stage0 release.

## Open

Which of these block the release is undecided.

Release tooling:

- [ ] Publish per-release cloud image IDs and the owner account / project (release notes stay
      editable under immutability).
- [ ] Single-region publish; no image deprecation / deregistration step
      (`gcloud compute images deprecate`, `aws ec2 enable-image-deprecation`).
- [ ] stage1's pre-split releases `v0.1.0` / `v0.2.0` ship an aarch64 varstore trusting Debian's
      public SnakeOil KEK + db. The user archives them in due time; check whether any AMI / GCP
      image was published from them.
- [ ] Not yet reviewed: `stage0/tools/publish/cleanup.sh`, `gcp/get-console.sh`,
      `gcp/install-gcloud.sh`.

GCP:

- [ ] **Firmware on a grown volume (untested).** After a PD resize the backup GPT is no longer at
      the disk's end. Expect the firmware to measure the primary unchanged; if it repairs or
      relocates the backup header, PCR5 / PCR2 move without stage2 writing anything. Test: stop,
      grow the PD, start; confirm the GPT digest is unchanged before stage2 acts, then the grow +
      reboot + reinit.
- [?] **`serial-port-enable=true`**: every run sets it, so whether output needs it is still
      untested (one boot with, one without, compare `get-serial-port-output`). Docs: it controls
      interactive access, off by default; if it must stay on, console input reaches the firmware
      and kernel for anyone with the project's credentials.
- [ ] Stale image `lockboot-x86-64-26-02-fc41` (2026-02-09) in project `lockboot`: delete by hand.

Docs and build:

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
- `lockboot-deploy create --args` applies to `_stage2` only. `_stage1.args` would become the UKI's
  LoadOptions, which it ignores under Secure Boot, so this is left as is.
