# Plan: the GPT measurement, the /data key, and the verifier

Status: **draft for decision, parked 2026-11-10** (pondering; EC2 still blocked). Written so it
survives a context compaction: every fact, rejected option and open question from the
2026-11-10 discussion is here. Tracker item: `WIP-RELEASE-TODO.md`, "TDX stage2 data key binds
PCR2". Companion verifier issue: lockboot/vaportpm#12.

## 1. Facts

### What the firmware measures

- `EV_EFI_GPT_EVENT` = `H_bank(UEFI_GPT_DATA)`: the **primary** GPT header (92 bytes: disk
  GUID, MyLBA, AlternateLBA, First/LastUsableLBA, entry-array LBA/count/size, entry-array
  CRC32, header CRC32) + a UINT64 partition count + every used 128-byte entry (type GUID,
  unique GUID, start/end LBA, attributes, name). The whole table, not just the disk GUID.
  Built in `stage0/tools/predict-pcrs.py` `gpt_data()` and `tools/pcr-replay/pcr-replay.py`
  `gpt_data()`. EDK2: `Tcg2MeasureGptTable` (DxeTpm2MeasureBootLib), measured once per boot.
- The image's GPT (`boot.disk`) is 228 bytes of measured data: 92 + 8 + 128 (ESP only).
- The firmware does **not** measure ESP filesystem contents; only `BOOT*.EFI` (Authenticode).
  stage0 does not read the ESP filesystem (no SimpleFileSystem use in stage0's crates).

### Where it lands

| Platform | GPT event | stage0 Authenticode | Evidence |
|---|---|---|---|
| QEMU/OVMF, GCE Shielded / SEV / SEV-SNP | PCR5 (after its separator; PCR5 holds nothing else) | PCR4 | captures in `tools/pcr-replay/platforms/gcp/captures/` |
| **GCE TDX** (c3) | **PCR2** (after PCR2's separator, before the Authenticode) | **PCR2** | `captures/2026-11-09-c3-standard-4-tdx.log` |
| EC2 Nitro | PCR5 expected; Nitro's profile defines PCR5 as "Boot Manager Code Configuration and Data **and** GPT" -- may hold more | PCR4 expected | unverified (AWS blocked) |

GCE TDX looks like logging by CC measurement register (TCG CC mapping: PCR2-6 -> RTMR1, "MR
index 2") reflected into the vTPM as PCR2. Same firmware binary as c3 Shielded.

### stage2's GPT rewrite and the data key (today)

- `stage2/crates/blockdev/src/lib.rs` `ensure_partitions()` (line ~158): idempotent,
  grow-only. Rebuilds the GPT whenever p3 (data) is missing or ends before `last_usable`;
  returns without writing when p3 already fills the device. Preserves the ESP entry verbatim
  and the disk GUID; p2 = runtime (fixed size, fixed GUID `4c4f434b-424f-4f54-...-02`), p3 =
  data (fills the rest, fixed GUID `...-03`). Refuses to shrink. So the rebuilt GPT is
  deterministic for a given disk size.
- `stage2/crates/bootstrap/src/main.rs`: `derive_data_key()` at line ~54, **before**
  `ensure_partitions()` at line ~59; `crypt_mount_or_mkfs()` at line ~103.
- `stage2/crates/tpm-derive/src/lib.rs`: `DATA_KEY_PCRS` = every PCR except 5 (GPT) and 10
  (IMA). Rationale in `stage2/PCR-BINDING.md` (PCR5: runtime GPT rewrite; PCR10: IMA boot
  aggregate = hash(PCR0-9), redundant, includes PCR5).
- `vaportpm/crates/vaportpm-attest/src/derive.rs` `derive_pcr_bound()`: keyedhash HMAC primary
  in the owner hierarchy, `authPolicy` = `PolicyPCR` over the **live** values of the chosen
  PCRs (sha256 bank), `userWithAuth` clear; every HMAC block re-satisfies `PolicyPCR` in a
  policy session. Key material = f(owner seed, template incl. authPolicy). Stateless.
- `crypt_mount_or_mkfs()`: plain dm-crypt `aes-xts-plain64` (no LUKS header); a wrong key
  decrypts the ext4 superblock to garbage -> no magic -> reinit (fail closed).

### Observed 2026-11-10 (pivot-init reboot test, cloudtest `7cf12890de5f`, `lb-rb-*.console.log`)

- **n2d SEV-SNP: PASS.** Boot 2 `data_reinit=false`, sentinel present, overlay root ephemeral.
- **c3 TDX: key moves once.** Boot 1 writes GPT-B; boot 2 measures GPT-B into PCR2 -> different
  key -> `data_reinit=true` (/data lost; pivot-init re-ran boot 1); boot 3 PASS. Data written
  on a TDX VM's first boot is lost at its first reboot; stable after, until a grow.

## 2. Requirements (from the discussion)

- PCR2 on TDX must stay bound and pinned: it carries stage0's Authenticode. Excluding it, or
  treating it as a free variable (data key or verifier), is not acceptable.
- No reconstruction of the post-rewrite GPT in the verifier from GUIDs / disk size: brittle.
- Every carrier that persists across boots (ESP, any disk region, TPM NV with empty owner auth)
  is **adversarial input**: an operator may run another author's stage1/stage2 on the same
  machine. The attack to defend is **substitution** (plant a key we then use), not disclosure.
- Unattested claims (in-guest CPUID etc.) are meaningless; no platform auto-detection in the
  verifier -- the caller names the platform file.

## 3. Leading candidate: grow, then reboot; bind PCR5 again

### Rule

In bootstrap: **if `ensure_partitions()` wrote the GPT this boot, sync and reboot before
touching `/data`.** No first-boot detection, no stored state: "free space -> grow into it" is
the existing logic, and its own outcome is the trigger. The next boot finds p3 filling the
device, writes nothing, measures the final GPT, and derives the key from it.

### Consequences

- First boot (64 MiB image -> full volume): grow, reboot, key from the final GPT. Nothing lost.
- **Volume grown later (EBS / PD resize): grow, reboot, key changes -> `/data` reinit (wiped)**
  through the existing fail-closed path. Accepted: you cannot grow the volume without wiping
  `/data` (until a key carrier exists, section 5).
- The GPT is final before any key is derived on every platform, so **PCR5 can be bound again**
  (`DATA_KEY_PCRS` = all but PCR10). Same behaviour on every platform, TDX included.
- Cost: one extra boot (~30 s) on first boot and after each grow.
- A volume resize by itself changes nothing measured (the primary GPT is untouched until stage2
  rewrites it) -- but see open question O2.

### Changes

1. `blockdev::ensure_partitions()` returns whether it wrote (today: only the two paths).
2. `bootstrap/src/main.rs`: on a write, sync + reboot; never reach `crypt_mount_or_mkfs()`.
   Move `derive_data_key()` after `ensure_partitions()` (deriving before a reboot is harmless
   but wasted; the new order states the dependency).
3. Reboot-loop guard (O1): before rebooting, re-read the table from the device and check that
   p3 now ends at `last_usable`; if not, fail closed instead of rebooting.
4. `tpm-derive`: `DATA_KEY_PCRS` gains PCR5; doc comment updated.
5. `stage2/PCR-BINDING.md`: PCR5 now bound (GPT final before derivation); grow = reinit; the
   TDX placement (PCR2); PCR10 still excluded (IMA boot aggregate).
6. pivot-init / grow-probe expectations: boot 1 now reboots once before the sentinel boot; a
   grow test expects reinit after a grow.

### Verification

- QEMU x86_64 + aarch64: `make -C stage2 selftest-<arch>` / `test-pivot-<arch>` (pivot-init,
  grow-probe with `PERSIST_GROW`), adjusted for the extra reboot and grow-wipes semantics.
- GCP, one VM at a time (AGENTS.md "Cloud test runs"), bundle like `chain-reboot`
  (`scratchpad/setup-reboot.sh`, `reboot-run.sh`, `test-lb-rb-{snp,tdx}.sh`): n2d SEV-SNP and
  c3 TDX must both PASS with no reinit after the provisioning reboot.
- A resized-volume test on GCP (O2): stop, grow the PD, start; confirm PCR5/PCR2 unchanged
  before stage2 acts, then the grow + reboot + reinit.
- EC2 when unblocked: same, plus O3.

### Open questions

- **O1 reboot loop.** If the GPT write does not persist (read-only/misbehaving device, firmware
  that "repairs" the table), every boot sees free space -> rewrite -> reboot, forever. The
  read-back guard (change 3) catches a write that didn't stick; it does not catch a firmware
  that rewrites the GPT on its next boot. Stronger bound wanted?
- **O2 firmware on a grown volume.** After a resize the backup GPT is no longer at the disk's
  end. Expect EDK2 to validate and measure the primary unchanged; if a firmware repairs or
  relocates the backup header, PCR5/PCR2 would move without stage2 rewriting anything. Check
  on a real resized disk (GCP, EC2).
- **O3 Nitro PCR5.** If NitroTPM's PCR5 holds more than the GPT, binding it on EC2 needs that
  content understood first. Needs an EC2 event-log capture (`tools/pcr-replay/EC2-NOTES.md`).

## 4. Verifier side (independent of the data-key choice)

- `pcr-replay` derives stage0's GPT event from `boot.disk`, which only holds on a boot before
  stage2's rewrite. With the provisioning reboot, **every workload boot** measures the
  rewritten GPT, so replaying PCR5 (non-TDX) / PCR2 (TDX) needs the GPT event digest from the
  attestation: **lockboot/vaportpm#12** (aux data: one digest in the attested bank, from the
  event log; the quote binds it via the PCR comparison). Needs: vaportpm-attest,
  vaportpm-verify (+ flat zkVM format), **vaportpm-zk** (commit it in `ZkPublicInputs`), and a
  pcr-replay "supplied digest" mechanism (open design; `tools/pcr-replay/README.md`, "Open:
  GPT digest from the attestation"). Inputs today are 32-byte sha256 only -> per-bank values.
- Already done (workspace a56e303, 454744c; stage0 8322629): `route` rules in platform files
  (GCE TDX: `EV_EFI_GPT_EVENT` 5 -> 2, `EV_EFI_BOOT_SERVICES_APPLICATION` 4 -> 2), stage0's
  replay file in firmware log order, `gcp-c3-standard-4-tdx.replay.json`; TDX full chain
  verified (first boot).
- Policy note: anything binding stage0's identity via PCR4 needs a TDX case (PCR2).

## 5. Options considered

### Rejected

- **Exclude PCR2 on TDX** (from the data key or the verifier): loses stage0's identity.
- **Accept the one-time loss** (document "reboot once before relying on /data"): no.
- **Final layout at image build:** the GPT header's LastUsableLBA/AlternateLBA depend on the
  disk size; would need a fixed disk size.
- **MAC under a GPT-independent PCR-derived key** (authenticating a blob): a foreign stage0
  runs first and can mimic every PCR except PCR2, then derive the MAC key -- "DOA".
- **Platform auto-detection / PCR0-based platform selection** in the verifier: the caller
  names the platform file; a wrong one fails closed.

### Key carriers (only needed if a grow must keep `/data`)

Predict the post-rewrite PCRs on the setup boot (replay the verified live event log with
`H(UEFI_GPT_DATA(GPT-after))`; PolicyPCR digest = `H(0^32 || TPM_CC_PolicyPCR || selection ||
H(PCR values))`) and carry the key K across the state change. Any carrier is adversarial.

- **a) Sealed blob + TPM creation record.** Seal K to `PolicyPCR(after)`; before use,
  `TPM2_CertifyCreation` (unsigned, `TPM_RH_NULL`) verifies the creation ticket, and the
  recorded creation-PCR digest must equal our chain's state at sealing: non-GPT PCRs = live;
  the GPT-holding PCR rebuilt from the verified live log with the stored pre-rewrite GPT
  digest (untrusted but harmless: in PCR2 the Authenticode follows the GPT, so a foreign
  stage0 would need a collision). Needs on-disk state (~200-byte blob); the ESP was considered
  (placeholder file written raw, A/B slots) and is adversarial like any location.
- **b) TPM NV index holding K.** `authPolicy` = `PolicyOR(NV_Read + PolicyPCR(after),
  NV_Write + PolicyPCR(before))`; attributes exactly `POLICYREAD | POLICYWRITE` (+ NO_DA; no
  OWNER*/AUTH*); handle in the owner range, not `0x01c0xxxx` (TCG / GCP AK). Reader checks
  `NV_ReadPublic` (attrs + authPolicy) against its own computation, so only a TPM in our full
  chain's before state can have written K. Grow carries K over (read old, define new), no
  re-encryption. Open: where the pre-setup GPT digest lives (second NV index or file;
  untrusted, same argument as a), A/B indices for crash-safe grows, NV persistence on GCE /
  NitroTPM / swtpm. Undefine via empty owner auth = DoS -> reinit.
- **Option 1 (last place): never rewrite the GPT.** Data region after the ESP found by its own
  header. Stateless, handles grows; a disk region with no partition entry.

## 6. Order of work (when un-parked)

1. Decide section 3 (and O1's bound). 2. stage2 changes 1-6 + QEMU selftest both arches.
3. GCP SNP + TDX reboot tests, resized-volume test (O2). 4. EC2: capture, O3, same tests.
5. vaportpm#12 (verifier aux digest) in parallel; it is needed either way.
