# EC2 platform notes (parked)

Status: not started. The AWS account is restricted pending a support case, so no EC2 event log
has been captured. Pick up from here once launches work again.

## What is known

- **Firmware source: [aws/uefi](https://github.com/aws/uefi).** AWS's EDK2 patches (on
  edk2-stable202211) for x86_64 Nitro guests, with a reproducible Nix build:
  `nix-build --pure` -> `result/ovmf_img.fd`. Its stated purpose is the AMD **SEV-SNP launch
  measurement** (`sev-snp-measure --mode snp --vcpus=N --vmm-type=ec2 --ovmf=ovmf_img.fd`;
  [AWS SEV-SNP guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/sev-snp.html)).
  Constellation precomputes these in CI (its aws-snp-launchmeasurement workflow).
- The README says nothing about **NitroTPM PCR0**, and nothing about Graviton (aarch64). Whether
  NitroTPM's PCR0 measures firmware volumes (derivable from that binary) or, like GCE, only
  strings, is unknown.
- stage0 on EC2: the test payload says "some firmware (EC2) does not hand out its log"
  (`stage0-test-payload` `print_event_log`, best effort). So the TCG2 event log may not be
  available through `EFI_TCG2_PROTOCOL.GetEventLog`. Untested on the current payload.
- PCR7 is expected to equal GCP's/QEMU's `ee5f65dc...` now that PK/KEK/db use GCP's owner GUID
  (`efi-vars.aws` comes from the same mkvarstore). Unverified.
- The AMI `ami-04abef7162f90706e` predates the GUID fix; recreate it.

## To do, in order (one instance at a time)

1. x86_64 (`c6i.large`), stage0 + test payload: PCR dump, and the event log if the firmware
   hands it out. If not, the Linux side (`/sys/kernel/security/tpm0/binary_bios_measurements`)
   from a chain boot, which needs a payload that prints it (pcr-dump does not yet).
2. From that log: what PCR0-2 contain. If PCR0 measures firmware volumes, check them against an
   aws/uefi build, and decide on a derivation node for a byte range of an artifact. Don't add
   the node before a log shows it's needed.
3. Write `ec2-x86_64.replay.json` (platform file: PCR0-2 from reset, derived where possible,
   pinned otherwise), then the same for aarch64 (`c7g.medium`).
4. Full chain (stage0 -> UKI -> stage2 pcr-dump) on each arch, `pcr-replay.py --check`.
