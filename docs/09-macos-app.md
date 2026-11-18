# 09 — macOS app: build, run, workflows, safety

The native macOS controller for the FL Esports MK750 (`3151:4015`, board 849,
yc500 family): a SwiftUI menu bar app with a standard control window, targeting
macOS 27+. No dependencies, no simulated keyboard, no writes at launch or
reconnect. Byte layouts live in [01-transport.md](01-transport.md) through
[08-command-reference.md](08-command-reference.md).

## Recorded status

- Core tests were observed passing (19); a read-only `--diagnose` returned board
  849, firmware 1.07 on the recon unit.
- Hardware-exercised there: identity, lighting read/write/restore, keymap/macro
  reads, settings reads. Settings, keymap, and macro **writes** and some lighting
  modes are reference-only: packet shapes implemented and read-back verified, but
  no hardware write recorded.
- Re-run the commands on your unit; these observations are not a guarantee.

## Requirements

- macOS 27+, a Swift 6.4 toolchain with SwiftPM (optionally `just`), and a **wired
  USB-C** connection. Bluetooth lacks the vendor interface; the receiver path
  is untested and unsupported by this app.
- No Xcode project or dependencies; Swift 5 language mode is used because the
  IOKit C API lacks strict-concurrency annotations. Targets: `MK750Kit` (protocol,
  IOKit transport, `Keyboard` actor), `MK750` (SwiftUI app), `MK750KitTests`.

## Build, check, bundle, run

```sh
just build      # swift build
just check      # build + test
just bundle     # ./scripts/bundle.sh
just run        # bundle, then open dist/MK750.app
just diagnose   # swift run MK750 --diagnose
```

`scripts/bundle.sh` builds the release product, asks SwiftPM for the binary path,
rewrites only `dist/MK750.app/Contents`, then ad-hoc signs and verifies it. That
is enough for local use, not distribution; rebuilding invalidates prior privacy
grants. Open the `.app` (as `just run` does), not the raw executable:
`LSUIElement` and menu bar presentation come from `Resources/Info.plist`.

## Diagnose mode

`just diagnose` performs the read-only identity/family handshake, prints the
`DeviceSnapshot` JSON (`boardID`, `firmware`, profile, lights, timers, options,
diagnostics), disconnects, and exits. It sends no SET reports and opens no window;
it exits nonzero when no keyboard/vendor interface is available or gates fail. Do
not run it during a write.

## Window and navigation

The control window has a native, collapsible sidebar: **Lighting**, **Keymap**,
**Macros**, and **Device** (`⌘1`–`⌘4`). The sidebar shows the wired connection
state. `⌘R` reads the keyboard again or attempts a connection when offline.
The MK750 menu offers the same navigation without the sidebar.

With the window open, MK750 has normal Mac menus and a Dock icon. Closing the
window leaves quick controls in the menu bar. There you can adjust backlight
brightness directly, choose a scene, start or finish focus, or reopen the window.
Without a keyboard the panel offers connection help instead of disabled sliders.

## Lighting and scenes

Scenes come first: four built-ins plus saved custom scenes, each storing both
channel states and applying with a read-back. Save via a small name sheet; delete
with confirmation.

Backlight and Side Light controls are live. Change a colour, mode, brightness
or speed and the app writes the settled value, then reads it back. The menu bar
brightness slider and the window share the same state. Advanced controls expose
the flag and option bytes and preserve unknown current values.
Host-data modes such as USERPIC are not offered; unverified effects are labelled
reference-only.

The focus timer saves both light states, applies calm lighting once, tracks a
wall-clock deadline, and restores on finish or quit. Failed restores and sessions
recovered after relaunch require explicit Restore; reconnect never changes lighting.

## Keymap

Read one of the four profiles to see its base and Fn bindings. Search by slot,
key name, or bytes, or filter by binding type to find macros or unassigned keys.

- Default columns are **Slot**, **Base**, and **Fn**. Turn on **Bytes** to see
  matrix positions and the raw binding bytes.
- Slots follow the scan matrix; physical placement is not published.
- Profiles 0/1 are writable; 2/3 are read-only here. The table always describes the
  loaded profile, so changing the read picker cannot mislabel data.
- Select a slot to inspect both layers, then choose which binding to edit:
  keyboard usage, consumer usage, macro, special action, transparent, or raw bytes. Writes name
  profile/layer/slot/result, back up both layers, and verify the layer.
- Import/export uses validated JSON with device identity, profile, and both full
  layers. Import rejects wrong lengths, invalid profiles, and board mismatches.

## Macros

Read slots 0–49 to load 256 bytes. **Steps** shows repeat count and compact key,
mouse-button, and mouse-move rows (press/release, delay, dx/dy); **Raw** shows the
hex blob. Unmodelled formats stay raw and are reported until overwritten.

The editor shows the write budget before saving. Only bytes 0–223 are
writable: a 256-byte input is saved after backing up the current macro, then all
256 read-back bytes are verified. Nonzero data in bytes 224–255 that differs from
the read-back refuses the save instead of inventing a page; a zero-only tail
preserves the existing unwritable bytes.

Unsaved macro work stays in the window when you switch sidebar sections.
Choosing a different slot or rereading the slot asks before discarding changes.
Only Save Macro writes the complete draft to its source slot.

## Device

Device controls take effect when edited. Changes target the individual register
or option bit; selecting a profile reads its settings rather than copying the
previous profile's settings onto it.

- **Everyday:** active profile (0/1), debounce (1–10 ms), automatic OS detection.
- **Sleep Timers** (collapsed): four 16-bit seconds values.
- **Options:** Win lock, Mac mode, WASD swap, backlight off, side light
  off, keyboard mode; unmodelled bits preserved.
