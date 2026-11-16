# FL Esports MK750 — documentation and protocol reference

This is the documentation and protocol reference for the vendor HID interface of
the FL Esports MK750 (ROYUAN `3151:4015`, board 849). It records what was
measured on one wired unit, separates that from what the public ROYUAN
reverse-engineering reference describes, and gives a Python `hidapi` quick start
so anyone with the keyboard can reproduce the safe reads and writes. Everything
here is **yc500**-family; do not apply `gen2` opcodes to this board. The shared
recon brief in [`data/recon-findings.md`](data/recon-findings.md) is the source
of truth for the verified values.

## Device identity

| Field | Value |
|---|---|
| Marketing name | FL Esports MK750 (75%, 82 keys, tri-mode) |
| Bluetooth name | `MK750 BT5.0 KB1` (not used; the vendor collection is cable-only) |
| USB VID/PID | `0x3151` / `0x4015` (`ROYUAN`, `Gaming Keyboard`) |
| Board ID | `849` (`0x00000351`), sharkfin registry row `腹灵 MK750 \| 849 \| 3151:4015 \| unknown` |
| Protocol family | `yc500` (verified on this unit; sharkfin registry says `unknown`) |
| Firmware revision | `1.07` (revision reply `0x0107`) |
| Active profile | `0` |
| Vendor feature collection | usage page `0xFFFF`, usage `2`, interface `2` |
| Report size | 64 data bytes |
| Report ID | `0` (the descriptor has no Report ID item) |
| Transport used | Wired USB-C; Bluetooth does not expose the `0xFFFF:2` collection |

## What is verified

| Area | Status | Basis |
|---|---|---|
| Device identity (board ID, family, revision) | Verified | `8F` identify → 849; `80` revision → 1.07 |
| Main LED read / write / restore | Verified | `87` GET, `07` SET, read-back and restore |
| Side light read / write / restore | Verified | `88` GET, `08` SET, read-back and restore |
| Keymap base + Fn layer read | Verified | `89` / `90`, pages 0..7 |
| Macros read | Verified | `8B` raw page read |
| Settings read (profile, debounce, sleep, options, auto-OS) | Verified | `85`, `91`, `92`, `86`, `97` |
| Keymap write | Not tested | reference-only |
| Macro write | Not tested | reference-only |
| Per-key colour (USERPIC) upload | Not tested | reference-only |
| Reset (`0x02`) | Not tested | reference-only |
| Bootloader / firmware flashing (`0x7F`) | Not tested | reference-only |
| 2.4 GHz receiver | Not tested | reference-only |
| Battery | Not tested | reference-only |

"Not tested" means the opcode is described in the public reference but no write
was sent to this unit; treat those rows as reference-only.

## Documentation map

| Document | Contents |
|---|---|
| [01-transport.md](01-transport.md) | HID descriptor, 65-byte report framing, Bit7/Bit8 checksums |
| [02-handshake.md](02-handshake.md) | Opening the device, identify, family detection, SET/GET settle rules |
| [03-lighting.md](03-lighting.md) | Main LED and side-light modes, byte layout, verified writes |
| [04-keymap-and-macros.md](04-keymap-and-macros.md) | Base/Fn page reads, slot encoding, macro reads |
| [05-settings-and-profiles.md](05-settings-and-profiles.md) | Profile, debounce, sleep, options, auto-OS |
| [06-safety-and-troubleshooting.md](06-safety-and-troubleshooting.md) | Destructive opcodes, backup discipline, failure symptoms |
| [07-verification.md](07-verification.md) | Exact probe bytes and how to reproduce them |
| [08-command-reference.md](08-command-reference.md) | Opcode table with byte layouts and evidence markers |
| [09-macos-app.md](09-macos-app.md) | Native macOS app, menu bar controls, build commands, and safety |
| [examples/mk750ctl.py](examples/mk750ctl.py) | Runnable CLI for the safe operations |

Data artifacts under [`data/`](data/):

- [`data/recon-findings.md`](data/recon-findings.md) — source of truth for verified values
- [`data/hid-descriptors.txt`](data/hid-descriptors.txt) — raw HID descriptor bytes
- [`data/probe-log.txt`](data/probe-log.txt) — probe log
- [`data/device-state.json`](data/device-state.json) — verified state and restore payloads
- [`data/keymap-profile0.tsv`](data/keymap-profile0.tsv) / [`data/keymap-profile0.json`](data/keymap-profile0.json) — decoded profile 0
- [`data/keymaps-raw.json`](data/keymaps-raw.json) — raw keymap pages
- [`data/README.md`](data/README.md) — artifact index

## Quick start

Create a virtual environment and install the bindings:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install hidapi
```

Open only the vendor feature collection. `hidapi` paths are dynamic on macOS
(`DevSrvsID:...`), so match on VID/PID, usage page `0xFFFF`, usage `2` and
interface `2`; never hard-code a path. Every exchange is a 64-byte payload
prefixed, in the `hidapi` buffer, by report ID `0x00` — 65 bytes on the wire.
`send_feature_report()` returns 65 on this unit and `get_feature_report(0, 65)`
returns the report ID followed by 64 data bytes.

Identify first: send `8f 00 00 00 00 00 00 70` and read the 65-byte reply. Its
data begins `8f 51 03 00 00 00 00 70`, i.e. board ID `0x00000351` = 849. Then
read the LED state with `87 ...`. To exercise a write safely, set solid red,
read it back, then restore the original mode 5, speed 2, brightness 4, flags 7,
RGB `FF456E`. The byte strings below are the exact verified packets from the
recon brief, checksums included; copy them rather than recomputing. A SET gets
no reply, and the first GET after a SET can return an older reply, so each
verification read is sent twice and the second reply is used.

```python
import time

