# yc500 protocol reference

This describes the ROYUAN yc500 HID feature-report protocol in general terms: framing, opcodes, payload layouts and operating rules. Support for any given opcode, mode or field varies by board and firmware, so enumerate and verify before relying on it. Boards in the gen2 family share the same VID ranges and several opcode numbers but use different register layouts; never assume a payload shape across families.

## Transport and framing

Commands use the vendor feature collection, usage page `0xFFFF`, usage `2`, normally on interface 2. Its report descriptor declares a 64-byte feature report in both directions, logical range -128..127, with no Report ID item, so the report ID is 0. Other interfaces carry boot keyboard, consumer, NKRO, mouse and vendor input reports; they are not the command channel.

The protocol payload is 64 bytes with the opcode at byte 0. `hidapi` needs a 65-byte buffer: report ID `0x00` followed by the payload. The Linux hidraw feature ioctls for that size are `0xC0414806` (set) and `0xC0414807` (get); some backends return a bare 64-byte payload for report ID 0, so normalize both shapes.

Reply rules:

* A SET produces no reply. Do not wait for one.
* A GET echoes its opcode in byte 0, except bulk page reads (keymap, Fn, macro, picture data), which return raw 64-byte pages with no echo.
* An unsupported command replays the previous reply instead of reporting an error. Compare against the immediately preceding response, not against zero.
* After a SET, the first GET can return an older reply. Send the GET twice and use the second, allowing 100–300 ms to settle.
* Do not validate a reply by its checksum byte; some firmware returns zero there.

## Checksums

```
Bit7: checksum = 0xFF - (sum(bytes[0:7]) & 0xFF)   stored at byte 7
Bit8: checksum = 0xFF - (sum(bytes[0:8]) & 0xFF)   stored at byte 8
```

Bit7 covers all app-mode requests except the two lighting SETs. Bit8 is used only by `SET_LEDPARAM` (`0x07`) and `SET_SLEDPARAM` (`0x08`). Bulk flash writes (`0x09`, `0x10`, `0x0C`, `0x16`) use Bit7 for the command packet; their 56-byte data pages carry no checksum. Some firmware accepts a lighting GET with either checksum position, but use Bit7 for all GETs and Bit8 only for the two lighting SETs.

## Family detection

The same VID/PID range is shared across families, so detect from replies before writing:

1. Send `[0x8F, 0, 0, 0, 0, 0, 0, ck7]`. Require an echo and a plausible little-endian ID; reject the known false-positive pattern `0x00FF0000`.
2. Send the yc500 base-keymap GET `[0x89, profile, page, 0, 0, 0, 0, ck7]`. A bulk page read has no opcode echo.
3. Send the gen2 keymap GET `[0x8A, profile, 0xFF, page, os, 0, 0, ck7]`.

yc500 signature: step 2 returns raw slot bytes with no `0x89` echo and step 3 returns all `FF` (the documented yc500 answer). Gen2 signature: step 2 echoes `0x89` (on gen2 that opcode is the options GET) or step 3 returns a non-`FF` raw page without echo. Identical replies, two echoes or two all-`FF` pages are inconclusive — stop and send no writes. `0x8A` is acceptable only as this read-only probe.

## Opcode catalog

Hazards: `none` read-only, `state` volatile setting, `flash` non-volatile write, `DANGER` destructive or boot entry. Every row is a protocol definition, not a promise of support on a particular board.

### Read-only

