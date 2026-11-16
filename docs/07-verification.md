# MK750 verification record

This document records what was actually observed on the FL Esports MK750
(board 849, `3151:4015`, firmware 1.07, yc500 family). It separates **verified**
results from **reference-only** protocol claims. All bytes below are the 64-byte
protocol payload; when calling `hidapi`, prepend the report-ID byte `0x00` to
make a 65-byte buffer.

## Environment

| Item | Value |
|---|---|
| Host | macOS 27.3, arm64 (Apple Silicon) |
| Python | 3.15 |
| `hidapi` Python bindings | 0.15.0 |
| Connection | wired USB-C only; Bluetooth does not expose the vendor collection |
| Target interface | interface 2, vendor collection `0xFFFF:0x02`, 64-byte feature report, report ID 0 |
| Device | ROYUAN Gaming Keyboard, VID `0x3151`, PID `0x4015`, bcdDevice `0x0107` |
| Board ID | 849 (`0x00000351`) |
| Family | yc500 (verified on this unit; confirmed by identify + keymap-read behaviour) |
| Firmware | revision reply decodes to `1.07` |

The `hidapi` enum path (`DevSrvsID:...`) is dynamic. The device must be matched
on `vendor_id == 0x3151`, `product_id == 0x4015`, `usage_page == 0xFFFF`,
`usage == 2`, and `interface_number == 2`.

## Method

* Open interface 2 and use 65-byte feature reports: one leading report-ID byte
  `0x00` followed by 64 protocol bytes. `send_feature_report()` returns 65 on
  this unit; `get_feature_report(0, 65)` returns the report ID plus 64 data bytes.
* Checksums: `0xFF - (sum & 0xFF)`. **Bit7** (sum of bytes 0..6, stored at byte 7)
  for all app-mode GETs and commands except the two lighting SETs. **Bit8** (sum
  of bytes 0..7, stored at byte 8) for `SET_LEDPARAM` (`0x07`) and
  `SET_SLEDPARAM` (`0x08`).
* Settle 250–300 ms between a SET and the following GET (the reference uses
  about 100 ms; these probes used 250–300 ms).
* A SET produces no reply; the GET reply buffer is stale until a GET is issued.
  Send the GET twice after a SET and use the second reply. An unsupported
  opcode replays the previous reply rather than returning an error.
* GETs echo the opcode in byte 0. Bulk page reads (keymap, macro) return raw
  page bytes with no echo.
* Lighting GET replies carry `0x00` at byte 8 on this firmware. That byte is
  **not** a checksum and must not be used for validation.

## Verified transcript

### Identity and state reads

Requests sent (Bit7 GET packets, all remaining bytes zero):

```text
8f 00 00 00 00 00 00 70   identify
80 00 00 00 00 00 00 7f   revision
85 00 00 00 00 00 00 7a   profile GET
91 00 00 00 00 00 00 6e   debounce GET
92 00 00 00 00 00 00 6d   sleep GET
86 00 00 00 00 00 00 79   options GET
97 00 00 00 00 00 00 68   auto-OS GET
87 00 00 00 00 00 00 78   LED GET
88 00 00 00 00 00 00 77   side GET
```

Recorded replies, verbatim from `docs/data/probe-log.txt`:

| Probe | Recorded bytes | Decoding |
|---|---|---|
| `id 8F` | `8f 51 03 00 00 00 00 70 00 00 00 00` | board ID `0x00000351` = 849 |
| `rev 80` | `80 07 01 00 00 00 00 7f 00 00 00 00` | `(reply[2]<<8)\|reply[1]` = `0x0107` = 1.07 |
| `profile 85 0` | `85 00 00 00 00 00 00 7a` | current profile 0 |
| `profile 85 1` | `85 00 00 00 00 00 00 79` | byte 1 still 0; checksum tracks the request |
| `profile 85 2` | `85 00 00 00 00 00 00 78` | byte 1 still 0; checksum tracks the request |
| `profile 85 3` | `85 00 00 00 00 00 00 77` | byte 1 still 0; checksum tracks the request |
| `debounce 91` | `91 00 01 00 00 00 00 6e` | debounce = 1 ms (range 1..10) |
| `sleep 92` | `92 78 00 78 00 58 02 58 02 00 00 00 00 00 00 00` | four u16 LE: 120, 120, 600, 600 s (BT sleep, 2.4G sleep, deep BT, deep 2.4G) |
| `options 86` | `86 00 02 02 00 00 00 79` | byte 2 = `0x02` (Mac mode), byte 3 = `0x02`, byte 4 = 0 |
| `auto-os 97` | `97 01 00 00 00 00 00 68` | auto-OS enabled |
| `led 87 ck7` | `87 05 02 04 07 ff 45 6e 00 00` | mode 5, speed 2, brightness 4, flags 7, RGB `FF456E` |
| `led 87 ck8` | `87 05 02 04 07 ff 45 6e 00 00` | same state; both checksum positions accepted on GET |
| `side 88 ck7` | `88 01 03 04 08 ff ff ff 00 00` | mode 1, speed 3, brightness 4, flags 8, RGB `FFFFFF` |

