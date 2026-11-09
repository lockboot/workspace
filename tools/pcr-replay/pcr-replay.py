#!/usr/bin/env python3
# pcr-replay: replay a chain of PCR replay files, re-derive every digest they embed, and check
# the result against a quote's PCR values. Format: README.md (schema "pcr-replay/v1").
# Python >= 3.11, standard library only.
#
#   pcr-replay.py FILE... [--artifacts PATH]... [--input NAME=HEX|@FILE]... [--banks B,B]
#                         [--out pcrs.json] [--check QUOTE] [-v]
#
# Files are applied in the order given (only the order of events within one PCR matters, so a
# platform file and the boot-chain files interleave freely). Every event whose derivation can be
# evaluated is recomputed and must equal the digests the file embeds; events that cannot be
# re-derived (pinned, or their artifact was not supplied) are carried at face value and reported
# as such. A PCR is only reproduced if some file models it from reset and every later file
# accounts for it.
#
# This compares PCR values; it does not verify the quote's signature or nonce (vaportpm-verify).
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import sys
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Literal, NotRequired, TypedDict, Union, cast

SCHEMA = "pcr-replay/v1"
BANKS = ("sha1", "sha256", "sha384", "sha512")
NPCR = 24
EFI_CERT_X509 = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
EFI_CERT_SHA256 = uuid.UUID("c1c41626-504c-4092-aca9-41f936934328")


# --- the file format (README.md) --------------------------------------------------------------------
# Derivations: each node is a single-key object (plus its own modifiers) evaluating to bytes.
class Utf8(TypedDict):
    utf8: str
    nul: NotRequired[bool]          # append one NUL byte


class Utf16le(TypedDict):
    utf16le: str
    nul: NotRequired[bool]          # append a UTF-16 NUL (two bytes)


class Hex(TypedDict):
    hex: str


class Guid(TypedDict):
    guid: str                       # the GUID's bytes in EFI (mixed-endian) order


class ArtifactRef(TypedDict):
    artifact: str                   # a declared artifact's whole contents


class InputRef(TypedDict):
    input: str                      # a declared input's 32 bytes


class Concat(TypedDict):
    concat: list[Derivation]


class Pad(TypedDict):
    pad: int                        # zero-pad to a multiple of this
    of: Derivation


class PeSection(TypedDict):
    pe_section: str                 # a PE section's contents (min(VirtualSize, SizeOfRawData))
    of: Derivation


class Gpt(TypedDict):
    gpt: Derivation                 # UEFI_GPT_DATA of a disk image


class UefiVariableArgs(TypedDict):
    vendor: str
    name: str
    data: Derivation


class UefiVariable(TypedDict):
    uefi_variable: UefiVariableArgs  # UEFI_VARIABLE_DATA


class EslArgs(TypedDict):
    type: str                       # "x509", "sha256" or a signature-type GUID
    owner: str
    data: Derivation


class Esl(TypedDict):
    efi_signature_list: EslArgs     # one EFI_SIGNATURE_LIST with one entry


class CpioEntry(TypedDict):
    ino: int
    mode: str                       # octal, including the file-type bits
    name: str
    data: NotRequired[Derivation]


class Cpio(TypedDict):
    cpio_newc: list[CpioEntry]      # newc entries (no trailer: spell it out, writers differ)


Derivation = Union[Utf8, Utf16le, Hex, Guid, ArtifactRef, InputRef, Concat, Pad, PeSection, Gpt,
                   UefiVariable, Esl, Cpio]
DigestMode = Literal["hash", "authenticode", "raw"]


class Event(TypedDict):
    pcr: int
    type: NotRequired[str]          # TCG event type, or "unlogged" for a direct TPM2_PCR_Extend
    by: NotRequired[str]            # who extends it
    about: NotRequired[str]
    derive: NotRequired[Derivation]
    digest: NotRequired[DigestMode]  # how the extended digest follows from the derived bytes
    banks: NotRequired[list[str]]   # only extended in these banks
    digests: NotRequired[dict[str, str]]  # bank -> hex, as the producer computed them
    value: NotRequired[dict[str, str]]    # instead of an extend: the PCR's pinned value here


