#!/usr/bin/env bash
# find_settings.sh — extract hidden BIOS setup questions (name + VarStore + VarOffset)
# from an FPT flash dump, so you can locate the Core Voltage Offset / lock settings for
# YOUR exact BIOS build.
#
# Usage:
#   ./find_settings.sh /path/to/bios.bin ["regex of setting names"]
#
# Example:
#   ./find_settings.sh bios.bin "Core Voltage Offset|Offset Prefix|Overclocking Lock|CFG Lock"
#
# Requires: curl, python3 (with lzma), and internet (to fetch UEFIExtract + IFRExtractor once).
# Read-only: it only reads bios.bin. Run on Linux or WSL.
set -u
BIOS="${1:?usage: find_settings.sh <bios.bin> [name-regex]}"
NEEDLE="${2:-Core Voltage Offset|Offset Prefix|Overclock|CFG Lock|Voltage Mode}"
WORK="$(mktemp -d)"
cd "$WORK" || exit 1
echo "workdir: $WORK"
[ -f "$BIOS" ] || { echo "bios.bin not found: $BIOS"; exit 1; }
cp -f "$BIOS" ./bios.bin

# --- tools (standard LongSoft UEFI tooling) ---
UEX_URL="https://github.com/LongSoft/UEFITool/releases/download/A74/UEFIExtract_NE_A74_x64_linux.zip"
IFR_URL="https://github.com/LongSoft/IFRExtractor-RS/releases/download/v1.6.1/ifrextractor_1.6.1_linux.zip"
curl -sL -o uefiextract.zip "$UEX_URL"
curl -sL -o ifrextractor.zip "$IFR_URL"
python3 -c "import zipfile;[zipfile.ZipFile(z).extractall('.') for z in ('uefiextract.zip','ifrextractor.zip')]"
chmod +x uefiextract ifrextractor

# --- unpack the firmware (decompresses all sections, incl. the Setup module) ---
echo "UEFIExtract ..."
./uefiextract bios.bin all >/dev/null 2>&1

# --- run IFRExtractor on every module that contains real setup forms, grep the result ---
echo "IFRExtractor ..."
find bios.bin.dump -type f -size +50k 2>/dev/null | while IFS= read -r f; do
  ./ifrextractor "$f" verbose >/dev/null 2>&1
done

echo
echo "############### matching questions (name, VarStore, VarOffset) ###############"
find bios.bin.dump -name '*.ifr.txt' -exec grep -ihE "$NEEDLE" {} \; 2>/dev/null \
  | grep -iE "OneOf|Numeric" | sort -u
echo
echo "############### VarStore definitions (map VarStoreId -> variable name + GUID) ###############"
find bios.bin.dump -name '*.ifr.txt' -exec grep -ihE "VarStore Guid:" {} \; 2>/dev/null | sort -u
echo
echo "Tip: note the GUID of the VarStore your target setting uses (usually 'Setup'),"
echo "and the VarOffset of Core Voltage Offset + Offset Prefix. Feed them to patch_offset.py."
echo "(clean up when done:  rm -rf $WORK )"
