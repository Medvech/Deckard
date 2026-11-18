# SMC-PAD Input Remap & MK3 Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the M-Vave SMC-PAD's presses land on the Deckard pad its LED lights, play what the current pad mode says (as the MK3 does), redraw its LEDs on group/mode/transposition changes, and keep its transport LEDs in sync.

**Architecture:** Pad presses become a device-script API call `deckard.pad(pad, down, velocity)` that emits a new `Out::Pad` from the device VM to the app. The app feeds it to `Surface::event()` (focus, step editing, shortcuts, held state) and to a small `PadVoices` helper that reuses the MK3's `pad_notes()`/`pad_velocity()` to emit engine `Live` notes. Pad mode/base/keys/notes flow from the main surface Lua VM through `View` into `deckard.state()` so the SMC script can mirror keyboard/chords LEDs and force a full rebuild when state changes. The SMC's `midi` role becomes exclusive so its notes no longer reach the engine's drum mapper (which would double-play). The MK3 and JAM paths are not refactored.

**Tech Stack:** Rust (mlua device/surface host, viewer app, engine `Live` events), Lua 5.4 device script, cargo tests.

**Spec:** `docs/superpowers/specs/2026-11-18-smc-pad-input-remap-design.md`

## Global Constraints

- `PAD_NUMBER = { 13,14,15,16, 9,10,11,12, 5,6,7,8, 1,2,3,4 }` (1-based, Deckard pad for each SMC pad). It is an involution; do not change it or any RGB address.
- SMC pad *p* sends note `35 + p` on the `midi` role (notes 36..51). Deckard pad = `PAD_NUMBER[p]`.
- `deckard.state()` uses 1-based `group`/`sound`, `sound.color` is an RGB table indexed 1..3, `scale.bank`/`scale.kind` are 1-based, `scale.root` is a MIDI note.
- `pads.keys()` is true only for modes `"keyboard"`/`"chords"`; `pads.notes()` always returns 16 entries and uses 128 for "none". Step+Keyboard must keep pad-mode LEDs (matches `global.lua:581`).
- `PadRoute` is `Copy`; `PadRoute::scaling` comes from `settings.velocity_scaling`, `fixed` from the song's `fixed_velocity` (clamped 0..127), `velocity` from `View.fixed_velocity`.
- Held notes use `Live::NoteOn { length: i64::MAX }` and stop with `Live::NoteRelease`; a chord's first note is `sounding`, the rest `chord_rest` (release order: rest first, then first).
- Device scripts run in a Lua VM separate from the main surface VM; `deckard.pad()` must set the device VM's own `Shared.pads` as well as emit `Out::Pad`.
- New `View` fields must have `Default` values (all `View` literals use `..Default::default()`).
- Keep MidiSuite closed while the SMC `service` port is owned; do not alter the SysEx session, address map, or restore-on-close behaviour.

## Review Focus

- **SMC 13/9/5/1 must become Deckard 1/5/9/13** (and the rest of each block) — test in Task 2 (`smc_pad_notes_become_deckard_pad_events`).
- **A remapped press must play the mode's notes, not always C3** (Keyboard → scale note, Chords → all chord notes) — tests in Task 4 (`pad_voices_*`).
- **A full 16-pad rebuild must follow a group / mode / transposition / focused-sound / scale change**, not just the 2-per-tick mirror — test in Task 5 (`smc_pad_keyboard_mode_redraws_when_state_changes`).
- **Record note 19 must toggle**, matching CC 29 and the MK3 — test in Task 5 (`smc_pad_note_19_toggles_record`).
- **No double playback**: the SMC's `midi` port must be exclusive and its `drums` entry gone, so its notes reach only the script — test in Task 2 (`smc_pad_takes_its_pad_notes_itself`).
- **A release must stop the notes the press started even if the mode changed while held** — test in Task 4 (`pad_voices_release_stops_the_original_notes`).

---

### Task 1: Device VM pad API and the `Out::Pad` event

**Files:**
- Modify: `crates/surface/src/device.rs:71-84, 339-364, 480-529`
- Modify: `apps/viewer/src/main.rs:6766-6773` (temporary match arm)
- Modify: `apps/viewer/src/jam_io.rs:333-338` (match arm)
- Test: `crates/surface/src/device_tests.rs`
- Commit with: the new spec doc and this plan doc (both currently untracked).

