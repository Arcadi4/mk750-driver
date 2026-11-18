# 01 — Transport

Every command in this documentation travels in a 64-byte HID feature report on
the MK750's vendor collection. The facts below were verified on the FL Esports
MK750 (board 849, `3151:4015`, firmware 1.07, **yc500** family) over wired
USB-C. Claims from the public reference are marked _(reference; not tested on
this unit)_.

## HID topology

From `docs/data/hid-descriptors.txt`:

| Interface | Primary usage page | Primary usage | Max input | Max output | Max feature | Purpose                                                                              |
| --------- | ------------------ | ------------- | --------- | ---------- | ----------- | ------------------------------------------------------------------------------------ |
| 0         | `0x0001`           | `0x06`        | 8         | 1          | 0           | boot keyboard                                                                        |
| 1         | `0x000C`           | `0x01`        | 16        | 1          | 1           | consumer + system + NKRO keyboard + mouse + vendor input `0xFFFF:0x01` (report ID 5) |
| **2**     | **`0xFFFF`**       | **`0x02`**    | 0         | 0          | **64**      | **vendor feature channel — all commands in these docs**                              |

Interface 2 is the only command channel. Its report descriptor is:

```text
06 ff ff 09 02 a1 01 09 02 15 80 25 7f 95 40 75 08 b1 02 c0
```

Decoded: usage page `0xFFFF`, usage `2`, application collection, usage `2`,
logical minimum `0x80` (-128), logical maximum `0x7F` (127), report count
`0x40` (64), report size 8, Feature (`b1 02`), 64 bytes in both directions.
There is no Report ID item, so **the report ID is 0**. The `0xFFFF:0x01`
collection on interface 1 is an input-only vendor report (used for the travel
stream on other boards); it is not the configuration channel.

## Link choices