class ArtifactDecl(TypedDict):
    sha256: str
    file: NotRequired[str]
    about: NotRequired[str]


class InputDecl(TypedDict):
    about: str
    next_entry: NotRequired[bool]   # defaults to the sha256 of the next file's entry artifact


class ReplayDoc(TypedDict):
    schema: str
    name: NotRequired[str]
    about: NotRequired[str]
    artifacts: NotRequired[dict[str, ArtifactDecl]]
    entry: NotRequired[str]         # the artifact the previous stage loads (and measures)
    inputs: NotRequired[dict[str, InputDecl]]
    reset: NotRequired[list[int]]   # PCRs this file models from their reset value
    unextended: NotRequired[list[int]]  # PCRs this file does not extend
    unpredictable: NotRequired[dict[str, str]]  # PCRs extended in ways no file can replay -> why
    events: list[Event]


class PcrsDoc(TypedDict):
    pcrs: dict[str, dict[str, str]]  # vaportpm layout: bank -> pcr -> hex


Hasher = Callable[..., "hashlib._Hash"]
InputKey = tuple[str, str]          # (file label, input name)
Quote = dict[tuple[str, int], str]  # (bank, pcr) -> hex


class Missing(Exception):
    """A derivation needs an artifact or input that was not supplied."""


class Bad(Exception):
    """The replay files are malformed or inconsistent."""


def hasher(bank: str) -> Hasher:
    return cast(Hasher, getattr(hashlib, bank))


def digest_size(bank: str) -> int:
    return hasher(bank)().digest_size


def reset_value(pcr: int, size: int) -> bytes:
    return (b"\xff" if 17 <= pcr <= 22 else b"\0") * size


# --- binary formats the derivations build -----------------------------------------------------------
def u16(b: bytes, off: int) -> int:
    return cast(int, struct.unpack_from("<H", b, off)[0])


def u32(b: bytes, off: int) -> int:
    return cast(int, struct.unpack_from("<I", b, off)[0])


def pe_section(pe: bytes, name: str) -> bytes:
    coff = u32(pe, 0x3C) + 4
    nsec, opt_size = u16(pe, coff + 2), u16(pe, coff + 16)
    for i in range(nsec):
        s = coff + 20 + opt_size + 40 * i
        if pe[s:s + 8].rstrip(b"\0").decode() == name:
            vsize, rsize, rptr = u32(pe, s + 8), u32(pe, s + 16), u32(pe, s + 20)
            return pe[rptr:rptr + min(vsize, rsize)]
    raise Bad(f"PE has no section {name}")


def authenticode(pe: bytes, H: Hasher) -> bytes:
    """Authenticode PE image hash (PE/COFF spec; what UEFI firmware logs for a loaded image)."""
    coff = u32(pe, 0x3C) + 4
    nsec, opt_size = u16(pe, coff + 2), u16(pe, coff + 16)
    opt = coff + 20
    checksum = opt + 64
    cert_dir = opt + (96 if u16(pe, opt) == 0x10B else 112) + 4 * 8   # DataDirectory[4] (security)
    size_hdrs = u32(pe, opt + 60)
    cert_off, cert_len = u32(pe, cert_dir), u32(pe, cert_dir + 4)
    h = H()
    h.update(pe[:checksum])
    h.update(pe[checksum + 4:cert_dir])
    h.update(pe[cert_dir + 8:size_hdrs])
    secs: list[tuple[int, int]] = []
    for i in range(nsec):
        s = opt + opt_size + 40 * i
        raw_size, raw_ptr = u32(pe, s + 16), u32(pe, s + 20)
        if raw_size:
            secs.append((raw_ptr, raw_size))
    done = size_hdrs
    for ptr, size in sorted(secs):
        h.update(pe[ptr:ptr + size])
        done = max(done, ptr + size)
    end = len(pe) - (cert_len if cert_off else 0)
    if end > done:
        h.update(pe[done:end])
    return h.digest()


