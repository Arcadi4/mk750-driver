# 06 — Safety and troubleshooting

This page covers the FL Esports MK750 (board 849, `3151:4015`, firmware `1.07`,
protocol family **yc500**, verified on this unit over wired USB) and the
ROYUAN-family tools that talk to it. Read [01-transport.md](01-transport.md) and
[02-handshake.md](02-handshake.md) first if you are writing a client; this page
is the gate before you send anything that changes the board.

Evidence markers follow the source documents: **[HW]** measured on hardware,
**[FW]** read from a firmware image, **[JS]** vendor host code only. Anything
marked *(reference; not tested on this unit)* comes from the public protocol
write-up or board registry and has not been exercised on this MK750. The recon
brief records what was actually verified: keymap write, macro write, per-key
colour upload, screen/OLED, reset, bootloader, the 2.4 GHz receiver and battery
are **not** verified on this unit.

## Threat model

Four ways a "harmless" packet can do damage:

1. **A misaddressed opcode lands on a live register.** The two command families
   share numeric opcodes with different meanings. yc500 `SET_KEYMATRIX` is gen2
   `SET_KBOPTION`; yc500 `SET_KBOPTION` is gen2 `SET_DEBOUNCE`; yc500
   `SET_DEBOUNCE` is gen2 `SET_SLEEPTIME` **[FW]**. A write built for the wrong
   family is not dropped — it changes a different setting on a live board. The
   same is true of profile opcodes (`0x05`/`0x85` on yc500, `0x04`/`0x84` on
   gen2) and reset (`0x02` vs `0x01`).
2. **The same VID:PID is shared across boards.** `3151:4015` is used by well over
   a hundred yc500 boards and by boards the registry still lists as `unknown`
   (for example `ABKO CJ87`, id 3227, and `akko 3098B Plus`, id 1281). The MK750
   row itself reads `腹灵 MK750 | 849 | 3151:4015 | unknown` even though this unit
   answers as yc500. A PID-based family guess is wrong for a large fraction of
   the fleet. Two unrelated HID layouts also live on `3151:4015` (for example
   the Akko 3098B at `3151:4002` has settings on the keyboard collection, not the
   vendor collection) **[HW]**, so check the report descriptor too.
3. **Shared opcode does not mean shared payload.** `USERPIC 0x0C/0x8C` has a
   different header in each family; FN `0x10/0x90` has a different shape;
   keymatrix `0x09/0x89` (yc500) versus `0x0A/0x8A` (gen2) has a different
   shape; debounce uses a different byte **[FW]**. Sending a yc500-shaped packet
   to a gen2 handler is a live write, not a parse error. The gen2 firmware
   bounds-checks neither USERPIC page nor length **[FW]**.
4. **Bluetooth and receiver paths are not the keyboard.** Bluetooth does not
   expose the `0xFFFF:2` vendor feature collection at all **[HW]**; this unit's
   Bluetooth name `MK750 BT5.0 KB1` is not a command path. The 2.4 GHz receiver
   enumerates its own collection, answers its own opcodes itself, and relays
   everything else only after an explicit select/poll sequence; not every
   receiver relays **[HW]**. This unit's receiver was not tested. Receiver
   replies do not echo the opcode, and a missed relay step returns the
   receiver's previous reply instead of the keyboard's.

## Operation classes

Keep these four classes separate in code and in your head. The class of an
opcode is a property of the write, not of the tool.

| Class | What it covers | Rule |
|---|---|---|
| **Safe reads** | Identify `0x8F`, revision `0x80`, profile GET `0x85`, LED GET `0x87`, side GET `0x88`, debounce GET `0x91`, sleep GET `0x92`, options GET `0x86`, auto-OS GET `0x97`, keymap pages `0x89`/`0x90`, macro pages `0x8B` | Read freely. `0x8C` (USERPIC GET) returns stable data that does not reflect writes: treat as write-only **[HW]**. `0x8A` on yc500 returns all `FF` **[HW]**; that is a valid answer, not a device failure. |
| **Safe settings writes (with read-back and restore)** | `SET_LEDPARAM 0x07` and `SET_SLEDPARAM 0x08` (Bit8 checksum), profile `0x05`, debounce `0x11`, sleep `0x12`, options `0x06`, auto-OS `0x17` (Bit7) | Settings only, with no flash commit flag. Read the current value first, change one field, GET twice, restore the saved value when testing. Options is a bitfield: read-modify-write so unmodelled bits survive **[FW]**. |
| **Flash writes (destructive enough to require a backup)** | Keymap base `0x09` and Fn `0x10` bulk layers, single-slot `0x13`/`0x15`, macro `0x16`, per-key colour `0x0C` | These stage or commit pages to flash. Never write without reading and saving the affected profile/layer first. Do not write profiles 2/3 on this unit: profile 2's Fn layer is erased and profile 3's is uninitialized. Do not unplug during or immediately after a write. |
| **Destructive / do not send** | `0x7F 55 AA 55 AA`, `0x30 55 AA 55 AA`, `0xAC`, `0x2C`, `0x02` (yc500 factory reset; gen2 `0x01`), `0x1C`/`0x1E`, blind `0x65`/`0xE5` writes, unknown-family writes | Refuse in any tool that is not deliberately flashing or recovering a board. See the table below. `0xAD` and `0xAE` are **GETs** of display chip versions, not erases **[FW]**; do not mistake them for `0xAC`. |

