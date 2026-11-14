# WIP release TODO

Working tracker for the current cross-repo release changeset, so nothing is lost from context.
Status legend: `[ ]` open, `[x]` done, `[?]` claim not yet verified against docs/behaviour.
Every cloud-platform claim must cite the doc (or observed behaviour) it was verified against.

## The changeset (one PR per repo; merge only when all pass together)

| Repo | PR | Branch |
|---|---|---|
| stage0 | lockboot/stage0#12 | `mkvarstore-port-forward` |
| stage1 | lockboot/stage1#21 | `aarch64-sysctl-arch-aliases` |
| stage2 | lockboot/stage2#2 | `resolv-conf-arch-aliases` |
| vaportpm | lockboot/vaportpm#11 | `attest-derive-subcommand` |
| workspace | lockboot/workspace#5 | `harness-sync-stage2` |

## Status 2026-11-10

- All five PRs draft, mergeable, CI green on their heads (stage0 8322629, stage1 b86bc5a, stage2
  bb96d47, vaportpm e956e5f, workspace 454744c). PR descriptions current.
- GCP x86_64 done: n2d Shielded / SEV / SEV-SNP, c3 Shielded / **TDX**. Full chain verified by
  `pcr-replay` against golden platform files on SEV, SEV-SNP and TDX (2026-11-10 regression);
  stage0 probes on Shielded n2d and c3. TDX needed direct gVNIC doorbells + the LAPIC tick
  (stage0 615b810, 34dbc69) and dropping `init_on_free=1` (stage1 b86bc5a).
- GCP project `lockboot` clean (no instances / images / objects).
- Merge gate unchanged: EC2 (AWS account still blocked) + the full suite on both arches.

## Open items 2026-11-10

Needs a decision / quick check:
- [x] **Reboot stability on GCP** (check E), 2026-11-10, pivot-init, cloudtest 7cf12890de5f
      `lb-rb-*.console.log`. **n2d SEV-SNP: PASS** (boot 2 `data_reinit=false`, sentinel present,
      overlay root ephemeral). **c3 TDX: key moves once** -- boot 2 `data_reinit=true` (/data
      wiped, pivot-init redid boot 1), boot 3 PASS (next item).
- [ ] **TDX stage2 data key binds PCR2, which now carries the GPT.** GCE TDX logs the GPT into
      PCR2 (not PCR5), and PCR2 is in `DATA_KEY_PCRS` (stage2 tpm-derive). stage2 rewrites the GPT
      on first boot, so the first reboot derives a different key and reinits `/data`; stable
      after, until a disk grow. CONFIRMED 2026-11-10 (lb-rb-tdx: boots 1-2 reinit, boot 3 PASS):
      data written on a TDX VM's first boot is lost at its first reboot. **Full plan:
      `PLAN-GPT-MEASUREMENT.md`** (leading candidate: grow -> reboot before deriving the key,
      bind PCR5 again, a volume grow wipes /data). **PARKED 2026-11-10**
      until EC2 works (NitroTPM NV behaviour is an input). Options discussed, none ideal:
      - Rejected: exclude PCR2 on TDX; accept the one-time loss; final layout at image build
        (GPT header depends on disk size); a MAC under a GPT-independent PCR-derived key (a
        foreign stage0 can mimic every PCR but PCR2).
      - Option 3, predict the post-rewrite PCRs on the setup boot and bind the key to them.
        Needs a carrier for the key across the state change; any carrier (ESP, disk, NV) is
        adversarial input -- the attack is substitution (plant a key we then use), not reading.
        a) Sealed blob + TPM creation record (CertifyCreation; creation PCRs checked against
           our chain, GPT-holding PCR rebuilt from the verified live log). Needs on-disk state.
        b) NV index holding K: authPolicy = OR(NV_Read + PolicyPCR(after), NV_Write +
           PolicyPCR(before)), attrs exactly POLICYREAD|POLICYWRITE; reader checks
           NV_ReadPublic attrs + authPolicy against its own computation, so only our full chain
           (before state) can have written K. Grow carries K over (no re-encryption). Open:
           where the pre-setup GPT digest lives, A/B indices for crash-safe grows, NV
           persistence on GCE / NitroTPM. Undefine by empty owner auth = DoS -> reinit.
      - Option 1 (last place): stage2 never rewrites the GPT (data region found by its own
        header) -- stateless, handles grows. PCR2 cannot simply be excluded on TDX: it also carries
      stage0's Authenticode.
- [ ] **PCR4 policy needs a TDX case:** anything binding stage0's identity via PCR4 (sealing,
      attestation policy) must use PCR2 on TDX.
- [x] **stage1 `stage0-snippet.json`**: DROPPED (stage1 46d2bd0); `lockboot-deploy create` +
      docs produce the `_stage1` document.

Follow-ups (filed / tracked):
- [ ] **GPT event digest as attestation aux data** -- lockboot/vaportpm#12: vaportpm-attest reads
      it from the event log, vaportpm-verify carries it (incl. the flat zkVM format), **matching
      vaportpm-zk change** (commit it in `ZkPublicInputs`), pcr-replay takes an event's digest from
      it (open design, workspace `tools/pcr-replay/README.md`). Then PCR2 and PCR5 pin on every
      boot, TDX and non-TDX; until then replay reproduces them on first boots only.
