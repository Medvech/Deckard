# SMC-PAD SysEx LED Mirroring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror the MK3's 16 pad colours onto the M-Vave SMC-PAD's RGB LEDs over the service SysEx port, behind a full MidiSuite-style handshake. Drive the five host-controllable button LEDs (LEFT/RIGHT/PLAY/STOP/REC) through the same session by arming their `Led` bytes and sending note-on feedback.

**Architecture:** All protocol and state-machine code lives in the shipped device's `main.lua` (the established pattern here: `launchpad_pro_mk3/main.lua` and `maschine_jam/main.lua` are also large single files). A new `service` port role isolates `SMC-PAD-Private`. The two new device Lua files (`device.lua` and `main.lua`) ARE registered in `Sources::SHIPPED` in `crates/surface/src/sources.rs`, so a clean checkout can load them; apart from that registration, Rust changes are confined to end-to-end tests in `device_tests.rs`. The Lua state machine is driven only from `tick()`; `midi("service", …)` consumes replies; colour writes are computed from `deckard.state()` and throttled. Button feedback goes out on the existing `daw` role as short MIDI notes.

**Tech Stack:** Lua 5.4 scripts in `crates/surface/lua/devices/mvawe_smc_pad/`, mlua-based `Device` host, Rust `#[cfg(test)]` tests, Swift emulator in `/tmp/scratchpad/smc-pad-virtual/`.

**Spec:** `docs/superpowers/specs/2026-11-18-smc-pad-sysex-leds-design.md`

## Global Constraints

- Logical packet: `00 59 cmd len24-LE payload ~sum(payload)&FF`, packed **LSB-first 8→7** into one `F0 … F7`.
- Identity request on the wire: `F0 00 32 45 00 00 00 40 7F F7`.
- State read on the wire: `F0 00 32 0D 41 00 00 00 02 00 00 00 00 40 01 00 00 6F 01 F7`.
- 29 region-5 reads: addresses `0, 1009, 2018, …`, length `1009` for the first 28, `60` for the last (total 28312).
- Region-5 pad-record address within a slot: `211 + bank*16*26 + record*26 + 5`; slot base `slot*3539`.
- Reading-order pad `i` → record `PAD_NUMBER[i] - 1`, with `PAD_NUMBER = {13,14,15,16, 9,10,11,12, 5,6,7,8, 1,2,3,4}`.
- Bank/slot from the 12-byte region-4 block: byte 6 (0-based) base bank, byte 10 slot, byte 11 toggle (`1` → bank index 7).
- Colour state from `deckard.state()` uses **`sound.color`** (an RGB table with indices 1..3), **not** `sound.rgb` (that is the Rust field name only). Other fields: `sound.used`, `sound.playing`, `sound.selected`, `s.group`, `s.sound`, `deckard.pad_held(i)`.
- `deckard.now()` is seconds since `Device` construction; tests must pass advancing `Instant`s (40 ms request spacing, 500 ms keep-alive, 5 s timeout).
- Reply checksum covers the payload only. A `0x22` write is ACKed by logical `00 59 00 01 00 00 00 FF`; ACKs are ignored.
- Button `Led` byte: region 5, address `slot*3539 + index*23 + 22`, one data byte = note selector. `index`: 0=LEFT(25), 1=RIGHT(26), 2=PLAY(27), 3=STOP(28), 4=REC(29). `FF` = unarmed. Slot 0 arm vectors (wire): `F0 00 32 09 49 00 00 40 02 16 00 00 00 10 00 00 00 19 14 03 F7` (left), `... 2D ... 1A 64 02 F7` (right), `... 44 ... 1B 34 02 F7` (play), `... 5B ... 1C 04 02 F7` (stop), `... 72 ... 1D 54 01 F7` (rec). Restore uses data `FF`.
- Button on/off is **note-on on the `daw` role**: `midi("daw", {0x90, 25+index, 5})` = on, velocity `0` = off. CC feedback `B0 cc 7F` is proven not to light buttons. Hardware spike confirmed: `FF` + `90 1B 05` = no light; `1B` + `90 1B 05` = PLAY lit.
- Buttons are slot-scoped only (no bank); re-arm on slot change and on every fresh session. PAD BANK / KNOB BANK / SHIFT / NOTE REPEAT / BT and encoder LEDs have no host path on stock firmware.
- Do not use `deckard.led()` for this device (that is the HID path); use `deckard.midi_send("service", bytes)`.

## Review Focus

