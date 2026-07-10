# Alienware m17 R2 — BIOS-native CPU undervolt (software only, no case opening)

Restore a **real FIVR core-voltage undervolt** on an Alienware m17 R2 (and similar locked
Dell/Alienware laptops) whose BIOS update killed undervolting as part of the **Plundervolt
mitigation** — **without a hardware BIOS flash and without opening the laptop.**

The undervolt is applied by the BIOS itself at every boot, so it is **set-and-forget**: no
ThrottleStop, no startup task, no kernel driver left running, and it works with Windows
**Memory Integrity turned back on**.

> Verified on: **Alienware m17 R2, i7-9750H, BIOS 1.24.0** (the last BIOS Dell released for it).
> The *method* generalizes to many locked Aptio-V Dell/Alienware machines, but the exact byte
> **offsets are specific to your BIOS build — you must extract your own** (steps below). Do not
> blindly copy the offsets in this repo onto a different machine.

---

## Why undervolting "disappeared," and why this fixes it

Undervolting works by writing a negative voltage offset to the CPU's **OC mailbox (MSR `0x150`)**,
which tells the on-chip regulator (FIVR) to run each domain below its stock V/F curve.

To mitigate **Plundervolt (CVE-2019-11157)**, Dell's BIOS **locks that mailbox during boot** (sets
the Overclocking-Lock bit in `FLEX_RATIO` MSR `0x194`). After that, any OS-side tool — ThrottleStop,
Intel XTU — gets its writes **silently rejected**. ThrottleStop shows "Locked" and the FIVR sliders
do nothing. Dell also **removed the BIOS menu** that used to let you set a voltage offset, and it
**force-resets the "Overclocking Feature" toggle to 0 on every POST**, so you can't just re-enable
overclocking to prop the mailbox open.

**The trick:** the BIOS *itself* writes MSR `0x150` **earlier in boot, before it applies the lock**,
using a hidden `Core Voltage Offset` value stored in an NVRAM setup variable. Dell deleted the *menu*
for that value but left the **read-and-apply code intact** and does **not** wipe the value.

So instead of fighting the lock, we **write the hidden offset value straight into NVRAM** (with AMI's
own SCEWIN tool). On the next boot the BIOS reads it and applies the undervolt through the mailbox
during the brief window before it locks — exactly as if you'd set it in a menu that no longer exists.

**This is why it succeeds where the usual fixes fail:**

| Approach | Result |
|---|---|
| ThrottleStop / XTU set voltage at runtime | ❌ Mailbox already locked → writes rejected |
| Flip `Overclocking Lock` = Disabled (the classic forum fix) | ❌ On this machine it's *already* 0; no effect |
| Enable `Overclocking Feature` to unlock the mailbox | ❌ BIOS force-resets it to 0 every POST |
| Copy a forum's `0xDA` offset | ❌ Wrong for this BIOS (that byte is an unrelated setting) |
| **Write `Core Voltage Offset` into NVRAM (this repo)** | ✅ Persists; BIOS applies it pre-lock, every boot |

The capability was never removed from the firmware — **only the UI to reach it.**

---

## ⚠️ Read first

- **Undervolting can cause instability** (crashes, WHEA errors) if too aggressive. Start small
  (‑100 mV), stress-test, step gradually. `-125..-150 mV` is typical for a 9750H.
- **Recovery if a value is too aggressive to boot:** enter BIOS setup (**F2** at power-on) →
  **Load Defaults (F9)** → Save. That resets the offset to 0. No case opening, no permanent damage.
