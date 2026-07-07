#!/usr/bin/env python3
"""
patch_offset.py — build a patched AMI "Setup" NVRAM variable for a BIOS-native CPU undervolt.

Reads a SCEWIN raw-mode dump (nvram_raw.txt, produced by
`SCEWIN_64.exe /o /c /l listing.txt /n nvram_raw.txt /h hii.bin /d`), changes ONLY the
Core Voltage Offset and Offset Prefix bytes in the target variable, and writes a binary
ready for:

    SCEWIN_64.exe /i /varname Setup /varguid <GUID> /varfile setup_patched.bin

The offsets/GUID are specific to your BIOS build. Find them with find_settings.sh and pass
them here. Defaults shown are for Alienware m17 R2 BIOS 1.24.0 (verify before trusting).

Example (-100 mV):
    python3 patch_offset.py --nvram nvram_raw.txt \
        --guid EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9 \
        --core-offset-addr 0x872 --prefix-addr 0x874 --mv 100 \
        --out setup_patched.bin
"""
import argparse, re, sys


def parse_scewin_raw(path):
    """Return {(name, guid_lower): bytearray} from a SCEWIN raw dump."""
    raw = open(path, "rb").read().decode("latin-1")
    lines = [x.replace("\r", "") for x in raw.split("\n")]
    out = {}
    i, N = 0, len(lines)
    while i < N:
        if lines[i].strip() == "GUID":
            guid = lines[i + 1].strip()
            name, data, j = None, [], i + 2
            while j < N and lines[j].strip() != "GUID":
                t = lines[j].strip()
                if t == "Variable Name":
                    name = lines[j + 1].strip(); j += 2; continue
                if t == "Variable Data":
                    j += 1
                    while j < N and lines[j].strip() and lines[j].strip() != "GUID":
                        toks = re.findall(r"[0-9A-Fa-f]{2}", lines[j])
                        if toks: data += toks
                        j += 1
                    break
                j += 1
            if name:
                out[(name, guid.lower())] = bytearray(int(x, 16) for x in data)
            i = j; continue
        i += 1
    return out


def main():
    ap = argparse.ArgumentParser(description="Build a patched Setup variable for a BIOS-native undervolt.")
    ap.add_argument("--nvram", required=True, help="SCEWIN raw dump (nvram_raw.txt)")
    ap.add_argument("--guid", required=True, help="Setup VarStore GUID (from find_settings.sh)")
    ap.add_argument("--varname", default="Setup", help="variable name (default: Setup)")
    ap.add_argument("--core-offset-addr", default="0x872",
                    help="VarOffset of Core Voltage Offset (u16), e.g. 0x872")
    ap.add_argument("--prefix-addr", default="0x874",
                    help="VarOffset of Offset Prefix (1=negative, 0=positive)")
    ap.add_argument("--mv", type=int, required=True,
                    help="undervolt magnitude in mV, e.g. 100 for -100 mV")
    ap.add_argument("--positive", action="store_true",
                    help="apply a POSITIVE offset (overvolt) instead of negative. Rarely wanted.")
    ap.add_argument("--out", default="setup_patched.bin")
    a = ap.parse_args()

    core = int(a.core_offset_addr, 0)
    prefix = int(a.prefix_addr, 0)
    if not (0 <= a.mv <= 500):
        sys.exit("refusing: --mv should be 0..500")

    vlist = parse_scewin_raw(a.nvram)
    key = next((k for k in vlist if k[0] == a.varname and k[1].startswith(a.guid.lower())), None)
    if key is None:
        sys.exit(f"variable {a.varname!r} with guid {a.guid} not found in {a.nvram}")
    b = bytearray(vlist[key])
    if core + 1 >= len(b) or prefix >= len(b):
        sys.exit(f"offset out of range for a {len(b)}-byte variable")

    before = (b[core] | (b[core + 1] << 8), b[prefix])
    b[core] = a.mv & 0xFF
    b[core + 1] = (a.mv >> 8) & 0xFF
    b[prefix] = 0 if a.positive else 1
    after = (b[core] | (b[core + 1] << 8), b[prefix])

    orig = vlist[key]
    changed = [hex(i) for i in range(len(b)) if b[i] != orig[i]]
    sign = "+" if a.positive else "-"
    print(f"variable : {a.varname}  guid={key[1]}  size={len(b)}")
    print(f"Core Voltage Offset @{hex(core)} : {before[0]} -> {after[0]}")
    print(f"Offset Prefix       @{hex(prefix)}: {before[1]} -> {after[1]}  ({sign})")
    print(f"result   : {sign}{a.mv} mV")
    print(f"bytes changed: {changed}")
    with open(a.out, "wb") as f:
        f.write(bytes(b))
    print(f"wrote {a.out} ({len(b)} bytes)")


if __name__ == "__main__":
    main()