def gpt_data(disk: bytes, sector: int = 512) -> bytes:
    """UEFI_GPT_DATA: the primary GPT header, NumberOfPartitions, the non-empty entries."""
    hdr = disk[sector:2 * sector]
    if hdr[:8] != b"EFI PART":
        raise Bad("no GPT header at LBA 1")
    hsize = u32(hdr, 12)
    ent_lba: int = struct.unpack_from("<Q", hdr, 72)[0]
    nent, esize = u32(hdr, 80), u32(hdr, 84)
    raw = disk[ent_lba * sector:ent_lba * sector + nent * esize]
    used = [raw[i:i + esize] for i in range(0, len(raw), esize) if raw[i:i + 16] != b"\0" * 16]
    return hdr[:hsize] + struct.pack("<Q", len(used)) + b"".join(used)


def pad(b: bytes, n: int) -> bytes:
    return b + b"\0" * ((-len(b)) % n)


def cpio_newc_entry(ino: int, mode: int, name: bytes, data: bytes) -> bytes:
    """One newc entry: uid/gid 0, nlink 1, mtime 0, dev/rdev 0, header+name and data 4-aligned."""
    def w(v: int) -> bytes:
        return b"%08x" % v
    hdr = (b"070701" + w(ino) + w(mode) + w(0) + w(0) + w(1) + w(0) + w(len(data))
           + w(0) * 4 + w(len(name) + 1) + w(0) + name + b"\0")
    return pad(hdr, 4) + pad(data, 4)


def guid(s: str) -> bytes:
    return uuid.UUID(s).bytes_le


# --- replay files -----------------------------------------------------------------------------------
@dataclass
class ReplayFile:
    path: str
    label: str
    artifacts: dict[str, ArtifactDecl]
    inputs: dict[str, InputDecl]
    entry: str | None
    events: list[Event]
    reset: set[int]
    unextended: set[int]
    unpredictable: dict[int, str]
    extends: set[int] = field(default_factory=set)

    @classmethod
    def load(cls, path: str) -> ReplayFile:
        with open(path) as f:
            d = cast(ReplayDoc, json.load(f))
        if d.get("schema") != SCHEMA:
            raise Bad(f"{path}: schema is {d.get('schema')!r}, expected {SCHEMA!r}")
        rf = cls(path=path, label=d.get("name") or os.path.basename(path),
                 artifacts=d.get("artifacts", {}), inputs=d.get("inputs", {}),
                 entry=d.get("entry"), events=d["events"],
                 reset=set(d.get("reset", [])), unextended=set(d.get("unextended", [])),
                 unpredictable={int(k): v for k, v in d.get("unpredictable", {}).items()})
        rf.extends = {e["pcr"] for e in rf.events}
        if rf.entry is not None and rf.entry not in rf.artifacts:
            raise Bad(f"{path}: entry {rf.entry!r} is not a declared artifact")
        clash = (rf.reset | rf.extends) & (rf.unextended | set(rf.unpredictable))
        if clash:
            raise Bad(f"{path}: PCR(s) {sorted(clash)} both extended and declared unextended/unpredictable")
        return rf


class Ctx:
    """What a derivation may draw on: the supplied artifacts (by sha256) and bound inputs."""

    def __init__(self, artifacts: dict[str, bytes], inputs: dict[InputKey, bytes], file: ReplayFile):
        self.artifacts, self.inputs, self.file = artifacts, inputs, file

    def artifact(self, name: str) -> bytes:
        decl = self.file.artifacts.get(name)
        if decl is None:
            raise Bad(f"{self.file.label}: artifact {name!r} is not declared")
        data = self.artifacts.get(decl["sha256"])
        if data is None:
            raise Missing(f"artifact {name} (sha256 {decl['sha256'][:16]}...)")
        return data

    def input(self, name: str) -> bytes:
        if name not in self.file.inputs:
            raise Bad(f"{self.file.label}: input {name!r} is not declared")
        v = self.inputs.get((self.file.label, name))
        if v is None:
            raise Missing(f"input {name}")
        return v