- **Bad or unmatched SysEx reply** (wrong cmd, checksum, region, address or length) must be dropped, not advance the handshake — test in Task 1 (malformed identity reply) and Task 2 (wrong-address config reply).
- **A stalled request** (no reply for 5 s) must restart from the identity query rather than hang — test in Task 1.
- **A bank toggle in the keep-alive state reply** must rebuild the address map and redraw all 16 pads — test in Task 2.
- **An edited preset with no 36..51 note run** must fall back to the state-derived bank instead of writing to an arbitrary record — test in Task 2.
- **No RGB write before `ready`, at most 2 writes per `tick()`, and original RGB restored on `close()`** (skipped if never ready) — tests in Tasks 3 and 5.
- **Buttons must not be lit before `ready`** (note-on to an unarmed button is wasted and would pollute the DAW port), and the obsolete `B0 cc 7F` feedback must be gone — tests in Task 4.
- **A slot change reported by keep-alive must re-arm the five `Led` bytes and redirect feedback** — test in Task 4.
- **`close()` sends button note-offs while still armed, then restores the five `Led` bytes** — test in Task 5.

---

## Task 1: Service port, wire codec, identity and state handshake

**Files:**
- Modify: `crates/surface/lua/devices/mvawe_smc_pad/device.lua`
- Modify: `crates/surface/lua/devices/mvawe_smc_pad/main.lua`
- Test: `crates/surface/src/device_tests.rs`

**Interfaces:**
- Consumes: `Device::new`, `Device::tick`, `Device::midi`, `Device::open`, `Out::Midi` from the existing host; `view()` from `tests_support`.
- Produces: role `service`; Lua locals `logical(cmd, payload)`, `pack7(bytes)`, `unpack7(sysex)`, `parse_reply(bytes) → cmd, payload, ok`, `send_request(kind)`; test helpers `hex`, `pack7`, `sync_reply`, `identity_reply`, `state_reply`, captured `IDENTITY_REPLY` / `STATE_REPLY`.

### Step 1: Add the test helpers and the failing handshake test

In `device_tests.rs`, next to `midi(role, bytes)`, add a `hex(s: &str) -> Vec<u8>` helper and these fixtures (all bytes verbatim):

```rust
const IDENTITY_QUERY: &str = "F0 00 32 45 00 00 00 40 7F F7";
const STATE_READ: &str = "F0 00 32 0D 41 00 00 00 02 00 00 00 00 40 01 00 00 6F 01 F7";
const IDENTITY_REPLY: &str =
    "F0 00 32 45 58 01 00 40 29 4D 06 35 01 15 08 51 2F 30 60 4C \
     01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0A F7";
const STATE_REPLY: &str =
    "F0 00 32 0D 21 01 00 00 02 00 00 00 00 0C 00 00 78 00 32 04 \
     00 00 02 00 01 01 00 00 3D F7";
```

Add Rust `pack7(data: &[u8]) -> Vec<u8>` (LSB-first accumulator, no manufacturer byte) and `sync_reply(cmd: u8, payload: &[u8]) -> Vec<u8>` (logical `00 59 cmd len24 payload checksum`, then `pack7`). Add `state_reply(bank: u8, slot: u8, toggle: u8) -> Vec<u8>` = `sync_reply(0x23, &[4,0,0,0, 0,12,0,0, 0,0,0,0,0,0,bank,0,0,0,slot,toggle])` — 8 header bytes plus a 12-byte block whose indices 6, 10, 11 are `bank`, `slot`, `toggle` (the captured `STATE_REPLY` above uses bank 2, slot 0, toggle 0).

Add:

```rust
#[test]
fn smc_pad_service_handshake_starts_and_advances() {
    let mut d = Device::new("mvawe_smc_pad", None);
    assert_eq!(d.error(), None);
    let v = view();
    let t = Instant::now();

    assert_eq!(d.tick(&v, t), [midi("service", &hex(IDENTITY_QUERY))]);

    // A malformed reply is dropped; the pending request stays pending.
    d.midi("service", &[0xF0, 0x00, 0x32, 0x00, 0xF7], &v, t);
    assert!(d.tick(&v, t + Duration::from_millis(50)).is_empty());

    // The captured identity reply advances to the state read.
    d.midi("service", &hex(IDENTITY_REPLY), &v, t + Duration::from_millis(50));
    assert_eq!(
        d.tick(&v, t + Duration::from_millis(100)),
        [midi("service", &hex(STATE_READ))]
    );
}
```

### Step 2: Run the test to verify it fails

