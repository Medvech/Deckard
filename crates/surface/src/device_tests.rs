use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::Action;
use crate::device::{Device, Out, Print, PrintedNote, devices};
use crate::tests_support::view;

/// A fresh user folder with device `test`: its manifest and `main.lua`. The guard
/// removes it when dropped.
fn test_device(main: &str) -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().to_path_buf();
    std::fs::create_dir_all(dir.join("devices/test")).unwrap();
    std::fs::write(
        dir.join("devices/test/device.lua"),
        r#"return { name = "Test", ports = { daw = { "Test DAW" } }, exclusive = { "daw" } }"#,
    )
    .unwrap();
    std::fs::write(dir.join("devices/test/main.lua"), main).unwrap();
    (tmp, dir)
}

fn midi(role: &str, bytes: &[u8]) -> Out {
    Out::Midi { role: role.into(), bytes: bytes.to_vec() }
}

fn hex(s: &str) -> Vec<u8> {
    s.split_whitespace().map(|b| u8::from_str_radix(b, 16).unwrap()).collect()
}

const IDENTITY_QUERY: &str = "F0 00 32 45 00 00 00 40 7F F7";
const STATE_READ: &str = "F0 00 32 0D 41 00 00 00 02 00 00 00 00 40 01 00 00 6F 01 F7";
const IDENTITY_REPLY: &str =
    "F0 00 32 45 58 01 00 40 29 4D 06 35 01 15 08 51 2F 30 60 4C \
     01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0A F7";
// Captured state block: bank 2, slot 0, toggle 0.
#[allow(dead_code)]
const STATE_REPLY: &str =
    "F0 00 32 0D 21 01 00 00 02 00 00 00 00 0C 00 00 78 00 32 04 \
     00 00 02 00 01 01 00 00 3D F7";

/// The SINCO 8→7 transport: an LSB-first accumulator, wrapped in F0 … F7.
fn pack7(data: &[u8]) -> Vec<u8> {
    let mut out = vec![0xF0];
    let mut acc = 0u32;
    let mut bits = 0u32;
    for &b in data {
        acc |= u32::from(b) << bits;
        bits += 8;
        while bits >= 7 {
            out.push((acc & 0x7F) as u8);
            acc >>= 7;
            bits -= 7;
        }
    }
    if bits > 0 {
        out.push((acc & 0x7F) as u8);
    }
    out.push(0xF7);
    out
}

/// Independent encoder for logical `00 59 cmd len24 payload ~sum(payload)` replies.
fn sync_reply(cmd: u8, payload: &[u8]) -> Vec<u8> {
    let len = payload.len() as u32;
    let mut logical = vec![0x00, 0x59, cmd];
    logical.extend_from_slice(&len.to_le_bytes()[..3]);
    logical.extend_from_slice(payload);
    let sum: u32 = payload.iter().map(|&b| u32::from(b)).sum();
    logical.push(!sum as u8);
    pack7(&logical)
}

/// Region-4 state block: the 12 data bytes carry bank at 6, slot at 10, toggle at 11.
fn state_reply(bank: u8, slot: u8, toggle: u8) -> Vec<u8> {
    sync_reply(
        0x23,
        &[4, 0, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, bank, 0, 0, 0, slot, toggle],
    )
}

