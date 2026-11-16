# Keymap and macros

This document covers reading and writing the keymap and macro banks on the FL
Esports MK750 (ROYUAN `3151:4015`, board id 849, firmware 1.07, **yc500**
protocol family, wired USB).

Verification legend:

* **Verified on this unit** — the read was executed against the connected
  keyboard during recon; results are recorded in `docs/data/recon-findings.md`
  and `docs/data/keymap-profile0.{tsv,json}`.
* **Reference-only (not tested on this unit)** — taken from the sharkfin
  protocol reference. Nothing here writes to a keyboard without a prior
  successful readback and explicit operator intent.

## Transport (needed for the examples)

All commands use the vendor feature collection on interface 2: usage page
`0xFFFF`, usage `2`, one 64-byte feature report, report ID 0. `hidapi` paths are
dynamic (`DevSrvsID:...` on macOS), so match on `vendor_id`, `product_id`,
`usage_page == 0xFFFF`, `usage == 2`, `interface_number == 2`; never hard-code a
path.

Every request is a 65-byte buffer: leading report-ID byte `0x00`, then 64
protocol bytes. `get_feature_report(0, 65)` returns report ID plus 64 data
bytes. All keymap and macro GETs use the **Bit7** checksum:
`checksum = 0xFF - (sum(bytes[0:7]) & 0xFF)`, stored at byte 7. A GET reply
echoes the opcode in byte 0, **except** bulk page reads (keymap, Fn layer,
macro), which return raw page bytes with no echo. A SET produces no reply; the
next GET may return the previous GET's reply, so send a GET twice after a SET
and use the second reply. Allow 100–300 ms settle time.

```python
import hid

def open_kb():
    for d in hid.enumerate():
        if (d["vendor_id"] == 0x3151 and d["product_id"] == 0x4015
                and d.get("usage_page") == 0xFFFF and d.get("usage") == 2
                and d.get("interface_number") == 2):
            dev = hid.device()
            dev.open_path(d["path"])
            return dev
    raise RuntimeError("MK750 vendor collection not found")

def bit7(pkt: bytearray) -> bytes:
    pkt[7] = (0xFF - (sum(pkt[0:7]) & 0xFF)) & 0xFF
    return bytes(pkt)

def get_page(dev, opcode, b1, b2):
    pkt = bit7(bytearray([opcode, b1, b2, 0, 0, 0, 0, 0]))
    dev.send_feature_report(b"\x00" + pkt)
    dev.get_feature_report(0, 65)          # discard stale reply
    return dev.get_feature_report(0, 65)[1:]  # 64 raw data bytes
```

## Reading the keymap (verified on this unit)

* Base layer: `0x89 [profile, page]` — request `89 profile page 00 00 00 00 ck`.
* Fn layer: `0x90 [profile, page]` — request `90 profile page 00 00 00 00 ck`.

Pages are `0..7`. Each reply is a raw 64-byte page (no opcode echo). A layer
holds 128 slots × 4 bytes = 512 bytes, split into eight 64-byte pages.

Slot math is exact:

```
page  = slot // 16
index = slot % 16
offset = index * 4          # 0, 4, 8, ..., 60 within the 64-byte page
slot = page * 16 + index
```

So slot `n` is stored at byte `(n % 16) * 4` of page `n // 16`. Four bytes per
slot, 16 slots per page.

```python
def read_layer(dev, opcode, profile):
    layer = bytearray(512)
    for page in range(8):
        data = get_page(dev, opcode, profile, page)
        layer[page * 64:(page + 1) * 64] = data
    return layer

def slot_value(layer, slot):
    return bytes(layer[slot * 4:slot * 4 + 4])

base = read_layer(dev, 0x89, 0)   # verified opcode on this unit
fn   = read_layer(dev, 0x90, 0)
print(slot_value(base, 0).hex(" "))  # 00 00 29 00  -> Esc
```

## Slot encoding (4 bytes, little-endian meaning)

Bytes 1..3 are the three bytes after byte 0 (the type byte). All values below
come from recon and the reference; observed values were read on this unit.

