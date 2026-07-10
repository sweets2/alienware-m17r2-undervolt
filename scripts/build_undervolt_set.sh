#!/usr/bin/env bash
# build_undervolt_set.sh — generate a "click-to-test" suite of undervolt steppings.
#
# For each millivolt value you list, this builds:
#   setup_<mv>mv.bin       — a patched Setup variable (via patch_offset.py)
#   Set-Undervolt-<mv>.bat — a self-elevating Windows batch file that writes it with SCEWIN
#
# Drop the outputs next to SCEWIN_64.exe / amifldrv64.sys, then just double-click a .bat,
# approve UAC, and restart to apply that undervolt. Each .bat changes only the offset byte,
# so you can jump between steppings freely (no need to reset in between).
#
# Usage:
#   ./build_undervolt_set.sh <nvram_raw.txt> <SETUP_GUID> [mv values...]
#
# Example (Alienware m17 R2, BIOS 1.24.0 — use YOUR own guid/offsets for other machines):
#   ./build_undervolt_set.sh nvram_raw.txt EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9 \
#       50 60 70 80 90 100 110 120 130 140 150
#
# Env overrides (defaults are for the reference m17 R2 build — verify yours with find_settings.sh):
#   CORE_ADDR=0x872   VarOffset of Core Voltage Offset (u16)
#   PREFIX_ADDR=0x874 VarOffset of Offset Prefix (1 = "-", 0 = "+")
#   OUTDIR=.          where to write the .bin and .bat files
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
NVRAM="${1:?usage: build_undervolt_set.sh <nvram_raw.txt> <SETUP_GUID> [mv values...]}"
GUID="${2:?need the Setup VarStore GUID (from find_settings.sh)}"
shift 2
MVS=("${@:-50 60 70 80 90 100 110 120 130 140 150}")
CORE_ADDR="${CORE_ADDR:-0x872}"
PREFIX_ADDR="${PREFIX_ADDR:-0x874}"
OUTDIR="${OUTDIR:-.}"
mkdir -p "$OUTDIR"

[ -f "$NVRAM" ] || { echo "nvram dump not found: $NVRAM"; exit 1; }

for MV in ${MVS[@]}; do
  BIN="setup_${MV}mv.bin"
  python3 "$HERE/patch_offset.py" \
    --nvram "$NVRAM" --guid "$GUID" \
    --core-offset-addr "$CORE_ADDR" --prefix-addr "$PREFIX_ADDR" \
    --mv "$MV" --out "$OUTDIR/$BIN" | grep -E "result|wrote" || { echo "patch failed for -${MV}mV"; exit 1; }

  BAT="$OUTDIR/Set-Undervolt-${MV}.bat"
  cat > "$BAT" <<EOF
@echo off
:: Apply CPU Core Voltage Offset = -${MV}mV by importing ${BIN}.
:: Self-elevates. Only the offset byte differs from stock.
fltmc >nul 2>&1 || (
    PowerShell Start -Verb RunAs '%0' 2> nul || (
        echo error: right-click this file and choose "Run as administrator"
        pause
    )
    exit /b 1
)
pushd %~dp0
for %%a in ("amifldrv64.sys","amigendrv64.sys","${BIN}") do (
    if not exist "%%~a" ( echo error: %%~a not found & pause & exit /b 1 )
)
echo Writing Core Voltage Offset = -${MV}mV to NVRAM...
SCEWIN_64.exe /i /varname Setup /varguid ${GUID} /varfile ${BIN} 2> set${MV}-log.txt
type set${MV}-log.txt
echo.
echo ===============================================
echo If it says "updated successfully" above, RESTART now.
echo After reboot the CPU runs at -${MV}mV. Verify in ThrottleStop FIVR.
echo To undo: run Reset-Undervolt.bat and restart.
echo ===============================================
pause
EOF
  # cmd.exe wants CRLF line endings
  sed -i 's/$/\r/' "$BAT"
  echo "  -> Set-Undervolt-${MV}.bat"
done

# also emit a stock/reset batch (offset 0) so there's always a one-click way back
python3 "$HERE/patch_offset.py" --nvram "$NVRAM" --guid "$GUID" \
  --core-offset-addr "$CORE_ADDR" --prefix-addr "$PREFIX_ADDR" --mv 0 \
  --out "$OUTDIR/setup_reset.bin" | grep -E "result|wrote"
cat > "$OUTDIR/Reset-Undervolt.bat" <<EOF
@echo off
:: Reset CPU Core Voltage Offset to 0mV (stock) by importing setup_reset.bin.
:: Self-elevates. Only the offset byte differs from any undervolt config.
fltmc >nul 2>&1 || (
    PowerShell Start -Verb RunAs '%0' 2> nul || (
        echo error: right-click this file and choose "Run as administrator"
        pause
    )
    exit /b 1
)
pushd %~dp0
for %%a in ("amifldrv64.sys","amigendrv64.sys","setup_reset.bin") do (
    if not exist "%%~a" ( echo error: %%~a not found & pause & exit /b 1 )
)
echo Writing Core Voltage Offset = 0mV to NVRAM...
SCEWIN_64.exe /i /varname Setup /varguid ${GUID} /varfile setup_reset.bin 2> reset-log.txt
type reset-log.txt
echo.
echo ===============================================
echo If it says "updated successfully" above, RESTART now.
echo After reboot the CPU runs at STOCK voltage (undervolt off).
echo ===============================================
pause
EOF
sed -i 's/$/\r/' "$OUTDIR/Reset-Undervolt.bat"
echo "  -> Reset-Undervolt.bat"
echo
echo "Done. Copy setup_*.bin + *.bat into your SCEWIN folder (next to SCEWIN_64.exe) and click one."
