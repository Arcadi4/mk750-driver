# MK750 recon findings (shared brief)

This file is the source of truth for the documentation. Values below were read
from the connected keyboard, or copied from the reference protocol document with
the evidence marker it uses (`[HW]` = measured on hardware, `[FW]` = read from a
firmware image, `[JS]` = vendor host code only). Do not invent extra bytes,
opcodes, mode numbers, or ranges. When the brief is silent, say so and mark the
claim as unverified.

## Unit under test

|                        |                                                                             |
| ---------------------- | --------------------------------------------------------------------------- |
| Marketing name         | FL Esports MK750 (75%, 82 keys, tri-mode)                                   |
| Bluetooth name         | `MK750 BT5.0 KB1` (not used; the vendor collection is cable-only)           |
| USB                    | `ROYUAN` `Gaming Keyboard`, VID `0x3151`, PID `0x4015`, bcdDevice `0x0107`  |
| Board ID               | `849` (`0x00000351`), matching sharkfin `docs/BOARDS.md` row `腹灵 MK750    | 849 | 3151:4015` |
| Protocol family        | **yc500** (verified on this unit; sharkfin's registry still says `unknown`) |
| Firmware               | revision reply decodes to `1.07`                                            |
| Active profile         | `0`                                                                         |
| Host OS used for tests | macOS 27.3, Apple Silicon, Python 3.15, `hidapi` 0.15.0                     |
| Connection used        | wired USB-C. Bluetooth does not expose the `0xFFFF:2` vendor collection.    |

## HID topology

All commands in this documentation use the vendor feature collection:

| Interface | Collection                                                                                                                       | Reports                                                  |
| --------- | -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| 0         | keyboard boot `0x01:0x06`                                                                                                        | 8-byte input, 1-byte output (LEDs)                       |
| 1         | consumer `0x0C:0x01`, system `0x01:0x80`, NKRO keyboard `0x01:0x06`, mouse `0x01:0x02`, vendor input `0xFFFF:0x01` (report ID 5) | mixed input; max feature size 1                          |
| 2         | vendor `0xFFFF:0x02`                                                                                                             | **64-byte feature report, report ID 0, both directions** |

Vendor feature report descriptor (interface 2):

```
06 ff ff 09 02 a1 01 09 02 15 80 25 7f 95 40 75 08 b1 02 c0
```

Decoded: usage page `0xFFFF`, usage `2`, application collection, logical
minimum `0x80` (-128), logical maximum `0x7F` (127), report count `0x40` (64),
report size 8, Feature (`b1 02`), 64 bytes. There is no Report ID item, so the
report ID is 0.

`hidapi` enumeration on macOS returns entries whose `path` values are dynamic
(`DevSrvsID:...`). Match on `vendor_id`, `product_id`, `usage_page == 0xFFFF`,
`usage == 2`, and `interface_number == 2`; never hard-code the path.

Newlines above are only for readability. The exact bytes are in
`docs/data/hid-descriptors.txt`.

## Wire framing

- 64 data bytes per feature report, report ID 0.
- With `hidapi`, pass a 65-byte buffer: one leading report-ID byte `0x00`
  followed by the 64 protocol bytes. `send_feature_report()` returns 65 on this
  unit. `get_feature_report(0, 65)` returns 65 bytes: report ID then 64 data
  bytes. On Linux the same 65-byte shape is used for `HIDIOCSFEATURE` /
  `HIDIOCGFEATURE`.
- The protocol byte at offset 0 of the 64-byte payload is the opcode.
- A SET command produces **no reply**. A following GET returns the reply to the
  most recent GET; after a SET, the first read can therefore return an older
  reply. Send the GET twice and use the second reply when in doubt.
- A GET reply echoes the opcode in byte 0 (bulk page reads are the exception).
  An unsupported command replays the previous reply, not an error.
- Recommended settle time: 100-300 ms between a SET and the following GET.
  The reference document uses about 100 ms; the probes below used 250-300 ms.

### Checksums

```
Bit7: checksum = 0xFF - (sum(bytes[0:7]) & 0xFF)   stored at byte 7
Bit8: checksum = 0xFF - (sum(bytes[0:8]) & 0xFF)   stored at byte 8
```

- `SET_LEDPARAM` (`0x07`) and `SET_SLEDPARAM` (`0x08`) use **Bit8**.
- All other app-mode commands use **Bit7**.
- On this unit, GETs for the LED and side-light state were accepted with either
  checksum position (both returned the current state), but use Bit7 for all
  GETs except the two lighting GETs, and Bit8 for the two lighting SETs, to
  match the reference.
- Bulk flash writes (`0x09`, `0x10`, `0x0C`, `0x16`) use the Bit7 form for the
  command packets; their 56-byte data pages carry no checksum.

## Verified exchanges (exact bytes)

All packets below are the 64-byte protocol payload; add the leading `0x00`
report ID when calling `hidapi`. Only the significant bytes are shown; the rest
are zero.

| Command      | Request                   | Reply                        | Meaning                                              |
| ------------ | ------------------------- | ---------------------------- | ---------------------------------------------------- |
| Identify     | `8f 00 00 00 00 00 00 70` | `8f 51 03 00 00 00 00 70`    | board ID 849 (`0x00000351`)                          |
| Revision     | `80 00 00 00 00 00 00 7f` | `80 07 01 00 00 00 00 7f`    | `(reply[2]<<8)                                       | reply[1]`=`0x0107` = 1.07 |
| Profile GET  | `85 00 00 00 00 00 00 7a` | `85 00 00 00 00 00 00 7a`    | current profile 0; no per-index query                |
| LED GET      | `87 00 00 00 00 00 00 78` | `87 05 02 04 07 ff 45 6e 00` | mode 5, speed 2, brightness 4, flags 7, RGB `FF456E` |
| Side GET     | `88 00 00 00 00 00 00 77` | `88 01 03 04 08 ff ff ff 00` | mode 1, speed 3, brightness 4, flags 8, RGB `FFFFFF` |
| Debounce GET | `91 00 00 00 00 00 00 6e` | `91 00 01 00 00 00 00 00`    | debounce 1 ms                                        |
| Sleep GET    | `92 00 00 00 00 00 00 6d` | `92 78 00 78 00 58 02 58 02` | 120, 120, 600, 600 seconds                           |
| Options GET  | `86 00 00 00 00 00 00 79` | `86 00 02 02 00 00 00 00`    | byte 2 = 2 (Mac mode), byte 3 = 2, byte 4 = 0        |
| Auto-OS GET  | `97 00 00 00 00 00 00 68` | `97 01 00 00 00 00 00 00`    | auto-OS enabled                                      |
| Macro GET    | `8b 00 00 00 00 00 00 74` | `0f 00 04 80 f2 01 …`        | raw 64-byte page, slot 0, page 0                     |

Write verification (all values restored afterwards):

```
SET LEDPARAM red   : 07 01 00 04 07 ff 00 00 ed
  GET after        : 87 01 00 04 07 ff 00 00 00
SET LEDPARAM blue  : 07 01 00 04 07 00 00 ff ed
  GET after        : 87 01 00 04 07 00 00 ff 00
SET LEDPARAM restore: 07 05 02 04 07 ff 45 6e 34
  GET after        : 87 05 02 04 07 ff 45 6e 00
SET SLEDPARAM red  : 08 01 00 04 07 ff 00 00 ec
  GET after        : 88 01 00 04 07 ff 00 00 00
SET SLEDPARAM restore: 08 01 03 04 08 ff ff ff ea
  GET after        : 88 01 03 04 08 ff ff ff 00
```

The reply's byte 8 is zero on this firmware, not a checksum. Do not use it for
validation.

## Family detection

The same VID:PID is shared by many yc500 and gen2 boards. Detect from the
device, not the PID:

1. Send `8F` and expect a valid identify reply (echo + 4-byte ID).
2. Send the yc500 keymap read `89 [profile, page]`. On this unit profile 0 /
   page 0 returns slot data beginning `00 00 29 00 00 00 35 00 …`.
3. Send the gen2 keymap read `8A [profile, 0xFF, page, os]`. On this unit it
   returns all `FF` bytes, which is the documented yc500 answer.

Conclusion: **yc500** on this unit. Do not use 0x8A, `0x84`, gen2 keymap writes,
or gen2 settings opcodes.

## Keymap facts

Read with `0x89 [profile, page]` (base) and `0x90 [profile, page]` (Fn layer),
pages 0..7, each reply is a raw 64-byte page (no opcode echo). Slot `n` lives
at byte `(n % 16) * 4` of page `n // 16`.

Slot encoding (4 bytes, little-endian meaning):

| byte 0 | meaning            | bytes 1..3                                                                             |
| ------ | ------------------ | -------------------------------------------------------------------------------------- |
| `0x00` | HID keyboard usage | `[0, usage, 0]` (`usage` in byte 2)                                                    |
| `0x01` | mouse button       |                                                                                        |
| `0x03` | consumer usage     | usage in bytes 2..3 little-endian (`[0, lo, hi]`)                                      |
| `0x09` | macro              | `[mode, index, 0]`, mode 0 repeat, 1 toggle, 2 hold                                    |
| `0x0A` | special            | `[code,0,0]`; 1 = Fn, 8 = observed, 12 = power save, 13 = observed, 17 = Caps LED swap |
| `0x0D` | extended Fn action | raw `[sub, a, b]`; observed sub 1,2,3,5,6. Meaning not published                       |
| `0x0E` | wireless channel   | observed `a=0,b=0..2` (BT 1..3) and `a=1,b=0` (2.4 GHz)                                |

Profile 0 and profile 1 base/Fn layers are identical. Profile 2's Fn layer is
all `FF` (erased), profile 3's Fn layer is random-looking uninitialized flash;
only profiles 0 and 1 are usable. All four profiles' base layers are identical.
Do not write profiles 2/3.

The base layer has 86 populated slots: 82 HID keyboard usages, three consumer
keys (Mute, VolumeUp, VolumeDown) and one special Fn key. The Fn layer includes:

- F1/F2 = brightness up/down; F7/F8/F9/F10/F11/F12 = media keys.
- Fn+1/2/3 = Bluetooth channels; Fn+4 = 2.4 GHz.
- Fn+Left/Right and Fn+Up/Down = extended Fn actions (probably speed and
  brightness; the exact semantics are not published, so label them raw).
- Fn+Insert = special 12 (power save per reference).
- Fn+Esc, Fn+Backspace, Fn+Delete, Fn+RCtrl, Fn+RShift = special / extended
  actions whose meanings are not published.

The full decode is in `docs/data/keymap-profile0.tsv` and
`docs/data/keymap-profile0.json`.

Matrix order maps to physical keys through a board-specific scan matrix. Slot
`n` is matrix column `n // 6`, row `n % 6` (the reference uses
`slot = column * 6 + row` for the Mac modifier transform). The physical key for
each slot is not published in the protocol; do not present a physical layout
table unless it is derived and marked as inferred.

## Lighting facts

Reference: sharkfin `docs/PROTOCOL.md` section "Lighting". Modes 1..19 are the
usual set; modes 13, 20, 21, 22, 25 need host-side data. yc500 speed is a
frame-divider index, 0..5 (0 fastest for most modes). Brightness 0..4 on most
boards. Flags nibble: `7` fixed colour, `8` rainbow on most boards; some boards
swap them. Preset flag values 0..6 select red, orange, yellow, green, cyan,
blue, magenta. RGB below `0x080808` renders unlit. Backlight-off is an options
bit, not a black write.

For this unit, flags `7` + RGB behaved as a fixed custom colour, and flags `8`
on the side light was the factory state. Do not claim the reverse without a
test.

## Configuration facts

Reference: sharkfin `docs/PROTOCOL.md` sections "Profiles", "Settings",
"Per-key colour", "Macros". Verified on this unit:

- Debounce = 1, range 1..10.
- Sleep timers = 120/120/600/600 s (BT sleep, 2.4G sleep, deep BT, deep 2.4G).
- Options byte 2 = `0x02` (Mac mode); byte 3 = `0x02`; byte 4 = 0.
- Auto-OS = enabled.
- Active profile = 0; four profile slots readable, but only 0/1 have valid Fn
  layers.

Not verified on this unit: keymap write, macro write, per-key colour upload,
screen/OLED, reset, bootloader, 2.4 GHz receiver, battery. Present those from
the reference and mark them as reference-only.

## Reference sources

- sharkfin protocol, the authoritative public reverse-engineering write-up:
  https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md
- sharkfin board registry (row for board 849, `3151:4015`, family `unknown`
  before this recon):
  https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md
- FL Esports official software page (Windows/macOS vendor configurator):
  https://flesportsglobal.com/pages/software
- `hidapi` Python bindings: https://pypi.org/project/hidapi/

## Hard safety rules

- Never send `0x7F 55 AA 55 AA` (USB bootloader), `0x30 55 AA 55 AA` (display
  boot), `0xAC`/`0x2C` (flash erase), or `0x02` (factory reset) from a tool that
  is not deliberately flashing/recovering a board.
- Never write a keymap, macro, or per-key colour without first reading and
  saving the affected profile.
- Per-key colour uploads land in flash and can stall the control endpoint if
  paced too fast. The reference recommends 2 uploads / 10 s, pages 100 ms
  apart, 2 s settle.
- The same opcode means different registers in yc500 and gen2. A misaddressed
  write lands on a live register. Confirm the family first.
- Bluetooth has no vendor collection. The 2.4 GHz receiver only relays if it
  enumerates the vendor collection; this unit's receiver was not tested.