Run: `cargo test -p deckard-surface --lib smc_pad_service_handshake_starts_and_advances -- --nocapture`
Expected: FAIL — `d.tick` returns `[]` (no `service` role, no handshake code).

### Step 3: Implement the service role and the first two handshake steps

In `device.lua`:
- Add `service = { "SMC-PAD-Private", "SMC-PAD-Virtual-Private" }` to `ports`.
- Add `"service"` to `exclusive`.
- Remove `"SMC-PAD-Private"` and `"SMC-PAD-Virtual-Private"` from `midi` and `drums`.

In `main.lua`:
- Add constants: `LOGO = {0x00,0x59}`, `READ = 0x23`, `WRITE = 0x22`, `RETRY = 0.04`, `TIMEOUT = 5.0`, `KEEPALIVE = 0.5`.
- Implement `logical`, `pack7`, `unpack7`, `parse_reply` as locals (pure; return byte tables, not strings). `parse_reply` verifies `00 59`, the checksum, and that `len24` is present; return `nil` for anything else.
- Keep a module-local `st.sess` table: `state` (`query`/`state`/`config`/`ready`), `pending` (nil or a table describing the outstanding request), `sent`, `next_at`.
- `M.open()` and `M.close()` become no-ops for pad LEDs (transport button LEDs stay in `open()`); remove only the three `for n = 1,16 do light(n, …)` loops.
- In `M.midi(role, bytes)`, dispatch `role == "service"` to a `service_reply(bytes)` local before the existing transport/encoder/DAW branches.
- In `M.tick()`, when `state` is `query` or `state` and no request is pending and `deckard.now() >= next_at`, send one request via `deckard.midi_send("service", …)`; set `pending`, `sent = now`, `next_at = now + RETRY`. If a pending request has waited `> TIMEOUT`, clear `pending`, set `state = "query"`.
- `service_reply`: unpack, parse; ignore malformed replies. On a valid `0x11` reply clear `pending` and set `state = "state"`. On a valid `0x23` reply with region 4 clear `pending` and set `state = "config"` (the config reads come in Task 2).
- Never throw from reply parsing (guard with `pcall` if needed); a runtime error in a device handler is reported by the host but would stall the session.

### Step 4: Run the test to verify it passes

Run: `cargo test -p deckard-surface --lib smc_pad_service_handshake_starts_and_advances -- --nocapture`
Expected: PASS.

### Step 5: Add and run the timeout test, then commit

Add to `device_tests.rs`:

```rust
#[test]
fn smc_pad_service_handshake_restarts_after_timeout() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    let t = Instant::now();
    assert_eq!(d.tick(&v, t), [midi("service", &hex(IDENTITY_QUERY))]);
    assert!(d.tick(&v, t + Duration::from_secs(6)).is_empty(), "pending request isn't repeated");
    // The next tick restarts from the identity query.
    assert_eq!(d.tick(&v, t + Duration::from_secs(6) + Duration::from_millis(40)), [midi("service", &hex(IDENTITY_QUERY))]);
}
```

Run: `cargo test -p deckard-surface --lib smc_pad_service -- --nocapture` — Expected: PASS (both tests).

```bash
git add crates/surface/lua/devices/mvawe_smc_pad/device.lua \
        crates/surface/lua/devices/mvawe_smc_pad/main.lua \
        crates/surface/src/device_tests.rs
git commit -m "feat(smc-pad): open service port and start SysEx handshake"
```

---

## Task 2: Region-5 config reads, address map, keep-alive

**Files:**
- Modify: `crates/surface/lua/devices/mvawe_smc_pad/main.lua`
- Test: `crates/surface/src/device_tests.rs`

**Interfaces:**
- Consumes: `logical`, `pack7`, `unpack7`, `parse_reply`, `st.sess`, `service_reply`, `READ`, `RETRY`, `KEEPALIVE` from Task 1.
- Produces: `st.sess.config`, `st.sess.chunk`, `st.sess.slot`, `st.sess.bank`, `st.sess.addr[16]`, `st.sess.orig[16]`; Rust helper `config_image()`, `config_reply(addr, data)`, `drive_handshake(d, v, t, bank, slot, toggle, notes) -> Vec<Out>`.

### Step 1: Add config fixtures and the `drive_handshake` helper

In `device_tests.rs` add:

```rust
fn config_image(notes: bool) -> Vec<u8> {
    let mut img = vec![0u8; 8 * 3539];
    // Factory Led bytes: FF = unarmed, for all five buttons in every slot.
    for slot in 0..8 {
        for index in 0..5 {
            img[slot * 3539 + index * 23 + 22] = 0xFF;
        }
    }
    if notes {
        for r in 0..16 {
            let at = 211 + 2 * 16 * 26 + r * 26; // slot 0, bank 2
            img[at + 2] = 36 + r as u8;          // note
            img[at + 5..at + 8].copy_from_slice(&[10, 20, 30]); // original RGB
        }
    }
    img
}

fn config_reply(addr: usize, data: &[u8]) -> Vec<u8> {
    let mut payload = vec![5];
    payload.extend_from_slice(&(addr as u32).to_le_bytes());
    payload.extend_from_slice(&(data.len() as u32).to_le_bytes()[..3]);
    payload.extend_from_slice(data);
    sync_reply(0x23, &payload)
}
```

`drive_handshake(d, v, t, bank, slot, toggle, notes) -> Vec<Out>` must: call `d.open(v, t)`; feed `hex(IDENTITY_REPLY)` and the `state_reply(bank, slot, toggle)` from Task 1 (whose 12-byte data block is `[0,0,0,0,0,0,bank,0,0,0,slot,toggle]`, matching the captured `STATE_REPLY` layout); then for each of the 29 config chunks call `d.tick` at `t + Duration::from_millis(50 * i)` (asserting one `Out::Midi` on `service`), then feed `config_reply(addr, &image[addr..addr+len])` via `d.midi`. Concatenate and return the `Vec<Out>` from every call, so the caller can inspect both requests and the one-time status message.

### Step 2: Add the failing test for the full request sequence and readiness

```rust
#[test]
fn smc_pad_service_reads_config_and_reports_ready() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    let t = Instant::now();
    let out = drive_handshake(&mut d, &v, t, 2, 0, 0, true);
    // Reads have wire byte 3 = 0x45 (identity) or 0x0D (0x23); the five button arm
    // writes added in Task 4 use 0x09 and must not be counted here.
    let reqs: Vec<Vec<u8>> = out.iter().filter_map(|o| match o {
        Out::Midi { role, bytes } if role == "service" && (bytes[3] == 0x0D || bytes[3] == 0x45) => Some(bytes.clone()),
        _ => None,
    }).collect();
    assert_eq!(reqs.len(), 31, "identity + state + 29 config reads");
    assert_eq!(reqs[0], hex("F0 00 32 45 00 00 00 40 7F F7"));
    assert_eq!(reqs[1], hex("F0 00 32 0D 41 00 00 00 02 00 00 00 00 40 01 00 00 6F 01 F7"));
    assert_eq!(reqs[2], hex("F0 00 32 0D 41 00 00 40 02 00 00 00 00 10 7E 00 00 06 00 F7"));
    assert_eq!(reqs[30], hex("F0 00 32 0D 41 00 00 40 02 5C 5C 01 00 40 07 00 00 74 01 F7"));
    // The derived map is observable in the one-time status message emitted by the
    // `midi` call that completed the handshake (inside drive_handshake).
    assert!(out.iter().any(|o| matches!(o, Out::Message(m) if m.contains("ready") && m.contains("bank=2") && m.contains("slot=0"))), "{out:?}");
    // Ready sends the keep-alive state read, not another config read.
    let keep = d.tick(&v, t + Duration::from_secs(3));
    assert!(keep.contains(&midi("service", &hex("F0 00 32 0D 41 00 00 00 02 00 00 00 00 40 01 00 00 6F 01 F7"))), "{keep:?}");
}
```

### Step 3: Run the test to verify it fails

Run: `cargo test -p deckard-surface --lib smc_pad_service_reads_config_and_reports_ready -- --nocapture`
Expected: FAIL — only two requests are sent; no readiness.

### Step 4: Implement config reads, map derivation and keep-alive

