# GCP platform measurements

Golden PCR0-2 for GCE: one platform replay file per instance configuration that measures
differently, each generated from a probe capture by `from-capture.py` (so it can be regenerated
from the evidence) and listed first in a chain:

```
pcr-replay.py platforms/gcp/gcp-n2d-standard-2-sev-snp.replay.json stage0.replay.json \
    stage1.replay.json stage2.replay.json ... --check <quote>
```

| File | PCR0 | PCR1 | Verified chains |
|---|---|---|---|
| `gcp-n2d-standard-2-shielded.replay.json` | `d0c70a93` | `09b32fdf` | stage0 only (no AK cert on Shielded VMs, so stage1 does not run) |
| `gcp-n2d-standard-2-sev.replay.json` | `a0b5ff33` | `2c4b6392` | full chain, 2026-11-09 |
| `gcp-n2d-standard-2-sev-snp.replay.json` | `50597a27` | `2c4b6392` | full chain, 2026-11-09 |
| `gcp-c3-standard-4-shielded.replay.json` | `d0c70a93` | `1e0e29fc` | stage0 only |
| `gcp-c3-standard-4-tdx.replay.json` | `0cca9ec1` | `baef2b3d` | full chain, 2026-11-10 (with `route`, below) |

Each file re-derives every PCR0-2 event from its logged bytes except the three ACPI DATA events,
which are pinned (their digests cover ACPI tables the log does not contain). Not covered: t2a / Arm (no network stack in the firmware, below), other
machine sizes (the ACPI tables may differ; unprobed).

## Captures (`captures/`)

Raw serial console of one stage0 boot each, kept as evidence: stage0 then the stage0 test payload,
which dumps every PCR in every bank and the full TCG event log (`EV` / `EVD` / `EVX` lines).
Recipe: AGENTS.md "Cloud test runs". Zone asia-southeast1-b, spot, Shielded VM (Secure Boot,
vTPM, integrity monitoring), gVNIC, our PK/KEK/db/dbx.

| Capture | Machine | Confidential | stage0 BUILD_ID | PCR0 sha256 | PCR1 sha256 | PCR2 sha256 | Events |
|---|---|---|---|---|---|---|---|
| `2026-11-09-n2d-standard-2-shielded.log` | n2d-standard-2 | none | stage0-689e96b8b206 | `d0c70a93` | `09b32fdf` | `3d458cfe` | 27 |
| `2026-11-09-n2d-standard-2-sev.log` | n2d-standard-2 | SEV | stage0-689e96b8b206 | `a0b5ff33` | `2c4b6392` | `3d458cfe` | 27 |
| `2026-11-09-n2d-standard-2-sev-snp.log` | n2d-standard-2 | SEV-SNP (AMD Milan) | stage0-689e96b8b206 | `50597a27` | `2c4b6392` | `3d458cfe` | 27 |
| `2026-11-09-c3-standard-4-shielded.log` | c3-standard-4 | none | stage0-689e96b8b206 | `d0c70a93` | `1e0e29fc` | `3d458cfe` | 27 |
| `2026-11-09-c3-standard-4-tdx.log` | c3-standard-4 | TDX | stage0-9437a5b63f47 (LAPIC tick + direct doorbells) | `0cca9ec1` | `baef2b3d` | `9d50b267` | 27 |
| `2026-11-09-t2a-standard-1-shielded-FAILED.log` | t2a-standard-1 | none | stage0-70b2df077e08 | - | - | - | - |