## Do-not-send table

| Packet | What it actually does | Consequence | Evidence |
|---|---|---|---|
| `7F 55 AA 55 AA` | USB bootloader entry with the required trailer **[JS] [HW]** | Erases the keymap block and the switch-settings block, then re-enumerates under a boot PID. The board stops answering app-mode opcodes. Only with a 64-byte report `7F 55 AA 55 AA` followed by zeros; without the trailer it is not the same command. | Reference; not tested on this unit. Trailer and erase are **[FW]/[HW]** elsewhere. |
| `30 55 AA 55 AA` | Display-chip boot entry, **not** USB boot **[JS]** | Puts the display chip into its own boot path; it is not a path back to the app and does not help a stuck keyboard. | Reference; not tested on this unit. |
| `AC` | Flash-chip erase in both families **[FW]** | On gen2 it erases every picture and takes about 55 seconds **[FW]**. It sets the same erase flag as `0x2C` on the images read and additionally preloads an `AA AA 55 55` reply. Nothing is recoverable over USB afterwards. | Reference; not tested on this unit. |
| `2C` | yc500 display erase; on the RT100 image it sets the same flag as `0xAC` **[FW]** | Triggers the display-chip erase/clear path (`0x25` to the chip on RT100). Same practical result as `0xAC` on the images read. | Reference; not tested on this unit. |
| `02` | Factory reset on yc500, bare opcode, about 4 s **[HW]**; gen2 uses `0x01` **[FW]** | Wipes stored settings/state. Not verified on this unit; do not use it as a "clear a problem" step. | Reference; not tested on this unit. |
| `1C`, `1E` | Magnetic sensor calibration on/off | On zeroes the stored travel tables in RAM; off saves them to flash. On-then-off **without pressing every key commits zeroed tables** — every affected switch loses its calibration. | **[FW]**; reference; not tested on this unit. |
| `65`, `E5` (magnetic-switch calibration) | `0xE5` is a column **read**; `0x65` writes one value or a 56-byte page. `last` raises the flag that saves the block to flash and re-runs apply **[FW]** | Neither handler bounds-checks: a bulk page past a column or a slot past the end writes into the neighbouring column. A family mismatch changes unrelated registers. This unit's yc500 firmware `1.07` has no `0x65`/`0xE5` (yc500 columns start at firmware 2.00 **[FW]**), so here they are dropped — but on other boards the same opcodes are live. | **[FW]**; reference; not tested on this unit. |
| Unknown-family writes | Any SET/flash opcode before family detection, and gen2 settings/keymap opcodes on this yc500 board (`0x8A`, `0x84`, gen2 keymap writes) | A live register changes: keymap, options, debounce, sleep or profile can be silently overwritten with a value decoded from the wrong layout. | **[HW]/[FW]**; collision confirmed in the reference, family of this unit verified here. |

Never send a destructive opcode as a GET probe. Do not use `0x8F`, `0x80`,
`0x89` and `0x8A` as "write" candidates either: they are reads, and `0x8A` on
yc500 answers all `FF` rather than echoing.

## Safe operating procedure

1. **Identify first.** Enumerate by properties, not by path or PID alone. On
   macOS `hidapi` paths are dynamic (`DevSrvsID:...`); match
   `vendor_id == 0x3151`, `product_id == 0x4015`,
   `usage_page == 0xFFFF`, `usage == 2`, `interface_number == 2`. Then send
   `0x8F`: this unit answers `8f 51 03 00 00 00 00 70`, board id `0x351` (849),
   and `0x80` answers `80 07 01 00 00 00 00 7f` (revision `1.07`). Use a 65-byte
   buffer: leading report ID `0x00` plus 64 protocol bytes.
