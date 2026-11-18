# Settings and profiles (yc500)

This page covers the configuration registers on the FL Esports MK750 (board
849, `3151:4015`, firmware 1.07). The unit is **yc500**. Opcodes collide with
gen2: yc500 `0x06` is gen2 debounce and yc500 `0x11` is gen2 sleep time, so a
misaddressed write lands on a live register. Confirm the family before sending
any SET. Family detection is covered in the transport documentation; the short
version is that `8F` must return a valid identify reply and `8A` must return
all `FF` bytes.

All packets below are the 64-byte protocol payload on interface 2
(`0xFFFF:0x02`, feature report ID 0). With `hidapi`, prepend one `0x00` report
ID byte and pass a 65-byte buffer. A SET produces **no reply**; a following GET
returns the reply to the most recent GET, so send a GET twice and use the second
reply when in doubt. Allow 100-300 ms between a SET and its verification GET.
App-mode commands use the Bit7 checksum:

```text
pkt[7] = 0xFF - (sum(pkt[0:7]) & 0xFF)
```

GET replies echo the opcode in byte 0. An unsupported command replays the
previous reply, not an error.

## Safe reads and live writes

Everything in this document falls into one of two groups. Keep them separate in
any tool you build.

| Safe reads (no state changes)                                                 | Live writes (change flash or RAM state)                                                        |
| ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `0x85` profile, `0x91` debounce, `0x92` sleep, `0x86` options, `0x97` auto-OS | `0x05` profile, `0x11` debounce, `0x12` sleep, `0x06` options, `0x17` auto-OS                  |
| `0x8C` per-key colour (returns stale data, see below)                         | `0x0C` per-key colour (flash write, endpoint-stall hazard)                                     |
| `0xF7` on a 2.4 GHz receiver (not tested on this unit)                        | `0x02` factory reset, `0xAC`/`0x2C` flash erase, `0x30` display boot (never in normal tooling) |

The per-key colour, screen, and reset sections are deliberately placed after
the settings sections and carry their own warnings.

## Profiles

|                            | SET    | GET    |
| -------------------------- | ------ | ------ |
| yc500 (this unit) **[HW]** | `0x05` | `0x85` |
| gen2 **[HW]**              | `0x04` | `0x84` |

GET returns the current, zero-based index in `reply[1]`. There is **no count
query**: nothing on the wire tells you how many profiles exist. Verified reply
on this unit: `85 00 00 00 00 00 00 7a`, i.e. profile 0.

Switch to a profile before writing its keymap. A `0x05` write selects the
profile for subsequent keymap operations; the reference does not spell out the
payload byte position, so place the index where the GET reports it (byte 1) and
confirm with a `0x85` read-back. Do not use `0x04`, which is a different
register on this family. Only profiles 0 and 1 have valid Fn layers on this
unit; profiles 2 and 3 must not be written.

```python
import hid

VID, PID = 0x3151, 0x4015

def open_board():
    for d in hid.enumerate(VID, PID):
        if (d["usage_page"] == 0xFFFF and d["usage"] == 2
                and d["interface_number"] == 2):
            dev = hid.device()
            dev.open_path(d["path"])   # paths are dynamic; never hard-code them
            return dev
    raise RuntimeError("vendor feature collection not found")

def send(dev, pkt):
    pkt[7] = (0xFF - (sum(pkt[:7]) & 0xFF)) & 0xFF
    buf = bytearray(65)
    buf[1:] = pkt
    return dev.send_feature_report(bytes(buf))

def get(dev, opcode):
    req = bytearray(64)
    req[0] = opcode
    send(dev, req)
    send(dev, req)                 # first read can replay an older reply
    return bytes(dev.get_feature_report(0, 65)[1:])

dev = open_board()
current = get(dev, 0x85)[1]
print("active profile:", current)
```

## Debounce

yc500 uses **SET `0x11` / GET `0x91`**, with the value at **byte 2** in both
directions. Range is **1..10**. yc500 pads byte 1 with zero; sending that shape
to a gen2 board writes debounce 0, since gen2 uses `0x06`/`0x86` with the value
at byte 1 (reference; not tested on this unit).

Verified on this unit:

```text
GET 91 00 00 00 00 00 00 6e  ->  91 00 01 00 00 00 00 00   (1 ms)
```

A SET to 1 ms is `11 00 01 00 00 00 00 ed`; restore the original value after
any experiment.

## Sleep timers

Four `u16` little-endian values in seconds, in this order: sleep BT, sleep
2.4G, deep BT, deep 2.4G. The offsets differ between SET and GET.