MODIFIERS = {"nul", "of"}


def derive(x: Derivation, c: Ctx) -> bytes:
    """Evaluate a derivation expression to the bytes an event's digest is computed over."""
    if not isinstance(x, dict) or len(set(x) - MODIFIERS) != 1:
        raise Bad(f"bad derivation {x!r}")
    if "utf8" in x:
        x = cast(Utf8, x)
        return x["utf8"].encode() + (b"\0" if x.get("nul") else b"")
    if "utf16le" in x:
        x = cast(Utf16le, x)
        return x["utf16le"].encode("utf-16-le") + (b"\0\0" if x.get("nul") else b"")
    if "hex" in x:
        return bytes.fromhex(cast(Hex, x)["hex"])
    if "guid" in x:
        return guid(cast(Guid, x)["guid"])
    if "artifact" in x:
        return c.artifact(cast(ArtifactRef, x)["artifact"])
    if "input" in x:
        return c.input(cast(InputRef, x)["input"])
    if "concat" in x:
        return b"".join(derive(e, c) for e in cast(Concat, x)["concat"])
    if "pad" in x:
        p = cast(Pad, x)
        return pad(derive(p["of"], c), p["pad"])
    if "pe_section" in x:
        s = cast(PeSection, x)
        return pe_section(derive(s["of"], c), s["pe_section"])
    if "gpt" in x:
        return gpt_data(derive(cast(Gpt, x)["gpt"], c))
    if "uefi_variable" in x:
        v = cast(UefiVariable, x)["uefi_variable"]
        data = derive(v["data"], c)
        return (guid(v["vendor"]) + struct.pack("<QQ", len(v["name"]), len(data))
                + v["name"].encode("utf-16-le") + data)
    if "efi_signature_list" in x:
        e = cast(Esl, x)["efi_signature_list"]
        st = {"x509": EFI_CERT_X509, "sha256": EFI_CERT_SHA256}.get(e["type"]) or uuid.UUID(e["type"])
        sig = guid(e["owner"]) + derive(e["data"], c)
        return st.bytes_le + struct.pack("<III", 28 + len(sig), 0, len(sig)) + sig
    if "cpio_newc" in x:
        return b"".join(cpio_newc_entry(ent["ino"], int(ent["mode"], 8), ent["name"].encode(),
                                        derive(ent["data"], c) if "data" in ent else b"")
                        for ent in cast(Cpio, x)["cpio_newc"])
    raise Bad(f"unknown derivation {sorted(x)}")


def event_digest(ev: Event, data: bytes, bank: str) -> bytes:
    H = hasher(bank)
    how: DigestMode = ev.get("digest", "hash")
    if how == "hash":
        return H(data).digest()
    if how == "authenticode":
        return authenticode(data, H)
    if how == "raw":
        if len(data) != digest_size(bank):
            raise Bad(f"raw extend of {len(data)} bytes into {bank}")
        return data
    raise Bad(f"unknown digest mode {how!r}")


def load_artifacts(paths: list[str]) -> dict[str, bytes]:
    """Every file under the given paths, keyed by sha256 (declarations name artifacts by hash)."""
    found: dict[str, bytes] = {}
    for p in paths:
        walk = [p] if os.path.isfile(p) else [os.path.join(r, n) for r, _, ns in os.walk(p) for n in ns]
        for fp in walk:
            with open(fp, "rb") as f:
                b = f.read()
            found[hashlib.sha256(b).hexdigest()] = b
    return found


