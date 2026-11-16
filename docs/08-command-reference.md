# 08 — Command reference (yc500 family)

Complete opcode reference for the ROYUAN yc500 command set, with gen2 differences
in the last column. Everything marked **Verified** was captured on the FL Esports
MK750 in this repo's recon (board 849, `3151:4015`, firmware 1.07, wired USB).
Everything else comes from the sharkfin `PROTOCOL.md` and is marked
*(reference; not tested on this unit)*. Gen2 rows are included so a tool can
recognise and refuse them: **this unit is yc500**, and a misaddressed write lands
on a different live register.

## Framing recap

Every packet below is the **64-byte protocol payload**. With `hidapi` prepend one
report-ID byte `0x00` and send a 65-byte buffer on the vendor collection
(`0xFFFF:2`, interface 2). See [01-transport.md](01-transport.md).

| Checksum | Rule | Used by |
|---|---|---|
| Bit7 | `ck = 0xFF - (sum(bytes[0:7]) & 0xFF)`, stored at byte 7 | All app-mode commands except the two lighting SETs |
| Bit8 | `ck = 0xFF - (sum(bytes[0:8]) & 0xFF)`, stored at byte 8 | `SET_LEDPARAM 0x07`, `SET_SLEDPARAM 0x08` only |
| none | — | 56-byte data pages of bulk writes, screen data reports, boot-mode image transfer |

A SET returns no reply. A GET echoes its opcode in byte 0, except bulk page reads
(keymap, Fn, macro, USERPIC), which return raw page bytes. An unsupported command
replays the previous reply rather than erroring; allow 100–300 ms after a SET and
read a GET twice when in doubt. See [02-handshake.md](02-handshake.md) and
[07-verification.md](07-verification.md).

Legend for the **Verified on this unit?** column:

- **Yes** — exact request/reply captured in the recon.
- **Reply observed** — sent as a probe; the reply is documented but the command is not for this family.
- *(reference; not tested on this unit)* — from `PROTOCOL.md` only; never sent to the MK750.

Hazard tags: `none` read-only, `state` volatile setting (read back), `flash` writes
flash (back up first), **DANGER** destructive or boot entry (never send from a
general-purpose tool).

**Detail per group:** read-only [02-handshake.md](02-handshake.md),
[04-keymap-and-macros.md](04-keymap-and-macros.md),
[05-settings-and-profiles.md](05-settings-and-profiles.md);
settings writes [03-lighting.md](03-lighting.md),
[05-settings-and-profiles.md](05-settings-and-profiles.md);
flash writes [04-keymap-and-macros.md](04-keymap-and-macros.md),
[05-settings-and-profiles.md](05-settings-and-profiles.md);
destructive commands [06-safety-and-troubleshooting.md](06-safety-and-troubleshooting.md).

## Read-only

