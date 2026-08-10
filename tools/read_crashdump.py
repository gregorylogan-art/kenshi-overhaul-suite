#!/usr/bin/env python3
"""read_crashdump.py -- parse Kenshi's native crash dump for a real answer.

WHY THIS EXISTS
Every crash so far had been diagnosed by inference from the LAST LINE of the
KenshiLua log (log-as-cursor) -- a reasonable technique when nothing else is
available, but a guess, not a fact: the last thing WE logged is not
necessarily the last thing that RAN before the fault, and it says nothing
about WHICH MODULE actually crashed.

Kenshi writes a real crash dump on a native fault:
  <Kenshi install>\\crashDump<version>_x64.zip
    - crashDump<version>_x64.dmp   -- a standard Windows minidump
    - save.log, Havok.log, MyGUI.log, terrain.log, kenshi.cfg, settings.cfg
      -- Kenshi's own logs, frozen at the moment of the crash

The .dmp is a real minidump (MDMP signature) with an ExceptionStream (the
exception code + faulting address) and a ModuleListStream (every loaded DLL's
base address and size). This script parses both directly -- no debugger
required -- and reports which MODULE the crash address falls inside.

That answers the one question log-as-cursor cannot: was this OUR code
(KenshiLua.dll) or something else entirely (OgreMain, Havok/PhysX, a Windows
system DLL, the game's own .exe)? 2026-08-10's slave-camp movement crash
turned out to be OgreMain_x64.dll -- nowhere near KenshiLua.dll -- which
meant a whole crash was NOT caused by the mod, something the Lua log alone
could not have proven either way.

LIMITS -- this is a minidump reader, not a debugger:
  - Reports the crashing MODULE and offset within it, not a symbolicated
    function name or full call stack. "KenshiLua.dll +0x1234" tells you it
    IS our code; it does not tell you which Lua callback triggered it.
  - If the crash address is inside KenshiLua.dll, that is real evidence our
    code is involved -- but the Lua-side log-as-cursor technique is still
    the way to find WHICH registered handler, since the dump alone cannot
    say that.
  - Standard exception codes are decoded (ACCESS_VIOLATION, STACK_OVERFLOW,
    etc.); an unrecognized code is printed as a raw hex value.

Usage:
    python tools/read_crashdump.py                 # find + read the newest crash zip
    python tools/read_crashdump.py path/to.dmp      # read a specific .dmp directly
    python tools/read_crashdump.py path/to.zip      # read a specific crash zip
"""
from __future__ import annotations

import datetime
import struct
import sys
import zipfile
from pathlib import Path

KENSHI_DIR = Path(r"D:\SteamLibrary\steamapps\common\Kenshi")

EXCEPTION_CODES = {
    0xC0000005: "EXCEPTION_ACCESS_VIOLATION",
    0xC00000FD: "EXCEPTION_STACK_OVERFLOW",
    0xC0000094: "EXCEPTION_INT_DIVIDE_BY_ZERO",
    0xC000001D: "EXCEPTION_ILLEGAL_INSTRUCTION",
    0x80000003: "EXCEPTION_BREAKPOINT",
    0xC0000025: "EXCEPTION_NONCONTINUABLE_EXCEPTION",
    0xC0000409: "STATUS_STACK_BUFFER_OVERRUN (/GS failure or fast-fail)",
}


def find_newest_crash_zip() -> Path | None:
    zips = sorted(KENSHI_DIR.glob("crashDump*_x64.zip"), key=lambda p: p.stat().st_mtime, reverse=True)
    return zips[0] if zips else None


def read_minidump_string(data: bytes, rva: int) -> str:
    (length,) = struct.unpack_from("<I", data, rva)
    raw = data[rva + 4 : rva + 4 + length]
    return raw.decode("utf-16-le", errors="replace")


