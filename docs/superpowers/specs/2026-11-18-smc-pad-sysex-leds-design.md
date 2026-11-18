# SMC-PAD: SysEx LED colour mirroring — design

Date: 2026-11-18
Branch: `feature/mvawe-smc-pad`

## Intent

The M-Vave/ SINCO SMC-PAD already works as a Deckard surface (pads, 8 encoders, transport,
navigation). Its pad LEDs currently show a fixed palette sent as notes to port 3. The
human partner wants the 16 pad LEDs to show the **same colours the MK3 pads show**, driven
over the stock firmware's **service SysEx** on `SINCO SMC-PAD-Private`, with the mandatory
service-session handshake. The reason: the SMC-PAD should act as a second, portable copy
of the MK3 pad display, not just a drum pad with static lights.

A follow-up request asks for the transport / navigation buttons to be driven by the same
service session where possible. A USB hardware spike established that the five buttons with
configuration records (LEFT/RIGHT/PLAY/STOP/REC, CC 25..29) can be armed with a one-byte
SysEx write and then lit with ordinary note-on on Port 3. The other five physical buttons
have no host LED path on stock firmware.

## Goals

- Replay the full service-session handshake before any LED write; without it the stock
  firmware silently ignores colour writes.
- Find the RGB address of each lit pad from the device's **live configuration** (region 5),
  not from a hardcoded `0x418` stock-preset address, because this unit's CC map has been
  edited and its bank/preset may change.
- Mirror the focused group's 16 pad colours from `deckard.state()` (`color`, `selected`,
  `playing`, `used`, `pad_held`) the way `global.lua` drives MK3 `LED_PAD_1..16`.
- Mirror the MK3 state of the five host-controllable buttons through the same session:
  arm their `Led` bytes over SysEx, then drive on/off note feedback on the DAW port.
- Keep the session alive and restore the saved colours / arm bytes on close.

## Non-goals

- No firmware flashing, no custom Arduino firmware, no BLE/GATT path — USB MIDI only.
- No RGB control of buttons or encoders: the five host-controllable buttons have physically
  single-colour LEDs (on/off only), and PAD BANK, KNOB BANK, SHIFT, NOTE REPEAT, Bluetooth
  and the encoder rings have no host-writable LED path on stock firmware.
- No persistence: region-5 writes stay in RAM, as in the stock editor.
- No exact reproduction of MK3's 17-entry palette LUT; Deckard does not expose MK3 LEDs to
  device scripts. The source RGB of each sound, with the same bright/dim/flash decisions,
  is the mirror.

## Constraints / facts from the specs

- Transport: logical packet `00 59 | cmd | len24 LE | payload | ~sum(payload) & FF`,
  bit-packed **LSB-first 8→7** into one `F0 … F7` SysEx (no manufacturer ID).
  Sources: `fedepaj/open-smc-pad/docs/sinco-protocol.md:7-23`,
  `host/sinco_proto.py:8-29`; Cristian Deluxe's article and `spectalive/smc-pad` captures.
- Only the `SINCO SMC-PAD-Private` port answers service SysEx. Master and Port 3 do not.
- MidiSuite's full connect exchange is required: `0x11` identity query, one `0x23` read of
  region 4 (`addr 0`, `len 12`), then 29 `0x23` reads of region 5 (8×3539 = 28312 bytes,
  chunks of 1009, last 60). Replies must be matched by command/region/address/length and
  checksum-checked. ~43 ms between requests, ~5 s per-reply timeout. **There is no separate
  login/unlock command** — replaying the whole read sequence is what unlocks writes.
