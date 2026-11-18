#!/usr/bin/env python3
# check-run: the release gate for one cloud test VM, from its captured console.
#
# The pivot-init test payload prints, on every boot it reaches, stage1's attestation, the config
# digest and every PCR. For each such boot this checks:
#   1. attestation  vaportpm-verify accepts stage1's attestation (quote signature, AK certificate
#                   chain to the provider's root).
#   2. nonce        it is the sha256 of the stage2 binary this run published.
#   3. replay       pcr-replay reproduces the QUOTED PCRs from the platform's golden file plus
#                   stage0's and stage1's replay files, with the GPT digest the attestation carries.
#                   stage1 quotes before it measures stage2, so PCR14 is not reproduced here.
#   4. final PCRs   pcr-replay reproduces the PCRs the payload read from the TPM, with stage2's
#                   replay file, the stage2 binary and the config digest. These values are NOT
#                   signed: stage2 produces no quote yet. This is what covers PCR14 and PCR15.
# and for the VM as a whole:
#   5. reboot       the last boot reports PIVOT_TEST=PASS (/data survived the reboot).
# A PCR that pcr-replay does not reproduce is a failure unless it is expected: PCR10 (IMA) always,
# PCR14 in step 3.
#
# usage: tools/cloudtest/check-run.py <vm-name> <platform.replay.json> [--run ID] [--arch ARCH]
#   check-run.py lb-snp tools/pcr-replay/platforms/gcp/gcp-n2d-standard-2-sev-snp.replay.json
# Reads cloudtest/<run>/<vm-name>.console.log (gcp-run.sh) and the run's replay/ and chain/
# snapshots (gcp-setup.sh); writes <vm-name>.boot<N>.{attest,verified,pcrs}.json next to it.
# vaportpm-verify: $VAPORTPM_VERIFY, else vaportpm's `make release-x86` output.
# Python >= 3.11, standard library only. Exit 0 only if every check passes.
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys

WS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REPLAY = os.path.join(WS, "tools", "pcr-replay", "pcr-replay.py")
VERIFY = os.environ.get("VAPORTPM_VERIFY") or os.path.join(
    WS, "vaportpm", "target", "x86_64-unknown-linux-musl", "release", "vaportpm-verify")
BOOT_MARK = "BdsDxe: loading"       # firmware, once per boot
PAYLOAD_MARK = "=== pivot-init"
IMA_PCR = 10