def parse_dump(data: bytes) -> dict:
    sig, ver, nstreams, dir_rva = struct.unpack_from("<IIII", data, 0)
    if sig != 0x504D444D:
        raise ValueError(f"not a minidump (signature {hex(sig)}, expected 0x504d444d)")

    modlist_rva = None
    exception_rva = None
    for i in range(nstreams):
        off = dir_rva + i * 12
        stype, dsize, rva = struct.unpack_from("<III", data, off)
        if stype == 4:  # ModuleListStream
            modlist_rva = rva
        elif stype == 6:  # ExceptionStream
            exception_rva = rva

    result = {"modules": []}

    if modlist_rva is not None:
        (nmods,) = struct.unpack_from("<I", data, modlist_rva)
        MODULE_ENTRY_SIZE = 108  # sizeof(MINIDUMP_MODULE)
        for i in range(nmods):
            off = modlist_rva + 4 + i * MODULE_ENTRY_SIZE
            base, size, checksum, timestamp, name_rva = struct.unpack_from("<QIIII", data, off)
            name = read_minidump_string(data, name_rva)
            result["modules"].append({"name": name, "base": base, "end": base + size})

    if exception_rva is not None:
        (tid,) = struct.unpack_from("<I", data, exception_rva)
        exc_code, exc_flags = struct.unpack_from("<II", data, exception_rva + 8)
        (exc_addr,) = struct.unpack_from("<Q", data, exception_rva + 24)
        result["thread_id"] = tid
        result["exception_code"] = exc_code
        result["exception_address"] = exc_addr

    return result


def module_at(modules: list[dict], addr: int) -> dict | None:
    for m in modules:
        if m["base"] <= addr < m["end"]:
            return m
    return None


def report(data: bytes):
    parsed = parse_dump(data)
    modules = parsed["modules"]
    print(f"{len(modules)} module(s) loaded at crash time")

    if "exception_address" not in parsed:
        print("No ExceptionStream found in this dump -- cannot report a faulting module.")
        return

    code = parsed["exception_code"]
    addr = parsed["exception_address"]
    tid = parsed["thread_id"]
    code_name = EXCEPTION_CODES.get(code, f"unrecognized ({hex(code)})")

    print()
    print(f"CRASHING THREAD: {tid}")
    print(f"EXCEPTION: {code_name}  ({hex(code)})")
    print(f"FAULT ADDRESS: {hex(addr)}")

    hit = module_at(modules, addr)
    print()
    if hit:
        offset = addr - hit["base"]
        print(f"CRASHED IN MODULE: {hit['name']}")
        print(f"  (base {hex(hit['base'])}, offset +{hex(offset)})")
        is_ours = "KenshiLua" in hit["name"]
        print()
        if is_ours:
            print("*** This IS inside KenshiLua.dll -- our plugin/Lua host. Real evidence the")
            print("*** mod is involved. This tool cannot say WHICH Lua callback, though --")
            print("*** cross-reference with the KenshiLua log's log-as-cursor trail for that.")
        else:
            print("This is NOT inside KenshiLua.dll -- the crash is in a different module")
            print("entirely (vanilla engine, a system DLL, etc.). Weighs AGAINST the mod")
            print("being the direct cause of this specific crash.")
    else:
        print("Fault address does not fall inside any loaded module's range.")
        print("Could be JIT-generated code (e.g. LuaJIT) or a corrupted/invalid address.")


def main() -> int:
    if len(sys.argv) > 1:
        target = Path(sys.argv[1])
        if target.suffix.lower() == ".zip":
            with zipfile.ZipFile(target) as z:
                dmp_name = next((n for n in z.namelist() if n.lower().endswith(".dmp")), None)
                if not dmp_name:
                    print("no .dmp file found inside the zip", file=sys.stderr)
                    return 2
                data = z.read(dmp_name)
        else:
            data = target.read_bytes()
        print(f"reading: {target}")
        report(data)
        return 0

    zpath = find_newest_crash_zip()
    if not zpath:
        print(f"no crashDump*_x64.zip found under {KENSHI_DIR}", file=sys.stderr)
        return 2
    mtime = datetime.datetime.fromtimestamp(zpath.stat().st_mtime)
    print(f"newest crash dump: {zpath.name}  (modified {mtime})")
    with zipfile.ZipFile(zpath) as z:
        dmp_name = next((n for n in z.namelist() if n.lower().endswith(".dmp")), None)
        if not dmp_name:
            print("no .dmp file found inside the zip", file=sys.stderr)
            return 2
        data = z.read(dmp_name)
    report(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