- Reply framing is the same logical packet: `00 59 cmd len24 payload checksum` (checksum is
  the one's complement of the payload sum). `0x11` reply: 27-byte payload, NUL-padded ASCII
  `SMC-PAD_00x` (this unit reports `SMC-PAD_004`). `0x23` reply: payload = `region(1),
  addr(4 LE), len(3 LE), data(len)`. A write is acknowledged by `00 59 00 01 00 00 00 FF`
  (cmd `0x00`, payload `00`).
- After the full read sequence, a region-4 read about every 500 ms keeps the session alive.
- LED colour = `0x22` write, region 5, 3 bytes at
  `slot*3539 + 211 + ((bank-1)*16 + record)*26 + 5`.
  Pad record: `type, channel, note, vmin, vmax, r, g, b, led, …`
  (`mvave-home-assistant/custom_components/mvave/devices/smc_pad.py:12-20,43-93,154-174`).
- Device pad numbers run bottom-left upward; reading-order position `i` (MK3 pad `i`,
  1 = top-left) is record `PAD_NUMBER_BY_READING_ORDER[i] - 1` with
  `(13,14,15,16, 9,10,11,12, 5,6,7,8, 1,2,3,4)`.
- Live slot/bank come from region-4 state: byte 6 = base bank (0-based, default 2 means
  image bank 3), byte 10 = preset slot (0-based), byte 11 = bank toggle
  (0 → base bank, 1 → image bank 8, i.e. bank index 7 regardless of base bank).
  The "note scan" examines the active slot's eight banks of 16 pad records and looks for
  the bank whose record notes are 36..51 in record order 0..15. If exactly one matches, use
  it; if none or several match, fall back to the bank derived from the state bytes.
- Button records: five per slot at offsets `0,23,46,69,92` of region 5, each 23 bytes:
  `type, channel, cc, min, max, sysex_len, sysex[16], Led`. `Led` is at offset 22; `FF` means
  unarmed. Physical order: LEFT (25), RIGHT (26), PLAY (27), STOP (28), REC (29). Arming
  address = `slot*3539 + index*23 + 22`, a **1-byte** `0x22` write carrying the note selector.
  Buttons have no bank dimension. USB spike 2026-11-18: original byte `FF`; writing `0x1B`
  then `90 1B 05` on `SINCO –Порт 3` lit PLAY; the same note-on with `FF` did nothing.
  CC feedback (`B0 1B 7F`) does not light buttons.
- Note-on velocity semantics for buttons: any non-zero velocity lights, `0` extinguishes
  (unlike pad records, where 127 selects a palette entry / off). Velocity `5` matches the
  measurement. Keep 25..29 outside the pad-feedback range 1..21 to avoid cross-talk.
- Button records are slot-scoped: re-arm when the displayed slot changes, and on every fresh
  session (power cycle clears RAM). No re-arm on PAD BANK toggle.
- `deckard.midi_send(role, bytes)` sends whole SysEx; `main.lua:midi(role, bytes)` receives
  a whole SysEx in one call (`docs/controller-api.md:447,455`). `deckard.now()` is seconds.

## Approaches considered

1. **Full protocol (chosen).** Generate handshake packets in Lua, parse replies, build the
   pad-address map from the live config, keep alive, mirror colours, restore on close.
   Robust against edited presets and bank changes; most code and most tests.
2. **Captured frames + stock address.** Replay the 31 recorded frames verbatim and write to
   `0x418 + (note−36)*26`. Small, but breaks when the preset/bank differs — unacceptable
   for this unit, whose map has been edited.
3. **Port-3 velocity palette.** Keep the existing note-based LEDs. Stable but only a fixed
   pastel palette, no true RGB mirror; does not meet the request.
4. **Button feedback via the service session (chosen for buttons).** Arm the five `Led`
   bytes during `ready`, then drive on/off by note-on on the DAW port. Keeping the old CC
   feedback was measured not to light anything. Local-only buttons are out of scope.

## Design

### Files

- `crates/surface/lua/devices/mvawe_smc_pad/device.lua`: add a `service` role matching
  `SMC-PAD-Private` (in and out), add it to `exclusive`, remove Private from `midi`/`drums`
  so `midi` resolves to Master and the SysEx goes only to Private.
- `crates/surface/lua/devices/mvawe_smc_pad/main.lua`: protocol state machine, colour
  mirror, button arming/feedback, LED writes. No Rust changes.
- `crates/surface/src/device_tests.rs`: end-to-end tests through `Device` (handshake
  requests, reply parsing, derived addresses, colour and button writes, restore on close).
- `/tmp/scratchpad/smc-pad-virtual/main.swift`: emulator learns a `SMC-PAD-Virtual-Private`
  endpoint that answers the handshake with synthetic region 4/5 replies and logs LED
  writes. Outside the project, as agreed earlier.

### Protocol module (inside `main.lua`, pure functions)

- `logical(cmd, payload)` → `00 59 cmd len24 payload checksum` as a Lua byte table.
- `pack7(bytes)` → `F0` + LSB-first 8→7 + `F7`; `unpack7(sysex)` → bytes.
- `read_request(region, addr, len)` → packed `0x23` packet;
  `write_request(region, addr, data)` → packed `0x22` packet (1 byte for buttons, 3 for pad
  RGB).
- `parse_reply(bytes)` → `cmd, payload, ok`; for `0x23`: `region, addr, len, data`.
  Trailing-zero packing loss is handled by trusting `len24`, not the byte count.

### Session state machine (driven from `tick()`)

- States: `query → state-read → config-read (29 chunks) → ready`; `failed` retries from
  `query` after a backoff.
- `tick()` sends at most one request per 40 ms, advances only after a matching, valid
  reply; a request without reply for 5 s restarts the handshake.
- Region-5 chunks are assembled by address into an 28312-byte string. Once complete:
  read the active slot/bank from the state block, locate the active bank's 16 pad records,
  and cache each pad's original RGB (for `close()`).
  Fall back to the configured slot/bank from the state reply if the note scan is ambiguous.
- In `ready`, send the region-4 read every 500 ms as keep-alive; if the reported slot/bank
  changes, rebuild the address map and redraw all 16 pads, and re-arm the buttons for the
  new slot.
- `open()` sends nothing until the first `tick()`; `midi("service", …)` feeds replies only.
- `close()` writes the cached original RGB back and restores the five `Led` bytes
  **synchronously**; note-off for the five buttons is sent first, while still armed.
  Deckard's host drops `Out::Midi` from `close()` when a port has already gone, so this is
  best-effort on unplug; app quit still sends it. No Rust host change. If the handshake
  never reached `ready`, there is nothing cached and restore is skipped. No session-end
  command was found in the protocol, so none is sent.

### Colour mirror

- Source: `deckard.state()`, focused group `groups[state.group]`, its `sounds[1..16]`.
- Per pad `i` (MK3 reading order): `off` when no sound or (`not used` and not selected and
  not held and not playing); white-dim for a selected empty slot; otherwise the sound's
  `color`, full when `selected or pad_held(i)`, dim (≈35 %) otherwise, white-mixed when
  `playing and not pad_held(i)`. This mirrors `global.lua:588-602`.
- 8-bit channels are passed through unchanged (the device accepts `0x00..0xFF`).
- `playing` is a **static 50 % mix with white** (`(c + 255) / 2`), not a temporal blink:
  the human partner explicitly chose no lag over blinking. This is the "flash" shade MK3
  mixes in, held steady. Colour writes are throttled and never block the UI thread.
- Cache the last colour per pad; `tick()` sends at most 2 changed pads per call (~60 writes/s
  at 30 Hz, near the measured ~5 full grids/s ceiling). No writes before `ready`.
- `0x22` writes are fire-and-forget: their ACK is parsed and ignored, they do not advance
  the handshake and are not subject to the 40 ms request spacing.
- Once `ready`, remove the existing note-based pad LED writes (BLUE on open, GREEN on pad
  press, OFF on close) from `main.lua`; they would fight the SysEx colours. Before `ready`,
  no pad LEDs are driven.

### Button LEDs

- On reaching `ready`, and whenever the keep-alive reports a different displayed slot, write
  the five `Led` bytes (`arm_note = 25 + index`) and cache their originals for `close()`.
  Use the same `0x22` builder as pad RGB with a single data byte.
- Desired state from `deckard.state()`: PLAY = `playing`, STOP = `playing`, REC = `recording`,
  LEFT = `control.page > 1`, RIGHT = `control.page < #control.pages`.
- Drive **changes only**, via `deckard.midi_send("daw", {0x90, 25+index, 5 or 0})` — note-on
  on the DAW port (Port 3), the path proven on hardware. Velocity `5` = on, `0` = off. Never
  before `ready`.
- Replace the existing `B0 cc 7F` feedback and the note-based transport LEDs (`light(17..19)`)
  with this path. Keep all button **input** unchanged (CC 27..29 on any role, notes 17..21 on
  DAW); add CC 25/26 as navigation so the LEFT/RIGHT buttons work in CC mode too.
- `close()`: send note-off for all five while still armed, then restore the cached `Led`
  bytes and the 16 pad RGBs synchronously.

## Error handling / UX

- Errors never throw from Lua: malformed/unmatched replies are dropped; handshake retries.
- `deckard.message("SMC-PAD: service session …")` once on success/failure, not per packet.
- If MidiSuite is running it also polls this port; the doc/user note says to close it.
- **User note:** close MidiSuite before using the `SMC-PAD-Private` service session — MidiSuite and DECKARD cannot own the port at the same time.

## Testing

- Unit: `Device::new("mvawe_smc_pad")`; `open()` then `tick()` produce the identity query;
  feed a captured identity reply, assert the state read; feed a synthetic state reply,
  assert the first region-5 request; feed 29 synthetic replies with a known pad record map,
  assert the first LED writes use the derived RGB addresses and expected RGB bytes.
- Unit: a malformed reply does not advance the state machine; timeout retries.
- Unit: after `ready`, assert the five arm writes (slot 0 PLAY =
  `F0 00 32 09 49 00 00 40 02 44 00 00 00 10 00 00 00 1B 34 02 F7`), that a playing view
  produces `midi("daw", {0x90, 27, 5})` and a non-playing view `midi("daw", {0x90, 27, 0})`,
  and that no button notes are emitted before `ready`.
- Unit: a keep-alive state reply with a new slot re-arms and redirects button writes.
- Unit: `close()` restores the five `Led` bytes and sends five note-offs.
- Emulator: `--selftest` checks the new handshake vectors; running it while Deckard is open
  prints parsed LED writes so the human partner can see the colours arriving.
- Verification: `cargo test -p deckard-surface --lib` and `cargo build -p deckard --release`.

## Left to the builder

- Exact pacing constants (40 ms request spacing, 500 ms keep-alive, 5 s timeout) are
  starting values from the captures; adjust if the device misses requests.
- Whether to retry the handshake forever or give up after N attempts: retry forever, with
  a status message, since the port may appear later.