- [ ] **`init_on_free=1` kills the TD on GCE TDX** (silent reset; dropped, `init_on_alloc=1` kept).
      Root cause parked. A triple fault and a TD kill look the same from inside; a #DF handler
      that dumps state before the triple fault would tell them apart.
- [ ] **GCP Arm (t2a):** firmware has no network stack above SNP (no MNP/IP4/DHCP4/TCP4); stage0
      would need to embed one. No t2a PCRs until then.
- [ ] **EC2** (blocked on the AWS case): platform golden files (`tools/pcr-replay/EC2-NOTES.md`),
      recreate the AMI (predates the PCR7 owner-GUID fix), ENA logging / `[S.mmm]` timestamps,
      ENA ExitBootServices quiesce (below).
- [ ] stage0 `REPRODUCIBLE-BUILDS.md`: varstore notes.
- [ ] No Makefile target for the verbose gvnic build (`--features verbose`).
- [ ] Blog: the gvnic post gains the TDX story (BAR2 doorbells, PIT-less TD, LAPIC tick).

After the release:
- [ ] **TDX quote / SNP report as supplementary attestation** (like Nitro's NSM document): bind the
      vTPM attestation to hardware evidence. Unattested in-guest claims (CPUID etc.) are not used.

## Status 2026-11-05 (end of GCP day)

- Merge gate: AWS account restriction (support case) -> then the full suite across EC2 + GCP,
  both arches where supported, before any PR merges. All PRs stay open/draft until then.
- GCP x86 done for Shielded / SEV / SEV-SNP (stage0 PR #12: 34bd6fa db8caab b3df2b0 aeecd8d);
  TDX + t2a open (below). GCP project `lockboot` cleaned: no instances/images/objects; buckets
  `lockboot` + `lockboot-test` kept empty (test keeps its allUsers grant).
- Blog draft (uncommitted, outside the build): `wavebend.org/drafts/2026-11-05-gcp-gvnic.md`.
  After merge: decide extra sections (UDP4 RecycleSignal, dbx), and add a correction note to the
  ENA post (it says GCP's OVMF brings up virtio-net -- no longer true).

## Up next (queued)

- [x] **stage0 gVNIC UEFI driver** -- DONE (stage0 #12; TDX too: 615b810 doorbells, 34dbc69 LAPIC
      tick). Original note: (embedded + measured like `ena.efi`). GCP enforces gVNIC for
      Confidential VMs AND Arm (t2a) -- API, observed 2026-11-05: "Confidential Compute VMs
      cannot use VIRTIO_NET. They must use GVNIC." / t2a: "Only [[GVNIC, UNSPECIFIED_NIC_TYPE]]
      nic types are allowed". GCP's UEFI firmware has no gVNIC driver (only virtio-net), so
      with gVNIC stage0 dies at `no EFI_IP4_CONFIG2 ... NOT_FOUND`. Blocks GCP SNP + GCP aarch64.
      Spec references: Linux `gve`, DPDK gve PMD. Until then GCP x86 = Shielded VM on virtio-net
      (test only); `launch-instance.sh` hard-codes GVNIC (introduced 7f1bc44 with the ENA
      driver, never booted on GCP since).
- [ ] **ENA ExitBootServices quiesce** (gvnic half DONE: full teardown -- DESTROY_TX/RX,
      UNREGISTER_PAGE_LIST, DECONFIGURE -- then reset, from an EBS event). ENA: later issue. `ena.efi` never resets the device
      at ExitBootServices, so RX DMA stays posted into boot-services memory the OS reuses. Linux
      evidently copes on EC2 (its driver resets at probe), but the window between EBS and the ENA
      probe is a real DMA-into-freed-memory hazard. gvnic registers an EBS event -> reset
      handshake from the start; port the same to ena.
- [x] **dbx A/B** -- DONE (resolved below: `dbx.auth.bin`). Original note: (after the DeployedMode question): `mkvarstore.py` emits `dbx.esl` (same
      placeholder already in efi-vars.{ovmf,aws}); `gcp/create.sh --forbidden-database-file`;
      confirm GCP's "BIN" = full EFI_SIGNATURE_LIST by comparing PCR 7 / the dbx event.

## GCP x86 matrix 2026-11-05 (gvnic driver, image A = GCP default dbx)

Spot, asia-southeast1-b, probe payload, sha256 PCRs (first 16 hex). All stable across reboots.
**Superseded** by workspace `tools/pcr-replay/platforms/gcp/` (captures + golden replay files,
2026-11-09/10), which also covers TDX. Kept as the 11-05 record.

| Config | Machine | Net/payload | PCR0 | PCR1 | PCR2,3,6 | PCR4 | PCR5 | PCR7 | PCR14 |
|---|---|---|---|---|---|---|---|---|---|
| Shielded | n2d-standard-2 | OK (6 boots) | d0c70a93 | 09b32fdf | 3d458cfe | 4fd748b2 | 170cbfef | c05a3c37 | 090f86bc |
| SEV | n2d-standard-2 | OK | a0b5ff33 | 2c4b6392 | 3d458cfe | 4fd748b2 | 170cbfef | c05a3c37 | 090f86bc |
| SEV-SNP | n2d-standard-2 (Milan) | OK | 50597a27 | 2c4b6392 | 3d458cfe | 4fd748b2 | 170cbfef | c05a3c37 | 090f86bc |
| Shielded | c3-standard-4 | OK | d0c70a93 | 1e0e29fc | 3d458cfe | 4fd748b2 | 170cbfef | c05a3c37 | 090f86bc |
| TDX | c3-standard-4 | **DHCP timeout** (11-05); OK 11-09 | 0cca9ec1 | baef2b3d | GPT + stage0 land in PCR2 | BDS action + sep only | sep only | | |
| local QEMU (our dbx) | | OK | 62852b26 | c3cc3083 | 3410b993/3d458cfe | 4fd748b2 | 170cbfef | 965cb27a | 090f86bc |

- PCR0 varies by confidential type; PCR1 by machine type / confidential-vs-not. PCR4 (stage0),
  PCR5 (GPT), PCR14 (payload) are portable across GCP configs AND local QEMU; PCR7 is uniform
  across GCP configs for one image (keys + dbx fixed).
- [x] **TDX: gvnic probe all PASSED + link up, but no packets (DHCP 30 s timeout).** RESOLVED
      2026-11-09. The QPL shared/private theory below was wrong. Two causes: (1) GCE backs the
      doorbell BAR2 as memory; under TDX EDK2's `PciIo.Mem` is a TDVMCALL MMIO hypercall that
      never reaches it -> direct stores to the BAR's host address (615b810); (2) GCE firmware
      ticks from the PIT/8259 and a TD gets no IRQ0, so no UEFI timer event ever fired -> LAPIC
      tick when the firmware tick is dead (34dbc69). Original note: Not the queue
      format (c3 Shielded works in GQI_QPL with the same device options 0x3+0x4). TDX-specific:
      AQ DMA works, data-path DMA doesn't -- look at shared/private conversion of the large QPL /
      ring buffers under TDX's IoMmu. Deferred.
- [ ] (deferred, 2026-11-10: GQI_QPL works on every platform we need) **DQO** (0x4) offered on c3 alongside GQI_QPL; not needed (GQI_QPL carries traffic). Revisit
      only if a series stops offering 0x3.
- [x] **dbx on GCP: RESOLVED.** A bare EFI_SIGNATURE_LIST as fileType BIN is accepted at image
      create but kills every VM at start (`compute.instances.hostError` ~8 s, all configs incl.
      TDX, console "Unknown CPU Platform"). GCP's BIN dbx is an AUTHENTICATED variable update
      (`EFI_VARIABLE_AUTHENTICATION_2` || ESL, as uefi.org DBXUpdate.bin used in RHEL's GCP docs),
      signed by an enrolled KEK. Build now emits `dbx.auth.bin` (mkvarstore.py `--out-dbx-auth`,
      KEK-signed via `openssl cms -noattr`, fixed timestamp) -- reproducible for a given key set,
      ESL byte-identical to efi-vars.{ovmf,aws}. Verified through gcp/create.sh: boots, PCR7
      `ee5f65dc` (an X.509 dbx entry also boots: PCR7 `09992522`; default dbx: `c05a3c37`).
- [x] **PCR7 GCP vs QEMU differs with identical dbx bytes** (`ee5f65dc` vs `965cb27a`). ROOT CAUSE
      (2026-11-06): GCP wraps the PK/KEK/db .cer we upload in an ESL with a fixed, undocumented
      SignatureOwner `d281fad2-8d88-47a4-9792-5baa47bb1b89` (seen in go-tpm-tools' GCE test event
      logs, cos-101 + ubuntu-2404); we used random per-key GUIDs (gen-keys.sh `uuidgen`). Event
      sequence is otherwise identical (SecureBoot, PK, KEK, db, dbx, separator, db authority) --
      offline replay (scratchpad gce-evlog/bin/predict.py) reproduces BOTH values exactly. FIX
      (committed, stage0 #12): gen-keys.sh writes GCP's GUID for all three; dev build/keys/*.guid rewritten.
      VERIFIED on QEMU: PCR7 `965cb27a` -> `ee5f65dc` (= GCP), PCR0-6/14 unchanged. EC2 pending
      (expected `ee5f65dc` too: efi-vars.aws comes from the same mkvarstore). The AMI
      `ami-04abef7162f90706e` predates the fix -> recreate. Follow-up DONE: predicted PCRs are a
      build output (`stage0.replay.json` + `pcrs.json`, stage0 #12).
- gcp/create.sh bugs found + fixed (committed, stage0 #12): `images list --filter=name=X` is a pattern match
  (X matched X-defdbx) -> exact `images describe`; gcloud types key files by extension (`.bin` ->
  BIN, else must be DER X.509) -> dbx passed as a `.bin` copy.
- [x] Signed BOOT*.EFI is not byte-reproducible across re-signings -- BY DESIGN: the Secure Boot
  keys are deliberately ephemeral (minted per build), so the signed binary differs per build.
  PCR4 (Authenticode hash) is unaffected.

## Findings 2026-11-05 (GCP day)

- stage0 DeployedMode gate refused every GCP boot: GCP can only provision PK/KEK/db/dbx, firmware
  boots in User Mode. Fixed in stage0 be996b4: require SecureBoot=1, SetupMode=0, AuditMode
  0/absent; accept User or Deployed. stage0 never writes DeployedMode.
- Local QEMU (our edk2): `AuditMode` absent, `DeployedMode` = our preset plain NV|BS variable
  (attrs 0x03), `SecureBoot`/`SetupMode` BS|RT -- this edk2 does not implement the UEFI 2.5
  modes; DeployedMode=1 on QEMU/EC2 was never firmware-enforced.
- A guest power-off leaves a GCP spot VM STOPPED (not deleted; `--max-run-duration` timer is
  cleared on stop). Manifest + cleanup.sh required.
- GCP org policy `iam.allowedPolicyMemberDomains` blocked allUsers; overridden on project
  `lockboot` only (2026-11-05). `gs://lockboot-test` = public-read payload mirror.
- `t2a` not offered in asia-southeast1-a -> default zone now `-b` (workspace Makefile).
- `lockboot-deploy create --args` applies to `_stage2` only; no way to set `_stage1` args
  (used jq for the probe). Test-only gap: `_stage1.args` become the chain-loaded EFI image's
  LoadOptions, which our UKI ignores under Secure Boot (stage0 `config.rs`); only a non-UKI stage1
  such as the stage0 test payload reads them. LEAVE (2026-11-10).
- Follow loops: stopping the host `docker exec` does not stop the in-container process; run
  followers under in-container `timeout`.

## Release gate

- [x] Local `make selftest`, both arches (x86_64 KVM, aarch64 TCG): ALL PASS (before the getcap
      fix; getcap fix verified by a single fresh-vTPM boot, no `core` file).
- [x] Tag rulesets (`lockboot-release-tags`, `refs/tags/v*`) + immutable releases: applied live,
      `make check-rulesets` ok on all 6 repos.
- [x] Release attestation covers zip contents (+ `qemu-test.sh`) via `subject-checksums`.
- [ ] Cloud serial-console check, 4 cells: {EC2, GCP} x {x86_64, aarch64}. GCP x86_64 DONE
      (2026-11-09/10, all lines present); EC2 both blocked (AWS case); GCP aarch64 blocked (no
      network stack in the t2a firmware). Per cell look for
      `stage0:` lines, kernel printk, `init:` lines, `stage1:` lines, stage2 loader lines.
      (See `CONSOLE-OUTPUT.md` Phase 2.) Watch userspace lines: `/dev/console` = last
      registered `console=`.
- [ ] (later -- user archives them in due time) stage1 old releases `v0.1.0` / `v0.2.0` (pre-split, from lockboot/lockboot): both ship an
      aarch64 varstore trusting Debian's public SnakeOil KEK + db (verified by parsing their
      `efi-vars.ovmf`). Decide: delete (recommended) or deprecate. Check whether any AMI / GCP
      image was ever published from them; deregister if so.
- [ ] (later, at the first tag) First tagged release: confirm attestation subject names (`gh attestation verify
      --format json`), that release-notes edits still work under immutability, and the new-ghcr-
      package push (org package-creation policy unknown).
- [ ] (later, when it comes up) stage1 `release-docker` builds arm64 without `docker/setup-qemu-action` (the stage0 harness
      and stage2 erofs-builder jobs add it). Likely broken the same way; untested.

## Cloud verification matrix (day plan)

Goal: the full chain (stage0 -> UKI -> stage1 -> packed stage2 loader -> `pivot-init`) boots,
is captured on the serial console, and survives an in-guest reboot on all four cells. Fill the
results table as you go; each `[?]` / experiment below resolves a tracked item.

### 0. Prep (local, once, before any cloud)

**STALE (2026-11-04):** stage0 has been rebuilt many times since; these hashes describe nothing
current. **Prep builds DONE 2026-11-04 18:30** (step 1 below; all four make steps ok). Snapshot -- if any of
these change, stage0 was rebuilt and every AMI / GCP image made earlier is stale:

| File | x86_64 sha256 (16) | aarch64 sha256 (16) |
|---|---|---|
| stage0 `BOOT*.EFI` | `99104de5ff746e61` | `40e8d596c36eb5ba` |
| stage0 `boot.disk` | `5f4b143de40e2642` | `7bea0a26a45f47d2` |
| stage0 `efi-vars.ovmf` | `04ae1c84463b731c` | `25e1cbf68ef26276` |
| stage0 `efi-vars.aws` | `8f8ea21083b3d435` | `8f8ea21083b3d435` (arch-independent) |
| stage0 `db.cer` (shared keys) | `47cd8e40b46dbe81` | `47cd8e40b46dbe81` |
| stage0 `BUILD_ID` | `stage0-99104de5ff74` | `stage0-40e8d596c36e` |
| stage1 `linux.efi` | `8b9a120e7c34f8d2` | `a75b5113b1333395` |
| stage2 `pack/stage2` | `2eea48a4353a5536` | `444cf15f12d14cfd` |

**Do NOT run any `make -C stage0 ...` while a cloud image built from the current keys is in use**
(still true by default; `HAZMAT_WARNING_NO_REGEN_KEYS_DEV_ONLY=1` reuses `build/keys` for dev
loops, refused under CI, never for a release) -- not just builds: any target that depends on the keys (`build-*`, `boot-*`, `smoke-boot-*`, `selftest-*`) regenerates
PK/KEK/db (observed: keys re-minted at 15:33 by a boot test and at 18:29 by this build), which
re-signs `BOOT*.EFI` and rewrites the varstores. (`gcp/create.sh` now names images by `BUILD_ID`,
faa8604, so it no longer silently reuses an old image.) stage1/stage2 makes are safe (UKI hashes reproduce exactly).

0. **Tooling: DONE (`lockboot:deploy` image built 2026-11-05).** All cloud work runs in
   `make deploy-shell` (workspace Makefile; never `make -C stage0 ...`). Image =
   `tools/deploy/Dockerfile`: aws CLI 2.39.4, coldsnap 0.12.0, gcloud 592.0.0, gh 2.103.3, jq/curl/unzip,
   all sha256-pinned. `/src` = workspace; `$HOME` = per-run tmpfs. Defaults: AWS `ap-southeast-1`,
   GCP project `lockboot`, `asia-southeast1` / `asia-southeast1-b` (201b614; t2a is not offered in -a) (override `DEPLOY_AWS_REGION`,
   `DEPLOY_GCP_PROJECT`, `DEPLOY_GCP_REGION`, `DEPLOY_GCP_ZONE`).
   **Credentials = browser sign-in (passkey) at shell start, only to the clouds you name; sign-out on
   exit.** Tokens exist only in the container's tmpfs (`tools/deploy/entry.sh`):
   ```bash
   make deploy-shell LOGIN=both     # or LOGIN=aws / LOGIN=gcp; keep ONE shell open for the day
   ```
   - AWS (current, 91902d6): sign-in as IAM user `lockboot` (passkey MFA), which can only assume role
     `lockboot-deploy` (least-privilege EC2/EBS-direct/S3; `tools/deploy/aws-iam.sh`). Original
     (root) notes: `aws login --remote` (console sign-in incl. passkey MFA; temp creds auto-refresh, session
     <= 12 h then re-login). IAM principal needs `SignInLocalDevelopmentAccess`, plus: `ec2`
     image/snapshot/instance/tag/console-output actions, `ebs:StartSnapshot/PutSnapshotBlock/
     CompleteSnapshot` (coldsnap), S3 put on the hosting bucket. Profile `default` wraps the login via
     `credential_process`, so aws/coldsnap/scripts need no `AWS_PROFILE`. Exit: `aws logout --all`.
   - GCP: `gcloud auth login --no-launch-browser`. The refresh token does NOT expire on its own
     (unless Cloud Identity "Google Cloud session control" is set) -> exit runs `gcloud auth revoke
     --all` (server-side). Needs Compute Instance Admin + Compute Storage Admin (images) + Storage
     Object Admin on the bucket.
   - Exit = `exit` / Ctrl-D in the shell (trap also fires on INT/TERM/HUP). If the container is
     killed hard (`docker kill`, host crash) no revoke runs: revoke the gcloud grant manually.
   - The container is named `lockboot-deploy` (`--rm`: gone on exit; one session at a time).
     `make deploy-exec CMD='...'` runs inside the open shell with its login (how Claude runs
     commands: read-only freely, ask before anything that creates/modifies/deletes or costs money;
     cloud test VMs follow AGENTS.md "Cloud test runs").
   - Builds while a logged-in shell is open: allowed by the user (2026-11-09). Originally avoided
     because builders are `--privileged` and could read the shell's tmpfs.
   - gh (release mode only; local-build mode doesn't need it): `GH_TOKEN` env passthrough.
1. All five repos on their PR branches (table above). Build once:
   ```bash
   make -C stage0 build-x86_64 build-aarch64      # boot.disk, efi-vars.{ovmf,aws}, *.cer
   make -C stage1 build-x86_64 build-aarch64      # tools/build-uki/<arch>/linux.efi
   make -C stage2 pack-x86_64 pack-aarch64        # build/<arch>/pack/stage2 (loader + pivot-init)
   make -C stage1 deploy-bin                      # target/x86_64-unknown-linux-musl/debug/lockboot-deploy
   ```
   (Done -- see the snapshot above. Remaining: step 2, which needs the hosting base URL.)
2. Host the UKI + stage2 over **plain http://** (stage0 has no TLS), publicly readable: an S3
   bucket (`http://<bucket>.s3.<region>.amazonaws.com`) or GCS (`http://storage.googleapis.com/<bucket>`).
   Do NOT use `stage1/tools/publish.sh` or the release `stage0-snippet.json` -- both emit a
   `_stage1` doc stage0 rejects (no `payload` wrapper, https). Use `lockboot-deploy`, which
   enforces http:// and the `payload`/`manifest` schema, and merges both arches into one doc:
   ```bash
   D=stage1/target/x86_64-unknown-linux-musl/debug/lockboot-deploy
   for a in x86_64 aarch64; do
     $D create --arch $a --uki stage1/tools/build-uki/$a/linux.efi \
       --stage2 stage2/build/$a/pack/stage2 --base-url http://<host>/<prefix> --out deploy/
   done
   $D validate deploy/user-data.json      # both hops, both arches
   # upload deploy/<arch>/* so URLs are <base>/<arch>/<file>
   ```
   One `deploy/user-data.json` serves all four cells (stage0/stage1 pick their arch's entry).
3. Record every created resource: pass `--manifest teardown.txt` to both `create.sh`; at day's
   end `stage0/tools/publish/cleanup.sh --dry-run teardown.txt` then without `--dry-run`.

### 1. Cells

| Cell | Machine | Security config to launch with |
|---|---|---|
| EC2 x86_64 | `c6i.large` | AMI: UEFI + NitroTPM v2 + IMDSv2 + our `--uefi-data` (set by `create.sh`) |
| EC2 aarch64 | `c7g.medium` | same |
| GCP x86_64 | `n2d-standard-2` | `--confidential-compute-type=SEV_SNP --min-cpu-platform="AMD Milan" --maintenance-policy=TERMINATE` + shielded secure boot/vTPM/integrity |
| GCP aarch64 | `t2a-standard-1` | Shielded VM (secure boot, vTPM, integrity) -- confidential type per experiment G2 |

**Script blockers to fix (or bypass with a manual command) before the cell runs:**
- EC2 (both): NOT a blocker for pivot. `boot.disk` is 66 MiB (64 MiB ESP + GPT); EBS sizes in
  whole GiB, so the AMI's root volume is 1 GiB, leaving ~900 MiB beyond the image for p2 + `/data`
  -- well past pivot-init's 64 MiB base check. Gap for real deployments (and any cloud grow test):
  `ec2/launch.sh` has no root-volume size option and no arg passthrough
  (`--block-device-mappings` needs a launch.sh option or a manual `aws ec2 run-instances`).
- GCP x86_64: FIXED (stage0 faa8604) -- n2d now `SEV_SNP` + `--min-cpu-platform="AMD Milan"`,
  `--no-service-account --no-scopes`.
- GCP aarch64: FIXED (stage0 faa8604) -- t2a is Shielded VM only; G2 passes
  `--confidential-compute-type=CCA` as a trailing option.
- Also fixed in faa8604: GCP image name now includes `BUILD_ID` (no stale reuse); `--manifest`
  records only resources the run created; instances recorded (`ec2/launch.sh --manifest`,
  `gcp/launch-instance.sh --manifest` FIRST arg) + `cleanup.sh` deletes them (GCP instances do
  not self-delete); `ec2/launch.sh --tail-timeout`; `get-console.sh --follow` byte offsets.
- Pre-existing GCP image `lockboot-x86-64-26-02-fc41` (2026-02-09, old build) -- not ours to
  sweep automatically; delete by hand if unwanted.
- GCP (both): `--boot-disk-size` can be added via `launch-instance.sh`'s trailing passthrough args.

### 2. Per-cell checks (columns of the results table)

- **A. Publish:** `create.sh <arch>` succeeds; record AMI / image ID.
- **B. Launch config actually applied:** EC2 `aws ec2 describe-images` (BootMode, TpmSupport,
  ImdsSupport) / GCP `gcloud compute instances describe` (`confidentialInstanceConfig`,
  `shieldedInstanceConfig`, `serviceAccounts`).
- **C. Console capture** (grep the retrieved console; mirrors `CONSOLE-OUTPUT.md` step 5):
  C1 `stage0:` lines (UEFI ConOut); C2 kernel `Linux version` + `console [...] enabled`;
  C3 `init:` lines; C4 `stage1:` lines; C5 stage2 loader lines; C6 `PIVOT_TEST=`.
- **D. Admission:** stage0 admitted the UKI; stage1 admitted stage2 (log lines).
- **E. Reboot stability:** `PIVOT_TEST=PASS` -- boot 2 re-derived the same `/data` key (bound PCRs
  stable across reboot on this platform -- the Nitro/GCP PCR5 caveat in `stage2/PCR-BINDING.md`)
  and the overlay root was ephemeral. If it FAILs with "sentinel missing", the derived key moved:
  capture which PCRs differ (no probe for this exists any more -- reboot-probe was deleted in
  stage2 9167e6e; compare the two boots' attestation docs, or add a probe). On GCE TDX expect one
  FAIL on the first reboot: the GPT lands in PCR2, which the data key binds (Open items).
- **F. Attestation:** pivot-init `[attest] stage1=... stage2=present`.
- **G. Confidential compute evidence** (GCP x86_64): kernel line like `Memory Encryption Features
  active: AMD SEV SEV-ES SEV-SNP` (proves SNP, not just SEV).

### 3. Experiments (resolve open `[?]` items)

- **G1. `serial-port-enable`** (GCP x86_64, cheap): one boot WITHOUT it, one WITH; compare
  `get-serial-port-output`. Decides whether it stays (user observation: needed for output; docs:
  interactive access only).
- **G2. Arm confidential compute** (GCP aarch64): try `--confidential-compute-type=CCA` on
  `t2a-standard-1`, and on `c4a-standard-1` if available in the zone; record the exact error /
  success. Then the Shielded-VM-only launch for the actual cell.
- **G3. No service account** (GCP, either arch): launch with `--no-service-account --no-scopes`,
  confirm the chain is unaffected (nothing in stage0/1/2 should call GCP APIs).
- **G4. PCR7 per platform:** note PCR7 from each cell's attestation (GCP gets Microsoft's dbx, see
  below) -- input to "publish expected PCRs per release".

### 4. Results

| Cell | A publish | B config | C1 stage0 | C2 kernel | C3 init | C4 stage1 | C5 loader | C6/E pivot | F attest | G | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| EC2 x86_64 | | | | | | | | | | n/a | |
| EC2 aarch64 | | | | | | | | | | n/a | |
| GCP x86_64 | ok | ok | ok | ok | ok | ok | ok | SNP PASS; TDX PASS after one reinit | ok | SNP, TDX | 2026-11-09/10: SEV, SEV-SNP, TDX full chains; E: lb-rb-snp, lb-rb-tdx |
| GCP aarch64 | | | | | | | | | | | |

Experiments: G1 = ; G2 = ; G3 = ; G4 = .

Afterwards: copy the C-columns into `CONSOLE-OUTPUT.md`'s matrix. Its "Local QEMU aarch64" row
predates the PL011 capture fix in stage0#12 -- UEFI ConOut is now captured locally on aarch64 too.

## Deployment posture review (AWS + GCP)

### Breaks a deployment

- [x] **stage1 `_stage1` snippet is rejected by stage0.** DROPPED (stage1 46d2bd0). (Was: build.sh:317-320.
      Added in stage1 e3c8f57, 2026-06-21, "stage0 netboot rework", as a fill-in template next to
      `linux.efi`; CI uploads it (build.yml:54). Superseded by `lockboot-deploy create`. Decide:
      drop it, or fix it.) `stage1/tools/build-uki/build.sh:306-309`
      (writes `stage0-snippet.json`, a release-zip asset) and `stage1/tools/publish.sh:88-94` emit
      `"<arch>": { "url", "sha256" }` with `https://`. stage0 requires `{ "payload": { ... } }`
      (`stage0/crates/stage0/src/config.rs:80-84`) and http:// only (`config.rs:160-164`).
      Verified against stage0 source.
- [x] **GCP aarch64 passes the wrong confidential-compute flag.** FIXED (stage0 faa8604: t2a is
      Shielded only; CCA only as an explicit trailing option). `gcp/launch-instance.sh:154-170`
      uses `--confidential-compute` for `t2a-*` (comment: "ARM TrustZone"). VERIFIED (gcloud
      `compute instances create` reference): `--confidential-compute` is DEPRECATED and means
      `--confidential-compute-type=SEV` -- AMD-only, cannot apply to Arm. The type enum DOES include
      `CCA` ("Arm Confidential Compute Architecture"), but no public doc names a machine series for
      it (supported-configurations and the CVM overview list only AMD/Intel series; the Arm-on-
      Compute page says nothing about confidential or shielded VMs). Unresolved: whether any Arm
      series (T2A, C4A, N4A) accepts `CCA` -> settle with a real launch attempt in the cloud check.
      Hardware note (unverified): CCA needs Armv9 RME; T2A is Neoverse N1 (Armv8.2).
- [x] **GCP x86_64 gets SEV, not SEV-SNP.** FIXED (stage0 faa8604: n2d -> SEV_SNP + AMD Milan, c2d
      -> SEV, c3 -> TDX). `launch-instance.sh:126-127` passes
      `--confidential-compute-type=SEV` for n2d/c2d; README + image `SEV_SNP_CAPABLE` claim SNP.
      VERIFIED (Create a Confidential VM instance doc): SNP = `--confidential-compute-type=SEV_SNP`
      + N2D + `--min-cpu-platform="AMD Milan"` + `--maintenance-policy=TERMINATE`. SEV = C2D, N2D,
      C3D, C4D. SNP is N2D-only (supported-configurations). TDX = c3-standard, c4-standard,
      a3-highgpu-1g. Decide: SNP-only on N2D, or SEV/SNP/TDX by machine type.
- [x] **GCP image reuse keyed on `VERSION_ID`, not `BUILD_ID`.** FIXED (stage0 faa8604: the image
      name includes `BUILD_ID`). `gcp/create.sh:157`: a local
      rebuild (new keys, new BUILD_ID, same VERSION_ID) silently returns the old image. README
      claims BUILD_ID matching (true for EC2 only). Verified against the script.

### Security posture

- [x] **Dedicated AWS deploy role; stop using root.** DONE (workspace 91902d6): IAM user `lockboot`
      (passkey MFA) -> role `lockboot-deploy`, converged by `tools/deploy/aws-iam.sh`; verified
      except launches (account still blocked). (2026-11-05: root `aws login` from a VPN
      egress tripped AWS fraud detection and the account was restricted -> support case.) Shape:
      an IAM user (console sign-in + passkey MFA, `SignInLocalDevelopmentAccess`, nothing else)
      that may only `sts:AssumeRole` into a `lockboot-deploy` role, conditioned on
      `aws:MultiFactorAuthPresent`. The role carries least privilege, scoped by
      `aws:RequestedRegion` = ap-southeast-1:
      ec2 Describe*/RegisterImage/DeregisterImage/ModifyImageAttribute/CreateTags/
      Delete+ModifySnapshotAttribute/RunInstances/TerminateInstances/GetConsoleOutput (+ the
      `iam:PassRole`-free defaults; no instance profile is attached), `ebs:StartSnapshot`/
      `PutSnapshotBlock`/`CompleteSnapshot` (coldsnap), `s3:PutObject`/`PutObjectAcl`/
      `DeleteObject`/`ListBucket` on `lockboot-ap-southeast-1` `test/*` (+ the release prefix).
      `entry.sh` then writes `[profile deploy] role_arn=... source_profile=login` and points
      `default`'s `credential_process` at it. Decide: IAM user + role (above) vs IAM Identity
      Center permission set (`aws configure sso`; also passkey, but its token cache lives in the
      tmpfs $HOME and needs re-login per shell -- same as now).
- [x] **GCP instances get the project's default service account.** FIXED (stage0 faa8604:
      `--no-service-account --no-scopes`). `launch-instance.sh` passes no
      `--service-account` / `--no-service-account --no-scopes`. VERIFIED (gcloud reference + service
      accounts doc): without them the VM gets the Compute Engine default SA
      (`PROJECT_NUMBER-compute@developer.gserviceaccount.com`) with scopes devstorage.read_only,
      logging.write, monitoring.write, service.management.readonly, servicecontrol, trace.append;
      that SA "might automatically be granted" project Editor (org-policy dependent; blocked by
      default for orgs created after 2024-05-03). The attested workload can mint tokens for it from
      the metadata server. Fix: `--no-service-account --no-scopes` (both flags exist). Confirm
      nothing in stage0/1/2 needs GCP API access first.
- [?] **GCP `serial-port-enable=true`: KEEP, still unresolved.** (2026-11-10: every probe set it,
      so G1 is still unrun. Fast-power-off guests additionally use `serial-port-logging-enable=true`,
      read back from Cloud Logging -- AGENTS.md "Cloud test runs".) User observation: without it
      nothing was captured. Docs (VERIFIED, interactive serial console page): it controls
      INTERACTIVE serial console access, "disabled by default"; when on, "clients can attempt to
      connect ... from any IP address" with a project/instance SSH key + `iam.serviceAccountUser`.
      The serial-output page never mentions it (output logging to Cloud Logging is a separate key,
      `serial-port-logging-enable`). Docs do not say whether it affects output -- they don't
      contradict the observation. Settle in the cloud check: one boot with, one without, compare
      `get-serial-port-output`. If it must stay on, the residual risk is console INPUT reaching
      firmware/kernel (e.g. UEFI ConIn) for anyone with those credentials.
- [ ] **Release verification lacks signer pinning.** DECIDED (2026-11-10): `--source-ref
      refs/tags/$VERSION` + `gh release verify-asset` (neither depends on the workflow file's
      location; the tag ruleset makes the ref meaningful). Not `--signer-workflow`. Testable only
      against a tagged, immutable release. ec2/create.sh, gcp/create.sh,
      stage1/tools/publish.sh run `gh attestation verify --repo` only. Add `--signer-workflow`,
      `--source-ref refs/tags/$VERSION`; consider `gh release verify-asset`. `GH_REPO` comes from
      `git remote get-url origin` (a fork verifies against the fork).
- [ ] **`source os-release` executes the downloaded file as shell.** (Still true 2026-11-10:
      gcp/create.sh:165; line numbers below are old.) ec2/create.sh:151,
      gcp/create.sh:153; unverified code under `--no-verify`. Parse keys instead.
- [x] **EC2 `--no-secure-boot` debug AMI is public by default** (`PUBLIC=true`). BY DESIGN (user,
      2026-11-10): ec2/create.sh is public by default; `--private` opts out.

### Release distribution & lifecycle (decisions, not fixes)

- [ ] Publish per-release cloud image IDs + owner account / project (release notes stay
      editable). Expected PCRs: DONE via the replay files each release ships
      (stage0/stage1/stage2 `*.replay.json`) + workspace golden platform files.
- [ ] stage1/tools/publish.sh uploads to a fixed `linux-<arch>.efi`: republishing breaks instances
      pinned to the old sha256 (fail closed). Content-address or version the object; bucket must
      be publicly readable over plain HTTP (not set or checked).
- [ ] Single-region publish; no image deprecation/deregistration step
      (`aws ec2 enable-image-deprecation`, `gcloud compute images deprecate`).

- [x] **GCP dbx is Microsoft's, not ours -> PCR7 differs per platform.** RESOLVED: we pass our own
      dbx (`dbx.auth.bin`, `--forbidden-database-file`); see "dbx on GCP" above. VERIFIED (Creating
      shielded images doc): custom certs "overwrite the default ones rather than merging"; for any
      field left unset (we set PK/KEK/db, not dbx) GCP supplies its default -- for dbx the
      Microsoft DBX revocation list. Harmless to admission, but PCR7 (which measures dbx) will not
      match EC2/local (our placeholder dbx). Publish expected PCR7 per platform, or pass our own
      dbx via `--forbidden-database-file`. Format: DER X.509 (our `.cer` files are DER).

### Verified good (keep)

- EC2 AMI: UEFI, NitroTPM v2, IMDSv2-only, our `--uefi-data`; launches attach no instance profile.
- GCP: `--maintenance-policy=TERMINATE` (required for SNP per the CVM create doc), Shielded
  Secure Boot + vTPM + integrity monitoring.
- Both clouds: our own PK/KEK/db enrolled (GCP: replaces Google/Microsoft defaults, verified).
- gVNIC on GCP Arm: T2A supports only NVMe + gVNIC (VERIFIED, Arm-on-Compute page); the script
      already sets `nic-type=GVNIC` and the image `GVNIC`.

### Docs consulted (GCP)

- gcloud `compute instances create` reference (flags: confidential-compute[-type], service
  account/scopes, min-cpu-platform)
- Confidential VM: supported configurations; create a Confidential VM instance; overview
- Compute Engine: viewing serial port output; interactive serial console; Arm VMs; service
  accounts; Shielded VM; creating shielded images (custom keys)

### Not yet reviewed

- `stage0/tools/publish/cleanup.sh`, `gcp/get-console.sh`, `gcp/install-gcloud.sh`.
