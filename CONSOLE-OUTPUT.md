# Console output matrix — where each stage's output lands, per platform

Working notes for capturing **full console output** (UEFI stages + Linux kernel + userspace) across
**local QEMU, AWS EC2, GCP**, on **x86_64 and aarch64**. This is an *observation* record: we run each
cell, capture whatever the platform actually emits **without modifying the QEMU device profile or the
kernel command line**, and write down what we see. Remedies (if any) come *after* the matrix is filled
with real data — not from derivation.

Status legend: `captured` / `absent` / **`TODO`** (not yet observed).

## The three output paths (mechanism, from source — to be confirmed by observation)

1. **UEFI ConOut** — stage0 and any UEFI code print via `uefi::println!` → firmware ConOut
   (`stage0/crates/stage0/src/timing.rs:94`, `main.rs:64`). No direct UART; the firmware decides which
   serial device ConOut maps to. Reaches a captured log only if the firmware's ConOut device is the one
   the platform captures.
2. **Kernel printk + initramfs script** — kernel command line is baked per-arch into the signed UKI
   (`stage1/tools/build-uki/build.sh:232-243`): x86 `console=ttyS0 console=ttyS1 vsyscall=none`,
   aarch64 `console=ttyAMA0 console=ttyS0`. printk fans to **all** `console=` devices; the initramfs
   `/init` logs to `/dev/kmsg` (`stage1/tools/build-uki/init:6`) → also all consoles.
3. **Userspace PID-1** — stage1 and stage2 (Rust) log to **stderr → `/dev/console`**, which binds to the
   **last** `console=` entry only (`stage1/crates/stage1/src/main.rs:131`;
   `stage2/crates/bootstrap/src/main.rs:101,116`). stage2 inherits stage1's fds.

## Retrieval per platform

| Platform | How to boot | How to read the console |
|---|---|---|
| Local QEMU | `make smoke-boot-<arch>` / `make test-chain-<arch>` (stage0 harness image) | harness **stdout** (the make target's captured log) |
| AWS EC2 | `tools/publish/ec2/create.sh <arch>` → `ec2/launch.sh --tail <ami> <config>` | `aws ec2 get-console-output --region <r> --instance-id <id> --latest --output text` (system log; **~minute lag**, ~2-min post-mortem drain) |
| GCP | `tools/publish/gcp/create.sh <arch>` → `gcp/launch-instance.sh <name> <zone> <type> <img> <config>` | `gcp/get-console.sh <name> <zone> [--follow]` = `gcloud compute instances get-serial-port-output <name> --zone <z>` (port 1) |

Known fail-closed drains that exist *because* of cloud lag: stage0 `FAIL_CLOSED_DRAIN_US` 90 s
(`stage0/crates/stage0/src/main.rs:53-60`); stage2 `fatal_halt` 60 s grace
(`stage2/crates/bootstrap/src/main.rs:114-128`).

## The matrix (fill with OBSERVED results)

Per cell, record whether each path's output was **captured** in the retrieved console log.

| Cell | UEFI ConOut | Kernel printk | Userspace PID-1 | Notes |
|---|---|---|---|---|
| Local QEMU x86_64 | **captured** | **captured** | **captured** | stage0 smoke-boot: full `stage0:`/`BdsDxe`. stage1 smoke-args chain: `Linux version`, `console [ttyS0] enabled`, `stage1:` userspace lines, and payload `arg[1]/arg[2]` — all on stdout via isa-serial=ttyS1 (the last `console=`). Fully observable. |
| Local QEMU aarch64 | **absent** (isolated; see below) | **captured** | **captured** | After the init fix: full chain PASSES (`smoke-args-aarch64`). stage1 runs (2 IMDS cycles + `GET /stage2`, matching x86), `stage1:` lines on ttyS0, payload `arg[1]/arg[2]` echoed. Only stage0/UEFI ConOut (→PL011) is uncaptured locally. |
| EC2 x86_64 | TODO | TODO | TODO | |
| EC2 aarch64 (Graviton) | TODO | TODO | TODO | |
| GCP x86_64 | TODO | TODO | TODO | |
| GCP aarch64 (t2a) | TODO | TODO | TODO | |

## Phase 1 — local observation (in progress)

Run the existing harness targets for both arches and record the captured stdout. **No** changes to
`qemu-test.sh` or the UKI cmdline. Targets that exercise the paths:
- `stage0`: `make smoke-boot-<arch>` — pure UEFI (stage0 → UEFI `payload.efi`, no kernel); exercises
  **UEFI ConOut only**.
- `stage1`: `make test-chain-<arch>` / `make smoke-args-<arch>` — full chain (stage0 → kernel → stage1
  PID-1 → stage2 → payload); exercises **kernel + userspace** too.

(Results filled in below as runs complete.)

## Phase 2 — cloud observation (outline; user runs with cloud creds)

Goal: boot the **current** build on each cloud cell and capture the console verbatim — no image or
guest changes. For each of {EC2, GCP} × {x86_64, aarch64}.

**Priority / expected effort (per project context):** this is the important dry-run phase toward a
coherent deployable point. **GCP is the focus** — it has not been exercised in a while, so Phase 2 for
GCP is as much about shaking out (and likely *refining*) the deployment scripts as observing the
console. **EC2 is believed complete**; treat it as a confirmation pass. So Phase 2 has two intertwined
outcomes per cloud: (a) does it deploy+boot at all, and (b) what console output is captured. Expect GCP
to surface deployment-script fixes; capture those as follow-ups.

### Scope: console debugging needs stage0 (and optionally stage1), NOT stage2

Console debugging asks one thing: **does each stage's console output get captured on this platform?**
The only path we can't see locally is **stage0's UEFI ConOut on aarch64** (→ PL011, nulled by the
harness). So the core cloud test is: **boot the stage0 image and read its serial console** — do
stage0's `stage0:` lines appear? stage0 prints these *before* it fetches any payload, so this is
answerable from the stage0 image alone.
- Kernel + stage1 userspace already work locally (via ttyS0); to reconfirm them on cloud, host a real
  **stage1 UKI** so stage0 chainloads it.
- **stage2 is out of scope.** Its job is measuring config into PCR15 — a separate security function,
  unrelated to console capture. A console-observation boot doesn't need it (PCR15 just won't be
  measured). (The local serve-dir / `SERVE_HOST` machinery is likewise test-only.)