/// Live region-5 image: unarmed button bytes everywhere, plus one 36..51 note run
/// and known RGBs in slot 0, bank 2 when `notes` is set.
fn config_image(notes: bool) -> Vec<u8> {
    let mut img = vec![0u8; 8 * 3539];
    for slot in 0..8 {
        for index in 0..5 {
            img[slot * 3539 + index * 23 + 22] = 0xFF;
        }
    }
    if notes {
        for r in 0..16 {
            let at = 211 + 2 * 16 * 26 + r * 26;
            img[at + 2] = 36 + r as u8;
            img[at + 5..at + 8].copy_from_slice(&[10, 20, 30]);
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

/// Drive the full service handshake: identity, region-4 state, 29 region-5 reads.
/// Every `Out` is returned so callers can inspect requests and status messages.
fn drive_handshake(d: &mut Device, v: &crate::View, t: Instant, bank: u8, slot: u8, toggle: u8, notes: bool) -> Vec<Out> {
    let mut out = d.open(v, t);
    out.extend(d.tick(v, t));
    let t50 = t + Duration::from_millis(50);
    out.extend(d.midi("service", &hex(IDENTITY_REPLY), v, t50));
    out.extend(d.tick(v, t50));
    out.extend(d.midi("service", &state_reply(bank, slot, toggle), v, t + Duration::from_millis(100)));

    let image = config_image(notes);
    for i in 0..29usize {
        let now = t + Duration::from_millis(100 + 50 * i as u64);
        let tick = d.tick(v, now);
        let reads: Vec<&Out> = tick.iter().filter(|o| matches!(o, Out::Midi { role, .. } if role == "service")).collect();
        assert_eq!(reads.len(), 1, "one config request per tick ({i}): {tick:?}");
        out.extend(tick);
        let addr: usize = i * 1009;
        let len: usize = if i < 28 { 1009 } else { 60 };
        out.extend(d.midi("service", &config_reply(addr, &image[addr..addr + len]), v, now));
    }
    out
}

#[test]
fn a_device_manifest_is_found() {
    let (_tmp, dir) = test_device("return {}");
    let found = devices(Some(&dir));
    let t = found.iter().find(|d| d.id == "test").expect("the test device");
    assert_eq!(t.name, "Test");
    assert_eq!(t.ports, [("daw".to_string(), vec!["Test DAW".to_string()])]);
    assert_eq!(t.exclusive, ["daw"]);
    assert!(found.iter().all(|d| d.id != "mk3"));
}

#[test]
fn midi_in_reaches_the_script_and_sends_back() {
    let (_tmp, dir) = test_device("return { midi = function(role, b) deckard.midi_send(role, { 0x90, b[2], 5 }) end }");
    let mut d = Device::new("test", Some(dir));
    assert_eq!(d.error(), None);
    assert_eq!(d.midi("daw", &[0x90, 11, 127], &view(), Instant::now()), [midi("daw", &[0x90, 11, 5])]);
}

#[test]
fn open_and_close_run() {
    let (_tmp, dir) = test_device(
        "return { open = function() deckard.midi_send('daw', { 0xF0, 0, 0x20, 0x29, 2, 0x0E, 0x10, 1, 0xF7 }) end,
                  close = function() deckard.midi_send('daw', { 0xF0, 0, 0x20, 0x29, 2, 0x0E, 0x10, 0, 0xF7 }) end }",
    );
    let mut d = Device::new("test", Some(dir));
    assert_eq!(d.open(&view(), Instant::now()), [midi("daw", &[0xF0, 0, 0x20, 0x29, 2, 0x0E, 0x10, 1, 0xF7])]);
    assert_eq!(d.close(), [midi("daw", &[0xF0, 0, 0x20, 0x29, 2, 0x0E, 0x10, 0, 0xF7])]);
}

#[test]
fn a_device_never_loads_mk3_pages() {
    let (_tmp, dir) = test_device(
        "return { open = function()
             deckard.message(tostring(pcall(require, 'pages.control')) .. ' ' .. tostring(pcall(require, 'lib.util')))
         end }",
    );
    let mut d = Device::new("test", Some(dir));
    assert_eq!(d.open(&view(), Instant::now()), [Out::Message("false true".into())]);
}

#[test]
fn launch_and_print_actions() {
    let (_tmp, dir) = test_device(
        "return { tick = function()
             deckard.launch_scene(2)
             deckard.print_notes { length = 4, notes = { { 60, 0.5, 0.25, 100 } } }
         end }",
    );
    let mut d = Device::new("test", Some(dir));
    let out = d.tick(&view(), Instant::now());
    assert!(out.contains(&Out::App(Action::LaunchScene(1))), "{out:?}");
    assert!(
        out.contains(&Out::Print(Print {
            length: 4.0,
            notes: vec![PrintedNote { pitch: 60, start: 0.5, length: 0.25, velocity: 100 }],
            track: None,
            device: "test".into(),
        })),
        "{out:?}"
    );
}

#[test]
fn the_device_sees_the_view() {
    let (_tmp, dir) =
        test_device("return { tick = function() deckard.message(deckard.state().groups[2].name .. ' ' .. deckard.device()) end }");
    let mut d = Device::new("test", Some(dir));
    assert_eq!(d.tick(&view(), Instant::now()), [Out::Message("Bass test".into())]);
}

