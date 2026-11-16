# Handshake, identification, and family detection

All packets here use the vendor feature collection on interface 2: usage page
`0xFFFF`, usage `2`, 64-byte feature reports, report ID 0 both directions. With
`hidapi` pass a 65-byte buffer: one leading `0x00` report-ID byte followed by the
64-byte payload. Every request below is written as that 64-byte payload; prepend
`0x00` on the wire.

Transport rules that matter for a handshake:

* A GET echoes its opcode in byte 0. Bulk page reads (keymap, Fn layer, macro,
  user picture) are the exception: they return raw bytes with no echo.
* A SET produces no reply. A following GET can return the reply to an older GET.
  Send a GET twice and use the second reply when in doubt.
* An unsupported command replays the previous reply rather than returning an
  error. Identical replies to different probes mean "inconclusive", not "same
  answer twice".
* Allow 100-300 ms to settle between requests. On this unit 250-300 ms was used.
* Requests are Bit7: `checksum = 0xFF - (sum(bytes[0:7]) & 0xFF)` at byte 7. Only
  `0x07` and `0x08` (LED/side-light SET) use Bit8 with the checksum at byte 8.
* Do not validate a reply by its checksum byte. The reply's byte 7 carries the
  request's checksum, and byte 8 is zero on this firmware.

## Identify: `0x8F`

`0x8F` is a Bit7 request with layout `[0x8F, id:u32 LE, …]`:

```text
request  8f 00 00 00 00 00 00 70
reply    8f 51 03 00 00 00 00 70
```

`reply[1:5] = 51 03 00 00` is a little-endian u32, `0x00000351` = **849**, the
board ID of this unit. Byte 7 of the reply is not a recomputed checksum; use the
opcode echo and the ID, not that byte, to accept a reply.

Do not treat every echo as identification: the ADX MK0620 pattern `0x00FF0000`
from sharkfin issue #98 (a probe echoed with byte 3 set to `FF`) is rejected as
an identification response (reference; not tested on this unit). Accept a reply
only when the opcode echoes and the little-endian ID is a plausible board ID.

Board 849 is sharkfin's registry row `腹灵 MK750 | 849 | 3151:4015`, the FL
Esports MK750. The registry still lists its family as `unknown`; this unit is a
verified yc500 MK750 sample from this recon. Do not "correct" the registry from the PID —
see the warning below.

## Revision: `0x80`

```text
request  80 00 00 00 00 00 00 7f
reply    80 07 01 00 00 00 00 7f
```

Decode `(reply[2] << 8) | reply[1]` = `0x0107`. Each nibble of the pair is a
decimal digit, so this reads as firmware **1.07**, matching the USB bcdDevice
`0x0107`.

Gen2 boards return zeros for `0x80` over the cable on every board sharkfin
reports; the vendor's gen2 driver treats `0x80` as the RF version and reads the
keyboard version from the identify reply instead, `(reply[8] << 8) | reply[7]`
(reference; not tested on this unit). A zero revision is therefore a family
signal, not evidence of a broken device.

## Current profile: `0x85`

```text
request  85 00 00 00 00 00 00 7a
reply    85 00 00 00 00 00 00 7a
```

`reply[1]` is the zero-based current profile (`0` on this unit). There is **no
per-index query**: every argument pattern sent in testing returned profile 0.
The GET reports the active profile only; it does not enumerate how many profiles
exist. The SET counterpart is `0x05` on yc500 and `0x04` on gen2.

## Family detection

The same USB VID:PID is reused across boards and across families. `3151:4015`
covers, for example, registry IDs 849 (MK750, family `unknown` before this
recon), 1586 (MK870 PRO, `unknown`), and 3430 (MK100T, `yc500`); sharkfin notes
that over a hundred yc500 boards share `3151:4015`. **Never infer the family from
the PID or the USB product name.** Resolve it from the device.

### Decision procedure

1. Send `8f 00 00 00 00 00 00 70`. Require `reply[0] == 0x8F` and a plausible
   little-endian ID; in particular reject the documented `0x00FF0000` echo
   pattern. If the reply fails, stop; send no writes.