### 1. Build
```bash
(cd stage0 && make build-<arch>)   # -> stage0/build/<arch>/{boot.disk, efi-vars.aws}   (the image inputs)
(cd stage1 && make build-<arch>)   # optional: the stage1 UKI (tools/build-uki/<arch>/linux.efi), for kernel+stage1
```
`build-<arch>` = `build-x86_64` / `build-aarch64` (also `build-amd64` / `build-arm64`) — same shape in
all three repos now.

### 2. EC2 — boot stage0, capture the console
```bash
cd stage0
AMI=$(tools/publish/ec2/create.sh <arch>)                 # from build/<arch>/{boot.disk, efi-vars.aws}
tools/publish/ec2/launch.sh --tail "$AMI" <user-data.json>
# full log anytime: aws ec2 get-console-output --region ap-southeast-1 --instance-id <id> --latest --output text
```
- Instance types auto: `c6i.large` (x86_64) / `c7g.medium` (arm64).
- **terminate (default) — do NOT pass `--stop`** (it leaves stopped instances to reap). `--tail` drains
  the serial buffer ~2 min after the instance is gone, and stage0's 90 s fail-closed hold flushes before
  poweroff, so termination still yields the full log.
- **Do NOT set `--nosleep`** in stage0's args — it disables that 90 s drain, whose whole purpose is to
  flush EC2's lagged serial buffer (fine locally, loses the log on EC2).
- Any valid `_stage1` user-data works for the stage0-UEFI check; stage0 prints regardless of payload
  reachability. To also chainload/observe the kernel + stage1, host a signed UKI (next).
- Optional housekeeping: `create.sh --manifest <f>` + `tools/publish/cleanup.sh <f>` deregisters the
  AMI/snapshot afterward.