| byte 0 | Meaning | Bytes 1..3 layout | Observed / reference values |
|---|---|---|---|
| `0x00` | HID keyboard usage | `[0, usage, 0]` — usage in byte 2 | e.g. `00 00 29 00` = Esc, `00 00 35 00` = Backquote, `00 00 e1 00` = LShift (verified) |
| `0x01` | Mouse button | reference does not detail bytes 1..3 | not observed on this unit's keymap |
| `0x03` | Consumer usage | `[0, lo, hi]` — 16-bit usage little-endian in bytes 2..3 | `03 00 70 00` BrightnessUp, `03 00 e9 00` VolumeUp, `03 00 b6 00` PrevTrack (verified). Reference example: Vol+ = `[3,0,0xE9,0]` |
| `0x09` | Macro | `[mode, index, 0]` | mode `0` repeat, `1` toggle, `2` hold; `index` is the macro slot (reference; binding verified only as an encoding, not written on this unit) |
| `0x0A` | Special | `[code, 0, 0]` | `1` = Fn (verified at base slot 65: `0a 01 00 00`), `8` observed (Fn+Backspace), `12` = power save (verified at Fn slot 85), `13` observed (Fn+Esc), `17` = Caps LED Swap (reference) |
| `0x0D` | Extended Fn action | raw `[sub, a, b]` | observed `sub` 1, 2, 3, 5, 6; semantics not published — treat as raw |
| `0x0E` | Wireless channel | raw `[a, b, 0]` in bytes 1..3 | observed `a=0,b=0..2` (BT 1..3) and `a=1,b=0` (2.4 GHz) |
| all zero | Fn layer: fall through to base. Base layer: key is dead | — | reference; many Fn slots are `00 00 00 00` = Transparent (verified) |

For `0x0A` code `1` (Fn), the reference notes that overwriting a slot holding
Fn is permitted.

## Profile facts (verified on this unit)

* Active profile is `0`; profile GET (`0x85`) returns `0` in `reply[1]`.
* Profiles `0` and `1` have identical base **and** Fn layers.
* All four profiles' base layers are identical.
* Profile `2`'s Fn layer is all `FF` (erased).
* Profile `3`'s Fn layer is random-looking uninitialized flash.
* Only profiles `0` and `1` have usable Fn layers.

**Do not write profiles 2 or 3.** Their Fn storage is not a valid keymap.
Confirm the family first (yc500 here, verified via `0x8F` identify and the
`0x89` read); the same opcodes mean different registers on gen2 boards and a
misaddressed write lands on a live register.

## This unit's keymap summary (verified on this unit)

* Base layer: **86 populated slots** — 82 HID keyboard usages, three consumer
  keys (Mute, VolumeUp, VolumeDown) and one special Fn key.
* Fn F-row: F1/F2 = brightness up/down (consumer `0x70`/`0x6F`); F3/F4 =
  ACBack/ACForward; F5/F6 pass through as F5/F6; F7/F8/F9 = PrevTrack /
  PlayPause / NextTrack; F10/F11/F12 = Mute / VolumeDown / VolumeUp.
* Fn+1/2/3 (`0x0E` `a=0,b=0/1/2`) = Bluetooth channels 1–3; Fn+4
  (`0x0E` `a=1,b=0`) = 2.4 GHz.
* Fn+Z/X/C/V carry `0x0D sub=6` with `a = 0, 1, 2, 128`; Fn+Up/Down
  `0x0D sub=2`, Fn+Left/Right `0x0D sub=3`, Fn+RShift `0x0D sub=5`,
  Fn+RCtrl and Fn+Delete `0x0D sub=1`. These are raw actions; the reference
  does not publish their semantics (the likely speed/brightness meaning is
  **inferred**, not verified).
* Fn+Insert = special `12` (power save per reference); Fn+Esc = special `13`
  (observed, meaning not published); Fn+Backspace = special `8` (observed).

Compact excerpt from the full decode (columns exactly as in the TSV):

