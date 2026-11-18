# SMC-PAD: input remap, MK3-style redraw and press registration — design

Date: 2026-11-18
Branch: `feature/mvawe-smc-pad`

## Intent

The SMC-PAD's SysEx LED mirror (previous work) lights the right physical pads for the
focused Deckard group, but four things still don't behave like the MK3:

1. **Pad numbering on input.** The LED table maps Deckard pad *i* → SMC pad
   `PAD_NUMBER[i] = {13,14,15,16, 9,10,11,12, 5,6,7,8, 1,2,3,4}` — i.e. SMC 13–16 →
   Deckard 1–4, 9–12 → 5–8, 5–8 → 9–12, 1–4 → 13–16. (The request said "13-15" for
   the last group; treated as "13-16" so all 16 pads are covered and the LED table stays
   unchanged.) But incoming Master-port notes go straight through the engine's
   drum-channel mapper (note 36 → pad 1), so pressing SMC pad 13 plays Deckard sound 13
   while lighting pad 13 — LEDs and sound disagree.
2. **Redraw on state changes.** Group, pad-mode or keyboard-transposition changes must
   refresh the SMC LEDs promptly, as they do on the MK3.
3. **Press registration in the current mode.** SMC presses must reach the main surface
   layer's handlers and play what the MK3 plays in the current mode: pad sounds in Pad
   mode, scale notes in Keyboard mode, chord notes in Chords mode, and step editing in
   Step mode.
4. **Transport button state.** LEFT/RIGHT/PLAY/STOP/REC must follow Deckard state like
   the MK3's; one gap remains (DAW note 19 always records instead of toggling).

The human partner chose **full MK3 parity for note generation** — item 3 is not just
"fire a surface event"; in Keyboard/Chords modes the SMC pads must play the same
scale/chord notes the MK3 plays.

## Goals

- Pressing SMC pad *p* lights and plays Deckard pad `PAD_NUMBER[p]`: pad 13 plays and
  lights sound 1, pad 9 → 5, pad 5 → 9, pad 1 → 13.
- A press plays what the current mode says, via the same `PadRoute` logic the MK3 uses:
  - Pad mode: the pad's sound at C3 (pitch 60), from the focused group.
  - Keyboard mode: the focused sound at the pad's scale note.
  - Chords mode: the focused sound at the pad's chord notes (all notes of the chord).
- A press also reaches `Surface::event()` as `PadOn/PadOff`, so held state, focus-on-press,
  SHIFT-pad shortcuts and the shown page's `pad()`/`pad_off()` handlers run (step
  editing, erase, SELECT/MUTE/SOLO, etc.).
- Pad mode, keyboard base and scale notes are exposed in `deckard.state()` so the SMC
  script can mirror keyboard/chords LED colours and force an immediate full redraw when
  group, mode, transposition or focused sound changes.
- The five transport LEDs keep following `playing`, `recording` and page bounds; note 19
  toggles record like the CC path and MK3.

## Non-goals

- No change to the SysEx service session, pad RGB addresses or the `PAD_NUMBER` LED
  table.