**Interfaces:**
- Consumes: `Out`, `Device::new/midi/tick`, `test_device(main)` and `view()` from `device_tests.rs`.
- Produces: `Out::Pad { pad: usize, down: bool, velocity: f64 }`; Lua `deckard.pad(pad, down, velocity)` (pad 1..=16, velocity clamped to 0..=1), which also updates the device VM's `deckard.pad_held(pad)`.

- [ ] **Step 1: Write the failing test**

In `crates/surface/src/device_tests.rs`, add:

```rust
#[test]
fn a_device_can_report_a_pad_and_see_it_held() {
    let (_tmp, dir) = test_device(r#"
      return {
        midi = function(role, bytes)
          deckard.pad(bytes[2], bytes[3] == 1, bytes[4] / 127)
          deckard.message(tostring(deckard.pad_held(bytes[2])))
        end
      }"#);
    let mut d = Device::new("test", Some(dir));
    let v = view();

    assert_eq!(
        d.midi("midi", &[0x90, 13, 1, 127], &v, Instant::now()),
        vec![Out::Pad { pad: 13, down: true, velocity: 1.0 }, Out::Message("true".into())]
    );
    assert_eq!(
        d.midi("midi", &[0x80, 13, 0, 0], &v, Instant::now()),
        vec![Out::Pad { pad: 13, down: false, velocity: 0.0 }, Out::Message("false".into())]
    );
    // Out-of-range pads are a script error, not a silent no-op.
    d.midi("midi", &[0x90, 17, 1, 127], &v, Instant::now());
    assert!(d.error().is_some_and(|e| e.contains("1..=16")), "{:?}", d.error());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p deckard-surface --lib a_device_can_report_a_pad_and_see_it_held -- --nocapture`
Expected: FAIL — `deckard.pad` is nil / no `Out::Pad`.

- [ ] **Step 3: Add `Out::Pad` and the Lua API**

In `crates/surface/src/device.rs`:
- Add `Pad { pad: usize, down: bool, velocity: f64 }` to `Out`.
- Change `fn install(lua, id, outs)` to `fn install(lua: &Lua, id: &str, shared: &Rc<RefCell<Shared>>, outs: &Rc<RefCell<Vec<Out>>>)`, update its call site (~line 354), and register `deckard.pad` there. Body: reject pads outside `1..=16` with `mlua::Error::runtime("pad: … isn't 1..=16")`, write `shared.borrow_mut().pads[pad - 1] = down`, push `Out::Pad { pad, down, velocity: velocity.clamp(0.0, 1.0) }`.
- Add temporary `Out::Pad { .. } => {}` arms to the two exhaustive matches in `apps/viewer/src/main.rs` and `apps/viewer/src/jam_io.rs` so the workspace compiles (Task 4 replaces the main.rs arm).

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p deckard-surface --lib a_device_can_report_a_pad_and_see_it_held -- --nocapture`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/surface/src/device.rs crates/surface/src/device_tests.rs \
  apps/viewer/src/main.rs apps/viewer/src/jam_io.rs \
  docs/superpowers/specs/2026-11-18-smc-pad-input-remap-design.md \
  docs/superpowers/plans/2026-11-18-smc-pad-input-remap.md
git commit -m "feat(surface): let device scripts report pad presses"
```

---

### Task 2: SMC pad notes become remapped `Out::Pad`; stop the drum path

**Files:**
- Modify: `crates/surface/lua/devices/mvawe_smc_pad/device.lua`
- Modify: `crates/surface/lua/devices/mvawe_smc_pad/main.lua:388-417`
- Test: `crates/surface/src/device_tests.rs`