| Opcode | Name | Direction | Checksum | Payload layout | Reply layout | Verified on this unit? | Hazard | Gen2 difference |
|---|---|---|---|---|---|---|---|---|
| `0x8F` | Identify | GET | Bit7 | `[0x8F,0,0,0,0,0,0,0x70]` | `[0x8F, id:u32 LE, …]`; this unit `8f 51 03 00 00 00 00 70` → board 849 | **Yes** | none | Same opcode and payload; gen2 also reads firmware revision from identify bytes 7..9 *(reference)* |
| `0x80` | Firmware revision | GET | Bit7 | `[0x80,0,0,0,0,0,0,0x7f]` | `(reply[2]<<8)\|reply[1]`, each nibble a decimal digit; this unit `0x0107` → 1.07 | **Yes** | none | Gen2 answers zeros over cable; revision is in identify bytes 7..9 *(reference)* |
| `0x87` | GET LEDPARAM | GET | Bit7 (either position accepted here; Bit7 canonical) | `[0x87,0,0,0,0,0,0,0x78]` | `[0x87, mode, speed, brightness, (option<<4)\|flags, R, G, B, 0]`; this unit `87 05 02 04 07 ff 45 6e 00` | **Yes** | none | Same opcode/payload; speed and flag-nibble meaning are per board (gen2 wire speed 0..4) |
| `0x88` | GET SLEDPARAM (side/edge) | GET | Bit7 (either accepted here) | `[0x88,0,0,0,0,0,0,0x77]` | Same layout as `0x87`; this unit `88 01 03 04 08 ff ff ff 00`. A reply does not prove edge LEDs exist — use the device record | **Yes** | none | Same opcode/payload; edge speed is not inverted in either family |
| `0x89` | GET keymap, base layer | GET | Bit7 | `[0x89, profile, page, 0, …]`, pages 0..7 | Raw 64-byte page, no echo; slot *n* at byte `(n%16)*4` of page `n//16` | **Yes** | none | Gen2 `0x89` = options GET (bytes 1..4); gen2 keymap GET is `0x8A` with `[profile,0xFF,page,os]` |
| `0x90` | GET keymap, Fn layer | GET | Bit7 | `[0x90, profile, page, 0, …]`, pages 0..7 | Raw 64-byte page, no echo | **Yes** | none | Same opcode, different shape: `[os, profile, 0xFF, page]` *(reference)* |
| `0x91` | GET debounce | GET | Bit7 | `[0x91,0,0,0,0,0,0,0x6e]` | Value at reply byte 2; this unit `1` (1 ms) | **Yes** | none | Gen2 `0x91` = sleep GET (bytes 8..15); gen2 debounce GET is `0x86` (byte 1) |
| `0x92` | GET sleep timers | GET | Bit7 | `[0x92,0,0,0,0,0,0,0x6d]` | Four u16 LE seconds at bytes 1..8 (BT sleep, 2.4G sleep, deep BT, deep 2.4G); this unit 120/120/600/600 | **Yes** | none | Not in the gen2 table; gen2 sleep GET is `0x91` (bytes 8..15) |
| `0x86` | GET options | GET | Bit7 | `[0x86,0,0,0,0,0,0,0x79]` | Byte 2 bitfield: `1` Win lock, `2` Mac mode, `8` WASD swap, `16` backlight off, `32` side light off, `64` keyboard mode, `128` keyboard lock; byte 3 Fn-matrix flag, byte 4 power save. This unit byte 2 = `0x02`, byte 3 = `0x02`, byte 4 = 0 | **Yes** | none | Gen2 `0x86` = debounce GET; gen2 options GET is `0x89` |
| `0x97` | GET auto-OS | GET | Bit7 | `[0x97,0,0,0,0,0,0,0x68]` | `reply[1] == 1` means enabled; this unit `1` | **Yes** | none | Same opcode and payload in both families |
| `0x85` | GET active profile | GET | Bit7 | `[0x85,0,0,0,0,0,0,0x7a]` | `reply[1]` = zero-based current profile; this unit `0`. No per-index query | **Yes** | none | Gen2 GET profile is `0x84` |
| `0x8B` | GET macro page | GET | Bit7 | `[0x8B, slot, page, 0, …]`, pages 0..3 | Raw 64-byte page, no echo; read-back is faithful. 50 slots × 256 bytes | **Yes** | none | Same opcode and payload in both families |
| `0x8C` | GET USERPIC | GET | Bit7 | `[0x8C, …]` | Stable data that does not reflect writes; treat USERPIC as write-only | *(reference; not tested on this unit)* | none | Same opcode; the gen2 **SET** header differs |
| `0x8A` | Gen2 keymatrix GET | GET | Bit7 | Gen2 `[0x8A, profile, 0xFF, page, os, …]` | Gen2: raw page. On yc500 it answers all `0xFF`, not an echo (documented yc500 answer) | **Reply observed** (all `FF`) during family detection; not a valid read here | none | Gen2-only keymap read; on this unit it is not a keymap |
| `0x84` | Gen2 GET profile | GET | Bit7 | Bare opcode + Bit7 | `reply[1]` = current profile *(reference; gen2 only)* | *(reference; gen2 only, not tested on this unit)* | none | Gen2 counterpart of yc500 `0x85` |
| `0xAD` | Display firmware version | GET | Bit7 | Bare opcode + Bit7 | `(reply[2]<<8)\|reply[1]`; an answering board has a display, an echo means none | *(reference; not tested on this unit)* | none | Same in both families; gen2 boards without a display answer a zero word |
| `0xAE` | Display `mledv` version | GET | Bit7 | Bare opcode + Bit7 | `(reply[2]<<8)\|reply[1]`, zero for none | *(reference; not tested on this unit)* | none | Same in both families |
| `0x83` | Gen2 report rate GET | GET | Bit7 | Bare opcode + Bit7 | Report-rate value *(reference; gen2 only)* | *(reference; gen2 only, not tested on this unit)* | none | yc500 has no report-rate command (vendor setter is a stub) |

