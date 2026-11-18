-- M-Vave SMC-PAD, measured by SDR3078/mvave-smc-pad-ableton:
-- ports 1/2 carry the encoders and MIDI-typed pads (no LEDs); port 3 is the DAW
-- ("Mackie") port with MCP-typed pads/buttons and the pad LEDs.
return {
  name = "M-Vave SMC Pad",
  ports = {
    midi = { "SMC-PAD-Virtual-Master", "SMC-PAD-Master", "MIDIIN1", "MIDIIN2", "MIDIOUT1", "MIDIOUT2" },
    daw = { "SMC-PAD-Virtual-DAW", "Порт 3", "Port 3", "SMC-PAD 2", "MIDIIN3", "MIDIOUT3" },
    -- Only the Private port answers service SysEx.
    service = { "SMC-PAD-Private", "SMC-PAD-Virtual-Private" },
  },
  -- Port 3's notes are buttons, the Private port is the service session, and the
  -- Master port's pad notes are read by the script and played through the app's
  -- pad route (as the MK3's are), not by DECKARD's drum channel.
  exclusive = { "daw", "service", "midi" },
}