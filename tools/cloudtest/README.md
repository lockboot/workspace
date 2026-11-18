# cloudtest

The release gate on real hardware: boot the whole chain on a cloud VM, capture its console, and
check that an attestation from that boot verifies and that every PCR is reproduced from the
platform's golden file and the release's replay files.

Rules for launching anything are in the workspace `AGENTS.md`, "Cloud test runs": one VM at a
time, each with the user's go-ahead, spot with a 3 minute cap, deleted as soon as it stops.

## A run

A run lives in `cloudtest/<id>/` (gitignored); `cloudtest/CURRENT` names the current one.

```
make deploy-shell-gcp                                   # the user opens this and signs in
make -C stage0 build-x86_64
make -C stage1 build-x86_64 deploy-bin
make -C stage2 pack-x86_64 INIT_PAYLOAD=pivot-init
make -C vaportpm release-x86                            # vaportpm-verify for the check

tools/cloudtest/gcp-setup.sh                            # bundle + upload + stage0 image
tools/cloudtest/test-snp.sh                             # one VM each: launch, delete, check
tools/cloudtest/test-sev.sh
tools/cloudtest/test-tdx.sh

make deploy-exec CMD='stage0/tools/publish/cleanup.sh cloudtest/<id>/teardown.txt'   # at the end
```

No stage0 make target between `gcp-setup.sh` and the end of the run: it would re-mint the Secure
Boot keys the image was built from. `gcp-setup.sh` snapshots what the replay needs into the
run's `replay/`, so a check can be repeated later.

## The confidential configurations

Only Confidential VMs run the full chain: stage1 attests before it runs stage2, and GCE issues
AK certificates only to Confidential VMs.

| Script | Machine | Platform file (`tools/pcr-replay/platforms/gcp/`) |
|---|---|---|
| `test-sev.sh` | n2d-standard-2, SEV | `gcp-n2d-standard-2-sev.replay.json` |
| `test-snp.sh` | n2d-standard-2, SEV-SNP (AMD Milan) | `gcp-n2d-standard-2-sev-snp.replay.json` |
| `test-tdx.sh` | c3-standard-4, TDX | `gcp-c3-standard-4-tdx.replay.json` |

## What one VM shows

The bundle's payload is stage2's `pivot-init` test `/init`. A VM boots three times:

1. stage2 finds free space, rewrites the GPT and reboots before deriving any key.
2. The payload runs for the first time: writes a sentinel to `/data`, reboots.
3. The payload finds the sentinel: `PIVOT_TEST=PASS`, power off.

On boots 2 and 3 the payload prints stage1's attestation, the config digest and every PCR.
`check-run.py` then checks, per boot: the attestation verifies (`vaportpm-verify`), its nonce is
the sha256 of the published stage2, the quoted PCRs replay from the golden platform file and the
stage0 / stage1 replay files with the GPT digest the attestation carries, and the PCRs the
payload read back replay with stage2's file too.

Limits, stated by the tool on every run:

- stage1 quotes before it measures stage2, so the attested replay does not cover PCR14 after
  stage2, or PCR15. Those are checked from the PCR values the payload read from the TPM, which
  are not signed (stage2 produces no quote yet).
- PCR10 (IMA) is never reproduced.
- The platform's ACPI table measurements in PCR1 are pinned in the golden file, not re-derived.

The kernel logs to the same console and sometimes cuts into a line the payload is printing.
`check-run.py` takes such a message out and rejoins the line; a wrongly repaired attestation
fails its signature check.

## Files

| File | |
|---|---|
| `gcp-setup.sh` | New run: snapshot, bundle, upload, stage0 image. |
| `test-{sev,snp,tdx}.sh` | The gate for one configuration: `gcp-run.sh`, `gcp-delete.sh`, `check-run.py`. |
| `gcp-run.sh` | One VM: create, follow, read the console back from Cloud Logging, summarize boots. |
| `gcp-delete.sh` | Delete one VM. |
| `check-run.py` | The checks above, from the captured console. Exit 0 only if all pass. |