**Detail:** identity/revision/settle behaviour in [02-handshake.md](02-handshake.md);
keymap pages, slot encoding and macro pages in [04-keymap-and-macros.md](04-keymap-and-macros.md);
settings/profile reads in [05-settings-and-profiles.md](05-settings-and-profiles.md);
exact captured bytes in [07-verification.md](07-verification.md).

## Safe settings writes

These change volatile configuration. Read the current state first and restore it
afterwards; a SET has no reply, so verify with the matching GET.

| Opcode | Name | Direction | Checksum | Payload layout | Reply layout | Verified on this unit? | Hazard | Gen2 difference |
|---|---|---|---|---|---|---|---|---|
| `0x07` | SET LEDPARAM | SET | **Bit8** | `[0x07, mode, speed, brightness, (option<<4)\|flags, R, G, B, 0, ck8]` | none; verify with `0x87`. yc500 speed is a frame-divider index 0..5; RGB below `0x080808` renders unlit | **Yes** (write, read-back, restore) | state | Same opcode/payload; gen2 wire speed 0..4, flag nibble per board. Never send a mode above 31 *(reference)* |
| `0x08` | SET SLEDPARAM (side/edge) | SET | **Bit8** | Same byte layout as `0x07`; edge modes 0 off, 1 static, 2 breathing, 3 neon, 4 wave, 5 snake; speed not inverted | none; verify with `0x88` | **Yes** (write, read-back, restore) | state | Same opcode/payload; edge flag nibble follows the board's backlight |
| `0x05` | SET profile | SET | Bit7 | `[0x05, profile, 0, …]` (one index byte) | none; verify with `0x85`. Switch profile before writing its keymap | *(reference; not tested on this unit — GET verified)* | state | Gen2 SET profile is `0x04` |
| `0x11` | SET debounce | SET | Bit7 | `[0x11, 0, value, 0, …]`, value 1..10 at byte 2 (yc500 pads a zero at byte 1) | none; verify with `0x91` | *(reference; not tested on this unit — GET verified)* | state | Gen2 SET debounce is `0x06`, value at byte 1 — the yc500 shape writes 0 on gen2 |
| `0x12` | SET sleep timers | SET | Bit7 | Four u16 LE seconds (BT sleep, 2.4G sleep, deep BT, deep 2.4G) at bytes 8..15 | none; verify with `0x92` (different reply offsets: bytes 1..8) | *(reference; not tested on this unit — GET verified)* | state | Gen2 SET sleep is `0x11`; gen2 GET offset differs |
| `0x06` | SET options | SET | Bit7 | Same bitfield as GET `0x86`, at byte 2; read-modify-write to keep unmodelled bits. Bit `128` locks the keyboard | none; verify with `0x86` | *(reference; not tested on this unit — GET verified)* | state | Gen2 SET options is `0x09`; gen2 decoded fields have unestablished meanings |
| `0x17` | SET auto-OS | SET | Bit7 | `[0x17, 0\|1, 0, …]` | none; verify with `0x97` (`reply[1] == 1`) | *(reference; not tested on this unit — GET verified)* | state | Same opcode and payload in both families |
| `0x28` | SET clock | SET | Bit7 | Fields past the checksum: bytes 8,9 year big-endian; 10 month (1..12); 11 day; 12 hour (0..23); 13 minute; 14 second | none — no read; the board keeps time itself | *(reference; not tested on this unit)* | state | Same builder in both families |
| `0x04` | Gen2 SET profile | SET | Bit7 | One index byte *(reference; gen2 only)* | none | *(reference; gen2 only, not tested on this unit)* | **Wrong-family write** | Gen2 counterpart of yc500 `0x05`; do not send on this unit |
| `0x03` | Gen2 SET report rate | SET | Bit7 | Report-rate value *(reference; gen2 only)* | none | *(reference; gen2 only, not tested on this unit)* | **Wrong-family write** | yc500 has no report-rate command |