- These steps use **community-distributed tools that load blocklisted kernel drivers**
  (SCEWIN's `amifldrv64.sys`, Intel FPT). You must temporarily disable **Memory Integrity** to load
  them. Turn it back on when done — the undervolt does not need them at runtime.
- **Use at your own risk.** This is not endorsed by Dell, Intel, or AMI.

---

## What you need

- Windows on the target laptop, admin rights.
- **SCEWIN / AMISCE** — from [ab3lkaizen/SCEHUB](https://github.com/ab3lkaizen/SCEHUB) (reads/writes
  raw NVRAM variables). Run its `DL_SCEWIN.py` to fetch the binaries.
- **Intel CSME System Tools** matching your ME generation (v12 for Coffee Lake / 300-series) — for
  `fptw64.exe`, a read-only BIOS flash dump. (win-raid archive.)
- **UEFITool `UEFIExtract`** + **IFRExtractor-RS** ([LongSoft](https://github.com/LongSoft)) — to read
  the hidden settings out of the dump. (The `scripts/` here automate this on Linux/WSL.)
- **ThrottleStop** — only to *verify/monitor* (it can't set the voltage; the BIOS does).
- Python 3 (Windows for `DL_SCEWIN.py`; Linux/WSL for the extraction scripts here).

---

## Steps

### 1. Disable Memory Integrity
Windows Security → Device security → Core isolation → **Memory Integrity → Off** → reboot.
(Re-enabled at the end.)

### 2. Get SCEWIN and dump your NVRAM
Download SCEHUB, run its downloader, then export a **raw** dump of all NVRAM variables:
```bat
py DL_SCEWIN.py
cd SCEWIN\<version>
:: run the next line in an ADMIN terminal:
SCEWIN_64.exe /o /c /l listing.txt /n nvram_raw.txt /h hii.bin /d
```
This produces `nvram_raw.txt` (every variable's name, GUID, and raw bytes). Keep it.

> Note: SCEWIN's *normal* script export (`/o /s nvram.txt`) returns almost nothing on Dell — the CPU
> forms aren't published to the runtime HII. **Raw mode (`/o /c /l /n /h`) is what works.**

### 3. Dump your BIOS region (read-only) with Intel FPT
```bat
:: admin terminal, in the CSME System Tools "Flash Programming Tool\WIN64" folder
fptw64.exe -bios -d bios.bin
```
`-d` = dump. This only **reads** the flash; it writes nothing.

### 4. Find *your* offsets from the dump
On Linux/WSL, point `find_settings.sh` at `bios.bin`. It decompresses the firmware, runs
UEFIExtract + IFRExtractor, and prints the voltage/lock settings with their exact VarStore + offset:
```bash
scripts/find_settings.sh /path/to/bios.bin "Core Voltage Offset|Offset Prefix|Overclocking Lock|CFG Lock"
```
Record, for **your** BIOS: the `Setup` VarStore **GUID**, and the **VarOffset** of
`Core Voltage Offset` and `Offset Prefix`. Confirm `Core Voltage Offset` is a 16-bit numeric and
`Offset Prefix` is a OneOf where `1 = "-"`, `0 = "+"`.

### 5. Build the patched variable
`patch_offset.py` reads your `nvram_raw.txt`, changes only those bytes, and writes `setup_patched.bin`:
```bash
python3 scripts/patch_offset.py \
  --nvram nvram_raw.txt \
  --guid EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9 \
  --core-offset-addr 0x872 --prefix-addr 0x874 \
  --mv 100 \
  --out setup_patched.bin
```
It prints a before/after and confirms exactly which bytes changed (should be only 2).

### 6. Write it, reboot, verify
```bat
:: admin terminal, in the SCEWIN folder next to setup_patched.bin
SCEWIN_64.exe /i /varname Setup /varguid <YOUR-SETUP-GUID> /varfile setup_patched.bin
```
Reboot. Open **ThrottleStop → FIVR**. The right-side table should show your negative offset on
**CPU Core** and **CPU Cache** (they're linked — setting Core applies to both) — e.g. `-0.0996`
for ‑100 mV. That value is read straight from the CPU's MSR, so it's the real applied offset, not a
menu echo. ThrottleStop's own sliders stay locked/greyed — that's expected; **the BIOS is in control now.**

### 7. Tune, stress-test, re-secure
- Step the `--mv` value up (‑100 → ‑125 → ‑135…), re-writing and rebooting each time.
- Stress-test each value ~15–20 min (ThrottleStop **TS Bench** or Cinebench loop). Any crash/WHEA →
  back off ~10–15 mV.
- When settled: **turn Memory Integrity back ON.** The undervolt persists (it's firmware-applied).

### Optional: build a whole "click-to-test" suite

Stepping the undervolt by hand (edit `--mv`, rebuild, rewrite) gets tedious while tuning.
`build_undervolt_set.sh` generates a set of one-click batch files — one per stepping — plus a
matching `Reset-Undervolt.bat`. Each `.bat` **self-elevates** (prompts for UAC), writes its
`setup_<mv>mv.bin` with SCEWIN, and tells you to reboot:

```bash
scripts/build_undervolt_set.sh nvram_raw.txt EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9 \
    50 60 70 80 90 100 110 120 130 140 150
# override offsets for a different BIOS:  CORE_ADDR=0x872 PREFIX_ADDR=0x874 ./build_undervolt_set.sh ...
```

Copy the resulting `setup_*.bin` + `Set-Undervolt-*.bat` + `Reset-Undervolt.bat` into your SCEWIN
folder (next to `SCEWIN_64.exe` and `amifldrv64.sys`). Then tuning is just: **double-click a
stepping → approve UAC → restart → verify in ThrottleStop → stress-test.** Every `.bat` changes
only the one offset byte, so you can jump straight between steppings — e.g. try `150`, and if it's
unstable click `130` — without resetting in between. If a value won't boot, recover with BIOS
**F2 → Load Defaults (F9)**.

> The generated `.bat`/`.bin` files embed your machine's Setup snapshot and offsets, so they are
> **not committed here** (see `.gitignore`) — generate your own from your own `nvram_raw.txt`.

---

## Verified values — Alienware m17 R2, BIOS 1.24.0 (reference only)

VarStore **`Setup`**, GUID **`EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9`**, VarStoreId `0x1`, size `0x13E6`:

| Setting | VarOffset | Notes |
|---|---|---|
| **Core Voltage Offset** | `0x872` (u16) | mV, 1:1 (value 100 → ‑0.0996 V). The undervolt value. |
| **Offset Prefix** | `0x874` | `1` = "‑" (undervolt), `0` = "+" |
| Core Voltage Mode | `0x86F` | `0` = Adaptive (leave), `1` = Override |
| Overclocking Lock | `0x7A0` | already `0` (unlocked) — not the blocker |
| CFG Lock | `0x704` | `1` (normal) |
| Overclocking Feature | `0x1270` | resets to `0` every boot — **not needed** for the offset |

Again: **these are for this exact BIOS. Extract your own for any other machine/version.**

---

## FAQ

**Is it actually undervolting or just a cosmetic setting?** Real. ThrottleStop reads the applied
offset directly from CPU MSR `0x150`; before the write it read `+0.0000`, after it reads your
negative value. Under load you'll measure lower VID / package power / temps.

**Do I need ThrottleStop running?** No. The offset is applied by the BIOS before Windows loads.
ThrottleStop is only useful as a monitor now.

**Why can't ThrottleStop change it?** The runtime mailbox stays hardware-locked. Its sliders move
(a per-profile UI checkbox) but Apply is rejected by the CPU. To change the undervolt, edit the NVRAM
value (steps 5–6) and reboot.

**Will a BIOS update undo it?** A BIOS flash could reset NVRAM. 1.24.0 is the last release for the
m17 R2, so there's nothing newer to install. If you ever update, just re-run steps 5–6.

---

## Credits
- [ab3lkaizen/SCEHUB](https://github.com/ab3lkaizen/SCEHUB) — SCEWIN/AMISCE packaging
- [LongSoft/UEFITool](https://github.com/LongSoft/UEFITool) & [IFRExtractor-RS](https://github.com/LongSoft/IFRExtractor-RS) — firmware/IFR extraction
- [TechPowerUp ThrottleStop](https://www.techpowerup.com/download/techpowerup-throttlestop/) — monitoring
- The win-raid / Intel-ME community — CSME System Tools (FPT)
- Plundervolt research — https://plundervolt.com/