| Opcode | Name | Request shape | Reply |
|---|---|---|---|
| `0x8F` | Identify | `[0x8F,0,0,0,0,0,0,ck7]` | echo + 4-byte ID at bytes 1..4 |
| `0x80` | Firmware revision | `[0x80,0,0,0,0,0,0,ck7]` | `(reply[2]<<8)|reply[1]`, each nibble a decimal digit |
| `0x85` | Active profile | `[0x85,0,0,0,0,0,0,ck7]` | `reply[1]`; no per-index query |
| `0x86` | Options | `[0x86,0,0,0,0,0,0,ck7]` | bitfield at bytes 2..4 |
| `0x87` | LED state | `[0x87,0,0,0,0,0,0,ck7]` | 8-byte lighting prefix at bytes 1..8 |
| `0x88` | Side-light state | `[0x88,0,0,0,0,0,0,ck7]` | same layout as `0x87` |
| `0x89` | Base keymap page | `[0x89, profile, page, 0, …]`, pages 0..7 | raw 64-byte page |
| `0x90` | Fn keymap page | `[0x90, profile, page, 0, …]`, pages 0..7 | raw 64-byte page |
| `0x91` | Debounce | `[0x91,0,0,0,0,0,0,ck7]` | value at byte 2 |
| `0x92` | Sleep timers | `[0x92,0,0,0,0,0,0,ck7]` | four u16 LE seconds at bytes 1..8 |
| `0x97` | Auto-OS | `[0x97,0,0,0,0,0,0,ck7]` | `reply[1] == 1` enabled |
| `0x8B` | Macro page | `[0x8B, slot, page, 0, …]`, pages 0..3 | raw 64-byte page |
| `0x8C` | Picture GET | bare + ck7 | stable data that ignores writes; treat as write-only |
| `0x84` | Gen2 profile GET | bare + ck7 | `reply[1]`; gen2 only |
| `0x83` | Gen2 report-rate GET | bare + ck7 | rate value; yc500 has no report-rate command |
| `0x8A` | Gen2 keymatrix GET | `[0x8A, profile, 0xFF, page, os]` | raw page on gen2, all `FF` on yc500 |
| `0xAD` / `0xAE` | Display firmware / `mledv` version | bare + ck7 | `(reply[2]<<8)|reply[1]`, zero for none |

### Settings writes

These change volatile configuration. Read the current state first and restore it afterwards; verify every SET with the matching GET.

| Opcode | Name | Payload layout | Checksum | Hazard |
|---|---|---|---|---|
| `0x07` | SET LEDPARAM | `[0x07, mode, speed, brightness, (option<<4)|flags, R, G, B, 0, ck8]` | Bit8 | state |
| `0x08` | SET SLEDPARAM | same layout as `0x07` | Bit8 | state |
| `0x05` | SET profile | `[0x05, profile, 0, …]`; switch before writing that profile's keymap | Bit7 | state |
| `0x06` | SET options | bitfield at byte 2, mirror of `0x86`; read-modify-write | Bit7 | state |
| `0x11` | SET debounce | `[0x11, 0, value, 0, …]`, value 1..10 at byte 2 | Bit7 | state |
| `0x12` | SET sleep timers | four u16 LE seconds at bytes 8..15; `0x92` GET uses bytes 1..8 | Bit7 | state |
| `0x17` | SET auto-OS | `[0x17, 0|1, 0, …]` | Bit7 | state |
| `0x28` | SET clock | after the checksum: bytes 8/9 year BE, 10 month (1..12), 11 day, 12 hour (0..23), 13 minute, 14 second; no read | Bit7 | state |
| `0x04` / `0x03` | Gen2 SET profile / report rate | gen2 only | Bit7 | wrong-family |

### Flash writes

These write non-volatile memory. Read and save the affected layer, slot or pattern before writing, and re-read it afterwards.

| Opcode | Name | Payload layout | Hazard |
|---|---|---|---|
| `0x09` | Bulk keymap write, base | `[0x09, profile, 0xF8, 1, page, 0, 0, 0, ck]` + 56 bytes at byte 8; 9 pages 0..8, commit flag on page 8; 504 of 512 bytes sent, slots 126–127 never transmitted | flash |
| `0x10` | Bulk keymap write, Fn | same shape as `0x09` | flash |
| `0x13` / `0x15` | Single-slot keymap write, base / Fn | `[op, profile, slot, 0, 0, 0, 0, 0, ck]` with the 4-byte value at bytes 8..11; some images drop these silently | flash |
| `0x16` | SET macro page | `[0x16, slot, page, 56, last, 0, 0, 0]` + 56 bytes from byte 8; `last=1` on the final page, pages 0..3 | flash |
| `0x0C` | SET picture data (USERPIC) | `[0x0C, 0, lenLo, lenHi, page, 0]` + 56 RGB bytes from byte 8; 7 pages, 384 bytes / 128 keys | flash |
| `0xA5` / `0x25` | Screen announce / data, mode 16 (RGB565) | announce: byte 1 frame, 2 count, 3 delay, 4..6 u16 LE length, 8..12 bounding box; data: 56 bytes from byte 8; echo, poll until `reply[1] == 1` | flash |
| `0xA9` / `0x29` | Screen announce / data, mode 24 (RGB triples) | same framing; each panel image implements one pair and rejects the other | flash |
| `0x31` / `0x32` | OLED start / TFT data | start with a 16-bit chunk count; data in 56-byte pages | flash |
| `0xB0` / `0xB1` / `0xB2` | OLED poll / verify / TFT probe | bare / byte-sum / page count; continue on `reply[1] == 1`, success on `reply[1] == 0x55` | handshake |