**Detail:** lighting bytes, modes and ranges in [03-lighting.md](03-lighting.md);
profile/settings semantics and read-modify-write rules in
[05-settings-and-profiles.md](05-settings-and-profiles.md);
verified SET/GET pairs in [07-verification.md](07-verification.md).

## Flash writes

These write non-volatile memory. Read and save the affected profile, macro slot
or pattern before writing. Pace USERPIC uploads: 2 uploads / 10 s, pages 100 ms
apart, 2 s settle; a stalled control endpoint needs USB re-enumeration.

| Opcode | Name | Direction | Checksum | Payload layout | Reply layout | Verified on this unit? | Hazard | Gen2 difference |
|---|---|---|---|---|---|---|---|---|
| `0x09` | Bulk keymap write, base | SET | Bit7; pages unchecked | `[0x09, profile, 0xF8, 1, page]` + 56 bytes at byte 8; 9 pages, commit on page 8. 504 of 512 bytes sent; slots 126..127 never transmit *(reference; FW)* | none | *(reference; not tested on this unit)* | flash | Gen2 `0x09` = options SET; gen2 bulk keymap is `0x0A` with `[profile,0xFF,page,len,last,os]`, 10 pages |
| `0x10` | Bulk keymap write, Fn | SET | Bit7; pages unchecked | Same shape as `0x09` *(reference; FW)* | none | *(reference; not tested on this unit)* | flash | Same opcode, different shape: `[os, profile, slot]` (single) or bulk with gen2 header |
| `0x13` | Single-slot keymap write, base | SET | Bit7 | `[0x13, profile, slot, 0, …]`, 4-byte value at bytes 8..11 | none | *(reference; not tested on this unit — absent from some yc500 images)* | flash | Gen2 writes slots through keymatrix `0x0A` with `[profile, slot, 0, 0, apply, os]` |
| `0x15` | Single-slot keymap write, Fn | SET | Bit7 | `[0x15, profile, slot, 0, …]`, 4-byte value at bytes 8..11 | none | *(reference; not tested on this unit)* | flash | Gen2 Fn single-slot write is `0x10` with `[os, profile, slot]` |
| `0x0A` | Gen2 keymatrix write | SET | Bit7 | Gen2 single `[0x0A, profile, slot, 0, 0, apply, os]` (value at 8..12); bulk `[0x0A, profile, 0xFF, page, len, last, os]` + ≤56 bytes at 8 *(reference; FW)* | none | *(reference; gen2 only, not tested on this unit)* | **Wrong-family write** — a different register on yc500 | yc500 uses `0x09`/`0x10`/`0x13`/`0x15` instead |
| `0x16` | SET macro page | SET | Bit7; pages unchecked | `[0x16, slot, page, 56, last, 0, 0, 0]` + 56 bytes from byte 8; `last=1` on final page; pages 0..3, 50 slots × 256 bytes | none | *(reference; not tested on this unit — macro read verified)* | flash — back up the slot | Gen2 SET macro is `0x0B`, same shape |
| `0x0C` | SET USERPIC (per-key colour) | SET | Bit7; pages unchecked | yc500 `[0x0C, 0, lenLo, lenHi, page, 0]` + RGB triples from byte 8; 7 pages, 384 bytes total *(reference; HW on other boards)* | none | *(reference; not tested on this unit)* | flash — pace uploads or the endpoint stalls | Same opcode, different header: gen2 `[0x0C, slot, 0xFF, page, pageLen, last]`, 378 bytes total |
| `0xA5` | Screen announce (mode 16, RGB565) | SET | Bit7 | `[1]` frame, `[2]` frame count, `[3]` delay, `[4..6]` length u16 LE, `[8..12]` bounding box *(reference; FW)* | Echoes opcode; poll until `reply[1] == 1` (vendor: 10 × 100 ms). Erases nothing, resets counters | *(reference; not tested on this unit — no screen evidenced)* | flash — frame goes to flash on yc3123 | Gen2 variants: yc3123 u32 length from `[4],[5],[16],[17]`; ry5088 forwards to a display chip with u16 length |
| `0x25` | Screen data (mode 16) | SET | Bit7 on command; page data unchecked | `[1]` frame, `[4..6]` page index, `[6]` page length, data at `[8]`, 56 bytes *(reference; FW)* | Echoes opcode on yc3123; disagreeing pages are dropped | *(reference; not tested on this unit)* | flash | Same opcode on gen2 yc3123; ry5088 forwards type-4 frames to the display chip |
| `0xA9` | Screen announce (mode 24, RGB triples) | SET | Bit7 | As `0xA5` *(reference; FW)* | Echo/poll as `0xA5` | *(reference; not tested on this unit)* | flash | Yc500-only pair in the vendor table; gen2 yc3123 images reject it |
| `0x29` | Screen data (mode 24) | SET | Bit7 on command; page data unchecked | As `0x25` *(reference; FW)* | Echo as `0x25` | *(reference; not tested on this unit)* | flash | Rejected by the gen2 yc3123 images that were read |
| `0x31` | OLED start (display-chip flashing) | SET | Bit7 | `0x31` plus the 16-bit chunk count *(reference; JS)* | Not documented | *(reference; not tested on this unit)* | flash — display-chip firmware path | Display-chip/TFT flashing dialect; same opcode in both families per the vendor table |
| `0x32` | TFT data | SET | none on data | 56-byte pages *(reference; JS)* | Not documented | *(reference; not tested on this unit)* | flash | Listed in both families' vendor tables |
| `0xB0` | OLED poll | GET-like control | Bit7 | Bare opcode *(reference; JS)* | Poll until it echoes and `reply[1] == 1` | *(reference; not tested on this unit)* | none by itself — flashing handshake | Display-chip flashing control; no yc500 command of this name is evidenced |
| `0xB1` | OLED verify | GET-like control | Bit7 | `0xB1` plus the byte-sum *(reference; JS)* | Success is `reply[1] == 0x55` | *(reference; not tested on this unit)* | none by itself — flashing handshake | Display-chip flashing control |
| `0xB2` | TFT probe | GET-like control | Bit7 | `0xB2` plus the page count *(reference; JS)* | Continue only if `reply[1] == 1` | *(reference; not tested on this unit)* | none by itself — flashing handshake | Display-chip flashing control |