def replay(files, artifacts, inputs, quote, banks):
    """Run pcr-replay; return (verifies, mismatched PCRs, not-reproduced PCRs, taken on trust)."""
    cmd = [sys.executable, "-I", REPLAY, *files, "--banks", banks, "--check", quote]
    for a in artifacts:
        cmd += ["--artifacts", a]
    for k, v in inputs.items():
        cmd += ["--input", f"{k}={v}"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    out = p.stdout + p.stderr
    bad = sorted({int(n) for n in re.findall(r"PCR(\d+)\s+MISMATCH", out)})
    gaps = {int(n) for n in re.findall(r"PCR(\d+)\s+not reproduced", out)}
    for lst in re.findall(r"in the quote but not reproduced: PCR ([\d,]+)", out):
        gaps |= {int(n) for n in lst.split(",")}
    trust = re.search(r"events: .*", out)
    verifies = p.returncode == 0 and "CHAIN VERIFIES" in out
    return verifies, bad, sorted(gaps), (trust.group(0) if trust else out.strip()[-300:]), out


def main() -> int:
    ap = argparse.ArgumentParser(description="Release-gate checks for one cloud test VM")
    ap.add_argument("name", help="VM name, as given to gcp-run.sh")
    ap.add_argument("platform", help="the platform's golden replay file")
    ap.add_argument("--run", help="run id (default: cloudtest/CURRENT)")
    ap.add_argument("--arch", default="x86_64")
    ap.add_argument("-v", "--verbose", action="store_true", help="print pcr-replay's output")
    a = ap.parse_args()

    run = a.run or open(os.path.join(WS, "cloudtest", "CURRENT")).read().strip()
    C = os.path.join(WS, "cloudtest", run)
    rp = os.path.join(C, "replay")
    uki = os.path.join(C, "chain", a.arch, "linux.efi")
    stage2 = os.path.join(C, "chain", a.arch, "stage2")
    stage2_sha = hashlib.sha256(open(stage2, "rb").read()).hexdigest()
    if not os.path.exists(VERIFY):
        print(f"error: no vaportpm-verify at {VERIFY} (make -C vaportpm release-x86, or set "
              "VAPORTPM_VERIFY)", file=sys.stderr)
        return 2

    text = open(os.path.join(C, f"{a.name}.console.log"), encoding="latin1").read()
    text = re.sub(r"\x1b\[[0-9;=]*[A-Za-z]", "", text.replace("\r", ""))
    # The kernel logs to the same console and can cut into a line the payload is printing:
    # "<start of line>[   12.242112] clocksource: ...\n<rest of line>". Take such a message out
    # and rejoin the line. Nothing the payload prints as evidence contains "[", and a wrongly
    # repaired attestation fails its signature check.
    text = re.sub(r"(?<=[^\n])\[ *\d+\.\d{6}\] [^\n]*\n", "", text)
    boots = text.split(BOOT_MARK)[1:]
    print(f"{a.name} (run {run}): {len(boots)} boot(s), platform {os.path.basename(a.platform)}")
    ok = True
    checked = 0

    for i, b in enumerate(boots, 1):
        if PAYLOAD_MARK not in b:
            why = "stage2 rewrote the GPT and rebooted" if "GPT rewritten" in b else "NO PAYLOAD"
            print(f"boot {i}: {why}")
            ok &= "GPT rewritten" in b
            continue
        checked += 1
        base = os.path.join(C, f"{a.name}.boot{i}")
        res: list[tuple[str, bool, str]] = []

        # 1. attestation
        m = re.search(r"===ATTESTATION-BEGIN===\n(.*?)===ATTESTATION-END===", b, re.S)
        att = verified = None
        if m:
            try:
                raw = base64.b64decode("".join(m.group(1).split()), validate=True)
                att = json.loads(raw)
                open(base + ".attest.json", "wb").write(raw)
            except ValueError as e:
                res.append(("attestation", False, f"garbled on the console: {e}"))
        else:
            res.append(("attestation", False, "none printed"))
        if att is not None:
            p = subprocess.run([VERIFY, base + ".attest.json"], capture_output=True, text=True)
            if p.returncode == 0:
                verified = json.loads(p.stdout)
                open(base + ".verified.json", "w").write(p.stdout)
                res.append(("attestation", True, f"verified, provider {verified.get('provider')}"))
            else:
                res.append(("attestation", False, p.stderr.strip()[:200]))

        # 2. nonce
        if verified is not None:
            n = verified.get("nonce", "").lower()
            res.append(("nonce", n == stage2_sha,
                        f"sha256(stage2) {stage2_sha[:16]}" if n == stage2_sha
                        else f"{n[:16]} is not sha256(stage2) {stage2_sha[:16]}"))

        # 3. replay of the quoted PCRs
        if verified is not None:
            v, bad, gaps, trust, out = replay(
                [a.platform, f"{rp}/stage0.replay.json", f"{rp}/stage1.replay.json"],
                [rp, uki], {}, base + ".verified.json", ",".join(verified["pcrs"]))
            want = {IMA_PCR, 14}
            good = v and not bad and set(gaps) <= want
            res.append(("replay (quoted)", good,
                        f"mismatch PCR {bad}" if bad else
                        f"not reproduced PCR {gaps}" + ("" if set(gaps) <= want else " UNEXPECTED")))
            res.append(("", True, trust))
            if a.verbose or not good:
                print(out)

        # 4. replay of the PCRs the payload read back
        pcrs: dict[str, dict[str, str]] = {}
        for bank, n, val in re.findall(r"^PCR (\w+) (\d\d) ([0-9a-f]+)$", b, re.M):
            pcrs.setdefault(bank, {})[str(int(n))] = val
        cfg = re.search(r"^CONFIG bytes=\d+ sha256=([0-9a-f]{64})$", b, re.M)
        banks = [x for x in ("sha256", "sha384") if len(pcrs.get(x, {})) == 24]
        if not banks or not cfg or "=== PCR-DUMP-END ===" not in b:
            res.append(("final PCRs", False, "PCR dump or CONFIG line missing or cut short"))
        else:
            doc = {"pcrs": {x: pcrs[x] for x in banks}}
            if att is not None and "gpt" in att:
                doc["gpt"] = att["gpt"]
            open(base + ".pcrs.json", "w").write(json.dumps(doc, indent=2) + "\n")
            v, bad, gaps, trust, out = replay(
                [a.platform, f"{rp}/stage0.replay.json", f"{rp}/stage1.replay.json",
                 f"{rp}/stage2.replay.json"],
                [rp, uki], {"stage2": "@" + stage2, "config": cfg.group(1)},
                base + ".pcrs.json", ",".join(banks))
            good = v and not bad and set(gaps) <= {IMA_PCR}
            res.append((f"final PCRs ({'+'.join(banks)}, unsigned)", good,
                        f"mismatch PCR {bad}" if bad else
                        f"not reproduced PCR {gaps}" + ("" if set(gaps) <= {IMA_PCR} else " UNEXPECTED")))
            if a.verbose or not good:
                print(out)

        gpt = (att or {}).get("gpt", {}).get("sha256", "")[:16]
        reinit = re.search(r"data_reinit=(\w+)", b)
        print(f"boot {i}: payload ran, data_reinit={reinit.group(1) if reinit else '?'}, gpt {gpt}")
        for what, good, detail in res:
            if what:
                print(f"  {'PASS' if good else 'FAIL'}  {what}: {detail}")
                ok &= good
            else:
                print(f"        {detail}")

    # 5. reboot
    last = boots[-1] if boots else ""
    passed = "PIVOT_TEST=PASS" in last
    print(f"{'PASS' if passed else 'FAIL'}  reboot: "
          + ("PIVOT_TEST=PASS on the last boot" if passed else "no PIVOT_TEST=PASS on the last boot"))
    ok &= passed and checked >= 2
    if checked < 2:
        print(f"FAIL  only {checked} boot(s) reached the payload; the test needs two")
    print("GATE: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