- **Advanced** (collapsed): keyboard lock, with explicit confirmation because the
  keyboard's own keys stop responding until cleared or power-cycled.
- **Diagnostics** (collapsed, read-only): Fn-matrix, power save, options byte,
  debounce read-back.
- **Backups:** back up a keymap profile, open the local folder, or reveal the latest
  file in Finder. Previously saved backups remain accessible offline.

Options are single-bit read-modify-write; changed registers are read back and
unmodelled bits, Fn-matrix, and power save verified unchanged. After a failure,
reload before retrying: some settings may already be applied.

## Safety rules

- Launch, reconnect, refresh, diagnose: read-only.
- Direct manipulation writes only after a user edit. Rapid changes to one control
  are combined. Writes run one at a time, even after you leave the screen.
- Key assignments, macros and imports are complete, explicitly targeted writes.
  Keymap and macro writes save raw state before the SET.
- Failed verification stops pending edits. Reconnect does not replay them.
- The macro limit is 224 bytes; nonzero tail data is never truncated.
- Keyboard lock has its own confirmation.
- Quit waits for in-flight work; repeated Quit stays deferred.
- Firmware, bootloader, factory-reset, calibration, and raw-command paths are not
  implemented.

## Backups and recovery data

- Backups: `~/Library/Application Support/MK750/Backups/`
- Scenes: `~/Library/Application Support/MK750/Scenes.json`
- Focus recovery: `~/Library/Application Support/MK750/FocusRecovery.json`

The app is not sandboxed, so these are literal paths. Backups are timestamped JSON
written atomically before the matching SET (`keymap-profile0-<UTC>.json`,
`settings-<UTC>.json`, `macro-slot0-<UTC>.json`). Each has `schemaVersion: 1`,
`kind`, `createdAt`, and `identity` (board, firmware, vendor/product IDs), with
lowercase hex. Keymap = both 512-byte layers; settings = raw GET replies; macro =
full 256-byte blob. Restore keymaps through validated import, not file copying.

`Scenes.json` holds custom scenes (name, ID, both states); built-ins are compiled
in. `FocusRecovery.json` holds pre-focus states, deadline, `status`
(`active`/`restorationPending`), `calmApplied`, and last failure, deleted only
after verified restore. Neither is a device backup.

## Exclusions

| Not implemented                                         | Reason                                                                         |
| ------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Per-key colour / USERPIC                                | Reference forbids general use; stale GETs prevent reliable backup/verification |
| OLED/screen content                                     | No established geometry or safe path for this board                            |
| 2.4 GHz receiver, battery                               | Untested here; wired USB is required                                           |
| Firmware update, bootloader, flash erase, factory reset | Destructive and outside a controller's scope                                   |
| Switch calibration                                      | Can zero stored tables; not evidenced here                                     |
| Report-rate changes, generic raw commands               | No verified safe path; raw commands bypass the allowlist                       |

## Accessibility and manual verification

Controls use native labels and sizes, including accessible names for icon buttons
and sliders. Check sheets with Escape, VoiceOver, and Full Keyboard Access; check
contrast and Reduce Transparency in both appearances. Only the checks in
**Recorded status** have been observed.

Software checks: run `just check`, `just bundle`, and
`codesign --verify --strict dist/MK750.app`. Open, close, and reopen the window from
the menu item; test scrolling at the minimum window size and `⌘1`–`⌘4`, `⌘R`, `⌘Q`.
Check disconnected controls, keyboard navigation, export/import sheets, and
relaunch with saved scenes or focus recovery.

Hardware (wired unit): `just diagnose` prints board 849 / firmware 1.07, no SET;
Device matches a fresh read; small main/side lighting changes read back with the
other channel unchanged; focus produces one calm write, a countdown, and an
explicit verified restore after quit/reconnect; profile 0 reads match
`data/keymap-profile0.tsv` without mislabelling; export/re-import and macro reads
preserve raw bytes; each write leaves a newer backup. Do not exercise
reference-only writes without accepting they are unverified.

## Troubleshooting

- **No keyboard:** wired USB-C, direct port, wired mode; Bluetooth cannot work.
- **HID permission:** check Input Monitoring, relaunch, re-approve after a
  rebuild; never `sudo`.
- **Seems not to launch:** it is `LSUIElement`; use the menu bar item or open once
  from Finder.
- **Protocol errors:** replug to re-enumerate; close other tools holding the interface.
- **Partial settings or missing restore:** reload and compare backups, and use the
  explicit focus Restore action. Do not enter the bootloader to "fix" configuration.

## References

Local detail: [docs index](README.md),
[`data/recon-findings.md`](data/recon-findings.md),
[04-keymap-and-macros.md](04-keymap-and-macros.md),
[07-verification.md](07-verification.md).

Apple documentation:

- SwiftUI `Window`: <https://developer.apple.com/documentation/swiftui/window>
- HIG — Sidebars: <https://developer.apple.com/design/human-interface-guidelines/sidebars>
- HIG — Toolbars: <https://developer.apple.com/design/human-interface-guidelines/toolbars>
- SwiftUI `MenuBarExtra`: <https://developer.apple.com/documentation/swiftui/menubarextra>
- SwiftUI `Table`: <https://developer.apple.com/documentation/swiftui/table>
- SwiftUI accessibility: <https://developer.apple.com/documentation/swiftui/accessibility>
- HIG — Accessibility: <https://developer.apple.com/design/human-interface-guidelines/accessibility>
- HIG — Buttons: <https://developer.apple.com/design/human-interface-guidelines/buttons>
- SwiftUI Liquid Glass: <https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views>
- `LSUIElement`: <https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement>
- Code signing: <https://developer.apple.com/documentation/security/code-signing>