- No rewrite of the SMC's stored pad-record notes; the remap lives in Deckard.
- No pressure / poly-aftertouch support for the SMC (plain note on/off only).
- No change to how the MK3 or JAM play, and no attempt to make SMC and MK3 share held
  state when both are connected at once (the SMC is a standalone/second surface; each
  controller's press path stays independent).
- No change to which SMC ports are exclusive or to the `drums` port selection.

## Constraints / facts

- The device VM and main surface VM are separate Lua states (`device.rs:339-363`,
  `sources.rs:78-80,92-97`). Device scripts see `deckard.state()` and the device-only
  API (`device.rs:480-529`); they cannot read the main VM's `pads` module or call
  `deckard.led`.
- `Surface::event()` (`lib.rs:1388-1433`) sets `pads[pad-1]` and dispatches to the shown
  page then `global.lua`. It does **not** play sounds.
- MK3 note generation lives in `mk3_io.rs`: `PadRoute` (`:15-34`), `pad_notes(route,pad)`
  (`:290-297`), `Touching::hit_velocity` (`:124-130`), and the thread loop (`:590-646`)
  that emits `Live::NoteOn`/`NoteRelease` and tracks held notes/chord rests. That thread
  only runs while MK3 **hardware** is connected (`boot.rs:274-279`, `mk3_io.rs:437-445`),
  so the SMC path cannot simply inject events into it.
- The pure pieces (`pad_notes`, `pad_velocity`, `PadRoute`) are reusable without hardware.
- `MidiTable::route_note()` drum branch (`engine/src/midi.rs:223-231`) maps notes
  C1(36)..51 on the configured drum channel to focused-group sounds 1..16 by `note-36`;
  this is the SMC's current playback path and produces pitch 60 regardless of mode.
- `deckard.state()` is built from the app's `View` (`api.rs:1120-1154`), filled each frame
  by `surface_view()` (`main.rs:5330`). `Surface::screen()` already reads `pads.mode`
  from the main VM (`lib.rs:1373-1378`).
- `global.lua:581` keys its LED logic on `pads.keys()` (Keyboard/Chords only, not
  step-with-keyboard); `pads.notes()` always returns 16 values, so the state must say
  explicitly whether they apply.
- `Out` variants are consumed in `midi_devices_sync()` (`main.rs:6766-6773`).

## Approaches

1. **Full bridge + shared note generation (chosen).** Add a device→app pad event, expose
   pad state in `deckard.state()`, and give the SMC press path the same `PadRoute`-based
   note generation the MK3 uses (reusing the pure helpers, with its own held-note
   tracking on the UI thread). True MK3 parity, no preset changes. Touches surface,
   engine, viewer and Lua.
2. **SysEx note rewrite.** Rewrite the SMC's pad-record notes so hardware sends
   Deckard-ordered notes. Doesn't modify which notes play in Keyboard/Chords, still
   can't register presses with the surface layer, and a crash leaves the RAM preset
   remapped. Rejected.
3. **Remap only, surface event only.** What the earlier draft proposed: remap the drum
   note and fire `Surface::event()`, but keep engine playback at pitch 60. Fails the
   human partner's explicit choice of full Keyboard/Chords parity. Rejected.

Approach 1 was chosen by the human partner.

## Design

### Part A — Pad press bridge (device VM → app)

**`crates/surface/src/device.rs`**
- Add `Out::Pad { pad: usize, down: bool, velocity: f64 }` to `Out`.
- In the device-only `install()`, add `deckard.pad(pad, down, velocity)`:
  - validate `pad` in 1..=16;
  - set the device VM's `shared.pads[pad-1] = down`, so `deckard.pad_held(i)` reflects
    SMC presses immediately;
  - push `Out::Pad { pad, down, velocity }` (velocity = note velocity / 127).

**`crates/surface/lua/devices/mvawe_smc_pad/main.lua` (`M.midi`)**
- On the `midi` role, note-on (0x90, vel>0) or note-off (0x80 / 0x90 vel 0) with note
  36..51: `p = note - 35` (SMC pad 1..16); call
  `deckard.pad(PAD_NUMBER[p], down, velocity/127)`.
- Keep CC 25–29, encoders and DAW notes 17–21 unchanged; DAW notes 1–16 stay ignored.

### Part B — Mode-aware note generation for SMC presses

The MK3's note-generation thread is hardware-bound, so the SMC press path reproduces
its behaviour on the UI thread from the same reusable pieces.

**`apps/viewer/src/mk3_io.rs`**
- Extract the "play a hit / release a pad" behaviour from the MK3 thread loop
  (`:590-646`) into a small reusable helper, e.g. `PadVoices`, holding
  `sounding: [Option<(group,sound,pitch)>;16]` and `chord_rest`, with methods that take
  a `&PadRoute` and return `Vec<Live>` (NoteOn for a hit, NoteRelease for a release),
  applying `pad_velocity` and `Touching::hit_velocity`. The MK3 thread uses it too, so
  there is one implementation of "what a pad hit plays" shared by both controllers.
  (If a full extract is too invasive, a first cut may reuse `pad_notes()` +
  `pad_velocity` directly in the app with equivalent held-note tracking; the builder
  decides based on what the code allows.)

**`apps/viewer/src/main.rs` (`midi_devices_sync`)**
- On `Out::Pad`:
  1. `self.surface.event(&Event::PadOn/PadOff, &view, now)` → execute returned Actions
     via `surface_act` (focus, step editing, shortcuts, held state in main VM).
  2. Play the note(s): with the current `PadRoute` (the same one `mk3_events()` computes
     each frame — reuse `self.surface.pads()`/`outputs()` for keys/chords when no NI
     controller), call the shared hit/release helper and send the `Live` events to the
     engine. Track held notes per pad so a release stops exactly what the hit started,
     even if the mode changed while held.
  3. If the engine isn't running, queue the notes the same way the MK3/JAM do
     (`Mk3Io::pending` / `take_pending`).
- Keep `Out::Midi` handling unchanged.

**Engine drum path:** with note generation moved to the shared route for SMC presses,
the Master-port notes must no longer also play through `MidiTable`'s drum branch (or
they'll double-play). The SMC's `drums` entry is removed from the manifest / the drum
channel is left unset for SMC, and the app plays SMC pads solely through Part B. MK3/JAM
are unaffected.

### Part C — Pad state in `deckard.state()` (main VM → device VM)

**`crates/surface/src/lib.rs` (`View`, `Surface`)**
- Add to `View`: `pad_mode: String`, `pad_base: i64`, `pad_keys: bool`, `pad_notes: Vec<i64>`
  (16 entries, meaningful only when `pad_keys` is true).
- Add `Surface::pads_state(&self) -> (String, i64, bool, Vec<i64>)` reading `lib.pads`'s
  `mode`, `base`, `keys()` and `notes()` from the main VM (same mechanism as `screen()`).

**`apps/viewer/src/main.rs` (`surface_view`)**
- Fill the four new `View` fields from `self.surface.pads_state()`.

**`crates/surface/src/api.rs`**
- Expose `s.pad_mode`, `s.pad_base`, `s.pad_keys`, `s.pad_notes` in `deckard.state()`.

**`crates/surface/lua/devices/mvawe_smc_pad/main.lua`**
- Extend `pad_colour(i, v)` to mirror `global.lua:577-603` exactly:
  - when `v.pad_keys` is true, use the focused sound's palette on all pads with the
    root pad (`v.pad_notes[i] % 12 == v.pad_base % 12`) at full brightness, others dim;
  - otherwise keep the existing pad-mode colour logic.
  - Held pads (from Part A) stay full brightness. `step-with-keyboard` follows MK3's
    `pads.keys()` predicate (LEDs stay pad-mode), matching `global.lua:581`.
- Track a signature `(v.group, v.sound, v.scale.bank, v.scale.kind, v.pad_mode,
  v.pad_base)`; on change set `s.redraw = true` for an all-16 rebuild instead of the
  2-per-tick mirror. This covers group, mode, transposition, focused sound and scale.

### Part D — Transport button fix

- In `M.midi`'s DAW note handler, change note 19 to toggle record from
  `deckard.state().recording`, matching the CC path and MK3.
- `drive_buttons()` already mirrors PLAY/STOP/REC/LEFT/RIGHT; no change.

### Files touched

- `crates/surface/src/device.rs` — `Out::Pad`, Lua `deckard.pad`.
- `crates/surface/src/lib.rs` — `View` fields, `Surface::pads_state`.
- `crates/surface/src/api.rs` — new state fields.
- `apps/viewer/src/mk3_io.rs` — reusable pad-voice helper.
- `apps/viewer/src/main.rs` — bridge routing + note generation, `surface_view`, drum path.
- `crates/surface/lua/devices/mvawe_smc_pad/device.lua` — remove/neutralise `drums`.
- `crates/surface/lua/devices/mvawe_smc_pad/main.lua` — press handling, colour mirror,
  redraw signature, note-19 toggle.
- `crates/surface/src/device_tests.rs`, `apps/viewer/src/*tests.rs` — coverage.

## Testing

- `device_tests.rs`: `deckard.pad(13, true, 1.0)` yields `Out::Pad` and sets
  `pad_held(13)`; the SMC script turns note 48 into `Out::Pad{pad=1,down=true,v=48/127}`;
  note-off clears it.
- Viewer: `Out::Pad` in Pad mode emits `Live::NoteOn{sound 0, pitch 60}` for SMC pad 13;
  with a Keyboard `PadRoute` it emits the mapped scale pitch; with Chords it emits every
  chord note; a release stops exactly those notes; a mode change while held still
  releases the original notes.
- SMC end-to-end: after handshake, `pad_colour` output changes when group, mode,
  `pad_base`, focused sound or scale changes, with an all-16 rebuild; note 19 toggles
  record.
- Regression: existing SMC handshake/colour/button/restore tests, MK3 pad-routing and
  JAM tests still pass.

## Left to the builder

- Exact shape of the reusable pad-voice helper (full extract vs. reuse `pad_notes()`
  directly), based on what compiles cleanly.
- Where the current `PadRoute` is kept for `midi_devices_sync` (recompute from
  `surface.pads()` vs. cache the frame's route).
- Whether "remove `drums`" is done in the manifest or by leaving the drum channel unset
  for SMC; ensure Preferences still behaves sensibly.
- Constant names, struct/tuple choices and test-helper placement follow surrounding code.