### 3. Hosting a stage1 UKI (only to also capture kernel + stage1)
`lockboot-deploy` signs/pins the UKI and emits `user-data.json` + an upload-ready dir:
```bash
lockboot-deploy keygen --out release.pem --pub release.pub.b64
lockboot-deploy create --arch <arch> --uki <linux.efi> --stage2 <stage2> --key release.pem \
  --base-url http://<bucket>.s3.<region>.amazonaws.com --out deploy/   # http only; integrity is the ed25519 pin
# upload deploy/<arch>/* to S3, then launch with deploy/user-data.json exactly as in step 2
```
(`create` still requires a `--stage2` even though it's not what we're watching — point it at any stage2
build; it doesn't affect the stage0/stage1 console.)

### 4. GCP — same image + user-data
```bash
IMG=$(tools/publish/gcp/create.sh <arch>)
tools/publish/gcp/launch-instance.sh lb-<arch> asia-southeast1-a <type> "$IMG" <user-data.json>
tools/publish/gcp/get-console.sh lb-<arch> asia-southeast1-a --follow   # gcloud get-serial-port-output (port 1)
```
Machine types `n2d-standard-2` (x86_64 SEV) / `t2a-standard-1` (aarch64). GCP manages SB vars + vTPM
itself (no `efi-vars.aws` / `--uefi-data`).

### 5. What to observe (fill the matrix)
Grep each captured console for the three paths:
- **UEFI ConOut (stage0):** `stage0: version`, `stage0: network`, `stage0: metadata` — *the key aarch64
  question*: does stage0's pre-kernel output land on the platform's serial?
- **Kernel:** `Linux version`, `console [tty…] enabled`.
- **Userspace:** `stage1:` lines, then the stage2/workload output.

## Findings / remedies

(Filled in only after the matrix has real data. No changes to console wiring are proposed here until an
observation shows a specific stage's output is actually missing on a specific cell.)

### Local aarch64 findings (observed 2026-07-15; no changes made)

Two separate things surfaced in `make smoke-args-aarch64` (full 593-line log in
`stage1/build/aarch64/smoke-args.log`); recorded as observations, not diagnoses:

1. **UEFI ConOut is not captured.** stage0 + AAVMF write ConOut → PL011, and the harness nulls PL011
   (`-serial none`); the captured device is the pci-serial (ttyS0). x86 differs only because OVMF ConOut
   lands on the captured isa-serial. (This is *only* an observability gap — the boot clearly proceeds
   into Linux.)
2. **Kernel + init ARE captured; the chain then dies in `/init` at ~2.1s — ROOT-CAUSED.** The kernel
   registers **only** `ttyS0` as a console (`console [ttyS0] enabled`; PL011 bootconsole `pl11`
   disabled; `ttyAMA0` never registers, no backend). So `/dev/console` = ttyS0 = captured, and 33
   `init:` lines appear — i.e. **console capture on aarch64 is working for the kernel/init path** (it is
   how we saw the failure). Then `reboot: Power down` at 2.1s.

   **Root cause (log + code): the initramfs `/init` dies before `exec /bin/stage1`.**
   - The captured die line is `init: sysctl: kernel.nmi_watchdog=0 failed`, immediately followed by
     `reboot: Power down`.
   - `stage1/tools/build-uki/init:113` runs `sysctl kernel/nmi_watchdog 0` **without `-f`**. The
     `sysctl()` helper (`init:12-23`) `die`s on a **write failure** (`:19-20`) unconditionally; `-f`
     only skips a **missing** file (`:15-17`). On aarch64 `/proc/sys/kernel/nmi_watchdog` *exists* but
     writing `0` fails (no NMI/hardlockup watchdog to toggle) → `die` → `poweroff -f`.
   - The sibling NMI sysctls at `init:117-120` are `-f`-guarded as "x86-only... not present on
     aarch64" — but `nmi_watchdog` is *present-but-unwritable*, a case `-f` does not cover, so it was
     missed.

   **Confirmed independently by the metadata-mock witness:** x86 shows **two** IMDS token+user-data
   cycles (stage0's, then stage1's) plus stage1's `GET /stage2`; aarch64 shows **only stage0's single
   cycle and no `GET /stage2`** — i.e. stage1 never runs its network phase. So stage1 does not run on
   aarch64, because `/init` powers off first.

   This is a **real init-script bug, not a console problem**. It is orthogonal to the UEFI-capture gap
   (item 1).

   **FIXED + verified (2026-07-15).** Applied option (a): `sysctl()` now honors `-f` on a *write
   failure* too (skip-with-warning, `stage1/tools/build-uki/init:19-21`), and `:113` is marked
   `sysctl -f kernel/nmi_watchdog 0`. Re-ran `make smoke-args-aarch64`:
   - `init: sysctl: kernel.nmi_watchdog=0 skipped (write failed)` — `/init` continues instead of dying.
   - stage1 now runs: **2** IMDS token+user-data cycles and **1** `GET /stage2` (matching x86), and
     `stage1:` userspace lines are captured on ttyS0 (`... exec stage2 ... ["--smoke", "hello world"]`).
   - Payload completes: `arg[1]: --smoke` / `arg[2]: hello world`; assertion **PASS**; normal 60 s-drain
     poweroff.

   So on aarch64 the entire kernel→init→stage1→stage2→payload path now works **and is captured**
   (via ttyS0). The **only** remaining aarch64 gap is item 1 (UEFI ConOut → PL011, uncaptured locally),
   which is isolated and best confirmed on EC2 (whose firmware ConOut = ttyS0 = the captured serial).

   Impact note: because `nmi_watchdog` unwritability is an aarch64 *kernel* property, this bug would have
   killed stage1 on **EC2/GCP aarch64 too** — the fix unblocks aarch64 on every platform.