def bind_inputs(files: list[ReplayFile], given: dict[str, bytes]) -> tuple[dict[InputKey, bytes], list[str]]:
    """Inputs are named per file; --input NAME applies to the one file declaring NAME (qualify as
    FILE:NAME if several do). An undeclared name is an error. An input marked "next_entry" with no
    value is bound to the next file's entry artifact; a given value must agree with it."""
    out: dict[InputKey, bytes] = {}
    notes: list[str] = []
    for spec, v in given.items():
        lab, _, name = spec.rpartition(":")
        owners = [f.label for f in files if name in f.inputs and lab in ("", f.label)]
        if len(owners) != 1:
            raise Bad(f"--input {spec}: declared by {owners or 'no file'}"
                      + (" (qualify as FILE:NAME)" if len(owners) > 1 else ""))
        out[(owners[0], name)] = v
    for f, nxt in zip(files, files[1:]):
        if nxt.entry is None:
            continue
        for name, decl in f.inputs.items():
            if not decl.get("next_entry"):
                continue
            want = bytes.fromhex(nxt.artifacts[nxt.entry]["sha256"])
            k = (f.label, name)
            if k in out and out[k] != want:
                raise Bad(f"{f.label} input {name} = {out[k].hex()[:16]}... but the next file, "
                          f"{nxt.label}, describes {nxt.entry} = {want.hex()[:16]}...")
            if k not in out:
                notes.append(f"{f.label}: input {name} = sha256 of {nxt.label}'s {nxt.entry}")
            out[k] = want
    return out, notes


# --- replay -----------------------------------------------------------------------------------------
EventStatus = Literal["verified", "derived", "pinned", "unchecked"]


@dataclass
class Trust:
    verified: int = 0                                    # re-derived, equal to the embedded digest
    derived: int = 0                                     # re-derived, nothing embedded to compare
    pinned: list[str] = field(default_factory=list)      # no derivation: taken on the file's word
    unchecked: list[str] = field(default_factory=list)   # derivable, but an artifact was not supplied


@dataclass
class Result:
    pcrs: dict[str, dict[int, str]]      # bank -> pcr -> hex, reproduced PCRs only
    gaps: dict[str, dict[int, str]]      # bank -> pcr -> why it is not reproduced
    trust: Trust


def extend(bank: str, v: bytes, d: bytes) -> bytes:
    return hasher(bank)(v + d).digest()


