#!/usr/bin/env python3
# End-to-end PCR reconstruction for a Lock.Boot deployment -- the verifier's view.
#
# Rebuilds the full expected PCR set from release artifacts and hashes only; it never needs the
# user-data or the stage2 config (which may hold secrets):
#
#   --stage0 pcrs.json            stage0 release: PCR3-7 from reset (stage0 tools/predict-pcrs.py)
#   --stage1-sha256 HEX           what stage0 ran (stage0 extends PCR14 with it). Stop here if the
#                                 next stage is not ours.
#   --stage1-measurements FILE    our stage1 release's fixed extends (PCR5/9/11; stage1
#                                 tools/predict-pcrs.py --emit-measurements) -- the UKI whose
#                                 sha256 is --stage1-sha256.
#   --stage2-sha256 HEX           what stage1 ran (stage1 extends PCR14 with it). Stop here if the
#                                 next stage is not ours.
#   --config-sha256 HEX           our stage2's config digest (stage2 extends PCR15, sha256 bank),
#                                 disclosed by the operator instead of the config itself.
#   --golden FILE                 per-instance-type readings (vaportpm layout) for what no release
#                                 can predict: PCR0-2 (provider firmware / boot entries / ROMs).
#
# Each step only appends that stage's events to the state the previous one left (the same
# contracts the per-stage tools implement), so a deployment that swaps in its own stage1 or stage2
# stops at the handoff and continues with its own measurements. PCR10 (IMA) is never predicted.
#
# --check takes a serial log ("PCR <bank> <nn> <hex>" lines) or any JSON with a vaportpm-style
# "pcrs" object (e.g. an attestation), and compares every predicted PCR.
import argparse
import hashlib
import json
import re
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def reconstruct(a, banks):
    stage0 = load(a.stage0)["pcrs"]
    s1m = load(a.stage1_measurements)["extends"] if a.stage1_measurements else None
    golden = load(a.golden)["pcrs"] if a.golden else {}
    out, sources = {}, {}
    for bank in banks:
        H = getattr(hashlib, bank)
        zero = "00" * H().digest_size
        if bank not in stage0:
            raise SystemExit(f"stage0 pcrs.json has no {bank} bank")
        p = {int(k): v for k, v in stage0[bank].items()}
        src = {k: "stage0" for k in p}

        def extend(pcr, digests, who):
            v = bytes.fromhex(p.get(pcr, zero))
            for d in digests:
                v = H(v + d).digest()
            p[pcr] = v.hex()
            src[pcr] = who

        if a.stage1_sha256:   # stage0 measures the payload it runs: H_bank(sha256(payload))
            extend(14, [H(bytes.fromhex(a.stage1_sha256)).digest()], "stage0")
        if s1m is not None:
            if bank not in s1m:
                raise SystemExit(f"stage1 measurements have no {bank} bank")
            for pcr, ds in s1m[bank].items():
                extend(int(pcr), [bytes.fromhex(d) for d in ds], "stage1")
            for k in (8, 12, 13):
                if k not in p:
                    p[k], src[k] = zero, "stage1"
        if a.stage2_sha256:   # stage1 measures the stage2 binary the same way
            extend(14, [H(bytes.fromhex(a.stage2_sha256)).digest()], "stage1")
        if a.config_sha256:   # our stage2: raw sha256(config) into PCR15, sha256 bank only
            if bank == "sha256":
                extend(15, [bytes.fromhex(a.config_sha256)], "stage2")
            elif 15 not in p:
                p[15], src[15] = zero, "stage2"
        for k, v in golden.get(bank, {}).items():
            k = int(k)
            if k not in p and k != 10:
                p[k], src[k] = v, "golden"
        # Everything no stage touched is still at its reset value at this handoff (17-22 reset to
        # all-ones). PCR10 is IMA's once Linux has run (our stage1), so it is left out from there.
        for k in range(3, 24):
            if k not in p and not (k == 10 and s1m is not None):
                p[k], src[k] = ("ff" if 17 <= k <= 22 else "00") * H().digest_size, "reset"
        out[bank] = {str(k): v for k, v in sorted(p.items())}
        sources[bank] = src
    return {"pcrs": out}, sources


def observed(path):
    with open(path, "rb") as f:
        raw = f.read()
    try:
        doc = json.loads(raw)
        return {(b, int(i)): v.lower() for b, pcrs in doc["pcrs"].items() for i, v in pcrs.items()}
    except (ValueError, KeyError, AttributeError):
        txt = raw.decode("latin1").replace("\r", "")
        return {(b, int(i)): v for b, i, v in
                re.findall(r"^(?:payload: )?PCR (\w+) (\d\d) ([0-9a-f]+)$", txt, re.M)}


def main():
    ap = argparse.ArgumentParser(description="Reconstruct a deployment's expected PCRs end to end")
    ap.add_argument("--stage0", required=True, help="stage0 release pcrs.json")
    ap.add_argument("--stage1-sha256", help="sha256 of the payload stage0 runs")
    ap.add_argument("--stage1-measurements", help="our stage1 release's measurements.json")
    ap.add_argument("--stage2-sha256", help="sha256 of the stage2 binary stage1 runs")
    ap.add_argument("--config-sha256", help="our stage2's config digest (from the operator)")
    ap.add_argument("--golden", help="golden readings for this instance type (PCR0-2)")
    ap.add_argument("--banks", default="sha256,sha384", help="comma-separated (default sha256,sha384)")
    ap.add_argument("--out", help="write JSON here (default stdout)")
    ap.add_argument("--check", metavar="FILE", help="serial log or attestation JSON to compare")
    a = ap.parse_args()
    if a.stage1_measurements and not a.stage1_sha256:
        ap.error("--stage1-measurements needs --stage1-sha256 (the UKI it describes)")
    if a.stage2_sha256 and not a.stage1_measurements:
        ap.error("--stage2-sha256 needs --stage1-measurements (it is our stage1 that measures it)")
    if a.config_sha256 and not a.stage2_sha256:
        ap.error("--config-sha256 needs --stage2-sha256 (it is our stage2 that measures it)")

    pred, sources = reconstruct(a, a.banks.split(","))
    for bank, src in sources.items():
        missing = [k for k in range(24) if k not in src]
        if missing:
            print(f"{bank}: not reconstructed: PCR {','.join(map(str, missing))}"
                  + ("" if a.golden else " (pass --golden for PCR0-2)"), file=sys.stderr)
    if a.check:
        seen = observed(a.check)
        bad = 0
        for bank, pcrs in pred["pcrs"].items():
            for i, want in pcrs.items():
                got = seen.get((bank, int(i)))
                st = "ok" if got == want else ("MISSING" if got is None else "MISMATCH")
                bad += st != "ok"
                print(f"{bank:7} PCR{int(i):<2} {st:8} [{sources[bank][int(i)]:6}] {want[:16]}"
                      + ("" if st == "ok" or got is None else f"  read {got[:16]}"))
        print("ALL RECONSTRUCTED PCRS MATCH" if not bad else f"{bad} PCR(S) DO NOT MATCH")
        sys.exit(1 if bad else 0)
    js = json.dumps(pred, indent=2) + "\n"
    if a.out:
        with open(a.out, "w") as f:
            f.write(js)
    else:
        sys.stdout.write(js)


if __name__ == "__main__":
    main()
