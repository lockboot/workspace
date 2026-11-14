# pcr-replay

Reproduce a machine's TPM PCRs from replay files: one file per boot stage or platform, each
listing the events that stage extends, how each event's digest follows from public artifacts,
and the digests its producer computed. `pcr-replay.py` replays a chain of them, re-derives every
digest it can, and compares the result with a quote.

Python >= 3.11, standard library only. `pcr-replay.py --help` for usage.

```
pcr-replay.py gcp-n2d.replay.json stage0.replay.json stage1.replay.json stage2.replay.json \
    --artifacts stage0-x86_64/ --artifacts linux.efi \
    --input stage2=<sha256 of the stage2 binary> --input config=<sha256 of its config> \
    --check attestation.json
```

## What a result means

- **CHAIN VERIFIES**: every PCR the files reproduce equals the quote. The tool also lists what
  that rests on:
  - **verified**: the event's derivation was re-evaluated from the supplied artifacts and equals
    the digest embedded in the file.
  - **derived**: re-evaluated; the file embeds no digest for that bank.
  - **unchecked**: derivable, but the artifact it needs was not supplied. The embedded digest
    was used unverified.
  - **pinned**: the file gives a digest or value without any derivation (platform firmware,
    say). The replay is only as good as that file's provenance.
- A derivation that disagrees with its embedded digest is an error (exit 2), whatever the quote
  says. A PCR that differs from the quote fails the check (exit 1).