t2a: stage0's gVNIC driver probes fine (link up, SNP installed), but GCP's Arm firmware ("built
at 09:00:00 on Jan 10 2025") ships no network stack above SNP: no MNP, ARP, IP4, IP4Config2,
DHCP4, UDP4 or TCP4 drivers. stage0 fails closed (`no EFI_IP4_CONFIG2 ... NOT_FOUND`) before
loading any payload, so there is no PCR dump or event log for Arm. Needs stage0 to embed the
EDK2 network stack (or its own) before GCP Arm can be probed.

## What PCR0-2 contain (so far)

From `2026-11-09-n2d-standard-2-shielded.log`:

- **PCR0**: `EV_S_CRTM_VERSION` UTF-16LE "GCE Virtual Firmware v2" + NUL; `EV_NONHOST_INFO`
  (0x11) "GCE NonHostInfo\0" + a confidential-technology byte (0 here) + 15 zero bytes;
  separator. Derivable from strings. No firmware code is measured: firmware integrity on GCE
  comes from the SEV-SNP/TDX launch measurement plus Google's endorsement, and plain Shielded VMs
  have none.
- **PCR1**: three `EV_PLATFORM_CONFIG_FLAGS` "ACPI DATA" (digests of ACPI tables that are not in
  the log -> must be pinned), then `EV_EFI_VARIABLE_BOOT` BootOrder, Boot0001, Boot0000 (digest =
  hash of the variable data only, not UEFI_VARIABLE_DATA), separator.
- **What differs Shielded -> SEV (n2d)**: PCR0 only by the NonHostInfo technology byte (0 -> 1).
  PCR1 only by Boot0001: Shielded boots "UEFI Google PersistentDisk " over SCSI
  (`PciRoot(0)/Pci(3,0)/Scsi(1,0)`), SEV "UEFI nvme_card-pd" over NVMe (`PciRoot(0)/Pci(4,0)/
  NVMe(1,...)`). The three ACPI DATA digests, BootOrder and Boot0000 are identical. So PCR1 is
  keyed by machine shape + boot-disk interface, not by the confidential type as such.
- **PCR2**: separator only.
- **n2d -> c3 (both Shielded)**: PCR0 identical (technology byte 0). PCR1: all three ACPI DATA
  digests differ (different machine, different ACPI tables), and Boot0001 is NVMe like SEV but
  at `Pci(5,0)` instead of `Pci(4,0)`; BootOrder and Boot0000 identical.
- **SEV -> SEV-SNP (n2d)**: PCR0 only by the technology byte (1 -> 4); PCR1 identical (same
  NVMe Boot0001, same ACPI DATA digests).
- Two `EV_NO_ACTION` SP800-155 events (not extended, so not attested by the vTPM): platform
  "Google Compute Engine", firmware version "2.7"; the second carries a reference-manifest URL
  whose name is the SHA-384 of the firmware binary:
  - Shielded and SEV: `gs://gce_tcb_integrity/ovmf_x64_csm/abd40f8b110602404abcf39cbf215fc0897587c92194f4d7b692754d5459ae112265df306e7f08b32657cdf5a28b96d8.fd.signed`
  - SEV-SNP: `gs://gce_tcb_integrity/ovmf_x64_csm/3cf4e1feb18c4e7eca34e7e7c2fc15579cdb1c79cc3923214b6cbc3dc3c362b86d465386f33204794ed01aba3b34b3b3.fd.signed`
  - c3 Shielded: `gs://gce_tcb_integrity/ovmf_x64_csm/624ac419f063f0d17a261e6ba512174cd174194ffd06e72531dce3514ec7e148aa876331b95dfa20cd4341004b280fb1.fd.signed`

  SNP boots a different firmware binary, yet PCR0 differs from SEV only by the technology byte:
  the vTPM PCRs do not bind the firmware. These URLs identify it, but as unextended events they
  are claims, not measurements. For SNP the binding is the launch measurement + Google's
  endorsement (gce-tcb-verifier).

## TDX measures differently

`2026-11-09-c3-standard-4-tdx.log` is the first TDX boot that reached a payload (it needed stage0's
LAPIC tick and direct gVNIC doorbells; see stage0 `lapic_tick.rs`, `crates/gvnic`). Its firmware
is the same binary as c3 Shielded (SP800-155 locator `624ac419...`), yet it places boot-phase
measurements in different PCRs:

| Event | c3 / n2d Shielded, SEV, SNP | c3 TDX |
|---|---|---|
| NonHostInfo technology byte (PCR0) | 0 none, 1 SEV, 4 SEV-SNP | **3** |
| `EV_EFI_GPT_EVENT` (boot disk GPT) | PCR5 | **PCR2** |
| `EV_EFI_BOOT_SERVICES_APPLICATION` (stage0's BOOTX64.EFI, Authenticode) | PCR4 | **PCR2** |
| "Calling EFI Application from Boot Option", separators | PCR4, PCR0-7 | PCR4, PCR0-7 (unchanged) |
| PCR7 (SecureBoot, PK, KEK, db, dbx, separator, db authority) | PCR7 | PCR7 (unchanged) |

So on TDX, PCR4 is only the BDS action + separator and PCR5 only its separator; stage0's identity
and the GPT land in PCR2, after its separator. This looks like the TDX measurement path logging by
CC measurement register rather than by PCR (TCG CC mapping: PCR2-6 all map to RTMR1, "MR index
2"), reflected into the vTPM as PCR2.

`gcp-c3-standard-4-tdx.replay.json` expresses this as two `route` rules (`EV_EFI_GPT_EVENT` 5 -> 2,
`EV_EFI_BOOT_SERVICES_APPLICATION` 4 -> 2), which from-capture.py writes when a capture shows a
boot-chain event type in PCR0-2 after the separator and never in its usual PCR. stage0's replay
file is unchanged apart from listing its events in log order (GPT before BOOTX64.EFI), which is
the order they reach PCR2. Verified against the TDX full-chain regression boot (2026-11-10:
stage0, stage1, stage2, every PCR but IMA's PCR10, sha256 and sha384).

- Anything binding stage0's identity via PCR4 (sealing policy, attestation policy) needs a TDX
  case: there it is PCR2, which also carries the GPT.
- The GPT is a free variable after the first boot (stage2 adds its partitions), so elsewhere PCR5
  is left unpinned. On TDX that free variable is PCR2, and stage0's Authenticode goes with it:
  past the first boot, PCR2 pins neither, and stage0 is bound only by PCR7 (signed by our db).
  The replay reproduces first boots only (the GPT of `boot.disk`).

## Expected (from the 2026-11-05 matrix, before captures were kept)

| Config | PCR0 | PCR1 |
|---|---|---|
| n2d Shielded | `d0c70a93` | `09b32fdf` |
| n2d SEV | `a0b5ff33` | `2c4b6392` |
| n2d SEV-SNP | `50597a27` | `2c4b6392` |
| c3 Shielded | `d0c70a93` | `1e0e29fc` |
| c3 TDX | DHCP timeout, no reading | |
| t2a Shielded | never booted | |
