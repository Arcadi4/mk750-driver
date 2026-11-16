# Lighting: backlight and side light

The MK750 is **yc500** (verified on the unit under test; the sharkfin registry still
lists board 849 as `unknown`). All bytes below are the 64-byte HID feature-report
payload on `0xFFFF:2`, interface 2, report ID 0. Add a leading `0x00` byte when using
`hidapi`. Bluetooth does not expose this collection; use wired USB.

## Packet layout

`SET_LEDPARAM 0x07` / `GET 0x87` control the backlight. `SET_SLEDPARAM 0x08` /
`GET 0x88` control the side light (edge light). Both use the same nine-byte prefix:

```text
[op, mode, speed, brightness, (option<<4)|flags, R, G, B, ck8]
 0    1      2         3                4        5  6  7    8
```

| Byte | Meaning |
|---|---|
| 0 | opcode: `0x07`/`0x08` for SET, `0x87`/`0x88` for GET |
| 1 | mode number (see below) |
| 2 | speed wire value |
| 3 | brightness |
| 4 | low nibble = flags, high nibble = mode-specific option |
| 5, 6, 7 | RGB, in that order |
| 8 | Bit8 checksum slot on SET: `0xFF - (sum(bytes[0:8]) & 0xFF)` (reference) |

Bytes 9..63 are zero padding. SET produces **no reply**. A GET request echoes the
opcode in byte 0 and carries a Bit7 checksum at byte 7; the verified requests are
`87 00 00 00 00 00 00 78` and `88 00 00 00 00 00 00 77`. The GET reply echoes the
opcode, then the eight state bytes, then `0x00` in byte 8 on this firmware — the
reply's byte 8 is **not** a checksum and must not be validated.

## Verified state and writes on this unit

Starting state (GET requests above, exact replies):

| Light | GET reply | Decoded state |
|---|---|---|
| main | `87 05 02 04 07 ff 45 6e 00` | mode 5 (ripple), speed 2, brightness 4, flags 7, RGB `FF456E` |
| side | `88 01 03 04 08 ff ff ff 00` | mode 1 (static), speed 3, brightness 4, flags 8, RGB `FFFFFF` |

These were read back after every write and the original state was restored:

```text
SET LEDPARAM red    : 07 01 00 04 07 ff 00 00 ed
  GET after         : 87 01 00 04 07 ff 00 00 00
SET LEDPARAM blue   : 07 01 00 04 07 00 00 ff ed
  GET after         : 87 01 00 04 07 00 00 ff 00
SET LEDPARAM restore: 07 05 02 04 07 ff 45 6e 34
  GET after         : 87 05 02 04 07 ff 45 6e 00
SET SLEDPARAM red   : 08 01 00 04 07 ff 00 00 ec
  GET after         : 88 01 00 04 07 ff 00 00 00
SET SLEDPARAM restore: 08 01 03 04 08 ff ff ff ea
  GET after         : 88 01 03 04 08 ff ff ff 00
```

The SET packets above carry the Bit8 checksum over bytes 0..7; the GET reply's
byte 8 is `0x00` on this firmware and is not a checksum. Build new packets with
the Bit8 formula and confirm the result with a GET. On this unit flags `7` plus the supplied RGB
produced a solid custom red/blue — that pairing is verified, the reverse (`8` as
fixed and `7` as rainbow) is not.

## Modes

Wire mode numbers, reference (PROTOCOL.md); the listed names and semantics were
not individually exercised on the MK750:

| Mode | Effect |
|---:|---|
| 1 | static |
| 2 | breathing |
| 3 | spectrum |
| 4 | wave |
| 5 | ripple |
| 6 | star dots |
| 7 | flow |
| 8 | key shadow |
| 9 | layers |
| 10 | sine |
| 11 | spring |
| 12 | neon |
| 14 | radiant |
| 15 | loop |
| 16 | colour grid |
| 17 | snowfall |
| 18 | meteor |
| 19 | silent snow |
| 23 | train |
| 24 | endless |

Modes 13, 20, 21, 22 and 25 need host-side data or a user picture: mode 13 selects
a USERPIC pattern slot (reference; not tested on this unit). The exact subset a
board implements, its option list and its speed/brightness ranges are per-board;
the MK750's full mode list was **not** enumerated, so do not assume it supports
every mode above.

## Flags, options, speed and brightness

The low nibble of byte 4 is the flags field (reference; PROTOCOL.md):

| Flags | Meaning |
|---:|---|
| 0..6 | preset colour: red, orange, yellow, green, cyan, blue, magenta (overrides RGB on GET) |
| 7 | fixed custom colour |
| 8 | rainbow on most boards |

Some boards swap `7` and `8` (reference; not tested on this unit), so probe with
a known RGB before relying on either. The high nibble of byte 4 is a
mode-specific option (direction, pattern slot, and so on); its meaning depends on
the mode and was not mapped for the MK750. On this unit, flag `7` with an explicit
RGB gave the supplied colour.

yc500 speed is a frame-divider index, wire `0..5`; `0` is fastest for most modes
and the host's 0..4 scale is inverted for many modes (reference; not measured
across modes on this unit). Brightness is `0..4` on most boards. Do not claim a
precise MK750 range beyond the observed values: main speed 2, side speed 3,
brightness 4 on both.

## Side light

`SET_SLEDPARAM 0x08` / `GET 0x88` use the identical byte layout and Bit8
checksum, with these modes (reference; PROTOCOL.md):