Screen geometry (size, pixel mode, layer count) is per board and nothing may
assume a default. Screen/OLED material is reference-only for this unit; see
[05-settings-and-profiles.md](05-settings-and-profiles.md) for the settings
context and [06-safety-and-troubleshooting.md](06-safety-and-troubleshooting.md)
before attempting any upload.

**Detail:** keymap/Fn page layout and macro blobs in
[04-keymap-and-macros.md](04-keymap-and-macros.md); per-key and display behaviour
in [05-settings-and-profiles.md](05-settings-and-profiles.md).

## Destructive / do not send

**DANGER** — these erase configuration or flash, or leave app mode. Only a tool
that is deliberately recovering or flashing a board should send them. `0x7F` and
`0x30` need the exact `55 AA 55 AA` trailer; without it they are not boot entry.

| Opcode | Name | Direction | Checksum | Payload layout | Reply layout | Verified on this unit? | Hazard | Gen2 difference |
|---|---|---|---|---|---|---|---|---|
| `0x02` | Factory reset (yc500) | SET | Bit7 | Bare opcode + Bit7; takes about 4 s *(reference; HW on other boards)* | none | *(reference; not tested on this unit)* | **DANGER** — erases configuration; never from a general tool | Gen2 factory reset is `0x01` |
| `0x7F` | USB boot entry | SET | Bit7 | `[0x7F, 0x55, 0xAA, 0x55, 0xAA]` | none; USB re-enumerates as a boot PID. A K86 boots to `3151:4016` (app PID `3151:4015`); vendor PID tables are incomplete | *(reference; not tested on this unit)* | **DANGER** — leaves app mode; a wrong image can leave the board unbootable | Both families, same opcode and trailer |
| `0x30` | Display-chip boot entry | SET | Bit7 | `[0x30, 0x55, 0xAA, 0x55, 0xAA, 0, 0, 0]` | none | *(reference; not tested on this unit)* | **DANGER** — display boot, not USB boot | Both families, same trailer |
| `0xAC` | Flash-chip erase | SET | Bit7 | Bare opcode + Bit7 *(reference)* | Some images preload `AA AA 55 55` | *(reference; not tested on this unit)* | **DANGER** — flash-chip erase in both families; erases every picture on gen2 (~55 s) | Both families set the same display-erase flag on yc3123 |
| `0x2C` | Display erase (yc500) | SET | Bit7 | Bare opcode + Bit7 *(reference)* | none | *(reference; not tested on this unit)* | **DANGER** — same flag as `0xAC` on the images read; never send blind | On gen2 yc3123, `0x2C` and `0xAC` set the same flag |
| `0x1C` / `0x1E` | Magnetic sensor calibration | SET | Bit7 | On/off sub-command *(reference; FW)* | none | *(reference; not tested on this unit — no magnetic switches evidenced)* | **DANGER** — on zeroes stored travel tables in RAM, off saves them; on-then-off commits zeros | Family-specific magnetic-switch columns; not present on this unit |

