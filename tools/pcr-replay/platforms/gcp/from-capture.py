#!/usr/bin/env python3
"""Write a GCE platform replay file (PCR0-2 from reset) from a probe capture.

A capture is the serial console of one boot of the stage0 test payload, which prints the TCG event
log as `payload: EV n pcr type` / `EVD n alg digest` / `EVX n hexdata` lines (see README.md).
Every PCR0-2 event becomes a derivation from its logged bytes, so pcr-replay re-checks it, except
the ACPI DATA events, whose digests cover ACPI tables that are not in the log: those are pinned.
An event type not handled below is refused, not guessed at.

usage: from-capture.py CAPTURE --name NAME --out FILE.replay.json
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import uuid
from typing import Any

PLATFORM_PCRS = (0, 1, 2)
ALG = {0x4: "sha1", 0xB: "sha256", 0xC: "sha384", 0xD: "sha512"}
EV_NO_ACTION = 0x3
EV_SEPARATOR = 0x4
EV_S_CRTM_VERSION = 0x8
EV_PLATFORM_CONFIG_FLAGS = 0xA
EV_NONHOST_INFO = 0x11
EV_EFI_VARIABLE_BOOT = 0x80000002
NONHOST_PREFIX = b"GCE NonHostInfo\0"


def parse(txt: str) -> tuple[list[dict[str, Any]], dict[tuple[str, int], str]]:
    evs: dict[int, dict[str, Any]] = {}
    for kind, n, rest in re.findall(r"payload: (EV|EVD|EVX) (\d+) ?([^\n]*)", txt):
        f = rest.split()
        if kind == "EV":
            evs[int(n)] = {"pcr": int(f[0]), "type": int(f[1], 16), "dg": {}, "data": b""}
        elif kind == "EVD":
            evs[int(n)]["dg"][ALG[int(f[0], 16)]] = f[1]
        else:
            evs[int(n)]["data"] += bytes.fromhex(f[0])
    if "EVENTLOG-END" not in txt or "truncated=false" not in txt:
        raise SystemExit("capture has no complete event log (no 'EVENTLOG-END ... truncated=false')")
    pcrs = {(b, int(i)): v for b, i, v in re.findall(r"payload: PCR (\w+) (\d\d) ([0-9a-f]+)", txt)}
    return [evs[n] for n in sorted(evs)], pcrs


def device_path(dp: bytes) -> str:
    """The device-path nodes GCE's boot options use, in UEFI text form; anything else as hex."""
    out, i = [], 0
    while i + 4 <= len(dp):
        t, s, ln = dp[i], dp[i + 1], struct.unpack_from("<H", dp, i + 2)[0]
        body = dp[i + 4:i + ln]
        if (t, s) == (0x7F, 0xFF):
            break
        if (t, s) == (2, 1):
            out.append(f"PciRoot({struct.unpack_from('<I', body, 4)[0]:#x})")
        elif (t, s) == (1, 1):
            out.append(f"Pci({body[1]:#x},{body[0]:#x})")
        elif (t, s) == (3, 2):
            out.append(f"Scsi({struct.unpack_from('<H', body, 0)[0]:#x},{struct.unpack_from('<H', body, 2)[0]:#x})")
        elif (t, s) == (3, 0x17):
            out.append(f"NVMe({struct.unpack_from('<I', body, 0)[0]:#x},{body[4:12].hex('-').upper()})")
        elif (t, s) == (4, 6):
            out.append(f"FvFile({uuid.UUID(bytes_le=body[:16])})")
        elif (t, s) == (4, 7):
            out.append(f"Fv({uuid.UUID(bytes_le=body[:16])})")
        else:
            out.append(f"Node({t:#x},{s:#x},{body.hex()})")
        i += ln
    return "/".join(out)


def utf16z(b: bytes) -> tuple[str, bytes]:
    for i in range(0, len(b) - 1, 2):
        if b[i:i + 2] == b"\0\0":
            return b[:i].decode("utf-16-le"), b[i + 2:]
    raise ValueError("unterminated UTF-16 string")