| Command                      | Offsets                                                  |
| ---------------------------- | -------------------------------------------------------- |
| yc500 SET `0x12`             | bytes **8..15** **[HW]**                                 |
| yc500 GET `0x92`             | bytes **1..8** (not the SET offsets) **[HW]**            |
| gen2 SET `0x11` / GET `0x91` | bytes 8..15 (SET **[FW]**, GET **[HW]**; reference only) |

Verified on this unit:

```text
GET 92 00 00 00 00 00 00 6d
 -> 92 78 00 78 00 58 02 58 02
    = 120 / 120 / 600 / 600 seconds
```

```python
import struct

reply = get(dev, 0x92)
sleep_bt, sleep_24g, deep_bt, deep_24g = struct.unpack_from("<4H", reply, 1)
print(sleep_bt, sleep_24g, deep_bt, deep_24g)   # 120 120 600 600
```

## Options bitfield

yc500 uses **SET `0x06` / GET `0x86`**. The GET reply byte 2 is a bitfield:

| Bit | Value | Meaning        |
| --- | ----- | -------------- |
| 0   | `1`   | Win lock       |
| 1   | `2`   | Mac mode       |
| 3   | `8`   | WASD swap      |
| 4   | `16`  | Backlight off  |
| 5   | `32`  | Side light off |
| 6   | `64`  | Keyboard mode  |
| 7   | `128` | Keyboard lock  |

Byte 3 is the Fn matrix flag and byte 4 is power save. Bit `128` locks the
keyboard. The vendor's setter writes Mac mode at bit 1 while its getter reads
bit 0 **[JS]**; trust the GET reply when deciding what is currently active.

Verified on this unit: `86 00 02 02 00 00 00 00`, i.e. byte 2 = `0x02`
(Mac mode), byte 3 = `0x02`, byte 4 = `0`. Backlight-off is this bit, not a
black LED write.

**Read-modify-write is mandatory.** The reference documents the reply bits only
and calls out unmodelled bits that a blind write would clear; the SET payload
byte positions below mirror the GET reply and are not verified on this unit.
Always read first, change one bit, write the whole set back, then read again and
restore when finished.

```python
def write_options(dev, byte2, byte3, byte4):
    # SET payload shape inferred from the GET reply layout; not tested on unit
    pkt = bytearray(64)
    pkt[0] = 0x06
    pkt[2], pkt[3], pkt[4] = byte2, byte3, byte4
    send(dev, pkt)

reply = get(dev, 0x86)
b2, b3, b4 = reply[2], reply[3], reply[4]
original = (b2, b3, b4)
write_options(dev, b2 ^ 0x02, b3, b4)   # toggle Mac mode only
after = get(dev, 0x86)
print(hex(after[2]), after[3], after[4])
write_options(dev, *original)           # restore
```

## Auto-OS

**SET `0x17 [0|1]` / GET `0x97`**, with `reply[1] == 1` meaning enabled. Verified
on this unit: `97 01 00 00 00 00 00 00`, auto-OS enabled. The opcode pair is the
same in gen2 **[HW]**.

## Report rate: not available here

Report rate is **gen2 only**: GET `0x83` **[HW]**, SET `0x03` **[FW]** (reference;
not tested on this unit). It is **absent on yc500** — the vendor setter is a stub
returning false **[JS]**. Do not send `0x83` or `0x03` to this board and expect a
meaningful reply; an unsupported opcode replays the previous GET result.

## Per-key colour (flash write, endpoint-stall hazard)

Not tested on this unit. Everything in this section is from the reference and
is marked reference-only. **Do not use this in a general-purpose settings
tool.** `SET_USERPIC 0x0C` uploads RGB triples in matrix order over seven pages,
384 bytes total (128 keys), with data from **byte 8**. The opcode is shared with
gen2 but the header is not.

| Byte | yc500 header **[HW]** |
| ---- | --------------------- |
| 0    | `0x0C` (opcode)       |
| 1    | `0`                   |
| 2    | length low            |
| 3    | length high           |
| 4    | page, 0..6            |
| 5    | `0`                   |
| 8..  | 56 bytes of RGB data  |

`GET_USERPIC 0x8C` returns stable data that does not reflect writes: treat it as
**write-only** (reference; not tested on this unit). Display the uploaded image
by selecting light mode **13**. On gen2 the mode's option nibble selects the
USERPIC slot; that detail is not evidenced for yc500 here.

Uploads land in flash. The measured cadence on the reference benches:

| Cadence                                                                    | Result                          |
| -------------------------------------------------------------------------- | ------------------------------- |
| 7 reports / 500 ms                                                         | endpoint dies after ~13 reports |
| 7 reports / 3 s                                                            | 42 reports, still responsive    |
| 2 uploads / 5 s, pages 40 ms apart, mode switch 600 ms after               | stalled on the second           |
| 2 uploads / 10 s, pages 100 ms apart, 2 s settle, no redundant mode switch | survives                        |

Individual reports needed about 12 ms spacing. A stalled endpoint fails every
report with `ioctl (SFEATURE): Protocol error` and does not recover on reopen;
the device needs USB re-enumeration. If you must upload, back up the affected
profile first, use the surviving cadence above, and expect to unplug the
keyboard if it stalls. This cadence is not evidenced on gen2.

## Screen / OLED / clock (not tested on this unit)

**Not tested on this unit; many boards have no panel at all.** A GET reply is
not evidence that a display exists: firmware is shared across boards with and
without panels. Nothing here should be sent by default tooling. These opcodes
come from the reference; screen geometry is per board (`other.screen`: `size.w`,
`size.h`, `mode`, `layer`) and no default size may be assumed.

| Opcode          | Role                                            | Notes                                                                                                                                                                     |
| --------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0xA5` / `0x25` | announce / data, mode 16 (RGB565) **[FW]**      | yc500 image with a panel; announce payload `[1]` frame, `[2]` count, `[3]` delay, `[4..6]` length u16 LE, `[8..12]` box; data has a header and 56 bytes from byte 8       |
| `0xA9` / `0x29` | announce / data, mode 24 (RGB triples) **[FW]** | alternate pair; each panel image implements one pair and rejects the other                                                                                                |
| `0x28`          | clock, Bit7 **[FW] [HW]**                       | fields after the checksum: bytes 8/9 year big-endian, 10 month 1..12, 11 day, 12 hour 0..23, 13 minute, 14 second. No read; round-tripped on a gen2 K86, not on this unit |
| `0xAC` / `0x2C` | flash-chip erase / display erase                | **Destructive.** `0xAC` erases every picture on gen2 (~55 s). Never send blind                                                                                            |
| `0x30` / `0x31` | display-chip boot in both families **[FW]**     | `0x30` with trailer `55 AA 55 AA` is boot entry; never send from normal tooling                                                                                           |

`0xAD` and `0xAE` are GETs of display chip firmware versions, not erases; a
gen2 board with no display answers with a zero word instead of echoing **[HW]**.
Whether this unit answers either is untested.

## Factory reset (destructive)

yc500 factory reset is bare opcode **`0x02`** and takes about 4 s **[HW]**.
(gen2 uses `0x01` **[FW]**; reference only.) This wipes configuration. **Do not
include `0x02` in normal tooling** and never send it as a GET.

## Battery

There is **no battery command on the keyboard's own collection**. Over 2.4 GHz
the receiver's status reply carries keyboard battery as a percent in **byte 1**
of opcode **`0xF7`** **[HW]**. This unit's receiver was not tested, and the
status byte layout is from the reference for other receivers; treat it as
reference-only here. Bluetooth does not expose the vendor feature collection.

## Settings dump snippet

This reads only the safe GET opcodes and prints the decoded values observed on
this unit. It never writes.

```python
import struct

def dump(dev):
    profile = get(dev, 0x85)[1]
    debounce = get(dev, 0x91)[2]                  # 1..10 ms
    timers = struct.unpack_from("<4H", get(dev, 0x92), 1)
    opt = get(dev, 0x86)
    auto_os = get(dev, 0x97)[1] == 1

    print(f"profile:   {profile}")
    print(f"debounce:  {debounce} ms")
    print("sleep s:   " + " / ".join(map(str, timers)))
    print(f"options:   byte2=0x{opt[2]:02x} byte3={opt[3]} byte4={opt[4]}")
    print(f"auto-OS:   {'enabled' if auto_os else 'disabled'}")

dump(open_board())
```

Expected on this unit: profile 0, debounce 1 ms, sleep 120/120/600/600 s,
options byte2 `0x02` / byte3 `0x02` / byte4 0, auto-OS enabled.

## Sources

- [sharkfin protocol reference](https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md) — opcodes, offsets, ranges, pacing, hazards, and display/reset/battery claims.
- [sharkfin board registry](https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md) — row `腹灵 MK750 | 849 | 3151:4015`.
- [MK750 recon findings (local brief)](data/recon-findings.md) — verified values, exact bytes, and family determination for this unit.
- [`hidapi` Python bindings](https://pypi.org/project/hidapi/) — feature-report API used in the examples.