2. **Detect the family from the device.** A valid `0x8F` reply (echo + 4-byte
   ID) is the first gate. The yc500 keymap read `0x89 [profile, page]` returns
   slot data (profile 0 / page 0 starts `00 00 29 00 00 00 35 00 …` here); the
   gen2 keymap read `0x8A [profile, 0xFF, page, os]` returns all `FF` on this
   unit, the documented yc500 answer. If `0x8F` does not give a valid identify
   reply, stop: do not guess yc500 or gen2 from the PID.
3. **Read before write.** Capture the current value or all eight raw pages of
   the affected layer. For settings, store the exact GET reply. For flash
   writes, store the full layer/page set, not just the slot you intend to
   change.
4. **Change one thing at a time.** One opcode, one field, one page. No batch of
   "cleanup" edits, no profile switches mixed with keymap writes. Switch to a
   profile before writing its keymap; a `SET_KEY_ONE` through the relay lands
   only when its profile byte names the active profile **[HW]**.
5. **Verify with a second GET.** A SET produces **no reply** on this unit, and
   an unsupported command replays the previous reply **[HW]**. Wait 100–300 ms,
   send the GET twice, and use the second reply. Compare against the preceding
   response rather than against zero. Do not validate by the reply's byte 8:
   it is zero on this firmware, not a checksum.
6. **Restore the original.** After a probe or test, write back the exact saved
   value/page and verify with a second GET that it matches. This unit's LED and
   side-light writes were restored this way.
7. **Keep a JSON backup.** Save identify, revision, family evidence, active
   profile, all settings GETs and every keymap/macro page you read, with raw
   hex bytes and a timestamp. Keep it outside the keyboard. There is no USB
   flash dump to fall back on.

```python
import binascii
import hid

VID, PID = 0x3151, 0x4015

dev = hid.device()
# Enumerate by properties; never hard-code dev.path (DevSrvsID:... on macOS).
for d in hid.enumerate(VID, PID):
    if (d.get("usage_page") == 0xFFFF and d.get("usage") == 2
            and d.get("interface_number") == 2):
        dev.open_path(d["path"])
        break
else:
    raise SystemExit("no vendor feature collection found")

def get(opcode: int, prefix: bytes = b"") -> bytes:
    # Bit7 checksum: 0xFF - (sum(bytes[0:7]) & 0xFF) at byte 7.
    packet = bytearray(64)
    packet[0] = opcode
    packet[1:1 + len(prefix)] = prefix
    packet[7] = 0xFF - (sum(packet[:7]) & 0xFF)
    dev.send_feature_report(bytes([0]) + bytes(packet))  # 65 bytes, report ID 0
    reply = dev.get_feature_report(0, 65)                 # ID + 64 data bytes
    return bytes(reply[1:])

ident = get(0x8F)
print(binascii.hexlify(ident[:8]).decode())  # -> 8f51030000000070 on this unit
if ident[0] != 0x8F or ident[1:5] != b"\x51\x03\x00\x00":
    raise SystemExit("unexpected identify reply: stop, do not write")

fn_probe = get(0x8A, b"\x00\xff\x00\x00")
if len(set(fn_probe)) == 1 and fn_probe[0] == 0xFF:
    family = "yc500"   # documented yc500 answer; this unit
else:
    family = "unknown" # do not send family-specific writes

if family != "yc500":
    raise SystemExit("family not established: read-only mode")

original = get(0x91)             # debounce GET, save before any test
print("debounce reply:", binascii.hexlify(original).decode())
dev.close()
```

## Flash hazards

* **Keymap, macro and per-key colour are flash writes.** Bulk keymap `0x09`
  (base) and `0x10` (Fn), single-slot `0x13`/`0x15`, macro `0x16` and
  per-key colour `0x0C` all stage and commit pages to flash **[HW]/[FW]**. On
  the images read, yc500 bulk keymap sets a commit flag on page 8 **[FW]**;
  macro pages are one 56-byte page per 64-byte report **[HW]**; USERPIC is
  seven pages with data from byte 8 **[HW]**. Some yc500 images have no
  single-slot writes and need the bulk upload path **[FW]** — a silent
  no-readback is not proof the slot was written. Magnetic-switch writes with
  `last` set also commit to flash **[FW]**.