def boot_variable(data: bytes) -> tuple[str, bytes]:
    """(description, VariableData) of an EV_EFI_VARIABLE_BOOT event's UEFI_VARIABLE_DATA."""
    nlen, dlen = struct.unpack_from("<QQ", data, 16)
    name = data[32:32 + 2 * nlen].decode("utf-16-le")
    var = data[32 + 2 * nlen:32 + 2 * nlen + dlen]
    if name == "BootOrder":
        order = ", ".join(f"Boot{n:04X}" for n in struct.unpack(f"<{len(var) // 2}H", var))
        return f"BootOrder = {order}", var
    if re.fullmatch(r"Boot[0-9A-F]{4}", name):
        _attr, fpl = struct.unpack_from("<IH", var, 0)
        desc, rest = utf16z(var[6:])
        return f"{name} \"{desc}\" {device_path(rest[:fpl])}", var
    raise SystemExit(f"unhandled boot variable {name}")


def platform_event(e: dict[str, Any]) -> dict[str, Any]:
    t, d, p = e["type"], e["data"], e["pcr"]
    ev: dict[str, Any] = {"pcr": p, "by": "GCE firmware"}
    if t == EV_S_CRTM_VERSION:
        s = d.decode("utf-16-le").rstrip("\0")
        ev |= {"type": "EV_S_CRTM_VERSION", "about": "firmware version string (no firmware code is measured)",
               "derive": {"utf16le": s, "nul": True}}
    elif t == EV_NONHOST_INFO:
        if not d.startswith(NONHOST_PREFIX) or len(d) != len(NONHOST_PREFIX) + 16:
            raise SystemExit(f"unexpected EV_NONHOST_INFO {d.hex()}")
        tech = d[len(NONHOST_PREFIX):]
        ev |= {"type": "EV_NONHOST_INFO",
               "about": f"confidential-computing technology byte {tech[0]} (0 none, 1 SEV, 4 SEV-SNP observed)",
               "derive": {"concat": [{"utf8": "GCE NonHostInfo", "nul": True}, {"hex": tech.hex()}]}}
    elif t == EV_PLATFORM_CONFIG_FLAGS and d == b"ACPI DATA":
        ev |= {"type": "EV_PLATFORM_CONFIG_FLAGS",
               "about": "ACPI DATA: digest of ACPI tables not in the log; pinned per machine shape"}
    elif t == EV_EFI_VARIABLE_BOOT:
        about, var = boot_variable(d)
        ev |= {"type": "EV_EFI_VARIABLE_BOOT", "about": f"{about} (digest covers VariableData only)",
               "derive": {"hex": var.hex()}}
    elif t == EV_SEPARATOR and d == b"\0\0\0\0":
        ev |= {"type": "EV_SEPARATOR", "about": "separator", "derive": {"hex": "00000000"}}
    else:
        raise SystemExit(f"unhandled PCR{p} event type {t:#x} ({d[:32].hex()})")
    ev["digests"] = dict(sorted(e["dg"].items()))
    return ev


def firmware_rim(evs: list[dict[str, Any]]) -> str | None:
    for e in evs:
        if e["type"] == EV_NO_ACTION and e["data"].startswith(b"SP800-155 Event3"):
            m = re.search(rb"https://[!-~]+", e["data"])
            if m:
                return m.group().decode()
    return None


def main() -> None:
    ap = argparse.ArgumentParser(description="Write a GCE platform replay file from a probe capture")
    ap.add_argument("capture")
    ap.add_argument("--name", required=True, help="the file's name, e.g. 'gcp n2d-standard-2 SEV'")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    with open(a.capture, "rb") as f:
        evs, pcrs = parse(f.read().decode("latin1").replace("\r", ""))
    events = [platform_event(e) for e in evs if e["pcr"] in PLATFORM_PCRS and e["type"] != EV_NO_ACTION]
    rim = firmware_rim(evs)
    doc = {
        "schema": "pcr-replay/v1",
        "name": a.name,
        "about": "GCE firmware, from reset to the separators in PCR0-2 (written by from-capture.py from "
                 f"captures/{a.capture.rsplit('/', 1)[-1]}). PCR0 does not measure the firmware binary: "
                 "firmware integrity comes from the SEV-SNP/TDX launch measurement plus Google's "
                 "endorsement, not from these PCRs. The log names the firmware it ran (an unextended "
                 f"SP800-155 event, a claim rather than a measurement): {rim or 'none'}.",
        "reset": list(PLATFORM_PCRS),
        "unextended": [p for p in range(24) if p not in PLATFORM_PCRS],
        "events": events,
    }
    with open(a.out, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    print(f"{a.out}: {len(events)} events, "
          + ", ".join(f"PCR{p} sha256 {pcrs.get(('sha256', p), '?')[:8]}" for p in PLATFORM_PCRS))


if __name__ == "__main__":
    main()