**Interfaces:**
- Consumes: `Out::Pad`, `deckard.pad` from Task 1; `PAD_NUMBER` in `main.lua`.
- Produces: SMC note 36+(*p*−1) → `Out::Pad { pad: PAD_NUMBER[p], down, velocity: d2/127 }`; manifest `exclusive` contains `"midi"` and `drums` is empty.

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn smc_pad_notes_become_deckard_pad_events() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    // SMC 13 -> Deckard 1, at full velocity.
    assert_eq!(d.midi("midi", &[0x90, 48, 127], &v, Instant::now()),
        vec![Out::Pad { pad: 1, down: true, velocity: 1.0 }]);
    assert_eq!(d.midi("midi", &[0x80, 48, 0], &v, Instant::now()),
        vec![Out::Pad { pad: 1, down: false, velocity: 0.0 }]);
    // SMC 1 -> Deckard 13; note-off on 0x90 with velocity 0 is a release too.
    assert_eq!(d.midi("midi", &[0x90, 36, 64], &v, Instant::now()),
        vec![Out::Pad { pad: 13, down: true, velocity: 64.0 / 127.0 }]);
    assert_eq!(d.midi("midi", &[0x90, 36, 0], &v, Instant::now()),
        vec![Out::Pad { pad: 13, down: false, velocity: 0.0 }]);
    // Out-of-range notes and CCs are untouched.
    assert!(d.midi("midi", &[0x90, 35, 127], &v, Instant::now()).is_empty());
}