* **Power loss risk.** The commit is deferred: a packet with the final flag
  raises a flag and a deferred routine erases/programs the block and re-applies
  it **[FW]**. Unplugging or resetting between the last packet and the commit
  can leave a partially written or unapplied block. Keep the board powered and
  idle for a settle period after the last page; never power-cycle as a
  "finish" step.
* **Per-key colour endpoint stall.** Repeated `0x0C` uploads can kill the USB
  control endpoint **[HW]**:

  | cadence | result |
  |---|---|
  | 7 reports / 500 ms | endpoint dies after ~13 reports |
  | 7 reports / 3 s | 42 reports, still responsive |
  | 2 uploads / 5 s, pages 40 ms apart, mode switch 600 ms after | stalled on the second |
  | 2 uploads / 10 s, pages 100 ms apart, 2 s settle, no redundant mode switch | survives |

  Individual reports needed about 12 ms spacing **[HW]**. The recon brief's
  rule of thumb is 2 uploads / 10 s, pages 100 ms apart, 2 s settle. A stalled
  endpoint fails **every** report with `ioctl (SFEATURE): Protocol error` and
  **does not recover on reopen** — the device needs USB re-enumeration. This
  cadence is **[HW]** on other boards and is not evidenced on gen2 or on this
  MK750; use it as an upper bound, not a guarantee.
* **No USB flash dump.** The bootloader dispatcher has no read command: chunks
  are written on arrival with an on-chip read-back compare and only pass/fail
  plus an error count leave over USB **[JS]/[FW]** (`0xC0BA` init, `0xC2BA`
  verify; replies use opcode `0xAB`). You cannot back up or recover flash by
  reading it over USB. The host's file-prefix skip is a host convention, not a
  write address; a board that can still enter boot can be written again
  **[FW]**.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| No device found | Bluetooth mode: no `0xFFFF:2` collection **[HW]**. Power-only or damaged cable, wrong port, or a receiver that does not enumerate the collection. | Use wired USB-C. Try another cable and port. Re-enumerate and match on VID/PID + usage page `0xFFFF` + usage `2` + interface `2`. If the keyboard is in boot mode it appears under a boot PID (see below). |
| Permission error on open | The process lacks access to the HID node (macOS input-monitoring permission; Linux device-node permissions). | Grant the specific permission for your OS/user, then retry enumeration. Do not treat this as a protocol failure and do not paper over it by running everything as root. |
| `read error` / `ioctl (SFEATURE): Protocol error` on every report | Stalled control endpoint, most often after too-fast `0x0C` uploads **[HW]**; also a wrong report size (use 65 bytes: ID `0x00` + 64 data bytes). | Check buffer length and report ID first. If the endpoint is truly stalled, reopening alone will not recover it: physically re-enumerate the device (see Recovery). Slow down to 2 uploads / 10 s, 100 ms between pages, 2 s settle. |
| Stale reply | A SET produced no reply, so the first GET returned an older reply **[HW]**; an unsupported command replays the previous reply **[FW]**; `0x8C` returns stable USERPIC data that ignores writes **[HW]**. | Send the GET twice and use the second reply. Compare against the immediately preceding response, not against zero. Verify per-key colour by eye (light mode 13), not with `0x8C`. |
| Device busy / dropped packet | Receiver accepts the next packet about 70 ms after a write and a reply is ready about 100 ms after the send **[HW]**; the vendor's relayed exchange polls `0xF7` five times at 100 ms **[JS]**. On gen2 display links a busy bit makes the chip drop the frame without telling the host **[FW]**. | Poll `0xF7` for `[5] == 1` before sending, select with `0xF6 10`, send, poll `0xF7` for `[0] == 1`, release with `0xFC`, then GET. Space pages and treat silence as failure, not success. Busy-bit behaviour is **[FW]** and not tested on this unit. |
| Wrong reply / unexpected value | Family mismatch (yc500 vs gen2 opcode or payload), a reply from a chip that is not fitted (firmware answers for absent parts **[FW]**), the vendor's Mac-mode setter/getter bit mismatch **[JS]**, or a profile/layer offset decoded with the wrong layout. | Re-run identify and the `0x89`/`0x8A` family probes. Decode with the yc500 layout only. Do not infer hardware presence from a reply; use the device record. Never write until this is resolved. |
| Keyboard appears under a boot PID such as `3151:4016` | The board is in the USB bootloader. Vendor PID tables are incomplete: `3151:4016` is in neither table and was seen on a K86 (1168) whose app PID is `3151:4015` **[HW]**; another vendor table adds `3151:5024` **[JS]**. | Treat app opcodes as invalid there: `0xBA` belongs on a boot PID, `0x7F` in app mode with its trailer **[FW]**. If you did not intend to flash, re-enumerate back to app mode without sending image chunks. Do not assume the boot PID is always app PID + 1. |
| Receiver present but nothing relays | The relay requires a select step; without it a keyboard packet is dropped and a keyboard GET returns the receiver's previous reply **[HW]**. Not every receiver relays **[HW]**; Bluetooth never exposes the collection. | Use the full `0xF7` → `0xF6 10` → packet → `0xF7` → `0xFC` → GET sequence. A SET leaves no reply waiting **[HW]**. If the receiver still does not relay, use the cable. This unit's receiver was not tested. |
| Worked once, then the path no longer opens | macOS `hidapi` paths are dynamic (`DevSrvsID:...`) and change across re-enumeration. | Re-enumerate every run and match on the four properties above. Never cache or hard-code `path`. |

