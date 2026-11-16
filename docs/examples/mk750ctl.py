#!/usr/bin/env python3
"""Read-only diagnostics for the FL Esports MK750 keyboard.

The unit is a ROYUAN 3151:4015 (board id 849, firmware 1.07, wired USB) in
the **yc500** protocol family. Requires the ``hidapi`` Python bindings
(``python3 -m pip install hidapi``); the module imports as ``hid``.

Transport
    Every command uses the vendor feature collection on interface 2: usage
    page 0xFFFF, usage 2, one 64-byte feature report, report ID 0. hidapi
    paths on macOS are dynamic (``DevSrvsID:...``), so the device is selected
    by VID, PID, usage page, usage and interface number, never by path.
    Bluetooth does not expose this collection: use the USB-C cable.

    Each request and response is a 65-byte buffer: leading report-ID byte
    0x00 followed by 64 protocol bytes. The opcode is protocol byte 0.
    A GET reply echoes the opcode at byte 0, except bulk page reads (keymap,
    macro), which return raw 64-byte pages with no echo. An unsupported
    command replays the previous reply rather than reporting an error.

Checksums
    Bit7: checksum = 0xFF - (sum(bytes[0:7]) & 0xFF), stored at byte 7.
          Every GET in this tool uses Bit7.
    Bit8: checksum = 0xFF - (sum(bytes[0:8]) & 0xFF), stored at byte 8.
          Only the two lighting SETs (0x07, 0x08) use Bit8.

    A SET produces no reply, and a following GET can return an older reply,
    so ``get()`` sends each request twice and returns the second reply.
    Allow 100-300 ms to settle after a SET before reading it back.

Scope
    This tool only reads state, apart from the two volatile lighting SETs
    issued by ``light set`` and ``side set``. It has no reset, bootloader,
    erase, flash, keymap-write, macro-write or per-key-colour commands.
    Slot decoding follows the recon encoding table: kinds 0x00, 0x03, 0x0A,
    0x0D and 0x0E were observed on this unit; 0x01 and 0x09 come from the
    reference (reference; not tested on this unit). Physical key names are
    not published in the protocol, so keyboard usages are shown as hex.

Examples::

    python3 mk750ctl.py info
    python3 mk750ctl.py light get
    python3 mk750ctl.py light set --mode 1 --speed 0 --brightness 4 --flags 7 --color ff0000
    python3 mk750ctl.py side get
    python3 mk750ctl.py keymap --profile 0 --fn
    python3 mk750ctl.py keymap --profile 0 --fn --json
    python3 mk750ctl.py macro --slot 0 --page 0
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any, Callable, Sequence

VID = 0x3151
PID = 0x4015
USAGE_PAGE = 0xFFFF
USAGE = 2
INTERFACE_NUMBER = 2

REPORT_ID = 0x00
REPORT_LEN = 64
BUFFER_LEN = REPORT_LEN + 1
SETTLE_SECONDS = 0.25

# yc500 opcodes, verified on this unit unless noted.
OP_LED_SET = 0x07          # Bit8
OP_SIDE_SET = 0x08         # Bit8 (SLEDPARAM / edge light)
OP_PROFILE_GET = 0x85
OP_OPTIONS_GET = 0x86
OP_LED_GET = 0x87
OP_SIDE_GET = 0x88
OP_KEYMAP_GET = 0x89       # base layer, raw pages
OP_FN_GET = 0x90           # Fn layer, raw pages
OP_DEBOUNCE_GET = 0x91
OP_SLEEP_GET = 0x92
OP_AUTO_OS_GET = 0x97
OP_REVISION_GET = 0x80
OP_IDENTIFY = 0x8F
OP_MACRO_GET = 0x8B        # raw pages

PROFILE_MIN, PROFILE_MAX = 0, 3
MACRO_SLOT_MIN, MACRO_SLOT_MAX = 0, 49
MACRO_PAGE_MIN, MACRO_PAGE_MAX = 0, 3

OPTION_BITS = (
    (0x01, "win_lock"),
    (0x02, "mac_mode"),
    (0x08, "wasd_swap"),
    (0x10, "backlight_off"),
    (0x20, "side_light_off"),
    (0x40, "keyboard_mode"),
    (0x80, "keyboard_lock"),
)


def open_device() -> Any:
    """Open the MK750 vendor collection by identity, never by HID path."""
    try:
        import hid
    except ImportError as exc:
        raise RuntimeError(
            "hidapi is not installed; use: python3 -m pip install hidapi"
        ) from exc

    for entry in hid.enumerate():
        if (
            entry.get("vendor_id") == VID
            and entry.get("product_id") == PID
            and entry.get("usage_page") == USAGE_PAGE
            and entry.get("usage") == USAGE
            and entry.get("interface_number") == INTERFACE_NUMBER
        ):
            device = hid.device()
            try:
                device.open_path(entry["path"])
            except OSError as exc:
                raise RuntimeError(
                    f"could not open MK750 vendor interface: {exc}"
                ) from exc
            return device

    raise RuntimeError(
        f"MK750 vendor interface not found (VID {VID:#06x}, PID {PID:#06x}, "
        f"usage page {USAGE_PAGE:#06x}, usage {USAGE}, interface "
        f"{INTERFACE_NUMBER}). Connect the keyboard by USB-C cable; Bluetooth "
        "does not expose this collection."
    )


def frame(payload: bytes) -> bytes:
    """Prepend the report ID to a 64-byte protocol payload."""
    if len(payload) != REPORT_LEN:
        raise ValueError(f"payload must be {REPORT_LEN} bytes, got {len(payload)}")
    return bytes([REPORT_ID]) + payload


def checksum(prefix: Sequence[int], *, position: int, covered: int) -> bytes:
    """Build a zero-padded 64-byte payload with a complement checksum."""
    payload = bytearray(REPORT_LEN)
    payload[: len(prefix)] = prefix
    payload[position] = (0xFF - (sum(payload[:covered]) & 0xFF)) & 0xFF
    return bytes(payload)


def bit7(prefix: Sequence[int]) -> bytes:
    """Checksum over bytes 0..6, stored at byte 7."""
    return checksum(prefix, position=7, covered=7)


def bit8(prefix: Sequence[int]) -> bytes:
    """Checksum over bytes 0..7, stored at byte 8."""
    return checksum(prefix, position=8, covered=8)


def send_set(device: Any, payload: bytes) -> None:
    """Send a SET report; the keyboard returns no reply."""
    device.send_feature_report(frame(payload))


def get(device: Any, opcode: int, *params: int) -> bytes:
    """Send a Bit7 GET twice, discard the stale reply, return the second."""
    request = bit7([opcode, *params])
    report = b""
    for _ in range(2):
        device.send_feature_report(frame(request))
        report = device.get_feature_report(REPORT_ID, BUFFER_LEN)
    if len(report) != BUFFER_LEN:
        raise RuntimeError(f"short feature report: {len(report)} bytes")
    return bytes(report[1:])


def hexbytes(data: bytes) -> str:
    """Format bytes as lowercase, space-separated hex pairs."""
    return " ".join(f"{byte:02x}" for byte in data)


def decode_light(reply: bytes) -> dict[str, Any]:
    """Decode an 0x87/0x88 LED or side-light GET reply."""
    return {
        "mode": reply[1],
        "speed": reply[2],
        "brightness": reply[3],
        "flags": reply[4] & 0x0F,
        "option_nibble": reply[4] >> 4,
        "rgb": f"{reply[5]:02x}{reply[6]:02x}{reply[7]:02x}",
        "raw": hexbytes(reply[:9]),
    }


def print_fields(title: str, fields: dict[str, Any]) -> None:
    print(title)
    for name, value in fields.items():
        print(f"  {name:<14} {value}")


def cmd_info(device: Any) -> None:
    """Print the device identity and all readable settings."""
    ident = get(device, OP_IDENTIFY)
    board_id = int.from_bytes(ident[1:5], "little")

    revision = get(device, OP_REVISION_GET)
    word = (revision[2] << 8) | revision[1]
    version = f"{(word >> 8) & 0x0F}.{(word >> 4) & 0x0F}{word & 0x0F}"

    profile = get(device, OP_PROFILE_GET)[1]
    debounce = get(device, OP_DEBOUNCE_GET)[2]

    sleep_reply = get(device, OP_SLEEP_GET)
    timers = [
        int.from_bytes(sleep_reply[1 + 2 * i : 3 + 2 * i], "little")
        for i in range(4)
    ]

    options_reply = get(device, OP_OPTIONS_GET)
    options = options_reply[2]
    option_names = [name for bit, name in OPTION_BITS if options & bit]
    auto_os = get(device, OP_AUTO_OS_GET)[1] == 1

    print("FL Esports MK750 (yc500, wired USB)")
    print_fields("identity", {
        "board_id": f"{board_id} (0x{board_id:04x})",
        "identify": hexbytes(ident[:8]),
        "revision": f"{version} (0x{word:04x}; {hexbytes(revision[:8])})",
    })
    print_fields("settings", {
        "profile": profile,
        "debounce_ms": debounce,
        "sleep_bt_s": timers[0],
        "sleep_2_4g_s": timers[1],
        "deep_bt_s": timers[2],
        "deep_2_4g_s": timers[3],
        "options_byte2": f"0x{options:02x} ({', '.join(option_names) or 'none'})",
        "options_byte3": f"0x{options_reply[3]:02x} (Fn matrix flag)",
        "options_byte4": f"0x{options_reply[4]:02x} (power save)",
        "auto_os": "enabled" if auto_os else "disabled",
    })
    print_fields("light", decode_light(get(device, OP_LED_GET)))
    print_fields("side light", decode_light(get(device, OP_SIDE_GET)))


def cmd_light_get(device: Any, side: bool) -> None:
    opcode = OP_SIDE_GET if side else OP_LED_GET
    title = "side light" if side else "light"
    print_fields(title, decode_light(get(device, opcode)))


def cmd_light_set(device: Any, args: argparse.Namespace, side: bool) -> None:
    opcode = OP_SIDE_SET if side else OP_LED_SET
    get_opcode = OP_SIDE_GET if side else OP_LED_GET
    red, green, blue = args.color
    prefix = [opcode, args.mode, args.speed, args.brightness, args.flags,
              red, green, blue]
    send_set(device, bit8(prefix))
    time.sleep(SETTLE_SECONDS)
    title = "side light after set" if side else "light after set"
    print_fields(title, decode_light(get(device, get_opcode)))


def read_layer(device: Any, opcode: int, profile: int) -> bytes:
    """Read eight raw 64-byte pages into a 512-byte layer."""
    layer = bytearray()
    for page in range(8):
        layer += get(device, opcode, profile, page)
    return bytes(layer)


def decode_slot(raw: bytes) -> dict[str, Any]:
    """Decode one 4-byte keymap entry without inventing physical key names."""
    decoded: dict[str, Any] = {"raw": hexbytes(raw)}
    kind = raw[0]
    if raw == b"\x00\x00\x00\x00":
        decoded["kind"] = "transparent"
    elif kind == 0x00:
        decoded.update(kind="key", usage=raw[2])
    elif kind == 0x01:
        decoded.update(kind="mouse", button=raw[1])
    elif kind == 0x03:
        decoded.update(kind="consumer", usage=raw[2] | (raw[3] << 8))
    elif kind == 0x09:
        decoded.update(kind="macro", mode=raw[1], index=raw[2])
    elif kind == 0x0A:
        decoded.update(kind="special", code=raw[1])
    elif kind == 0x0D:
        decoded.update(kind="extended_fn", sub=raw[1], a=raw[2], b=raw[3])
    elif kind == 0x0E:
        decoded.update(kind="wireless", a=raw[1], b=raw[2])
    else:
        decoded["kind"] = "unknown"
    return decoded


def slot_text(slot: dict[str, Any]) -> str:
    kind = slot["kind"]
    if kind == "transparent":
        return "--"
    if kind == "key":
        return f"key:{slot['usage']:02x}"
    if kind == "mouse":
        return f"mouse:{slot['button']:02x}"
    if kind == "consumer":
        return f"cons:{slot['usage']:04x}"
    if kind == "macro":
        return f"macro:{slot['mode']}:{slot['index']}"
    if kind == "special":
        return f"special:{slot['code']}"
    if kind == "extended_fn":
        return f"ext:{slot['sub']}:{slot['a']}:{slot['b']}"
    if kind == "wireless":
        return f"wireless:{slot['a']}:{slot['b']}"
    return slot["raw"]


def cmd_keymap(device: Any, args: argparse.Namespace) -> None:
    profile = args.profile
    base = read_layer(device, OP_KEYMAP_GET, profile)
    fn = read_layer(device, OP_FN_GET, profile) if args.fn else None

    rows = []
    for slot in range(128):
        entry: dict[str, Any] = {
            "slot": slot,
            "base": decode_slot(base[slot * 4 : slot * 4 + 4]),
        }
        if fn is not None:
            entry["fn"] = decode_slot(fn[slot * 4 : slot * 4 + 4])
        rows.append(entry)

    if args.json:
        print(json.dumps({
            "device": "FL Esports MK750 (3151:4015, board 849)",
            "profile": profile,
            "layers": ["base", "fn"] if fn is not None else ["base"],
            "slots": rows,
        }, indent=2))
        return

    print(f"profile {profile}  (layers: {'base, fn' if fn is not None else 'base'})")
    header = f"{'slot':>4}  {'base':<20}"
    if fn is not None:
        header += f"  {'fn':<20}"
    print(header)
    for entry in rows:
        line = f"{entry['slot']:4d}  {slot_text(entry['base']):<20}"
        if fn is not None:
            line += f"  {slot_text(entry['fn']):<20}"
        print(line)
    print("note: all-zero Fn slots fall through to base; on base they are dead "
          "(reference; not tested on this unit).")


def cmd_macro(device: Any, args: argparse.Namespace) -> None:
    reply = get(device, OP_MACRO_GET, args.slot, args.page)
    print(f"macro slot {args.slot} page {args.page}")
    print(hexbytes(reply))


def bounded(name: str, low: int, high: int) -> Callable[[str], int]:
    """Build an argparse type accepting a decimal or 0x-prefixed integer."""
    def parse(value: str) -> int:
        try:
            number = int(value, 0) if value.lower().startswith("0x") else int(value, 10)
        except ValueError as exc:
            raise argparse.ArgumentTypeError(f"{name} must be an integer") from exc
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f"{name} must be {low}..{high}")
        return number
    return parse


def color(value: str) -> tuple[int, int, int]:
    """Parse --color RRGGBB into three byte values."""
    text = value.strip()
    if len(text) != 6:
        raise argparse.ArgumentTypeError("--color must be RRGGBB (six hex digits)")
    try:
        red, green, blue = (int(text[i : i + 2], 16) for i in (0, 2, 4))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("--color must be RRGGBB (six hex digits)") from exc
    if any(not 0 <= byte <= 255 for byte in (red, green, blue)):
        raise argparse.ArgumentTypeError("RGB components must be 0..255")
    return red, green, blue


def add_light_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--mode", required=True, type=bounded("--mode", 0, 31))
    parser.add_argument("--speed", required=True, type=bounded("--speed", 0, 5))
    parser.add_argument(
        "--brightness", required=True, type=bounded("--brightness", 0, 4)
    )
    parser.add_argument("--flags", required=True, type=bounded("--flags", 0, 15))
    parser.add_argument("--color", required=True, type=color, metavar="RRGGBB")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Read MK750 state over the yc500 vendor HID collection.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("info", help="identify, revision and all readable settings")

    light = commands.add_parser("light", help="main backlight state")
    light_actions = light.add_subparsers(dest="action", required=True)
    light_actions.add_parser("get", help="read current light state")
    add_light_args(light_actions.add_parser("set", help="set light state and read back"))

    side = commands.add_parser("side", help="side / edge light state")
    side_actions = side.add_subparsers(dest="action", required=True)
    side_actions.add_parser("get", help="read current side-light state")
    add_light_args(
        side_actions.add_parser("set", help="set side-light state and read back")
    )

    keymap = commands.add_parser("keymap", help="read the base and optional Fn layer")
    keymap.add_argument(
        "--profile", required=True, type=bounded("--profile", PROFILE_MIN, PROFILE_MAX)
    )
    keymap.add_argument("--fn", action="store_true", help="also read the Fn layer (0x90)")
    keymap.add_argument("--json", action="store_true", help="emit JSON instead of a table")

    macro = commands.add_parser("macro", help="dump one raw 64-byte macro page")
    macro.add_argument(
        "--slot", required=True,
        type=bounded("--slot", MACRO_SLOT_MIN, MACRO_SLOT_MAX),
    )
    macro.add_argument(
        "--page", required=True,
        type=bounded("--page", MACRO_PAGE_MIN, MACRO_PAGE_MAX),
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        device = open_device()
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    try:
        if args.command == "info":
            cmd_info(device)
        elif args.command == "light":
            if args.action == "get":
                cmd_light_get(device, side=False)
            else:
                cmd_light_set(device, args, side=False)
        elif args.command == "side":
            if args.action == "get":
                cmd_light_get(device, side=True)
            else:
                cmd_light_set(device, args, side=True)
        elif args.command == "keymap":
            cmd_keymap(device, args)
        elif args.command == "macro":
            cmd_macro(device, args)
    finally:
        device.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# Sources
# - Recon findings (verified on this unit): docs/data/recon-findings.md
# - ROYUAN protocol reference: https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md
# - Board registry (board 849, 3151:4015): https://github.com/dniminenn/sharkfin/blob/master/docs/BOARDS.md
# - hidapi Python bindings: https://pypi.org/project/hidapi/