In `main.lua`:
- Extend `M.tick()`: in `state == "config"`, send one `read_request(5, chunk*1009, chunk < 28 and 1009 or 60)` every `RETRY` seconds. Set `pending = {cmd=READ, region=5, addr=…, len=…}`.
- In `service_reply`, accept a `0x23` reply only when its `region`, `addr` and `len` match `pending`; otherwise drop it (this pins the wrong-address Review Focus item). Copy `data` into `st.sess.config[addr+1 … addr+len]`; increment `chunk`. On `chunk == 29`, derive the map: parse the stored 12-byte state block (byte 6 → `bank`, byte 10 → `slot`, byte 11 → `toggle`; toggle `1` overrides `bank = 7`); scan the eight banks of the active slot for exactly one whose record notes are `36..51`, else keep the state-derived bank (pins the edited-preset Review Focus item); compute `addr[i] = slot*3539 + 211 + bank*416 + (PAD_NUMBER[i]-1)*26 + 5` and cache `orig[i] = {config[addr+6], config[addr+7], config[addr+8]}`; set `state = "ready"`, `keepalive_at = deckard.now() + KEEPALIVE`; emit `deckard.message("SMC-PAD: service session ready (slot=" .. slot .. " bank=" .. bank .. ")")` **from `service_reply`**, so it is returned by the `midi()` call that delivered the last chunk rather than by a later `tick()`.
- In `ready`, send the region-4 read at most every `KEEPALIVE` seconds as a keep-alive. Compare the new block's `(slot, bank, toggle)` to the cached ones; if changed, rebuild `addr`/`orig`, reset `last` so all 16 pads redraw, and emit the updated status message from `service_reply` as well.
- Keep the `0x00` write ACK reply ignored.

### Step 5: Run the test to verify it passes

Run: `cargo test -p deckard-surface --lib smc_pad_service_reads_config_and_reports_ready -- --nocapture`
Expected: PASS.

### Step 6: Add the two map-robustness tests, run, then commit

```rust
#[test]
fn smc_pad_service_rebuilds_map_on_bank_toggle() {
    // drive_handshake(..., bank=2, slot=0, toggle=0, true); then feed
    // state_reply(2, 0, 1) via d.midi("service", …).
    // Assert that CALL'S Out::Message contains "bank=7", and that a tick afterwards
    // writes pad 1 to slot 0, bank 7, record 12 (address 0xD70 = 211 + 7*416 + 12*26 + 5,
    // wire bytes "F0 00 32 09 59 00 00 40 02 70 1A 00 00 30 00 00 00 7F 05 79 59 0F F7").
}

#[test]
fn smc_pad_service_falls_back_when_notes_differ() {
    // drive_handshake(..., bank=2, slot=0, toggle=0, notes=false).
    // Assert the ready message still says "bank=2" (no 36..51 run found).
}

#[test]
fn smc_pad_service_ignores_a_wrong_address_config_reply() {
    // After the first config request, feed config_reply(999, &[0; 1009]) instead of
    // the expected chunk 0. The next tick must re-send the SAME first config request
    // (bytes "F0 00 32 0D 41 00 00 40 02 00 00 00 00 10 7E 00 00 06 00 F7"),
    // not advance to chunk 1.
}
```

Run: `cargo test -p deckard-surface --lib smc_pad_service -- --nocapture` — Expected: PASS (all five tests).

```bash
git add crates/surface/lua/devices/mvawe_smc_pad/main.lua crates/surface/src/device_tests.rs
git commit -m "feat(smc-pad): derive pad RGB addresses from the live service config"
```

---

## Task 3: Colour mirror and throttled RGB writes

**Files:**
- Modify: `crates/surface/lua/devices/mvawe_smc_pad/main.lua`
- Test: `crates/surface/src/device_tests.rs`

**Interfaces:**
- Consumes: `st.sess.addr`, `st.sess.orig`, `st.sess.state == "ready"`, `deckard.state()`, `deckard.pad_held(i)`, `WRITE`, `pack7`.
- Produces: `pad_colour(i, s) → {r,g,b}`, `st.sess.last[16]`, `write_request(addr, rgb)`; Rust helper `drive_handshake` from Task 2.

### Step 1: Add the failing colour tests

```rust
#[test]
fn smc_pad_service_mirrors_mk3_pad_colours() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    let t = Instant::now();
    drive_handshake(&mut d, &v, t, 2, 0, 0, true);

    // Pad 1 is the focused sound: full RGB [255,66,62], at slot 0 bank 2 record 12 (0x550).
    let out = d.tick(&v, t + Duration::from_millis(1700));
    assert_eq!(sync_write(0x550, [255, 66, 62]), hex("F0 00 32 09 59 00 00 40 02 50 0A 00 00 30 00 00 00 7F 05 79 19 02 F7"));
    assert!(out.contains(&sync_write(0x550, [255, 66, 62])), "{out:?}");
    assert!(out.iter().filter(|o| matches!(o, Out::Midi { role, .. } if role == "service")).count() <= 2);
}

#[test]
fn smc_pad_service_writes_nothing_before_ready() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    let t = Instant::now();
    assert_eq!(d.tick(&v, t), [midi("service", &hex("F0 00 32 45 00 00 00 40 7F F7"))]);
}
```