The profile GET has no per-index query; byte 1 of the reply is the active
profile (0) on every read. Four profile slots are readable, but only profiles 0
and 1 hold valid Fn layers (see Keymap verification).

Family detection was confirmed by behaviour, not by PID: `8F` returned a valid
identify reply; the yc500 keymap read `89 [profile, page]` returned slot data
beginning `00 00 29 00 00 00 35 00 ...`; the gen2 keymap read `8A` returned all
`FF`. Conclusion: yc500. Gen2 keymap writes and gen2 settings opcodes were
therefore not used.

### Lighting write verification (restored)

These writes were performed and read back, then the original state was
restored. Bit8 checksums on the SET packets; the reply's byte 8 is `0x00`
throughout and is not a checksum.

```text
SET LEDPARAM red     : 07 01 00 04 07 ff 00 00 ed
  GET after          : 87 01 00 04 07 ff 00 00 00
SET LEDPARAM blue    : 07 01 00 04 07 00 00 ff ed
  GET after          : 87 01 00 04 07 00 00 ff 00
SET LEDPARAM restore : 07 05 02 04 07 ff 45 6e 34
  GET after          : 87 05 02 04 07 ff 45 6e 00
SET SLEDPARAM red    : 08 01 00 04 07 ff 00 00 ec
  GET after          : 88 01 00 04 07 ff 00 00 00
SET SLEDPARAM restore: 08 01 03 04 08 ff ff ff ea
  GET after          : 88 01 03 04 08 ff ff ff 00
```

`docs/data/probe-log.txt` contains the checksum-discrimination test (LED state
read with both Bit7 and Bit8 GET forms, which returned the same state) and the
side-light write/restore. The excerpt below shows the significant leading bytes;
the remainder are zero. A SET has no reply, so the line printed while a SET was
issued is the preceding GET's reply — the next `read` line shows the new state.

```text
## checksum discrimination: set red (ck8), read with ck7 and ck8
set red      : 88 01 03 04 08 ff ff ff 00 00 00 ... (64 bytes)
read ck7     : 87 01 00 04 07 ff 00 00 00 00
read ck8     : 87 01 00 04 07 ff 00 00 00 00
restore      : 87 01 00 04 07 ff 00 00 00 00 00 ... (64 bytes)
read ck7     : 87 05 02 04 07 ff 45 6e 00 00
## side light write/restore
side before  : 88 01 03 04 08 ff ff ff 00 00
set side red : 88 01 03 04 08 ff ff ff 00 00 00 ... (64 bytes)
read         : 88 01 00 04 07 ff 00 00 00 00
restore side : 88 01 00 04 07 ff 00 00 00 00 00 ... (64 bytes)
read         : 88 01 03 04 08 ff ff ff 00 00
```

Interpretation: a fixed colour with flags `7` plus an RGB triple behaved as a
custom colour on this unit, and flags `8` on the side light is the factory
state. The reverse was not tested and is not claimed.

## Keymap verification

Reads only. Base layer with `0x89 [profile, page]`, Fn layer with
`0x90 [profile, page]`, for profiles 0..3 and pages 0..7 — that is 4 profiles ×
8 pages × 2 layers = 64 raw 64-byte page reads. Pages carry no opcode echo.
Slot `n` lives at byte `(n % 16) * 4` of page `n // 16`. Raw dumps are in
`docs/data/keymaps-raw.json`.