2. Send the yc500 base-keymap GET for profile 0, page 0:
   `89 00 00 00 00 00 00 76`. This is a bulk page read, so the 64-byte reply has
   no opcode echo. On this unit it returns slot data starting
   `00 00 29 00 00 00 35 00 …`.
3. Send the gen2 keymap GET for profile 0, sentinel `0xFF`, page 0, os 0:
   `8A 00 FF 00 00 00 00 76`. Also a bulk page read. On this unit the reply is
   all `FF`.
4. Decide from the two replies:
   * **yc500** — step 2 returned non-`FF` bytes with no `0x89` echo, *and* step 3
     returned all `FF`. That pair is the verified signature on this unit; the
     all-`FF` answer to `0x8A` is also the documented yc500 behavior.
   * **gen2** — step 2 echoed `0x89` in byte 0 (on gen2, `0x89` is the options
     GET, which echoes), *or* step 3 returned a non-all-`FF` raw page without an
     `0x8A` echo.
   * Otherwise the probes are inconclusive — identical replies (a replay), two
     echoes, or two all-`FF` pages. Stop and send no writes.

The checksum bytes in steps 2 and 3 are computed with the documented Bit7
formula: for `89 00 00 00 00 00 00`, `sum(bytes[0:7]) = 0x89`, so the checksum is
`0x76`; for `8A 00 FF 00 00 00 00`, `sum(bytes[0:7]) = 0x189`, which also gives
`0x76`. The brief names the opcodes and arguments but does not print these two
full request strings.

| Probe | yc500 (verified on this unit) | gen2 (reference; not tested on this unit) |
|---|---|---|
| `89 00 00 00 00 00 00 76` | raw page of slot data, no echo: `00 00 29 00 …` | echoed `89 …` reply: `0x89` is the gen2 options GET |
| `8A 00 FF 00 00 00 00 76` | all `FF` | raw keymap page, no echo |

**Conclusion for this unit: yc500.** Use only the yc500 column below. In
particular, do not send `0x84`, `0x0A`, `0x04`, `0x01`, or any gen2-shaped
settings write. `0x8A` is acceptable only as the read-only probe in step 3.
Because `0x09`, `0x11`, and `0x06` are live in both families but name different
registers, never send a gen2-shaped payload to this board.

### Family differences

Every gen2 value in this table is (reference; not tested on this unit). The
"Evidence" column marks the yc500 behavior actually observed here.

| Function | yc500 | gen2 | Evidence here |
|---|---|---|---|
| Keymap base GET | `0x89 [profile, page]`, raw page | `0x8A [profile, 0xFF, page, os]`, raw page | `0x89` slot data; `0x8A` all `FF` |
| Keymap base SET | `0x09` bulk; `0x13` single slot | `0x0A` (slot or bulk) | not written here |
| Profiles SET / GET | `0x05` / `0x85` | `0x04` / `0x84` | `0x85` GET verified |
| Debounce SET / GET | `0x11` / `0x91`, value at byte 2, zero pad at byte 1 | `0x06` / `0x86`, value at byte 1 | `0x91` GET = 1 ms; range 1..10 |
| Sleep SET / GET | `0x12` (bytes 8..15) / `0x92` (bytes 1..8) | `0x11` (bytes 8..15) / `0x91` (bytes 8..15) | `0x92` GET = 120/120/600/600 s |
| Options SET / GET | `0x06` / `0x86`, bitfield at byte 2 | `0x09` / `0x89`, decoded fields, meanings unestablished | `0x86` GET byte 2 = `0x02` (Mac mode) |
| Reset | `0x02`, needs about 4 s | `0x01`, bare opcode | not sent here; destructive |
| Revision GET | `0x80`, `(reply[2]<<8)\|reply[1]` | `0x80` returns zeros over cable | `0x80` = `0x0107` |
| Macro SET | `0x16` | `0x0B` | not written here |
| Report rate | absent | GET `0x83`, SET `0x03` | not tested |