#[test]
fn a_failing_device_script_reports_and_keeps_the_last() {
    let (_tmp, dir) = test_device("return { tick = function() deckard.message('old') end }");
    let mut d = Device::new("test", Some(dir.clone()));
    std::fs::write(dir.join("devices/test/main.lua"), "return { tick = function( end }").unwrap();
    assert!(!d.reload());
    assert!(d.error().is_some());
    assert_eq!(d.tick(&view(), Instant::now()), [Out::Message("old".into())]);
}

#[test]
fn a_runtime_error_is_reported() {
    let (_tmp, dir) = test_device("return { midi = function() error('boom') end }");
    let mut d = Device::new("test", Some(dir));
    assert_eq!(d.midi("daw", &[0x90, 1, 1], &view(), Instant::now()), []);
    assert!(d.error().is_some_and(|e| e.contains("boom")), "{:?}", d.error());
}

#[test]
fn only_the_devices_own_files_reload_it() {
    let (_tmp, dir) = test_device("return { open = function() deckard.message('opened') end }");
    let mut d = Device::new("test", Some(dir.clone()));
    d.open(&view(), Instant::now());
    std::fs::create_dir_all(dir.join("pages")).unwrap();
    std::fs::write(dir.join("pages/control.lua"), "return {}").unwrap();
    assert!(!d.reload(), "an MK3 page isn't the device's");
    std::fs::create_dir_all(dir.join("lib")).unwrap();
    std::fs::write(dir.join("lib/mine.lua"), "return {}").unwrap();
    assert!(d.reload(), "lib/ is shared");
}

#[test]
fn mvawe_smc_pad_knobs_turn_the_mk3_knobs() {
    let mut d = Device::new("mvawe_smc_pad", None);
    assert_eq!(d.error(), None);
    let v = view();
    let out = d.midi("midi", &[0xB0, 36, 70], &v, Instant::now());
    assert!(!out.iter().any(|o| matches!(o, Out::App(Action::Turn { .. }))), "{out:?}");
    let out = d.midi("midi", &[0xB0, 36, 71], &v, Instant::now());
    assert!(out.contains(&Out::App(Action::Turn { knob: 0, inc: 1.0 / 127.0, fine: false })), "{out:?}");
    let out = d.midi("midi", &[0xB0, 36, 70], &v, Instant::now());
    assert!(!out.iter().any(|o| matches!(o, Out::App(Action::Turn { .. }))), "one back is flicker");
    let out = d.midi("midi", &[0xB0, 36, 69], &v, Instant::now());
    assert!(out.contains(&Out::App(Action::Turn { knob: 0, inc: -2.0 / 127.0, fine: false })), "{out:?}");

    let out = d.midi("daw", &[0x90, 17, 127], &v, Instant::now());
    assert!(out.contains(&Out::App(Action::Play)), "{out:?}");
    let out = d.midi("daw", &[0x90, 18, 127], &v, Instant::now());
    assert!(out.contains(&Out::App(Action::Stop)), "{out:?}");
    let out = d.midi("daw", &[0x90, 19, 127], &v, Instant::now());
    assert!(out.contains(&Out::App(Action::Record { on: true, count_in: false })), "{out:?}");
}

#[test]
fn mvawe_smc_pad_play_cc_toggles_transport() {
    let mut d = Device::new("mvawe_smc_pad", None);
    assert_eq!(d.error(), None);
    let v = view();
    // The Play button is configured as CC 27 (127 press, 0 release), on either port.
    for role in ["midi", "daw"] {
        let out = d.midi(role, &[0xB0, 27, 127], &v, Instant::now());
        assert!(out.contains(&Out::App(Action::Play)), "{role}: {out:?}");
        assert!(out.contains(&midi(role, &[0xB0, 27, 127])), "LED feedback: {role}: {out:?}");
        let out = d.midi(role, &[0xB0, 27, 0], &v, Instant::now());
        assert!(!out.iter().any(|o| matches!(o, Out::App(Action::Play | Action::Stop))), "{role}: {out:?}");
    }
    // MK3's PLAY toggles: pressing again while playing stops.
    let mut playing = view();
    playing.playing = true;
    let out = d.midi("midi", &[0xB0, 27, 127], &playing, Instant::now());
    assert!(out.contains(&Out::App(Action::Stop)), "{out:?}");
}

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