Also add a helper `sync_write(addr: usize, rgb: [u8;3]) -> Vec<u8>` using `sync_reply(0x22, &[5, addr.le bytes, 3,0,0, r,g,b])` — the independent Rust encoder for expected write bytes.

### Step 2: Run the tests to verify they fail

Run: `cargo test -p deckard-surface --lib smc_pad_service_mirrors_mk3_pad_colours -- --nocapture`
Expected: FAIL — no colour writes are emitted.

### Step 3: Implement the mirror

In `main.lua`:
- Implement `pad_colour(i, s)`: get `s.groups[s.group].sounds[i]`; use `name = "PAD_" .. i`. Apply the `global.lua:588-602` decisions: `off` when no sound or (`not used` and not selected and not held and not playing); a dim white constant `{255,255,255}` scaled by `DIM = 0.35` when `not used` but chosen/held/playing; otherwise the sound's `color[1..3]`, scaled by `DIM` unless `selected or i == s.sound or pad_held(i)`; `playing and not pad_held(i)` mixes each channel with white as `math.floor((c + 255) / 2 + 0.5)` (static — no blink). Round every scaled channel with `math.floor(c * f + 0.5)` and clamp to `0..255`.
- Implement `write_request(addr, rgb)` from `logical(WRITE, {5, addr bytes LE4, 3,0,0, r,g,b})` and `pack7`.
- In `ready`, on each `tick()` compute colours for all 16 pads, compare with `st.sess.last[i]`, collect changed ones, and send **at most 2** per tick (round-robin so no pad starves), updating `last[i]` only for pads actually sent. Do not send while a handshake request is pending.
- Remove the old note-based pad LED writes still present: `light(d1, GREEN)` in the DAW pad branch and the `light(n, …)` loops already removed in Task 1. Leave the transport/nav `light(...)` calls for now — Task 4 replaces them.
- Keep all existing transport/encoder **input** behaviour unchanged. The existing `mvawe_smc_pad_*` tests must still pass here; Task 4 updates the CC-feedback assertion.

### Step 4: Run the tests to verify they pass

Run: `cargo test -p deckard-surface --lib smc_pad_service -- --nocapture`
Expected: PASS (all tests, including the two pre-existing mvawe tests).

### Step 5: Add the throttle/playing/empty-slot tests, run, then commit

Pin these in three further tests using `drive_handshake` and a mutated `view()`:
- `playing = true` on sound 1 → expected RGB `[255, 161, 159]` at address `0x550`.
- A view whose sound 1 is unused and not selected → expected dim white `[89,89,89]` at `0x550`.
- A view where all 16 colours change → exactly 2 writes on the first `tick()`, 2 on the next (pins the throttle).

Run: `cargo test -p deckard-surface --lib smc_pad_service -- --nocapture` — Expected: PASS.

```bash
git add crates/surface/lua/devices/mvawe_smc_pad/main.lua crates/surface/src/device_tests.rs
git commit -m "feat(smc-pad): mirror MK3 pad colours over SysEx"
```

---

## Task 4: Arm and drive the five button LEDs over the service session

**Files:**
- Modify: `crates/surface/lua/devices/mvawe_smc_pad/main.lua`
- Test: `crates/surface/src/device_tests.rs`

**Interfaces:**
- Consumes: `st.sess.slot`, `st.sess.config`, `st.sess.state == "ready"`, generalized `write_request(addr, data)` from Task 3, `state_reply(bank, slot, toggle)` from Task 1, `drive_handshake` from Task 2.
- Produces: `st.sess.btn_orig[5]`, `st.sess.btn_last[5]`, `arm_buttons()`, `button_led(index, on)`; Rust helper `sync_write_bytes(addr, data) -> Vec<u8>`.

Hardware evidence (USB spike 2026-11-18): slot 0 PLAY `Led` byte at `0x44` was `FF`; writing `0x1B` then `90 1B 05` on Port 3 lit it; the same note-on with `FF` did nothing; CC feedback does nothing. Only these five buttons have a host path.

### Step 1: Add the failing button tests