def replay(files: list[ReplayFile], banks: list[str], artifacts: dict[str, bytes],
           inputs: dict[InputKey, bytes], verbose: bool) -> Result:
    val = {b: {p: reset_value(p, digest_size(b)) for p in range(NPCR)} for b in banks}
    lost: dict[str, dict[int, str]] = {b: {} for b in banks}       # pcr -> why its value is unknown
    cov: dict[int, str | None] = {p: "no file models it from reset" for p in range(NPCR)}  # None: modelled
    touched: set[int] = set()
    trust = Trust()
    errors: list[str] = []

    for f in files:
        for p in range(NPCR):
            if p in f.reset:
                if p in touched:
                    raise Bad(f"{f.label}: models PCR{p} from reset, but an earlier file extended it")
                cov[p] = None
            elif p in f.unpredictable:
                cov[p] = f"unpredictable after {f.label}: {f.unpredictable[p]}"
            elif cov[p] is None and p not in f.extends and p not in f.unextended:
                cov[p] = f"{f.label} does not account for it"
        c = Ctx(artifacts, inputs, f)
        for n, ev in enumerate(f.events):
            p = ev["pcr"]
            what = f"{f.label} #{n} PCR{p} {ev.get('type', '')} {ev.get('about', '')}".rstrip()
            if "value" in ev:     # the PCR's value at this point, pinned: models it from here
                if p in touched:
                    raise Bad(f"{what}: pins a value over earlier events")
                touched.add(p)
                cov[p] = None
                for b in banks:
                    if b in ev["value"]:
                        val[b][p] = bytes.fromhex(ev["value"][b])
                    else:
                        lost[b][p] = f"{f.label} pins no {b} value"
                trust.pinned.append(what)
                if verbose:
                    print(f"  pinned    {what}", file=sys.stderr)
                continue
            touched.add(p)
            data: bytes | None = None
            why: str | None = None
            if "derive" in ev:
                try:
                    data = derive(ev["derive"], c)
                except Missing as e:
                    why = str(e)
            st: EventStatus | None = None
            for b in banks:
                if "banks" in ev and b not in ev["banks"]:
                    continue
                emb_hex = ev.get("digests", {}).get(b)
                emb = bytes.fromhex(emb_hex) if emb_hex else None
                if data is not None:
                    d = event_digest(ev, data, b)
                    if emb is not None and emb != d:
                        errors.append(f"{what}: {b} digest re-derives to {d.hex()[:16]}..., "
                                      f"file says {emb.hex()[:16]}...")
                    st = "verified" if emb is not None else (st or "derived")
                elif emb is not None:
                    d, st = emb, ("pinned" if "derive" not in ev else "unchecked")
                else:
                    lost[b].setdefault(p, f"{what}: {why}" if why else f"{what}: no {b} digest")
                    continue
                if p not in lost[b]:
                    val[b][p] = extend(b, val[b][p], d)
            if st == "verified":
                trust.verified += 1
            elif st == "derived":
                trust.derived += 1
            elif st == "pinned":
                trust.pinned.append(what)
            elif st == "unchecked":
                trust.unchecked.append(f"{what} ({why})")
            if verbose:
                print(f"  {st or 'lost':9} {what}" + (f"  [{why}]" if why else ""), file=sys.stderr)
    if errors:
        raise Bad("replay files do not match their own derivations:\n  " + "\n  ".join(errors))
    pcrs = {b: {p: val[b][p].hex() for p in range(NPCR) if cov[p] is None and p not in lost[b]}
            for b in banks}
    gaps = {b: {p: cov[p] or lost[b][p] for p in range(NPCR) if cov[p] is not None or p in lost[b]}
            for b in banks}
    return Result(pcrs, gaps, trust)


# --- quotes -----------------------------------------------------------------------------------------
def read_quote(path: str) -> Quote:
    """A vaportpm attestation / any JSON with a top-level "pcrs" {bank: {n: hex}}, or a serial log
    with "PCR <bank> <nn> <hex>" lines."""
    with open(path, "rb") as f:
        raw = f.read()
    quote: Quote
    try:
        doc = cast(PcrsDoc, json.loads(raw))
        quote = {(b, int(i)): v.lower() for b, pcrs in doc["pcrs"].items() for i, v in pcrs.items()}
    except (ValueError, KeyError, AttributeError, TypeError):
        txt = raw.decode("latin1").replace("\r", "")
        quote = {(b, int(i)): v for b, i, v in
                 re.findall(r"^(?:payload: )?PCR (\w+) (\d\d) ([0-9a-f]+)$", txt, re.M)}
    # A truncated or garbled value (a console cut off mid-line) is a malformed quote, not a PCR
    # that differs.
    for (b, i), v in sorted(quote.items()):
        if hasattr(hashlib, b) and not re.fullmatch(f"[0-9a-f]{{{2 * digest_size(b)}}}", v):
            raise Bad(f"quote {path}: {b} PCR{i} is not {digest_size(b)} bytes of hex: {v!r}")
    return quote


def parse_inputs(ap: argparse.ArgumentParser, specs: list[str]) -> dict[str, bytes]:
    given: dict[str, bytes] = {}
    for s in specs:
        k, sep, v = s.partition("=")
        if not sep:
            ap.error(f"--input {s}: expected NAME=VALUE")
        if v.startswith("@"):
            with open(v[1:], "rb") as f:
                given[k] = hashlib.sha256(f.read()).digest()
        else:
            given[k] = bytes.fromhex(v)
            if len(given[k]) != 32:
                ap.error(f"--input {k}: expected a 32-byte sha256")
    return given