**Detail:** backup procedure, stall recovery, boot PID caveats and failure modes in
[06-safety-and-troubleshooting.md](06-safety-and-troubleshooting.md).

## Opcode collision quick map

The same opcode addresses a different register in each family. Confirm the family
with `0x8F` and the `0x89`/`0x8A` probe before any write
([02-handshake.md](02-handshake.md)).

| Opcode | yc500 meaning | gen2 meaning |
|---|---|---|
| `0x09` / `0x89` | keymap bulk write / base keymap GET | options SET / options GET |
| `0x06` / `0x86` | options SET / GET | debounce SET / GET |
| `0x11` / `0x91` | debounce SET / GET | sleep SET / GET |
| `0x0A` / `0x8A` | gen2 keymatrix, unused (all `FF` on GET) | keymatrix SET / GET |
| `0x0C` / `0x8C` | USERPIC SET / GET | USERPIC SET (different header) / GET |
| `0x10` / `0x90` | Fn bulk write / Fn GET | Fn write / Fn GET, different shape |
| `0x05` / `0x85` | profile SET / GET | `0x04` / `0x84` |
| `0x16` / `0x8B` | macro SET / GET | `0x0B` / `0x8B` |
| `0x02` | factory reset | `0x01` |

## Minimal `hidapi` example

Pattern only; the full tool lives in `examples/mk750ctl.py`. Match on VID/PID,
`usage_page == 0xFFFF`, `usage == 2` and `interface_number == 2` — never
hard-code the dynamic `path`.

```python
import time
import hid

VID, PID = 0x3151, 0x4015

def open_keyboard():
    for d in hid.enumerate():
        if (d["vendor_id"] == VID and d["product_id"] == PID
                and d.get("usage_page") == 0xFFFF and d.get("usage") == 2
                and d.get("interface_number") == 2):
            dev = hid.device()
            dev.open_path(d["path"])
            return dev
    raise RuntimeError("MK750 vendor collection not found")

def checksum(pkt, at):
    """pkt is a 64-byte bytearray; at=7 for Bit7, at=8 for Bit8."""
    pkt[at] = (0xFF - (sum(pkt[:at]) & 0xFF)) & 0xFF
    return pkt

def get(dev, opcode):
    req = checksum(bytearray([opcode] + [0] * 63), 7)
    dev.send_feature_report(bytes([0]) + bytes(req))  # 65 bytes, report ID 0
    time.sleep(0.15)
    dev.get_feature_report(0, 65)                     # discard stale reply
    time.sleep(0.15)
    return dev.get_feature_report(0, 65)[1:]          # 64-byte payload

dev = open_keyboard()
ident = get(dev, 0x8F)
board_id = int.from_bytes(ident[1:5], "little")       # 849 on this unit

# Bit8 SET: static red backlight, then verify with 0x87.
pkt = checksum(bytearray([0x07, 0x01, 0x00, 0x04, 0x07, 0xFF, 0x00, 0x00]
                         + [0] * 56), 8)
dev.send_feature_report(bytes([0]) + bytes(pkt))
time.sleep(0.25)
state = get(dev, 0x87)                                # 87 01 00 04 07 ff 00 00 00
```

Restore the original lighting bytes (from `0x87` before the write) before
finishing. See [07-verification.md](07-verification.md) for the exact probe bytes.

## Sources

- [MK750 recon findings (local, verified source of truth)](data/recon-findings.md)
- [sharkfin protocol reference](https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md)
- [sharkfin board registry](https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md)
- [FL Esports official software page](https://flesportsglobal.com/pages/software)
- [`hidapi` Python bindings](https://pypi.org/project/hidapi/)