### Destructive — do not send from normal tooling

| Opcode | Name | Payload | Effect |
|---|---|---|---|
| `0x02` | Factory reset | bare + ck7, about 4 s | wipes configuration; gen2 uses `0x01` |
| `0x7F` | USB boot entry | `7F 55 AA 55 AA` + zero padding | re-enumerates under a board-specific boot PID; without the trailer this is not the same command |
| `0x30` | Display-chip boot | `30 55 AA 55 AA 00 00 00` | display chip boot path, not USB boot |
| `0xAC` | Flash-chip erase | bare + ck7 | erases pictures on gen2 (~55 s), preloads `AA AA 55 55` |
| `0x2C` | Display erase | bare + ck7 | same erase flag as `0xAC` on the images read |
| `0x1C` / `0x1E` | Magnetic calibration off / on | on/off subcommand | `on` zeroes stored travel tables in RAM, `off` saves them; on-then-off commits zeros |
| `0x65` / `0xE5` | Magnetic column write / read | single value or 56-byte page; `last` commits | no bounds check — a page past a column corrupts the next; present only on firmware with magnetic-switch support |

## Keymap layout

Base and Fn layers are read with `0x89` and `0x90`, eight 64-byte pages per profile. Slot `n` is at byte `(n % 16) * 4` of page `n // 16`. Four-byte slots decode as:

| byte 0 | meaning | bytes 1..3 |
|---|---|---|
| `0x00` | HID keyboard usage | `[0, usage, 0]` |
| `0x01` | mouse button | — |
| `0x03` | consumer usage | `[0, lo, hi]` |
| `0x09` | macro | `[mode, index, 0]`, mode 0 repeat, 1 toggle, 2 hold |
| `0x0A` | special | `[code, 0, 0]`; 1 Fn, 12 power save, 17 Caps LED swap |
| `0x0D` | extended Fn action | raw `[sub, a, b]`; published semantics are incomplete |
| `0x0E` | wireless channel | `[a, b]` for Bluetooth channels or 2.4 GHz |

Matrix order maps to physical keys through a board-specific scan matrix; slot `n` is matrix column `n // 6`, row `n % 6`. Physical key names are not part of the protocol and must not be inferred from slot numbers alone.

Macros are 50 slots of 256 bytes each, read four 64-byte pages per slot with `0x8B`.

## Byte layouts

Lighting prefix: `[op, mode, speed, brightness, (option<<4)|flags, R, G, B, ck8]`. Byte 4's low nibble is flags, high nibble is a mode-specific option (direction or pattern slot) whose meaning depends on the mode. RGB below `0x080808` renders unlit.

Main light modes: 1 static, 2 breathing, 3 spectrum, 4 wave, 5 ripple, 6 star dots, 7 flow, 8 key shadow, 9 layers, 10 sine, 11 spring, 12 neon, 14 radiant, 15 loop, 16 colour grid, 17 snowfall, 18 meteor, 19 silent snow, 23 train, 24 endless. Modes 13, 20, 21, 22 and 25 need host-side data; mode 13 selects a picture slot. Board support varies — enumerate rather than assuming the full list.

Flags (byte 4 low nibble): 0..6 preset colours red, orange, yellow, green, cyan, blue, magenta, overriding RGB on GET; 7 fixed custom colour; 8 rainbow on most boards. Speed is a wire frame-divider index 0..5, host scale 0..4 inverted for many modes; brightness 0..4. Side-light modes: 0 off, 1 static, 2 breathing, 3 neon (forces the rainbow nibble), 4 wave, 5 snake; side speed is not inverted.