```rust
fn sync_write_bytes(addr: usize, data: &[u8]) -> Vec<u8> {
    let mut payload = vec![5];
    payload.extend_from_slice(&(addr as u32).to_le_bytes());
    payload.extend_from_slice(&(data.len() as u32).to_le_bytes()[..3]);
    payload.extend_from_slice(data);
    sync_reply(0x22, &payload)
}

#[test]
fn smc_pad_service_arms_buttons_and_drives_play_led() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    let t = Instant::now();
    let out = drive_handshake(&mut d, &v, t, 2, 0, 0, true);
    // Five 1-byte arm writes in slot 0, indexes LEFT..REC.
    for (addr, note) in [(0x16u32, 25u8), (0x2D, 26), (0x44, 27), (0x5B, 28), (0x72, 29)] {
        assert!(out.contains(&sync_write_bytes(addr as usize, &[note])), "{addr:#x}: {out:?}");
    }
    // view() starts not playing; flipping it on must light PLAY via DAW note-on.
    let mut playing = view();
    playing.playing = true;
    let out = d.tick(&playing, t + Duration::from_millis(1700));
    assert!(out.contains(&midi("daw", &[0x90, 27, 5])), "{out:?}");
}
```

Also update the existing `mvawe_smc_pad_play_cc_toggles_transport` test: drop the assertion
`out.contains(&midi(role, &[0xB0, 27, 127]))` and assert instead that no `Out::Midi` is emitted
before the service session is ready (LED feedback now requires arming).

### Step 2: Run the tests to verify they fail

Run: `cargo test -p deckard-surface --lib smc_pad_service_arms_buttons_and_drives_play_led -- --nocapture`
Expected: FAIL — no arm writes and no DAW note-on.

### Step 3: Implement button arming and feedback

In `main.lua`:
- Generalize `write_request(addr, data)` from Task 3: `data` is a byte table of any length (pad RGB still 3 bytes, button arm 1 byte).
- On the `ready` transition inside `service_reply`, call `arm_buttons()`: for `index = 0..4`, compute `addr = st.sess.slot*3539 + index*23 + 22`, read the current byte from `st.sess.config[addr+1]`, cache it in `st.sess.btn_orig[index+1]`, and `deckard.midi_send("service", write_request(addr, {25+index}))`.
- When a keep-alive state reply reports a **different slot**, update `st.sess.slot` and call `arm_buttons()` again before redrawing pads.
- `button_led(index, on)` → `deckard.midi_send("daw", {0x90, 25+index, on and 5 or 0})`.
- In `ready` on each `tick()`, compute desired states from `deckard.state()`:
  `PLAY = s.playing`, `STOP = s.playing`, `REC = s.recording`,
  `LEFT = s.control.page > 1`, `RIGHT = s.control.page < #s.control.pages`.
  Compare with `st.sess.btn_last[index+1]`, send only changes (at most five), and never before `ready`.
- Remove `button_light()` and all its calls (the `B0 cc 7F` feedback in the CC 27..29 branch). Remove **all** remaining `light(...)` calls and the `light()` helper itself — from `open()`, `close()`, the CC branch and the DAW-note branch. These include `light(PLAY|STOP|REC|LEFT|RIGHT, …)` with notes 17..21 and the GREEN/BLUE/OFF palette values. Keep every **input** action unchanged.
- In the CC branch add `d1 == 25` → `deckard.previous_page()` and `d1 == 26` → `deckard.next_page()`, each followed by `return`, so LEFT/RIGHT work in CC mode too. Note 20/21 navigation on the DAW role stays.

### Step 4: Run the tests to verify they pass

Run: `cargo test -p deckard-surface --lib smc_pad_service -- --nocapture`
Expected: PASS (all service tests plus the two pre-existing mvawe tests, with the updated CC assertion).

### Step 5: Add the robustness tests, run, then commit

Add three tests:
- `smc_pad_service_emits_no_button_notes_before_ready`: after one `tick()`, assert no `Out::Midi` with `role == "daw"`.
- `smc_pad_service_rearms_buttons_on_slot_change`: after `drive_handshake`, call `d.tick(&v, t + Duration::from_millis(1600))` to emit the first keep-alive state read, then feed `state_reply(2, 1, 0)` via `d.midi("service", …)`; assert that call emits arm writes to slot 1 addresses (`3539 + 0x16`, `3539 + 0x2D`, …). An unmatched state reply is dropped, so the pending keep-alive request is required.
- `smc_pad_service_button_leds_follow_state`: clone `view()`, set `recording = true` and `control.page = 2` (`view()` has two `control.pages`), then on a `tick()` assert `midi("daw", {0x90, 29, 5})` (REC) and `midi("daw", {0x90, 25, 5})` (LEFT), plus `midi("daw", {0x90, 26, 0})` (RIGHT off).

Run: `cargo test -p deckard-surface --lib smc_pad_service -- --nocapture` — Expected: PASS.

```bash
git add crates/surface/lua/devices/mvawe_smc_pad/main.lua crates/surface/src/device_tests.rs
git commit -m "feat(smc-pad): arm and drive button LEDs over the service session"
```