The opcode collisions are the reason for the decision procedure: yc500
`SET_KEYMATRIX` (`0x09`) is gen2 `SET_KBOPTION`, yc500 `SET_KBOPTION` (`0x06`)
is gen2 `SET_DEBOUNCE`, and yc500 `SET_DEBOUNCE` (`0x11`) is gen2
`SET_SLEEPTIME`. A misaddressed write lands on a live register. Reset,
bootloader, and flash-erase opcodes must never be sent as a probe.

## Python example

```python
import time
import hid

VID, PID = 0x3151, 0x4015
USAGE_PAGE, USAGE, INTERFACE = 0xFFFF, 2, 2
SETTLE = 0.25


def open_board():
    # Enumeration paths are dynamic (DevSrvsID:... on macOS). Match on IDs.
    for d in hid.enumerate(VID, PID):
        if (d.get("usage_page") == USAGE_PAGE
                and d.get("usage") == USAGE
                and d.get("interface_number") == INTERFACE):
            dev = hid.device()
            dev.open_path(d["path"])
            return dev
    raise RuntimeError("MK750 vendor collection not found")


def frame(opcode, *args):
    """Build a 64-byte Bit7 request."""
    p = bytearray(64)
    p[0] = opcode
    for i, arg in enumerate(args, 1):
        p[i] = arg
    p[7] = 0xFF - (sum(p[:7]) & 0xFF)
    return bytes(p)


def xfer(dev, packet):
    dev.send_feature_report(b"\x00" + packet)       # 65 bytes with report ID 0
    time.sleep(SETTLE)
    return bytes(dev.get_feature_report(0, 65))[1:]  # strip report ID


def get(dev, opcode, *args):
    p = frame(opcode, *args)
    xfer(dev, p)            # first read may replay an older GET
    time.sleep(0.1)
    return xfer(dev, p)     # use the second reply


def identify(dev):
    reply = get(dev, 0x8F)  # 8f 00 00 00 00 00 00 70
    if reply[0] != 0x8F:
        raise RuntimeError(f"identify failed: {reply[:8].hex(' ')}")
    board_id = int.from_bytes(reply[1:5], "little")
    if board_id == 0x00FF0000:
        raise RuntimeError(f"rejected identify echo: {board_id:#x}")

    rev = get(dev, 0x80)    # 80 00 00 00 00 00 00 7f
    revision = None
    if rev[0] == 0x80:
        word = (rev[2] << 8) | rev[1]
        revision = f"{word >> 8}.{word & 0xFF:02d}"
    return {"board_id": board_id, "revision": revision}


def detect_family(dev, board_id):
    if board_id == 0x00FF0000:
        raise RuntimeError("call identify() first")

    # yc500 base keymap, profile 0 page 0: 89 00 00 00 00 00 00 76
    yc = get(dev, 0x89, 0, 0)
    # gen2 keymap, profile 0 / sentinel FF / page 0 / os 0:
    # 8A 00 FF 00 00 00 00 76
    g2 = get(dev, 0x8A, 0, 0xFF, 0, 0)

    yc_ff = all(b == 0xFF for b in yc)
    g2_ff = all(b == 0xFF for b in g2)

    if yc == g2:
        raise RuntimeError("probe replies identical (replay); family unknown")
    if (not yc_ff) and yc[0] != 0x89 and g2_ff:
        return "yc500"
    if yc[0] == 0x89 or ((not g2_ff) and g2[0] != 0x8A):
        return "gen2"
    raise RuntimeError("inconclusive probes; send no writes")


dev = open_board()
try:
    info = identify(dev)                            # board_id 849, revision 1.07
    family = detect_family(dev, info["board_id"])   # "yc500" on this unit
    print(info, family)
finally:
    dev.close()
```

## Sources

* [MK750 recon findings (local, verified source of truth)](data/recon-findings.md)
* [sharkfin protocol reference](https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md)
* [sharkfin board registry](https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md)
* [`hidapi` Python bindings](https://pypi.org/project/hidapi/)