import hid

VID, PID = 0x3151, 0x4015


def open_keyboard():
    for d in hid.enumerate(VID, PID):
        if (d["usage_page"] == 0xFFFF and d["usage"] == 2
                and d["interface_number"] == 2):
            dev = hid.device()
            dev.open_path(d["path"])
            return dev
    raise RuntimeError("MK750 vendor collection not found")


def send(dev, hex_payload):
    payload = bytes.fromhex(hex_payload)
    assert len(payload) == 64
    dev.send_feature_report(b"\x00" + payload)  # report ID 0 + 64 data bytes


def get(dev):
    return bytes(dev.get_feature_report(0, 65))[1:]  # strip report ID


def get_fresh(dev, request):
    send(dev, request)
    get(dev)          # may be a stale reply after a SET
    time.sleep(0.2)
    send(dev, request)
    return get(dev)   # use the reply to the second request


dev = open_keyboard()

# Identify: expect 8f 51 03 00 00 00 00 70 -> board ID 849.
send(dev, "8f 00 00 00 00 00 00 70")
print(get(dev)[:8].hex(" "))

# Read current LED state: expect 87 05 02 04 07 ff 45 6e 00.
print(get_fresh(dev, "87 00 00 00 00 00 00 78")[:9].hex(" "))

# Safe write test: solid red (mode 1, RGB FF0000), read back, then restore.
send(dev, "07 01 00 04 07 ff 00 00 ed")
print(get_fresh(dev, "87 00 00 00 00 00 00 78")[:9].hex(" "))  # 87 01 00 04 07 ff 00 00 00

send(dev, "07 05 02 04 07 ff 45 6e 34")  # mode 5, speed 2, brightness 4, flags 7, FF456E
print(get_fresh(dev, "87 00 00 00 00 00 00 78")[:9].hex(" "))  # 87 05 02 04 07 ff 45 6e 00
```

## Capability summary

- **Lighting (verified):** main LED (`07`/`87`) and side light (`08`/`88`) —
  mode, speed, brightness, flags and RGB; writes read back on this unit.
- **Keymap and Fn-layer read (verified):** `89`/`90`, eight 64-byte pages per
  profile; slot `n` at byte `(n % 16) * 4` of page `n // 16`.
- **Macros read (verified):** `8B`, 50 slots × 256 bytes, four raw pages each.
- **Profiles and settings (verified):** profile `85`/`05`, debounce `91`/`11`,
  sleep `92`/`12`, options `86`/`06`, auto-OS `97`/`17`.
- **Per-key colour and screen pointer (reference; not tested on this unit):**
  `0C` USERPIC uploads (seven pages, 384 bytes total) shown with light mode 13,
  plus the screen/OLED picture-pointer opcodes, are described in the public
  reference but were not exercised here.
- **Battery (reference; not tested on this unit):** no command on the keyboard's
  own collection; only the 2.4 GHz receiver's status reply carries it (byte 1),
  and this unit's receiver was not tested.

## Safety

> **Never send `0x7F` (USB bootloader), `0x30` (display boot), `0xAC`/`0x2C`
> (flash erase) or `0x02` (factory reset) from a tool that is not deliberately
> flashing or recovering the board.** These are live writes, and `yc500` and
> `gen2` share opcode numbers, so a misaddressed write lands on a real register.
> Read and save the affected profile before any keymap, macro or per-key-colour
> write. Per-key uploads land in flash and can stall the control endpoint if
> paced too fast — the reference recommends two uploads per 10 s, pages 100 ms
> apart and a 2 s settle. See [06-safety-and-troubleshooting.md](06-safety-and-troubleshooting.md).

## Repository layout

```text
mk750/
└── docs/
    ├── README.md                       this file
    ├── 01-transport.md
    ├── 02-handshake.md
    ├── 03-lighting.md
    ├── 04-keymap-and-macros.md
    ├── 05-settings-and-profiles.md
    ├── 06-safety-and-troubleshooting.md
    ├── 07-verification.md
    ├── 08-command-reference.md
    ├── examples/
    │   └── mk750ctl.py
    └── data/
        ├── recon-findings.md
        ├── hid-descriptors.txt
        ├── probe-log.txt
        ├── device-state.json
        ├── README.md
        ├── keymap-profile0.tsv
        ├── keymap-profile0.json
        └── keymaps-raw.json
```

## Sources

- [MK750 recon findings (shared brief)](data/recon-findings.md) — verified values used throughout
- [Raw HID descriptors](data/hid-descriptors.txt) and [probe log](data/probe-log.txt)
- [sharkfin ROYUAN protocol reference](https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md)
- [sharkfin board registry](https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md) — row `腹灵 MK750 | 849 | 3151:4015 | unknown`
- [FL Esports software page](https://flesportsglobal.com/pages/software)
- [`hidapi` Python bindings on PyPI](https://pypi.org/project/hidapi/)