---

## Task 5: Restore on close, emulator, full verification

**Files:**
- Modify: `crates/surface/lua/devices/mvawe_smc_pad/main.lua`
- Test: `crates/surface/src/device_tests.rs`
- Modify (outside the project): `/tmp/scratchpad/smc-pad-virtual/main.swift`

**Interfaces:**
- Consumes: `st.sess.orig`, `st.sess.addr`, `st.sess.btn_orig`, `st.sess.state`, `write_request` from Tasks 3 and 4.
- Produces: restore-on-close behaviour (16 pad RGBs + 5 `Led` bytes + 5 note-offs); emulator `SMC-PAD-Virtual-Private` endpoint.

### Step 1: Add the failing close tests

```rust
#[test]
fn smc_pad_service_restores_original_pad_rgb_on_close() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    let t = Instant::now();
    drive_handshake(&mut d, &v, t, 2, 0, 0, true);
    let out = d.close();
    // 16 pad RGBs + 5 button Led bytes on the service port; 5 note-offs on daw.
    assert_eq!(out.iter().filter(|o| matches!(o, Out::Midi { role, .. } if role == "service")).count(), 21);
    assert_eq!(out.iter().filter(|o| matches!(o, Out::Midi { role, .. } if role == "daw")).count(), 5);
    // Pad 1's record 12 at 0x550 originally held RGB [10,20,30].
    assert!(out.contains(&sync_write(0x550, [10, 20, 30])), "{out:?}");
    // Every Led byte was FF originally; play is at 0x44.
    assert!(out.contains(&sync_write_bytes(0x44, &[0xFF])), "{out:?}");
    for note in 25..=29 {
        assert!(out.contains(&midi("daw", &[0x90, note, 0])), "{out:?}");
    }
}

#[test]
fn smc_pad_service_close_before_ready_sends_no_writes() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    let t = Instant::now();
    d.tick(&v, t); // only the identity query went out
    let out = d.close();
    assert!(out.iter().all(|o| !matches!(o, Out::Midi { role, .. } if role == "service")));
    assert!(out.iter().all(|o| !matches!(o, Out::Midi { role, .. } if role == "daw")), "{out:?}");
}
```

### Step 2: Run the tests to verify they fail

Run: `cargo test -p deckard-surface --lib smc_pad_service_restores -- --nocapture`
Expected: FAIL — `close()` emits no SysEx.

### Step 3: Implement synchronous restore

In `M.close()`: when `st.sess.state == "ready"`, first send `deckard.midi_send("daw", {0x90, 25+i, 0})` for `i = 0..4` (note-offs while still armed), then loop `i = 1..16` sending `deckard.midi_send("service", write_request(addr[i], orig[i]))`, then loop `i = 1..5` sending `deckard.midi_send("service", write_request(slot*3539 + (i-1)*23 + 22, {btn_orig[i]}))`. Set `state = "closed"`. Do not send anything if the handshake never reached `ready`. No session-end command exists. (The old `close()` only turned pad LEDs off, so there are no other writes to keep.)

### Step 4: Run the tests to verify they pass

Run: `cargo test -p deckard-surface --lib smc_pad_service -- --nocapture` — Expected: PASS (all).

### Step 5: Update the emulator and verify end to end

In `/tmp/scratchpad/smc-pad-virtual/main.swift`: add a `SMC-PAD-Virtual-Private` MIDI destination/source pair; on an inbound `F0 00 32 …` SysEx, unpack it, and reply with the identity/state/config fixtures from Task 1/2 using the same sync-reply builder; parse and print `0x22` writes as `pad <record> @0x<addr> rgb=<r>,<g>,<b>` for 3-byte payloads and `button <index> @0x<addr> led=<byte>` for 1-byte payloads; additionally print DAW note-ons `90 19..1D` as `button on/off`. Extend `--selftest` to assert the identity query, one pad `0x22` write vector and one button arm vector. Build with the existing Swift command and run `--selftest`.

Run: `cargo test -p deckard-surface --lib` — Expected: all tests pass (currently 293 passed, 2 ignored; 17 new tests → expect 310 passed, 2 ignored).
Run: `cargo build -p deckard --release` — Expected: success; binary at `target/release/deckard`.

### Step 6: Commit

```bash
git add crates/surface/lua/devices/mvawe_smc_pad/main.lua crates/surface/src/device_tests.rs
git commit -m "feat(smc-pad): restore LEDs on close and verify release build"
```