| Link                          | Usable for these commands?                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Wired USB-C                   | Yes. All verified exchanges used this link.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Bluetooth (`MK750 BT5.0 KB1`) | No. Bluetooth does not expose the `0xFFFF:0x02` vendor collection, so there is nowhere to send a feature report. Enumerate over cable instead.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| 2.4 GHz receiver              | _(reference; not tested on this unit)_ Only if the receiver itself enumerates the `0xFFFF:0x02` collection and relays to the keyboard. A receiver (`3151:4011` on an X86) answers its own opcodes and relays everything else after a target-select step; not every receiver relays (the Typhoon Ultimate TKL's does not). Receiver opcodes are Bit7 and their replies do not echo the opcode. The relay sequence is: poll `0xF7` until `[5] == 1`, send `0xF6 10` (keyboard), send the keyboard packet with its usual checksum, poll `0xF7` until `[0] == 1`, send bare `0xFC`, then GET the keyboard's reply (opcode echoed). A reply is ready about 100 ms after the send and the receiver accepts the next packet about 70 ms after a write; the vendor polls up to five times at 100 ms. Without the select step a keyboard packet is dropped and a keyboard GET returns the receiver's previous reply. A SET leaves no reply waiting. Battery percentage appears in receiver status reply byte 1. This unit's receiver was not probed; use the cable. |

## `hidapi` framing

The protocol payload is 64 bytes. `hidapi` needs a **65-byte buffer**: byte 0
is the report ID `0x00`, bytes 1..64 are the payload. The opcode is payload
byte 0 (buffer byte 1). `send_feature_report()` returns 65 on this unit;
`get_feature_report(0, 65)` returns 65 bytes (report ID then 64 data bytes).
On Linux, pass the same leading report-ID byte to the `HIDIOCSFEATURE` /
`HIDIOCGFEATURE` ioctls (65-byte buffer). The kernel's returned length and
report-ID convention can differ between hidraw devices; normalize the reply
before decoding. The macOS behavior above is what was verified on this unit.

These helpers use only `hidapi` and build Bit7 requests (see
[Checksums](#checksums)):

```python
import hid

PAYLOAD_LEN = 64
BUF_LEN = PAYLOAD_LEN + 1          # report ID + payload

def build(opcode: int, *args: int, checksum_at: int = 7) -> bytes:
    """64-byte payload; Bit7 by default, checksum_at=8 for the two LED SETs."""
    p = bytearray(PAYLOAD_LEN)
    p[0] = opcode
    for i, value in enumerate(args, 1):
        p[i] = value
    span = checksum_at             # Bit7 covers 0..6, Bit8 covers 0..7
    p[checksum_at] = (0xFF - (sum(p[:span]) & 0xFF)) & 0xFF
    return bytes(p)

def write_report(dev: hid.device, payload: bytes) -> int:
    if len(payload) != PAYLOAD_LEN:
        raise ValueError("payload must be 64 bytes")
    return dev.send_feature_report(b"\x00" + payload)   # 65 on this unit

def read_report(dev: hid.device) -> bytes:
    buf = dev.get_feature_report(0, BUF_LEN)            # 65 bytes
    if len(buf) != BUF_LEN or buf[0] != 0:
        raise RuntimeError(f"bad feature report: {len(buf)} bytes, id {buf[0]:#x}")
    return bytes(buf[1:])
```

Linux `hidraw` equivalent, if you bypass `hidapi`. The ioctl number encodes
the buffer length (65). Supply the node path discovered for VID `0x3151` /
PID `0x4015` (for example from the udev rule below); do not assume a fixed
`hidrawN` number:

```python
import fcntl

HIDIOCSFEATURE_65 = 0xC0414806   # _IOC(WRITE|READ, 'H', 0x06, 65)
HIDIOCGFEATURE_65 = 0xC0414807   # _IOC(WRITE|READ, 'H', 0x07, 65)

def hidraw_get(path: str, payload: bytes) -> bytes:
    buf = bytearray(65)
    buf[0] = 0x00                 # report ID
    buf[1:1 + len(payload)] = payload
    with open(path, "r+b", buffering=0) as fd:
        fcntl.ioctl(fd, HIDIOCSFEATURE_65, buf)
        fcntl.ioctl(fd, HIDIOCGFEATURE_65, buf)
    # hidraw includes the report ID for numbered reports; for report ID 0 some
    # backends return only the 64-byte payload. Normalize both shapes.
    if buf[0] == 0x00 and buf[1] == payload[0]:
        return bytes(buf[1:])     # report ID + 64-byte payload
    return bytes(buf[:64])        # payload only

reply = hidraw_get(node_path, build(0x8F))
```

## Enumeration

Match on device properties. Never hard-code `path`: on macOS it is a
per-boot `DevSrvsID:...` value. VID alone is not enough — many boards share
`3151:4015` — and usage `0xFFFF:1` on interface 1 is not the right entry.

```python
import hid

VID, PID = 0x3151, 0x4015
USAGE_PAGE, USAGE, INTERFACE = 0xFFFF, 0x0002, 2

def open_keyboard():
    for dev_info in hid.enumerate(VID, PID):
        if (dev_info["usage_page"] == USAGE_PAGE
                and dev_info["usage"] == USAGE
                and dev_info["interface_number"] == INTERFACE):
            dev = hid.device()
            dev.open_path(dev_info["path"])     # dynamic; do not persist it
            return dev
    raise RuntimeError("MK750 vendor feature interface not found")

dev = open_keyboard()
```

The `hid.enumerate()` entry you want looks like
`{'path': b'DevSrvsID:4294971932', 'usage_page': 65535, 'usage': 2,
'interface_number': 2, ...}`; the numeric 65535 is `0xFFFF`. Re-run
enumeration on every launch and after any re-enumeration.

## Platform notes

- **macOS.** `hidapi` enumerates the interfaces through IOKit; entries for the
  same USB interface can share a `path`, and paths change across boots and
  re-enumeration. Match on VID/PID + usage page + usage + interface number,
  never on a cached `DevSrvsID`. If opening the device fails with a permission
  error, grant the invoking terminal or interpreter Input Monitoring in
  System Settings → Privacy & Security and restart it. No kernel extension or
  vendor driver is needed for feature reports.
- **Linux.** `hidapi` uses `hidraw` for feature reports; the node
  (`/dev/hidrawN`) is owned by root by default. Add a udev rule for a
  non-root user, then replug or run `udevadm trigger`:

  ```text
  SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3151", ATTRS{idProduct}=="4015", GROUP="plugdev", MODE="0660"
  ```

  Add your user to `plugdev` if necessary. The 65-byte buffer shape is the
  same as in the ioctl example above.

- **Windows.** `hidapi` calls the OS HID API (`HidD_SetFeature` /
  `HidD_GetFeature`) through `hid.dll`. No vendor kernel driver is required to
  use the 64-byte feature reports; a vendor driver is only relevant to the
  vendor's own application. Enumerate and filter the same four properties. A
  permission/opens failure is a host configuration problem, not a protocol
  failure.

## Transaction pattern

| Rule                  | Detail                                                                                                                          |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| SET has no reply      | A write is fire-and-forget. Do not wait for a response to a SET.                                                                |
| GET echoes the opcode | Reply byte 0 equals the request opcode. Bulk page reads (`0x89`, `0x90`, `0x8B`, etc.) return raw 64-byte pages with no echo.   |
| Unsupported command   | Replays the previous reply, not an error. Compare with the immediately preceding response, not with zero.                       |
| GET twice after a SET | The first GET can return the reply to an older GET. Send the GET twice and use the second reply.                                |
| Settle                | Allow 100–300 ms between a SET and the following GET. The reference uses about 100 ms; the probes on this unit used 250–300 ms. |
| Reply checksum        | Do not validate a reply by its checksum byte. The reply's byte 8 is `0x00` on this firmware.                                    |

## Checksums

```text
Bit7: checksum = 0xFF - (sum(bytes[0:7]) & 0xFF)   stored at byte 7
Bit8: checksum = 0xFF - (sum(bytes[0:8]) & 0xFF)   stored at byte 8
```

| Mode | Covers             | Stored at | Used by                                                                                                                                                                                         |
| ---- | ------------------ | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bit7 | payload bytes 0..6 | byte 7    | all app-mode requests except the two below; bulk flash writes (`0x09`, `0x10`, `0x0C`, `0x16`) use Bit7 for their command packets, while the 56-byte data pages carry no checksum _(reference)_ |
| Bit8 | payload bytes 0..7 | byte 8    | `SET_LEDPARAM` (`0x07`) and `SET_SLEDPARAM` (`0x08`) only                                                                                                                                       |
| none | —                  | —         | USB boot data path and OLED/TFT data reports _(reference)_                                                                                                                                      |

Worked Bit7 examples from the captured requests (all other payload bytes are
zero):

```text
identify  8f 00 00 00 00 00 00 70
          sum(bytes 0..6) = 0x8f       -> 0xFF - 0x8f = 0x70
revision  80 00 00 00 00 00 00 7f
          sum(bytes 0..6) = 0x80       -> 0xFF - 0x80 = 0x7f
LED GET   87 00 00 00 00 00 00 78
          sum(bytes 0..6) = 0x87       -> 0xFF - 0x87 = 0x78
```

Worked Bit8 examples from the captured writes. Byte 8 is the checksum slot;
each value is `0xFF - (sum(bytes 0..7) & 0xFF)`:

```text
SET LEDPARAM red      07 01 00 04 07 ff 00 00 ed   sum = 0x112 -> ck8 = 0xED
SET LEDPARAM blue     07 01 00 04 07 00 00 ff ed   sum = 0x112 -> ck8 = 0xED
SET LEDPARAM restore  07 05 02 04 07 ff 45 6e 34   sum = 0x1CB -> ck8 = 0x34
SET SLEDPARAM red     08 01 00 04 07 ff 00 00 ec   sum = 0x113 -> ck8 = 0xEC
SET SLEDPARAM restore 08 01 03 04 08 ff ff ff ea   sum = 0x315 -> ck8 = 0xEA
```

On this unit, lighting GETs (`0x87`, `0x88`) returned the current state with
either checksum position. Use the standard split anyway: Bit7 for every GET,
Bit8 only for the two lighting SETs. _(reference for the split; the tolerance
on GETs was measured on this unit.)_

## Worked example: identify, revision, LED GET, restore

Self-contained script (`pip install hidapi`, no hard-coded path):

```python
import time
import hid

def open_keyboard():
    for d in hid.enumerate(0x3151, 0x4015):
        if (d["usage_page"] == 0xFFFF and d["usage"] == 2
                and d["interface_number"] == 2):
            dev = hid.device()
            dev.open_path(d["path"])
            return dev
    raise RuntimeError("MK750 vendor feature interface not found")

def frame(opcode, *args, ck=7):
    p = bytearray(64)
    p[0] = opcode
    for i, value in enumerate(args, 1):
        p[i] = value
    p[ck] = (0xFF - (sum(p[:ck]) & 0xFF)) & 0xFF
    return bytes(p)

def send(dev, payload):
    dev.send_feature_report(b"\x00" + payload)

def recv(dev):
    buf = dev.get_feature_report(0, 65)
    if len(buf) != 65 or buf[0] != 0:
        raise RuntimeError("bad feature report")
    return bytes(buf[1:])

def get(dev, opcode, *args):
    """GET twice after any SET; use the second reply."""
    for _ in range(2):
        send(dev, frame(opcode, *args))
        time.sleep(0.28)                 # 100-300 ms settle
        reply = recv(dev)
    if reply[0] != opcode:
        raise RuntimeError(f"echo mismatch: {reply[0]:#04x} != {opcode:#04x}")
    return reply

dev = open_keyboard()

ident = get(dev, 0x8F)
board_id = int.from_bytes(ident[1:5], "little")
rev = get(dev, 0x80)
revision = (rev[2] << 8) | rev[1]
led = get(dev, 0x87)
print(f"board {board_id} (0x{board_id:08x}), "
      f"revision {revision >> 8}.{revision & 0xFF:02x}")
print("LED state:", " ".join(f"{b:02x}" for b in led[:9]))

# Restore exactly the LED state that was read:
# [op, mode, speed, brightness, flags, R, G, B, ck8]
send(dev, frame(0x07, *led[1:8], ck=8))
time.sleep(0.28)
verify = get(dev, 0x87)
if verify[1:8] != led[1:8]:
    raise RuntimeError("LED restore did not read back")
```

Transcript from the verified session. The leading `00` is the `hidapi` report
ID; the 64 bytes after it are the payload:

```text
identify request   00 8f 00 00 00 00 00 00 70
identify reply     00 8f 51 03 00 00 00 00 70     board 0x351 = 849
revision request   00 80 00 00 00 00 00 00 7f
revision reply     00 80 07 01 00 00 00 00 7f     (0x0107) = 1.07
LED GET request    00 87 00 00 00 00 00 00 78
LED GET reply      00 87 05 02 04 07 ff 45 6e 00 mode 5, speed 2, brightness 4,
                                                  flags 7, RGB FF456E
restore SET        00 07 05 02 04 07 ff 45 6e 34 byte 8 is the Bit8 checksum
                                                  slot
verify GET         00 87 05 02 04 07 ff 45 6e 00 state restored
```

Other captured writes, restored afterwards on this unit, for comparison:

```text
SET LEDPARAM red     07 01 00 04 07 ff 00 00 ed    GET after: 87 01 00 04 07 ff 00 00 00
SET LEDPARAM blue    07 01 00 04 07 00 00 ff ed    GET after: 87 01 00 04 07 00 00 ff 00
SET SLEDPARAM red    08 01 00 04 07 ff 00 00 ec    GET after: 88 01 00 04 07 ff 00 00 00
SET SLEDPARAM restore 08 01 03 04 08 ff ff ff ea   GET after: 88 01 03 04 08 ff ff ff 00
```

## Error handling

| Symptom                                                                               | Likely cause                                                                                                                                            | Action                                                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `read error`, short read, or wrong first byte                                         | 64-byte buffer passed where 65 is required, missing leading `0x00`, or wrong report ID                                                                  | Check the framing first: `send_feature_report(b"\x00" + payload)` and `get_feature_report(0, 65)`. Validate length 65 and `buf[0] == 0` before using the reply.                                                                 |
| Stalled control endpoint: every report fails, e.g. `ioctl (SFEATURE): Protocol error` | Too-fast flash-bound writes, notably per-key colour uploads _(reference; pacing verified on this unit)_                                                 | Slow down: 2 uploads / 10 s, pages 100 ms apart, 2 s settle. Reopening alone will not recover a stalled endpoint; the device needs USB re-enumeration.                                                                          |
| Stale reply (GET returns the previous opcode or previous data)                        | SET produced no reply; unsupported command replayed the previous reply; `0x8C` USERPIC GET returns stable stale data                                    | Send GET twice and use the second reply. Compare with the preceding response, not with zero. Check the opcode echo, except on raw page reads.                                                                                   |
| All-`FF` answer to `0x8A`                                                             | Expected yc500 behaviour on this unit, not a device failure                                                                                             | Treat as the family signal; use `0x89`/`0x90` for keymap reads. Do not retry with gen2 commands.                                                                                                                                |
| Device busy / dropped packet                                                          | Receiver relay not selected or too soon after a write _(reference; not tested on this unit)_; display link busy bit drops frames silently _(reference)_ | Over the receiver, poll `0xF7` for `[5] == 1`, select with `0xF6 10`, send, poll `0xF7` for `[0] == 1`, release with `0xFC`, then GET. Space packets at least 70 ms; budget about 100 ms for a reply. Treat silence as failure. |

Retry policy: settle 100–300 ms between attempts; retry a failed read up to
three times with linear backoff (about 100 ms, 200 ms, 300 ms); re-enumerate
and re-match the device once between retry batches; stop and report after a
second failed batch rather than hammering the endpoint. Validate using the
opcode echo and the immediately preceding reply, never the reply's byte 8.
Before any write, read and save the affected state so a failed or partial
exchange can be restored.

## Sources

- Recon brief (source of truth for this unit): `docs/data/recon-findings.md`
- HID descriptors and enumeration sample: `docs/data/hid-descriptors.txt`
- sharkfin protocol, authoritative public reverse-engineering reference:
  https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md
- sharkfin board registry (row `腹灵 MK750 | 849 | 3151:4015 | unknown` before
  this recon): https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md
- `hidapi` Python bindings: https://pypi.org/project/hidapi/
- Linux `hidraw` and feature-report ioctls:
  https://docs.kernel.org/7.3/hid/hidraw.html
- FL Esports official software page: https://flesportsglobal.com/pages/software