| Mode | Effect |
|---:|---|
| 0 | off |
| 1 | static |
| 2 | breathing |
| 3 | neon (forces the rainbow nibble) |
| 4 | wave |
| 5 | snake |

Side-light speed is **not** inverted. A reply to `0x88` does not prove the board
has edge LEDs (reference); the MK750 does, as its factory side-light state above
shows.

## Turning the backlight off

Backlight-off is a **settings bit**, not a black RGB write: bit value `16`
(`0x10`) in byte 2 of the `GET 0x86` / `SET 0x06` options field, alongside bits
`1` Win lock, `2` Mac mode, `8` WASD swap, `32` side light off, `64` keyboard
mode and `128` keyboard lock (reference; PROTOCOL.md). Use read-modify-write to
preserve unmodelled bits; see the settings document. RGB values below
`0x080808` render unlit, so writing black is not a reliable off switch.

## Safe write / read / restore

1. Detect the family first (`0x8F` identify → board 849); opcode `0x06` or `0x07`
   means different registers on gen2 boards.
2. Read both current states with `0x87` and `0x88` and keep the eight state bytes
   as the restore points.
3. Send SET packets with zero padding to 64 bytes. SETs are fire-and-forget.
4. Allow 100-300 ms to settle, send the GET twice, and use the **second** reply:
   the first read can return the previous GET's reply (or an older one after a
   SET). An unsupported command also replays the last reply rather than
   erroring, so check the echoed opcode.
5. Compare reply bytes 1..7 (state) and ignore reply byte 8; restore both lights
   in a `finally` block.

```python
"""Read, write and restore MK750 lighting over wired USB."""
import time

import hid

VID, PID = 0x3151, 0x4015
MAIN_GET, SIDE_GET = 0x87, 0x88

# Verified packets from the capture, shown through byte 8; zero-padded on send.
CAPTURED = {
    "main_red":     bytes.fromhex("07 01 00 04 07 ff 00 00 ed"),
    "main_blue":    bytes.fromhex("07 01 00 04 07 00 00 ff ed"),
    "main_restore": bytes.fromhex("07 05 02 04 07 ff 45 6e 34"),
    "side_red":     bytes.fromhex("08 01 00 04 07 ff 00 00 ec"),
    "side_restore": bytes.fromhex("08 01 03 04 08 ff ff ff ea"),
}


def open_board():
    for dev in hid.enumerate(VID, PID):
        if (dev.get("usage_page") == 0xFFFF
                and dev.get("usage") == 2
                and dev.get("interface_number") == 2):
            handle = hid.device()
            handle.open_path(dev["path"])
            return handle
    raise RuntimeError("no 0xFFFF:2 vendor collection on 3151:4015")


def frame(packet):
    """64 protocol bytes -> 65-byte hidapi report with leading report ID 0."""
    assert len(packet) == 64
    return b"\x00" + packet


def send(handle, packet):
    written = handle.send_feature_report(frame(packet))
    if written != 65:
        raise RuntimeError(f"short feature write: {written}")


def get_state(handle, opcode):
    request = bytearray(64)
    request[0] = opcode
    request[7] = (0xFF - opcode) & 0xFF  # Bit7 checksum on GET requests
    send(handle, request)               # discard the first reply: it may be stale
    time.sleep(0.25)
    send(handle, request)
    time.sleep(0.25)
    reply = handle.get_feature_report(0, 65)
    if reply[0] != 0 or reply[1] != opcode:
        raise RuntimeError(f"unexpected reply: {reply[:9].hex(' ')}")
    return bytes(reply[1:])             # [op, mode, speed, brightness, flags, R, G, B, 0]


def set_state(handle, name):
    packet = bytearray(64)
    source = CAPTURED[name]
    packet[:len(source)] = source       # zero padding to 64 bytes
    send(handle, packet)


def build_set(op, mode, speed, brightness, option, flags, rgb):
    """Reference Bit8 builder for new values (verify the effect with a GET)."""
    packet = bytearray(64)
    packet[:8] = bytes([op, mode, speed, brightness, (option << 4) | flags, *rgb])
    packet[8] = (0xFF - (sum(packet[:8]) & 0xFF)) & 0xFF
    return packet


board = open_board()
try:
    main_before = get_state(board, MAIN_GET)  # 87 05 02 04 07 ff 45 6e 00
    side_before = get_state(board, SIDE_GET)  # 88 01 03 04 08 ff ff ff 00
    for name in ("main_red", "main_blue"):
        set_state(board, name)
        after = get_state(board, MAIN_GET)
        assert after[1:8] == CAPTURED[name][1:8], (name, after[:9].hex(" "))
    set_state(board, "side_red")              # 88 01 00 04 07 ff 00 00 00
finally:
    set_state(board, "main_restore")
    set_state(board, "side_restore")
    board.close()
```

Per-key colour (`SET_USERPIC 0x0C`) is a separate flash-writing feature that
selects mode-13 patterns; it is covered in document 05 and is deliberately not
detailed here. Uploading per-key colour data can stall the USB control endpoint
if paced too quickly.

## Sources

- [sharkfin protocol reference, "Lighting", "Checksums" and "Settings"](https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md)
- [sharkfin board registry, row `腹灵 MK750 | 849 | 3151:4015`](https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md)
- Local recon record: `docs/data/recon-findings.md` (hardware probes and captured bytes)
- [`hidapi` Python bindings](https://pypi.org/project/hidapi/)