#[test]
fn smc_pad_service_reads_config_and_reports_ready() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    let t = Instant::now();
    let out = drive_handshake(&mut d, &v, t, 2, 0, 0, true);
    // Reads have wire byte 3 = 0x45 (identity) or 0x0D (0x23); the five button
    // arm writes added in Task 4 use 0x09 and must not be counted here.
    let reqs: Vec<Vec<u8>> = out
        .iter()
        .filter_map(|o| match o {
            Out::Midi { role, bytes } if role == "service" && (bytes[3] == 0x0D || bytes[3] == 0x45) => Some(bytes.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(reqs.len(), 31, "identity + state + 29 config reads");
    assert_eq!(reqs[0], hex("F0 00 32 45 00 00 00 40 7F F7"));
    assert_eq!(reqs[1], hex("F0 00 32 0D 41 00 00 00 02 00 00 00 00 40 01 00 00 6F 01 F7"));
    assert_eq!(reqs[2], hex("F0 00 32 0D 41 00 00 40 02 00 00 00 00 10 7E 00 00 06 00 F7"));
    assert_eq!(reqs[30], hex("F0 00 32 0D 41 00 00 40 02 5C 5C 01 00 40 07 00 00 74 01 F7"));
    // The ready message comes from the `midi` call that delivered the last chunk.
    assert!(
        out.iter().any(|o| matches!(o, Out::Message(m) if m.contains("ready") && m.contains("bank=2") && m.contains("slot=0"))),
        "{out:?}"
    );
    // Ready sends the keep-alive state read, not another config read.
    let keep = d.tick(&v, t + Duration::from_secs(3));
    assert!(
        keep.contains(&midi("service", &hex("F0 00 32 0D 41 00 00 00 02 00 00 00 00 40 01 00 00 6F 01 F7"))),
        "{keep:?}"
    );
}

#[test]
fn smc_pad_service_rebuilds_map_on_bank_toggle() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    let t = Instant::now();
    drive_handshake(&mut d, &v, t, 2, 0, 0, true);

    // A keep-alive request must be outstanding before its reply is accepted.
    let keep = d.tick(&v, t + Duration::from_millis(2100));
    assert!(keep.contains(&midi("service", &hex(STATE_READ))), "{keep:?}");

    let out = d.midi("service", &state_reply(2, 0, 1), &v, t + Duration::from_millis(2150));
    assert!(out.iter().any(|o| matches!(o, Out::Message(m) if m.contains("bank=7"))), "{out:?}");

    // Pad 1 now lives in bank 7, record 12 at 0xD70, and is redrawn.
    let out = d.tick(&v, t + Duration::from_millis(2200));
    assert!(
        out.contains(&midi("service", &hex("F0 00 32 09 59 00 00 40 02 70 1A 00 00 30 00 00 00 7F 05 79 59 0F F7"))),
        "{out:?}"
    );
}

#[test]
fn smc_pad_service_falls_back_when_notes_differ() {
    let mut d = Device::new("mvawe_smc_pad", None);
    let v = view();
    let t = Instant::now();
    let out = drive_handshake(&mut d, &v, t, 2, 0, 0, false);
    // No bank carries a 36..51 note run: the state-derived bank stays in use.
    assert!(
        out.iter().any(|o| matches!(o, Out::Message(m) if m.contains("ready") && m.contains("bank=2"))),
        "{out:?}"
    );
}

#[test]
fn smc_pad_service_ignores_a_wrong_address_config_reply() {
    let mut d = Device::new("mvawe_smc_pad", None);
    assert_eq!(d.error(), None);
    let v = view();
    let t = Instant::now();
    assert_eq!(d.tick(&v, t), [midi("service", &hex(IDENTITY_QUERY))]);
    d.midi("service", &hex(IDENTITY_REPLY), &v, t + Duration::from_millis(50));
    assert_eq!(d.tick(&v, t + Duration::from_millis(50)), [midi("service", &hex(STATE_READ))]);
    d.midi("service", &state_reply(2, 0, 0), &v, t + Duration::from_millis(100));
    let first = hex("F0 00 32 0D 41 00 00 40 02 00 00 00 00 10 7E 00 00 06 00 F7");
    assert_eq!(d.tick(&v, t + Duration::from_millis(100)), [midi("service", &first)]);

    d.midi("service", &config_reply(999, &[0; 1009]), &v, t + Duration::from_millis(150));
    assert_eq!(
        d.tick(&v, t + Duration::from_millis(200)),
        [midi("service", &first)],
        "the bad reply didn't advance chunk 0"
    );
}