| slot | base bytes | base | fn bytes | fn |
|---:|---|---|---|---|
| 0 | `00 00 29 00` | Esc | `0a 0d 00 00` | SPECIAL(13) |
| 7 | `00 00 1e 00` | 1 | `0e 00 00 00` | FN_0E(a=0,b=0) — BT 1 |
| 12 | `00 00 3a 00` | F1 | `03 00 70 00` | BrightnessUp |
| 13 | `00 00 1f 00` | 2 | `0e 00 01 00` | FN_0E(a=0,b=1) — BT 2 |
| 19 | `00 00 20 00` | 3 | `0e 00 02 00` | FN_0E(a=0,b=2) — BT 3 |
| 25 | `00 00 21 00` | 4 | `0e 01 00 00` | FN_0E(a=1,b=0) — 2.4 GHz |
| 48 | `00 00 40 00` | F7 | `03 00 b6 00` | PrevTrack |
| 65 | `0a 01 00 00` | SPECIAL(1) — Fn | `00 00 00 00` | Transparent |
| 71 | `00 00 e4 00` | RCtrl | `0d 01 00 00` | FN_0D(sub=1,a=0,b=0) |
| 77 | `00 00 50 00` | Left | `0d 03 01 00` | FN_0D(sub=3,a=1,b=0) |
| 82 | `00 00 52 00` | Up | `0d 02 01 00` | FN_0D(sub=2,a=1,b=0) |
| 85 | `00 00 49 00` | Insert | `0a 0c 00 00` | SPECIAL(12) — power save |
| 90 | `03 00 e9 00` | VolumeUp | `00 00 00 00` | Transparent |

The complete decoded table (all slots) is in:

* `docs/data/keymap-profile0.tsv` — human-readable rows.
* `docs/data/keymap-profile0.json` — same data as JSON (`device`, `profile`,
  `source`, `slots`).

## Matrix-order caveat

Slot numbering follows the scan matrix, not a physical keyboard layout. Slot
`n` is matrix **column** `n // 6`, **row** `n % 6` (the reference uses
`slot = column * 6 + row` for its Mac-modifier transform). The mapping from a
matrix position to a physical key is board-specific and is **not published**
in the protocol.

Do not present a physical key↔slot table as fact. If a layout is derived by
reasoning about this unit's matrix, label it **inferred** and keep the raw slot
numbers alongside it. The excerpt above is a decode of read bytes; where a
friendly key name is given it is a decode of the HID/consumer usage, not a
claim about physical placement beyond the recon labels.

## Write paths (reference-only, not tested on this unit)

> Never write a keymap without first reading and saving the affected profile.
> See the backup/restore recipe below. All items in this section are
> **reference-only**; they were not executed on this unit.

Two write shapes exist on yc500:

1. **Single slot** — base `0x13`, Fn `0x15`, payload `[profile, slot, 0, 0, 0,
   0, 0, ck]` with the 4-byte value at bytes **8..11**. Bit7 checksum.
2. **Bulk layer** — base `0x09`, Fn `0x10`, payload `[profile, 0xF8, 1, page,
   0, 0, 0, ck]` followed by **56 data bytes at byte 8**. Nine pages (`0..8`),
   commit flag on page 8. The loop transfers 9 × 56 = 504 of the 512 bytes;
   slots 126–127 are never transmitted. Command packets use Bit7; the 56-byte
   data pages carry no checksum. The reference records the bulk storage layout
   (`page × 56`, commit on page 8) from firmware images, not from this unit.

The reference warns that **some yc500 images lack the single-slot writes**:
`0x13` and `0x15` fall through to a default handler that drops the packet.
After any single-slot write, read the slot back; if it does not match after
three looks, fall back to a bulk upload for that layer. This fallback is
inferred from the miss, not evidenced per board. Switch to the target profile
before writing (profile SET `0x05` on yc500) as documented in the reference.

Verify every write with a fresh paired GET (send twice, use the second reply),
comparing against the saved layer.

## Backup / restore recipe

1. Confirm the family is yc500 (`0x8F` identify, `0x89` read returns slot data).
2. For each profile you intend to touch (only `0` or `1`), read **all 8 pages**
   of the base layer (`0x89`) and all 8 pages of the Fn layer (`0x90`) using
   `read_layer()` above. This is 512 bytes per layer.
3. Save the raw bytes as JSON, together with the device identifiers and the
   opcodes used, before making any change. Keep one file per profile/layer.

```python
import json, time

def backup(dev, profile, path):
    doc = {
        "device": "FL Esports MK750 (3151:4015, board 849, yc500)",
        "profile": profile,
        "source": "raw GET 0x89 (base) / 0x90 (fn), pages 0..7",
        "base": read_layer(dev, 0x89, profile).hex(),
        "fn":   read_layer(dev, 0x90, profile).hex(),
    }
    with open(path, "w") as f:
        json.dump(doc, f, indent=1)
    return doc

def restore_bytes(path):
    doc = json.load(open(path))
    return bytes.fromhex(doc["base"]), bytes.fromhex(doc["fn"])
```