Options reply byte 2 bitfield: `0x01` Win lock, `0x02` Mac mode, `0x08` WASD swap, `0x10` backlight off, `0x20` side light off, `0x40` keyboard mode, `0x80` keyboard lock. Byte 3 is the Fn matrix flag, byte 4 power save. The setter reads the Mac bit differently from the getter in some host code; trust the GET reply. Backlight-off is this bit, not a black RGB write.

Macro blob: `u16` LE repeat count, then an alternating event/delay stream. Key or mouse event is `[code, pressed<<7 | delay]`, or `[code, pressed ? 0x80 : 0, delay u16 LE]` when the delay is 0 or greater than 127 ms. Mouse move is `[0xF9, delay, dx i8, dy i8]`; mouse buttons `0xF0..0xF4`; key codes HID usages `0x04..0xEF`; four zero bytes terminate.

## Family collision map

The same opcode addresses a different register in each family. Confirm the family before any write.

| Opcode | yc500 | gen2 |
|---|---|---|
| `0x09` / `0x89` | keymap bulk write / base keymap GET | options SET / GET |
| `0x06` / `0x86` | options SET / GET | debounce SET / GET |
| `0x11` / `0x91` | debounce SET / GET | sleep SET / GET |
| `0x0A` / `0x8A` | unused; GET answers all `FF` | keymatrix SET / GET |
| `0x0C` / `0x8C` | picture SET / GET | picture SET with a different header / GET |
| `0x10` / `0x90` | Fn bulk write / Fn GET | Fn write / GET with a different shape |
| `0x05` / `0x85` | profile SET / GET | `0x04` / `0x84` |
| `0x16` / `0x8B` | macro SET / GET | `0x0B` / `0x8B` |
| `0x02` | factory reset | `0x01` |

## Flash safety and recovery

Keymap, macro and picture writes stage pages to flash. The commit is deferred until a final-flag packet, so keep the device powered and idle after the last page — disconnecting then can leave a partly written block. After any write, re-read the whole affected layer and compare byte-for-byte with the saved backup. Some images lack the single-slot writes and drop those packets silently.

Picture upload cadence that survives on reference benches: 2 uploads / 10 s, pages 100 ms apart, 2 s settle, about 12 ms between individual reports, no redundant mode switch. Faster pacing kills the control endpoint with `ioctl (SFEATURE): Protocol error`. A stalled endpoint does not recover on reopen; only USB re-enumeration helps. There is no USB flash read command, so flash cannot be backed up or recovered over USB.

Recovery order: re-enumerate the USB device, re-match by properties and re-identify, try another cable and port, power-cycle, and only then consider vendor software. Do not enter the bootloader unless writing a known image for the target board.

## Receiver relay

A 2.4 GHz receiver can answer its own opcodes and relay others only after a target-select step; not every receiver relays. Receiver opcodes use Bit7 and their replies do not echo the opcode. Sequence: poll `0xF7` until byte 5 is 1, send `0xF6 10` to select the keyboard, send the keyboard packet with its usual checksum, poll `0xF7` until byte 0 is 1, send bare `0xFC`, then GET the keyboard reply with its opcode echoed. Budget about 100 ms for a reply and 70 ms before the next packet. Battery percentage is in byte 1 of the receiver's `0xF7` status reply. Verify that the receiver exposes the vendor collection before using this path.

## Host-side notes

Match devices by vendor ID, product ID, usage page `0xFFFF`, usage `2` and interface number; never cache the `hidapi` path, which changes across boots (`DevSrvsID:...` on macOS). On Linux, a non-root user needs a udev rule matching the board's VID/PID with `GROUP="plugdev", MODE="0660"`. On macOS, permission failures need Input Monitoring granted to the invoking terminal or interpreter. On Windows, `HidD_SetFeature` / `HidD_GetFeature` are used through `hid.dll`; no vendor kernel driver is needed for feature reports.

Common failure signatures: a short read or wrong first byte means the 65-byte framing is wrong; a stale GET means a preceding SET or unsupported command replayed an older reply; an all-`FF` `0x8A` reply is the expected yc500 family signal, not a failure. Retry a failed read up to three times with 100/200/300 ms backoff, re-enumerate once between retry batches, and stop after a second failed batch. Never validate a reply by byte 8.