#[test]
fn smc_pad_takes_its_pad_notes_itself() {
    let d = crate::device::devices(None);
    let smc = d.iter().find(|m| m.id == "mvawe_smc_pad").expect("shipped");
    assert!(smc.exclusive.iter().any(|r| r == "midi"), "{smc:?}");
    assert!(smc.drums.is_empty(), "{smc:?}");
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p deckard-surface --lib smc_pad_notes_become_deckard_pad_events -- --nocapture` then `cargo test -p deckard-surface --lib smc_pad_takes_its_pad_notes_itself -- --nocapture`
Expected: FAIL — `M.midi("midi", …)` returns no `Out::Pad`; manifest still has `drums` and no `midi` in `exclusive`.

- [ ] **Step 3: Route the notes in the SMC script and manifest**

In `device.lua`: add `"midi"` to `exclusive`; delete the `drums` line and replace its comment with one saying pad notes are read by the script and played through the app's pad route, not a drum channel.

In `main.lua::M.midi`, after the CC 25–29 button block and before the encoder block, add a `role == "midi"` branch for `kind == 0x90 or kind == 0x80` with `d1` in 36..51 that computes `p = d1 - 35`, `down = kind == 0x90 and d2 > 0`, `velocity = (down and d2 or 0) / 127`, calls `deckard.pad(PAD_NUMBER[p], down, velocity)`, and returns.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p deckard-surface --lib smc_pad_ -- --nocapture`
Expected: PASS — including all pre-existing SMC handshake/LED/button tests.

- [ ] **Step 5: Commit**

```bash
git add crates/surface/lua/devices/mvawe_smc_pad/device.lua \
  crates/surface/lua/devices/mvawe_smc_pad/main.lua crates/surface/src/device_tests.rs
git commit -m "feat(smc-pad): remap pad notes and take them off the drum channel"
```

---

### Task 3: Expose pad mode, base, keys and notes to device scripts

**Files:**
- Modify: `crates/surface/src/lib.rs:31-133` (`View`), near `screen()` at `1371-1378` (`pads_state`)
- Modify: `crates/surface/src/api.rs:1122-1137` (state builder)
- Modify: `apps/viewer/src/main.rs:5330-5424` (`surface_view`)
- Test: `crates/surface/src/tests.rs`, `crates/surface/src/device_tests.rs`

**Interfaces:**
- Consumes: `require("lib.pads")` from the main surface VM (`mode`, `base`, `keys()`, `notes()`); `tests_support::view()`, `press()`, `Surface::new()`.
- Produces: `View.pad_mode: String`, `pad_base: i64`, `pad_keys: bool`, `pad_notes: Vec<i64>`; `Surface::pads_state(&self) -> (String, i64, bool, Vec<i64>)`; `deckard.state()` keys `pad_mode`, `pad_base`, `pad_keys`, `pad_notes`.

- [ ] **Step 1: Write the failing tests**

In `crates/surface/src/tests.rs`:

```rust
#[test]
fn pads_state_follows_the_main_pad_mode() {
    let (mut s, v) = (Surface::new(), view());
    s.tick(&v, Instant::now());
    assert_eq!(s.pads_state().0, "pad");
    press(&mut s, &v, "BUTTON_KEYBOARD");
    let (mode, _, keys, notes) = s.pads_state();
    assert_eq!(mode, "keyboard");
    assert!(keys);
    assert_eq!(notes.len(), 16);
}
```

In `crates/surface/src/device_tests.rs`:

```rust
#[test]
fn pad_state_reaches_device_scripts() {
    let (_tmp, dir) = test_device(r#"
      return { open = function()
        local s = deckard.state()
        deckard.message(table.concat({ s.pad_mode, s.pad_base,
          tostring(s.pad_keys), #s.pad_notes, s.pad_notes[1] }, ":"))
      end }"#);
    let mut d = Device::new("test", Some(dir));
    let mut v = view();
    v.pad_mode = "keyboard".into();
    v.pad_base = 62;
    v.pad_keys = true;
    v.pad_notes = vec![62; 16];

    assert!(d.open(&v, Instant::now()).contains(
        &Out::Message("keyboard:62:true:16:62".into())), "state not visible to the device VM");
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p deckard-surface --lib pads_state_follows_the_main_pad_mode -- --nocapture` then `cargo test -p deckard-surface --lib pad_state_reaches_device_scripts -- --nocapture`
Expected: FAIL — `pads_state` and the state keys don't exist.

- [ ] **Step 3: Add the four fields, accessor and state keys**

- In `crates/surface/src/lib.rs`, add the four documented fields to `View` (all with sensible `Default`: `String::new()`, `60`, `false`, `Vec::new()`).
- Add `pub fn pads_state(&self) -> (String, i64, bool, Vec<i64>)` next to `screen()`, using the same `require("lib.pads")` mechanism; fall back to `("pad".into(), 60, false, Vec::new())` if the VM or table is absent. Read `base` with `Table::get`, and `keys`/`notes` by getting the `Function` and calling it with `()`.
- In `crates/surface/src/api.rs::state()`, set `pad_mode`, `pad_base`, `pad_keys`, and `pad_notes` via `lua.create_sequence_from(v.pad_notes.iter().copied())` just after the `scale` table.
- In `apps/viewer/src/main.rs::surface_view()`, call `self.surface.pads_state()` immediately before `let mut v = View {` (line 5398, an immutable borrow like `self.surface.page()`) and set the four fields inside the literal.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p deckard-surface --lib -- --nocapture`
Expected: PASS (all surface tests, including the new two).

- [ ] **Step 5: Commit**

```bash
git add crates/surface/src/lib.rs crates/surface/src/api.rs \
  crates/surface/src/tests.rs crates/surface/src/device_tests.rs apps/viewer/src/main.rs
git commit -m "feat(surface): expose pad mode and notes in deckard.state()"
```

---

### Task 4: Play SMC presses with the MK3's note logic

**Files:**
- Modify: `apps/viewer/src/mk3_io.rs` (`PadVoices`, `Mk3Io::route`, tests)
- Modify: `apps/viewer/src/main.rs:5129-5138, 5183, 5231-5243, 6749-6773` (`pad_touches`, `pad_route_from_surface`, `Out::Pad` arm)
- Test: `apps/viewer/src/mk3_io.rs` test module (~line 770+)

**Interfaces:**
- Consumes: `Out::Pad` from Task 1; `pad_notes()`, `pad_velocity()`, `Touching::hit_velocity()`, `PadRoute` from `mk3_io.rs`; `Surface::pads(&View)` and `Surface::event(&Event, &View, Instant)`; `Mk3Io::set_route` already called each frame.
- Produces: `mk3_io::PadVoices::{on(pad, &PadRoute, from_pressure) -> Vec<Live>, off(pad) -> Vec<Live>}`; `Mk3Io::route(&self) -> Option<PadRoute>`; `App::pad_touches(group)`, `App::pad_route_from_surface(&View) -> PadRoute`.

- [ ] **Step 1: Write the failing tests**

In the `mk3_io.rs` test module, using its existing `route()` and `keys()` helpers:

```rust
#[test]
fn pad_voices_play_and_release_the_pad_mode_note() {
    let mut voices = PadVoices::default();
    let r = route(PadTouch::default());
    assert_eq!(voices.on(13, &r, 100), vec![Live::NoteOn {
        group: 0, sound: 12, pitch: PAD_PITCH, velocity: 100, length: i64::MAX }]);
    assert_eq!(voices.off(13), vec![Live::NoteRelease { group: 0, sound: 12, pitch: PAD_PITCH }]);
    assert!(voices.off(13).is_empty(), "a second release sends nothing");
}

#[test]
fn pad_voices_play_scale_and_chord_notes() {
    let mut voices = PadVoices::default();
    let mut r = route(PadTouch::default());
    r.keys = Some((3, [60, 62, 64, 65, 67, 69, 71, 72, // pad 9 -> 72
                       74, 76, 77, 79, 81, 83, 84, 86]));
    assert_eq!(voices.on(9, &r, 90), vec![Live::NoteOn {
        group: 0, sound: 3, pitch: 72, velocity: 90, length: i64::MAX }]);

    r.chords = Some(std::array::from_fn(|_| [60, 64, 67, 128, 128, 128, 128, 128,
                                             128, 128, 128, 128, 128, 128, 128, 128]));
    assert_eq!(voices.on(2, &r, 80).len(), 3, "Chords plays every note");
    assert_eq!(voices.off(2).len(), 3, "and releases every note");
}

#[test]
fn pad_voices_release_stops_the_original_notes() {
    let mut voices = PadVoices::default();
    let r = route(PadTouch::default());
    voices.on(4, &r, 100);
    let changed = PadRoute { keys: Some((0, [64; 16])), ..r };
    assert_eq!(voices.off(4), vec![Live::NoteRelease { group: 0, sound: 3, pitch: PAD_PITCH }],
        "a mode change while held must not lose the original note");
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p deckard --bin deckard pad_voices -- --nocapture`
Expected: FAIL — `PadVoices` not found.

- [ ] **Step 3: Add `PadVoices` and the route accessors**

In `apps/viewer/src/mk3_io.rs`:
- Add `#[derive(Default)] pub struct PadVoices { sounding: [Option<(usize, usize, i64)>; 16], chord_rest: [Vec<(usize, usize, i64)>; 16] }`.
- `on`: return `[]` if `!route.play`; use `pad_notes(route, pad)`, take the first `(sound, pitch)`, compute `velocity = Touching::hit_velocity(route, route.group, sound, from_pressure)`, emit one `Live::NoteOn{length:i64::MAX}` per note, store the first in `sounding[pad-1]` and the rest in `chord_rest[pad-1]`.
- `off`: take and clear both slots; emit `NoteRelease` for `chord_rest` first, then `sounding` (same order as the MK3 thread at `mk3_io.rs:605-613`). Do not add pressure/Pad Touch handling.
- Add `pub fn route(&self) -> Option<PadRoute>` to `Mk3Io`, returning the `Copy` route from `Shared` (no new state).
- Leave the MK3 thread loop unchanged.

In `apps/viewer/src/main.rs`:
- Replace the `touches` closure (5129-5138) with `fn pad_touches(&self, group: usize) -> [PadTouch; 16]` containing that body, and update both call sites (5183, 5242). Add `fn pad_route_from_surface(&self, v: &View) -> PadRoute` containing the body currently at 5231-5243 (including the `fixed_velocity` lookup), using `self.surface.pads(v)` and `self.pad_touches(self.group)`; call it from the DECKARD branch of `mk3_events`.
- Add a `smc_voices: mk3_io::PadVoices` field to `App` (Default).
- Replace the placeholder `Out::Pad { .. } => {}` arm in `midi_devices_sync` with: build `deckard_mk3::Event::PadOn(pad, velocity)` / `PadOff(pad)`, call `self.surface.event(&ev, &view, now)`, run each returned `Action` through `self.surface_act(a)`. Then get the route (`self.mk3.as_ref().and_then(mk3_io::Mk3Io::route).unwrap_or_else(|| self.pad_route_from_surface(&view))`), compute `from_pressure` from `velocity` with `mk3_io::pad_velocity(v, route.scaling)` exactly as the MK3 thread does at 599, and apply `voices.on/off`. Send each `Live` with `out.live(l)` when `self.output` has an engine; otherwise use `self.play_note(l)` for `NoteOn` and skip `NoteRelease`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p deckard --bin deckard pad_voices -- --nocapture`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/viewer/src/mk3_io.rs apps/viewer/src/main.rs
git commit -m "feat(viewer): play SMC pad presses through the MK3 pad route"
```

---

### Task 5: Keyboard/chords LED mirror, full redraw, record toggle

**Files:**
- Modify: `crates/surface/lua/devices/mvawe_smc_pad/main.lua:241-260, 388-475, 477-513`
- Test: `crates/surface/src/device_tests.rs`

**Interfaces:**
- Consumes: `View.pad_keys`, `pad_notes`, `pad_base`, `pad_mode`, `scale` from Task 3; `s.redraw`, `s.last`, `redraw_pads()`, `drive_handshake()` from existing SMC code.
- Produces: keyboard/chords branch in `pad_colour`, a state signature in `st.sess.sig`, toggling note 19.

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn smc_pad_note_19_toggles_record() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let mut v = view();
    v.recording = true;
    let out = d.midi("daw", &[0x90, 19, 127], &v, Instant::now());
    assert!(out.contains(&Out::App(Action::Record { on: false, count_in: false })), "{out:?}");
}

#[test]
fn smc_pad_keyboard_mode_redraws_when_state_changes() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let mut v = view();
    v.pad_mode = "keyboard".into();
    v.pad_keys = true;
    v.pad_base = 60;
    v.pad_notes = vec![60, 62, 64, 65, 67, 69, 71, 72, 74, 76, 77, 79, 81, 83, 84, 86];
    let t = Instant::now();
    drive_handshake(&mut d, &v, t, 2, 0, 0, Some(2));

    // A region-5 0x22 write packs with wire byte 3 == 0x09 (identity 0x45, read 0x0D).
    let writes = |out: &[Out]| out.iter().filter(|o| matches!(o,
        Out::Midi { role, bytes } if role == "service" && bytes.len() > 3 && bytes[3] == 0x09)).count();
    // The handshake ends at t+1550 ms and arms the first keepalive for t+2050 ms,
    // so these ticks stay clear of it.
    let t0 = t + Duration::from_millis(1600);
    d.tick(&v, t0); // first ready tick establishes the signature (16 writes)
    assert_eq!(writes(&d.tick(&v, t0 + Duration::from_millis(50))), 0, "settled");

    v.pad_base = 62; // transposition
    assert_eq!(writes(&d.tick(&v, t0 + Duration::from_millis(100))), 16, "full rebuild");
    v.group = 1;
    assert_eq!(writes(&d.tick(&v, t0 + Duration::from_millis(150))), 16, "group change");
    v.sound = 2;
    assert_eq!(writes(&d.tick(&v, t0 + Duration::from_millis(200))), 16, "focused sound");
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p deckard-surface --lib smc_pad_note_19_toggles_record -- --nocapture` then `cargo test -p deckard-surface --lib smc_pad_keyboard_mode_redraws_when_state_changes -- --nocapture`
Expected: FAIL — note 19 forces `on: true`; transposition only changes 2 pads per tick.

- [ ] **Step 3: Implement the LED and transport changes**

In `main.lua`:
- At the top of `pad_colour(i, v)`, add a `v.pad_keys` branch: get `v.groups[v.group].sounds[v.sound]`; if missing return black; pick `v.pad_notes[i]`; bright when `deckard.pad_held(i)` or (`note < 128` and `note % 12 == v.pad_base % 12`); use the focused sound's `color` (or `EMPTY_SLOT`) with factor `1`/`DIM`, clamped 0..255. Mirror `global.lua:581-586`: no playing-mix in this mode.
- In `M.midi`'s DAW note branch, change `REC` from `deckard.record(true, false)` to `deckard.record(not deckard.state().recording, false)`.
- In `M.tick`'s `ready` branch, before `drive_buttons()`, build a signature string from `v.group`, `v.sound`, `v.scale.root/bank/kind`, `v.pad_mode`, `v.pad_base`, `v.pad_keys` and the joined `v.pad_notes`. When it differs from `st.sess.sig`, store it, clear `s.last` and set `s.redraw = true` so the existing `redraw_pads()` call writes all 16 pads.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p deckard-surface --lib smc_pad_ -- --nocapture`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/surface/lua/devices/mvawe_smc_pad/main.lua crates/surface/src/device_tests.rs
git commit -m "feat(smc-pad): mirror keyboard LEDs and toggle record"
```

---

### Task 6: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Run the whole test suite**

Run: `cargo test --workspace`
Expected: EXIT 0.

- [ ] **Step 2: Build the release binary**

Run: `cargo build -p deckard --release`
Expected: success; note the path and SHA-256 of `target/release/deckard` for handoff.

- [ ] **Step 3: Hand off for hardware verification**

Report the binary path/hash and list what still needs real hardware: pad press → correct sound/LED in all four blocks, Pad/Keyboard/Chords modes, group/mode/transposition redraw, and transport LEDs. Do not push, merge or open a PR.