4. Write back only to the profile/layer you backed up. Prefer the single-slot
   path for isolated changes (verify each slot readback); use the bulk path for
   a whole-layer restore (all 9 pages, commit on page 8). Both write paths are
   reference-only — see the warning above.
5. Re-read all 8 pages of both layers after the write and compare byte-for-byte
   with the saved blobs. Because a SET leaves no reply and a GET can return a
   stale reply, read twice and compare the second read; insert 100–300 ms
   settle time. If any byte differs, stop and restore from the backup.

## Macros

There are 50 macro slots of 256 bytes each.

### Reading a macro (verified on this unit)

`0x8B [slot, page]`, pages `0..3`, raw 64-byte replies (no opcode echo).
Request `8b slot page 00 00 00 00 ck` (Bit7). Recon read slot 0 page 0 and got
a raw page beginning `0f 00 04 80 f2 01 ...`. Read-back is faithful per the
reference.

```python
def read_macro(dev, slot):
    blob = bytearray()
    for page in range(4):
        blob += get_page(dev, 0x8B, slot, page)
    return bytes(blob)   # 256 bytes
```

### Writing a macro (reference-only, not tested on this unit)

Write with `0x16` (yc500), Bit7, one report per 56-byte page:

| byte | meaning |
|---|---|
| 0 | opcode `0x16` |
| 1 | slot |
| 2 | page |
| 3 | `56` (payload length) |
| 4 | `1` on the final page, else `0` |
| 8.. | 56 payload bytes (zero-padded) |

The vendor sends only the prefix of pages that contain a non-zero byte. Always
read the slot back with `0x8B` after writing and confirm it matches before
considering the write successful.

### Macro blob format

* `u16` little-endian repeat count, then a strictly alternating
  event / delay stream.
* Key or mouse button event: `[code, pressed<<7 | delay]`, or
  `[code, pressed ? 0x80 : 0, delay u16 LE]` when the delay is 0 or greater
  than 127 ms.
* Mouse move: `[0xF9, delay, dx i8, dy i8]`.
* Mouse buttons: `0xF0`..`0xF4`. Key codes: HID usages `0x04`..`0xEF`.
* Four zero bytes terminate the stream.

Bind a macro to a key with the keymap slot value `[0x09, mode, index, 0]`,
where `mode` is `0` repeat, `1` toggle, `2` hold, and `index` is the macro
slot. Writing that binding is reference-only on this unit; the encoding itself
is documented in both recon and the reference.

## Verification status at a glance

| Area | Status on this unit |
|---|---|
| Keymap read `0x89` / Fn read `0x90`, slot math, page layout | Verified (all profiles/pages probed) |
| Slot encoding and observed `0x00/0x03/0x0A/0x0D/0x0E` values | Verified from read data |
| Profile 0/1 identity, 2/3 invalid Fn, all base identical | Verified |
| Full profile-0 decode (`keymap-profile0.{tsv,json}`) | Verified |
| Macro read `0x8B` | Verified (slot 0 page 0 read) |
| Keymap writes `0x13`/`0x15`, bulk `0x09`/`0x10` | Reference-only — not tested |
| Macro write `0x16` and blob authoring | Reference-only — not tested |
| Physical key ↔ slot mapping | Not published; any layout is inferred |

## Sources

* Recon findings (verified source of truth for this unit):
  `docs/data/recon-findings.md` in this repository.
* Full keymap decode: `docs/data/keymap-profile0.tsv` and
  `docs/data/keymap-profile0.json` in this repository.
* sharkfin protocol, authoritative public reverse-engineering reference:
  https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md
  (local copy read: `/tmp/sharkfin/docs/PROTOCOL.md` — Keymap, Slot values,
  Macros, Checksums, Families).
* sharkfin board registry, row `腹灵 MK750 | 849 | 3151:4015 | unknown`:
  https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md
  (local copy read: `/tmp/sharkfin/docs/BOARDS.md`).
* FL Esports official software (vendor configurator):
  https://flesportsglobal.com/pages/software
* `hidapi` Python bindings: https://pypi.org/project/hidapi/