| Observation | Result |
|---|---|
| Base layers, all 4 profiles | identical |
| Profiles 0 and 1 | base and Fn layers identical |
| Profile 2 Fn layer | all `FF` (erased) |
| Profile 3 Fn layer | random-looking uninitialized flash |
| Usable profiles | 0 and 1 only; profiles 2/3 were not written |
| Base layer | 86 populated slots: 82 keyboard usages, 3 consumer keys, 1 Fn key |
| Slot encoding | byte 0 = type; HID usage `0x00`, mouse `0x01`, consumer `0x03`, macro `0x09`, special `0x0A`, extended Fn `0x0D`, wireless channel `0x0E` |

The Fn layer carries F1/F2 = brightness up/down, F7–F12 = media keys,
Fn+1/2/3 = Bluetooth channels, Fn+4 = 2.4 GHz, and extended actions on
Fn+arrows. Slot-to-physical-key mapping is board-specific and not published; no
physical layout table is derived here. Extended Fn codes `0x0D` and `0x0E` were
observed but their sub-fields remain undecoded and are labelled raw in the
decode files.

Full per-slot decode: `docs/data/keymap-profile0.tsv` and
`docs/data/keymap-profile0.json`.

## Verified vs reference-only

| Capability | Status | Basis |
|---|---|---|
| Identify, revision, family detection | Verified | `8F`/`80` replies; `89` vs `8A` behaviour |
| Profile, debounce, sleep, options, auto-OS GET | Verified | `85`/`91`/`92`/`86`/`97` replies |
| LED and side-light state GET | Verified | `87`/`88` replies |
| LED and side-light SET, with restore | Verified | `07`/`08` writes read back and returned to original values |
| Keymap base + Fn page reads | Verified | 4 profiles × 8 pages × 2 layers |
| Macro GET (slot 0, page 0) | Verified | `8B` reply is a raw page (brief's verified-exchange set) |
| Keymap writes (single slot or bulk) | **Not run** — reference-only | PROTOCOL.md Keymap |
| Macro writes (`0x16`) | **Not run** — reference-only | PROTOCOL.md Macros |
| Per-key colour / USERPIC upload (`0x0C`) | **Not run** — reference-only | PROTOCOL.md Per-key colour |
| Screen / OLED frame upload | **Not run** — reference-only | PROTOCOL.md Screens |
| Factory reset (`0x02`) | **Not sent** — reference-only | destructive opcode |
| Bootloader entry (`0x7F 55 AA 55 AA`) | **Not sent** — reference-only | destructive opcode |
| Flash erase (`0xAC` / `0x2C`) | **Not sent** — reference-only | destructive opcode |
| 2.4 GHz receiver | **Not tested** | no receiver present |
| Battery | **Not tested** — reference-only | no command on the keyboard's own collection |
| Bluetooth vendor channel | **Unavailable** | Bluetooth does not expose `0xFFFF:2` |

## Side effects

* Every lighting value that was written was read back and restored. The unit was
  returned to its original main-light state (`87 05 02 04 07 ff 45 6e`, mode 5,
  speed 2, brightness 4, flags 7, RGB `FF456E`) and original side-light state
  (`88 01 03 04 08 ff ff ff`, mode 1, speed 3, brightness 4, flags 8, RGB
  `FFFFFF`). Final reads confirmed both.
* No flash writes were made: no keymap, macro, or per-key colour upload; no
  factory reset, display boot, flash erase, or bootloader entry.
* All other operations were reads and left device state unchanged. The active
  profile remained 0.

## Limitations

* One unit only (board 849), one firmware revision (1.07), one OS (macOS 27.3
  arm64). Behaviour on other boards, firmware versions, or hosts is not
  established here.
* No 2.4 GHz receiver was available; receiver opcodes and relayed exchanges
  were not exercised.
* Bluetooth exposes no `0xFFFF:2` vendor collection, so there was no Bluetooth
  vendor channel to test.
* No physical slot-to-key mapping was derived. The protocol gives matrix order,
  not the board's scan-matrix wiring.
* Extended Fn codes `0x0D` and `0x0E` were observed in the Fn layer but their
  sub-fields remain undecoded; they are recorded as raw values.
* Profile 3's Fn layer is uninitialized flash; its contents are not a valid
  configuration and must not be treated as one.

## Reproduction checklist

Read-only procedure. Every command below is a GET. Do not send any SET opcode
unless deliberately restoring the lighting state you changed, and never send a
destructive opcode.

1. Set up Python and confirm the bindings:

   ```bash
   python3 -m pip install hidapi==0.15.0
   python3 -c "import hid; print(hid.__file__)"
   ```

2. Connect the keyboard by USB-C. Confirm it enumerates as `3151:4015` with a
   `0xFFFF:0x02` collection on interface 2 (for example with `hid.enumerate()`
   as below, or a system USB/HID descriptor tool).

3. Run the read-only probe:

   ```python
   import time
   import hid

   VID, PID = 0x3151, 0x4015

   def find_keyboard():
       for d in hid.enumerate():
           if (d["vendor_id"] == VID
                   and d["product_id"] == PID
                   and d["usage_page"] == 0xFFFF
                   and d["usage"] == 2
                   and d["interface_number"] == 2):
               return d
       raise SystemExit("MK750 vendor interface (0xFFFF:2) not found")

   info = find_keyboard()
   dev = hid.device()
   dev.open_path(info["path"])

   def build(opcode, data=(), checksum_at=7):
       """Bit7 when checksum_at==7, Bit8 when checksum_at==8."""
       p = bytearray(64)
       p[0] = opcode
       for i, b in enumerate(data, start=1):
           p[i] = b
       span = checksum_at
       p[checksum_at] = (0xFF - (sum(p[:span]) & 0xFF)) & 0xFF
       return bytes(p)

   def query(opcode, data=(), checksum_at=7, settle=0.28):
       """Read-only GET: send request, settle, return 64-byte payload."""
       dev.send_feature_report(b"\x00" + build(opcode, data, checksum_at))
       time.sleep(settle)
       return bytes(dev.get_feature_report(0, 65)[1:])

   def query_after_set(opcode, data=(), checksum_at=7, settle=0.28):
       """Use only after a SET: read twice, return the second reply."""
       dev.send_feature_report(b"\x00" + build(opcode, data, checksum_at))
       time.sleep(settle)
       dev.get_feature_report(0, 65)          # stale; discard
       time.sleep(0.05)
       return bytes(dev.get_feature_report(0, 65)[1:])

   # --- state reads (no writes) ---
   for name, opcode in [
       ("identity", 0x8F), ("revision", 0x80), ("profile", 0x85),
       ("debounce", 0x91), ("sleep", 0x92), ("options", 0x86),
       ("auto-os", 0x97), ("led", 0x87), ("side", 0x88),
   ]:
       print(f"{name:9s}", query(opcode).hex(" "))

   # --- keymap reads: 4 profiles x 8 pages, base and Fn (no writes) ---
   for profile in range(4):
       for page in range(8):
           base = query(0x89, (profile, page))   # raw page, no opcode echo
           fn = query(0x90, (profile, page))
           assert len(base) == 64 and len(fn) == 64
   print("keymap: 4 profiles x 8 pages x 2 layers read OK")

   dev.close()
   ```

   Expected first reads: identity `8f 51 03 00 00 00 00 70 ...`; revision
   `80 07 01 00 00 00 00 7f ...`; LED `87 05 02 04 07 ff 45 6e 00 00`; side
   `88 01 03 04 08 ff ff ff 00 00`. Keymap pages for profiles 0/1 should match;
   profile 2's Fn pages should be all `FF`.

4. Confirm no state changed: re-run the state reads at the end. LED and side
   values must equal the originals above, and profile must still read 0.

5. Never run, from a probe tool: `0x7F 55 AA 55 AA` (USB bootloader),
   `0x30 55 AA 55 AA` (display boot), `0xAC` / `0x2C` (flash erase), `0x02`
   (factory reset), or any keymap/macro/USERPIC write without first saving the
   affected profile. Confirm the family before any write: overlapping opcodes
   address different registers in yc500 and gen2.

## Sources

* Shared recon brief (source of truth for this unit): `docs/data/recon-findings.md`
* Raw probe transcript: `docs/data/probe-log.txt`
* Keymap data: `docs/data/keymap-profile0.tsv`, `docs/data/keymap-profile0.json`,
  `docs/data/keymaps-raw.json`
* sharkfin protocol, authoritative public reverse-engineering reference:
  https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md
* sharkfin board registry (row for board 849, `3151:4015`):
  https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md
* `hidapi` Python bindings: https://pypi.org/project/hidapi/
* FL Esports software page: https://flesportsglobal.com/pages/software