def check(result: Result, banks: list[str], seen: Quote) -> bool:
    bad = absent = 0
    for b in banks:
        for p, want in result.pcrs[b].items():
            got = seen.get((b, p))
            st = "ok" if got == want else ("absent" if got is None else "MISMATCH")
            bad += st == "MISMATCH"
            absent += st == "absent"
            print(f"{b:7} PCR{p:<2} {st:8} {want[:16]}" + (f"  quote {got[:16]}" if got and st == "MISMATCH" else ""))
        extra = sorted(p for (qb, p) in seen if qb == b and p not in result.pcrs[b])
        if extra:
            print(f"{b:7} in the quote but not reproduced: PCR {','.join(map(str, extra))}")
    trusted = len(result.trust.pinned) + len(result.trust.unchecked)
    if bad:
        print(f"CHAIN DOES NOT VERIFY: {bad} PCR(s) differ")
        return False
    print("CHAIN VERIFIES" + (f" ({absent} reproduced PCR(s) not in the quote)" if absent else "")
          + ("" if not trusted else f" -- taking {trusted} event(s) on trust, listed above"))
    return True


def main() -> None:
    ap = argparse.ArgumentParser(description="Replay PCR replay files and check them against a quote")
    ap.add_argument("files", nargs="+", help="replay files, in boot order")
    ap.add_argument("--artifacts", action="append", default=[], metavar="PATH",
                    help="file or directory of artifacts to re-derive from (matched by sha256)")
    ap.add_argument("--input", action="append", default=[], metavar="NAME=HEX|@FILE",
                    help="value of a declared input (a sha256; @FILE hashes FILE)")
    ap.add_argument("--banks", default="sha256,sha384", help="comma-separated (default sha256,sha384)")
    ap.add_argument("--out", help="write the reproduced PCRs as JSON (vaportpm layout)")
    ap.add_argument("--check", metavar="QUOTE", help="attestation JSON or serial log to compare")
    ap.add_argument("-v", "--verbose", action="store_true", help="list every event")
    a = ap.parse_args()
    banks: list[str] = a.banks.split(",")
    for b in banks:
        if b not in BANKS:
            ap.error(f"unknown bank {b}")
    given = parse_inputs(ap, a.input)
    try:
        files = [ReplayFile.load(p) for p in a.files]
        labels = [f.label for f in files]
        if len(set(labels)) != len(labels):
            raise Bad(f"replay files share a name: {labels}")
        inputs, notes = bind_inputs(files, given)
        for note in notes:
            print(f"bound: {note}", file=sys.stderr)
        result = replay(files, banks, load_artifacts(a.artifacts), inputs, a.verbose)
        seen = read_quote(a.check) if a.check else None
    except Bad as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)

    for b in banks:
        for p, why in sorted(result.gaps[b].items()):
            print(f"{b:7} PCR{p:<2} not reproduced: {why}", file=sys.stderr)
    t = result.trust
    print(f"events: {t.verified} re-derived and verified, {t.derived} derived, "
          f"{len(t.pinned)} pinned, {len(t.unchecked)} unchecked", file=sys.stderr)
    for w in t.pinned:
        print(f"  pinned: {w}", file=sys.stderr)
    for w in t.unchecked:
        print(f"  unchecked: {w}", file=sys.stderr)

    if a.out:
        out: PcrsDoc = {"pcrs": {b: {str(p): v for p, v in r.items()} for b, r in result.pcrs.items()}}
        with open(a.out, "w") as f:
            json.dump(out, f, indent=2)
            f.write("\n")
    if seen is not None and not check(result, banks, seen):
        sys.exit(1)


if __name__ == "__main__":
    main()
