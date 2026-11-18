# ROYUAN yc500 protocol notes

This directory documents the yc500 HID feature-report protocol: packet framing, checksums, opcodes, payload layouts and operating rules. It is written for the protocol family rather than any one board — support for a given opcode, mode or field varies by device and firmware, so enumerate and verify before relying on it. gen2 boards share parts of the VID/PID space and several opcode numbers but different register layouts, so family detection must precede every write.

## Core rules

Transport: commands use the vendor feature collection `0xFFFF:2`, normally interface 2. The payload is 64 bytes with the opcode at byte 0; `hidapi` needs a 65-byte buffer with a leading report-ID byte `0x00`. Other interfaces carry boot keyboard, consumer, mouse and vendor input reports, not configuration commands.

Checksums: Bit7 is `0xFF - (sum(bytes[0:7]) & 0xFF)` at byte 7 for all requests except the two lighting SETs; Bit8 is `0xFF - (sum(bytes[0:8]) & 0xFF)` at byte 8 for `0x07` and `0x08` only. Bulk-write data pages have no checksum.

Replies: a SET returns no reply. A GET echoes its opcode in byte 0 except bulk page reads, which return raw 64-byte pages. An unsupported command replays the previous reply. Allow 100–300 ms after a SET and read a GET twice, using the second reply. Never validate a reply by its checksum byte.

Family detection: identify with `0x8F`, then compare the yc500 keymap read `0x89` with the gen2 keymatrix read `0x8A`. A raw `0x89` page with no echo plus an all-`FF` `0x8A` reply indicates yc500. An echoed `0x89` or a non-`FF` `0x8A` page indicates gen2. Ambiguous results must stop before any write.

## Safety

> **Never send `0x7F` (USB boot), `0x30` (display boot), `0xAC`/`0x2C` (flash erase) or `0x02` (factory reset) from general-purpose tooling.** These are live writes and the two families share opcode numbers, so a misaddressed write can hit a real register. Read and save the affected layer or slot before any keymap, macro or picture write. Picture uploads land in flash and can stall the control endpoint if paced too fast: 2 uploads / 10 s, pages 100 ms apart, 2 s settle.

## Files

| Path | Contents |
|---|---|
| [protocol.md](protocol.md) | Full reference: framing, checksums, family detection, opcode catalog, byte layouts, flash safety, receiver relay and host notes |