## Recovery checklist

Work down this list in order. Stop as soon as the board answers `0x8F` with
board id 849.

1. **Re-enumerate the USB device.** Unplug and replug the keyboard (or power-cycle
   a hub) and let the OS settle. This is the only recovery for a stalled
   control endpoint; reopening the same handle does not help **[HW]**.
2. **Reopen and re-identify.** Re-run `hid.enumerate()`, match by properties,
   send `0x8F` and check the board ID and revision, then re-detect the family.
   Do not send writes until both match.
3. **Try another cable and another port.** A power-only cable or a bad port
   explains "no device" far more often than a protocol fault. Use a direct
   wired USB-C connection; do not attempt recovery over Bluetooth.
4. **Power-cycle the board.** With the cable disconnected, wait, reconnect, and
   confirm that it comes back under `3151:4015` rather than a boot PID.
5. **Reinstall vendor software only as a last resort.** Use the FL Esports
   configurator to restore factory settings, and only after you have exhausted
   the steps above and saved any readable state. It can overwrite settings you
   wanted to keep.
6. **Do not enter the bootloader unless you are flashing a known image.** A
   wrong image can leave the board unable to answer `0x7F`; no recovery without
   a running app or USB bootloader has been verified, and SWD and the ROM UART
   path are unverified **[FW]**. Flash only an image for board 849 that you
   have identified and checksummed, and never unplug during the transfer.

## Verification checklist for any new tool

Before the tool is allowed to write:

- [ ] Enumerates by `vendor_id`, `product_id`, `usage_page == 0xFFFF`,
      `usage == 2` and `interface_number == 2`; no hard-coded `hidapi` path.
- [ ] Uses a 65-byte feature-report buffer (report ID `0x00` + 64 data bytes)
      and the correct checksum position: Bit7 for all app-mode GETs and most
      SETs, Bit8 only for `SET_LEDPARAM 0x07` and `SET_SLEDPARAM 0x08`
      **[HW]**.
- [ ] Validates the `0x8F` reply (echo + 4-byte ID, board `849` here) and
      checks the `0x80` revision before choosing any command.
- [ ] Establishes the family from the device (`0x89` returns pages; `0x8A`
      returns all `FF` on yc500) and refuses to write while it is unknown.
- [ ] Blocks the entire do-not-send table, including malformed `0x7F`/
      `0x30` variants and any unknown opcode it has not classified.
- [ ] Treats SET as reply-less, sends each GET twice when verifying, and never
      uses reply byte 8 as a checksum or `0x8C` as write verification.
- [ ] Reads and saves the affected settings or all eight raw layer pages to a
      timestamped JSON backup before any write, including macro and USERPIC
      uploads.
- [ ] Changes one field at a time, read-modify-writes bitfields such as options
      `0x06`, and restores the original value after a probe.
- [ ] For flash writes, keeps the board powered through the commit and paces
      USERPIC at no more than 2 uploads / 10 s, 100 ms per page, 2 s settle.
- [ ] Reports boot PIDs (including ones outside the vendor tables, e.g.
      `3151:4016`) as a distinct state and does not send app-mode opcodes or
      image chunks there.
- [ ] Treats receiver and Bluetooth paths as untrusted: full relay sequence
      required, no collection in Bluetooth, and cable fallback available.

## Sources

* [MK750 recon findings (local, source of truth)](data/recon-findings.md)
* [sharkfin ROYUAN protocol reference](https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md)
* [sharkfin board registry, row `腹灵 MK750 | 849 | 3151:4015`](https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md)
* [`hidapi` Python bindings](https://pypi.org/project/hidapi/) (API cited by the recon brief)