- A PCR is reported **not reproduced** when no file models it from reset, when a later file does
  not account for it, when a file declares it unpredictable (IMA's PCR10), or when it needs an
  input that was not given. That last case is how a chain stops at a handoff: replay up to the
  stage you know, and the stage you don't know starts from there.

Artifacts are matched by sha256, never by name. Files are applied in the order given. Only the
order of events within one PCR matters, but list a platform file first: its `route` rules apply
to the files after it. Producers list events in the order the firmware logs them, so a routed
event lands in its new PCR in the right place.

There is no platform detection. Which platform file heads the chain is the caller's choice, and
a wrong choice fails closed (the PCRs differ).

The tool compares PCR values. It does not verify the quote's signature, nonce or AK; that is the
attestation verifier's job (vaportpm-verify). Pass `--check` the PCRs of an already-verified
quote.

## File format (`pcr-replay/v1`)

```json
{
  "schema": "pcr-replay/v1",
  "name": "stage1 x86_64",
  "about": "free text",
  "artifacts": { "linux.efi": { "sha256": "0a7e…" } },
  "entry": "linux.efi",
  "inputs": { "stage2": { "about": "…", "next_entry": true } },
  "reset": [],
  "unextended": [0, 1, 2, 3, 4, 6, 7, 8, 12, 13, 15, 16, 17, 18, 19, 20, 21, 22, 23],
  "unpredictable": { "10": "IMA" },
  "events": [ … ]
}
```

| Field | Meaning |
|---|---|
| `name` | Label in reports; must be unique within a chain. |
| `artifacts` | Files the derivations read, by name, each pinned by sha256. |
| `entry` | The artifact the previous stage loads, and measures. |
| `inputs` | Deployment-specific 32-byte values (sha256 digests) that derivations use. `--input NAME=HEX` or `NAME=@FILE` (hashes FILE); qualify as `FILE:NAME` if two files declare NAME. An input with `next_entry` and no value takes the sha256 of the next file's `entry`. A value that contradicts the next file's `entry` is an error. |
| `reset` | PCRs this file models from their reset value: nothing extended them before it. Reset is all-zero, all-ones for PCR17-22. |
| `unextended` | PCRs this file does not extend. Every PCR must be accounted for (events, `unextended` or `unpredictable`) by every file after the one that modelled it from reset, or it stops being reproduced. |
| `unpredictable` | PCRs extended from here in ways no file can replay, with the reason. |
| `route` | `[{"type", "from", "to", "about"?}]`: this platform's firmware logs events of TCG type `type` into PCR `to` where the boot chain's files say `from`. Every later file's matching events are replayed into `to`; each move is reported. A PCR an event is routed into counts as extended by that file, and one left with no events as unextended. |
| `events` | In extend order. |

An event:

| Field | Meaning |
|---|---|
| `pcr` | PCR index. |
| `type`, `by`, `about` | Descriptive: the TCG event type (or `unlogged` for a direct `TPM2_PCR_Extend`), who extends it, and what it is. |
| `derive` | Derivation of the bytes the digest is computed over (below). Absent: the event is pinned. |
| `digest` | How the extended digest follows from those bytes: `hash` (the bank's hash, default), `authenticode` (Authenticode PE image hash with the bank's hash), `raw` (the bytes are the digest). |
| `banks` | Only extended in these banks; other banks are unaffected. |
| `digests` | `{bank: hex}` as the producer computed them. |
| `value` | Instead of an extend: `{bank: hex}`, the PCR's value at this point (pinned). Only before any event in that PCR. |

Derivations are single-key objects, nested:

| Node | Bytes |
|---|---|
| `{"utf8": s}` / `{"utf16le": s}` | The string encoded. `"nul": true` appends a NUL in that encoding. |
| `{"hex": h}` | Literal bytes. |
| `{"guid": g}` | A GUID in EFI byte order. |
| `{"artifact": name}` | A declared artifact's contents. |
| `{"input": name}` | A declared input's 32 bytes. |
| `{"concat": [d, …]}` | Concatenation. |
| `{"pad": n, "of": d}` | Zero-padded to a multiple of n. |
| `{"pe_section": ".name", "of": d}` | A PE section's contents: min(VirtualSize, SizeOfRawData) bytes. |
| `{"gpt": d}` | `UEFI_GPT_DATA` of a disk image: primary header, partition count, non-empty entries. |
| `{"uefi_variable": {"vendor", "name", "data"}}` | `UEFI_VARIABLE_DATA`. |
| `{"efi_signature_list": {"type", "owner", "data"}}` | One `EFI_SIGNATURE_LIST` with one entry. `type` is `x509`, `sha256` or a GUID. |
| `{"cpio_newc": [{"ino", "mode", "name", "data"?}, …]}` | newc entries, with uid/gid 0, nlink 1 and mtime 0. Each entry's mode is an octal string with the type bits. No trailer: writers differ, so spell it out with `utf8`/`hex`. |

## Open: GPT digest from the attestation

stage0's `EV_EFI_GPT_EVENT` derives from `boot.disk`, which only holds on a first boot: stage2
rewrites the GPT (adds its partitions), so later boots measure a GPT no release artifact
describes. Reconstructing it is brittle and not planned. Instead the attestation will carry that
event's digest as auxiliary data (lockboot/vaportpm#12, with a matching change in vaportpm-zk),
and the replay takes it from there, which pins PCR5 (non-TDX) and PCR2 (TDX) on every boot. The
quote binds the supplied digest: a wrong one fails the PCR comparison.

Undecided: how a replay file says "this event's digest comes from the attestation's aux data".
Something like `"supplied": "gpt"` on the event (a new status besides verified / derived /
pinned / unchecked, reported as such), with the value read from `--check`'s attestation JSON or
given per bank on the command line, falling back to the `boot.disk` derivation when absent.
Inputs today are 32-byte sha256 values only, so an aux digest needs a per-bank value.

## Producers

- **stage0** (`tools/predict-pcrs.py`, `stage0.replay.json` in each release, with its
  reference `pcrs.json`): firmware and stage0 from reset for PCR3-23, in the firmware's log
  order. Its input `payload` is PCR14.
- **stage1** (`tools/predict-pcrs.py`, `stage1.replay.json` in each UKI release): systemd-stub
  (PCR11), the kernel's EFI stub (PCR9), ExitBootServices (PCR5). Its input `stage2` is PCR14.
- **stage2** (`tools/stage2.replay.json`, static, in each release): input `config` into PCR15,
  sha256 bank, raw.
- **platforms** (`platforms/`): provider firmware's PCR0-2, pinned where it cannot be re-derived.
  GCE: `platforms/gcp/`, generated from probe captures kept alongside (TDX with `route`). EC2: not yet
  (`EC2-NOTES.md`).
