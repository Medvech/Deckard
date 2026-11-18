-- M-Vave SMC-PAD, mapped to DECKARD's MK3 controls.
-- Measured MIDI: docs/HARDWARE.md in SDR3078/mvave-smc-pad-ableton.
-- Encoders are on ports 1/2, relative CCs (63 = -1, 65 = +1).
-- Transport and pads are on port 3 (notes 17-21, 1-16); buttons are not notes
-- to play (the manifest declares that port exclusive).

local M = {}

local PLAY, STOP, REC = 17, 18, 19
local LEFT, RIGHT = 20, 21
local GREEN, RED, BLUE, OFF = 5, 14, 21, 0

-- Service session on the Private port: 00 59 | cmd | len24 LE | payload | ~sum,
-- packed LSB-first 8→7 into one F0 … F7. Everything is driven from tick().
local LOGO = { 0x00, 0x59 }
local QUERY, READ, WRITE = 0x11, 0x23, 0x22
local RETRY, TIMEOUT, KEEPALIVE = 0.04, 5.0, 0.5

local st = { sess = { state = "query", sent = 0, next_at = 0 } }

local function logical(cmd, payload)
  local n = #payload
  local pkt = { LOGO[1], LOGO[2], cmd, n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF }
  local sum = 0
  for i = 1, n do
    local b = payload[i]
    pkt[6 + i] = b
    sum = (sum + b) & 0xFF
  end
  pkt[7 + n] = (~sum) & 0xFF
  return pkt
end

local function pack7(bytes)
  local out = { 0xF0 }
  local acc, bits = 0, 0
  for i = 1, #bytes do
    acc = acc | (bytes[i] << bits)
    bits = bits + 8
    while bits >= 7 do
      out[#out + 1] = acc & 0x7F
      acc = acc >> 7
      bits = bits - 7
    end
  end
  if bits > 0 then out[#out + 1] = acc & 0x7F end
  out[#out + 1] = 0xF7
  return out
end

local function unpack7(sysex)
  local out = {}
  local acc, bits = 0, 0
  local first, last = 1, #sysex
  if sysex[first] == 0xF0 then first = first + 1 end
  if sysex[last] == 0xF7 then last = last - 1 end
  for i = first, last do
    acc = acc | ((sysex[i] & 0x7F) << bits)
    bits = bits + 7
    while bits >= 8 do
      out[#out + 1] = acc & 0xFF
      acc = acc >> 8
      bits = bits - 8
    end
  end
  return out
end

-- Returns cmd, payload, true; nil for bad framing, short length or checksum.
local function parse_reply(bytes)
  if #bytes < 7 or bytes[1] ~= LOGO[1] or bytes[2] ~= LOGO[2] then return nil end
  local n = bytes[4] | (bytes[5] << 8) | (bytes[6] << 16)
  if #bytes < 7 + n then return nil end
  local payload, sum = {}, 0
  for i = 1, n do
    local b = bytes[6 + i]
    payload[i] = b
    sum = (sum + b) & 0xFF
  end
  if bytes[7 + n] ~= (~sum) & 0xFF then return nil end
  return bytes[3], payload, true
end

-- Encoders 1..8, in physical order, bank 1 and bank 2.
-- Measured on hardware: knob 1 sends CC 36 with values moving 70/71, not 63/65.
-- The eight encoders are the descending CC run 36..29.
local CC = {
  [36] = 1, [37] = 2, [34] = 3, [35] = 4, [32] = 5, [33] = 6, [30] = 7, [31] = 8,
}
local prev, dir, back = {}, {}, {}

local function send_request(kind)
  local s = st.sess
  local bytes, pending
  if kind == "query" then
    bytes = pack7(logical(QUERY, {}))
    pending = { kind = "query", cmd = QUERY }
  elseif kind == "state" then
    bytes = pack7(logical(READ, { 4, 0, 0, 0, 0, 12, 0, 0 }))
    pending = { kind = "state", cmd = READ, region = 4, addr = 0, len = 12 }
  else
    return
  end
  local now = deckard.now()
  s.pending = pending
  s.sent = now
  s.next_at = now + RETRY
  deckard.midi_send("service", bytes)
end

local function service_reply(bytes)
  -- Parsing must never throw out of a MIDI handler and stall the session.
  local ok, cmd, payload = pcall(function() return parse_reply(unpack7(bytes)) end)
  if not ok or not cmd or not payload then return end
  local s = st.sess
  local pending = s.pending
  if not pending then return end
  if cmd == QUERY and pending.kind == "query" then
    s.pending = nil
    s.state = "state"
  elseif cmd == READ and pending.kind == "state" then
    if #payload < 8 then return end
    local region = payload[1]
    local addr = payload[2] | (payload[3] << 8) | (payload[4] << 16) | (payload[5] << 24)
    local len = payload[6] | (payload[7] << 8) | (payload[8] << 16)
    if region ~= pending.region or addr ~= pending.addr or len ~= pending.len then return end
    s.state_data = {}
    for i = 9, #payload do s.state_data[#s.state_data + 1] = payload[i] end
    s.pending = nil
    s.state = "config"
  end
end

local function light(note, colour)
  deckard.midi_send("daw", { 0x90, note, colour })
end

local function button_light(role, cc, on)
  deckard.midi_send(role, { 0xB0, cc, on and 127 or 0 })
end

function M.open()
  light(PLAY, OFF)
  light(STOP, OFF)
  light(REC, OFF)
end

function M.close()
end

function M.midi(role, bytes)
  if role == "service" then
    service_reply(bytes)
    return
  end
  if #bytes < 3 then return end
  local status, d1, d2 = bytes[1], bytes[2], bytes[3]
  local kind = status & 0xF0

  -- Transport buttons can be configured as CCs (Play = CC 27, 127 press / 0
  -- release) on any port. Handle them before the encoder CCs consume the message.
  if kind == 0xB0 and d1 >= 27 and d1 <= 29 then
    if d2 > 0 then
      local s = deckard.state()
      if d1 == 27 then
        if s.playing then deckard.stop() else deckard.play() end
        button_light(role, d1, not s.playing)
        light(PLAY, s.playing and GREEN or OFF)
        light(STOP, s.playing and OFF or RED)
      elseif d1 == 28 then
        deckard.stop()
        button_light(role, d1, false)
        light(STOP, RED)
        light(PLAY, OFF)
      else
        deckard.record(not s.recording, false)
        button_light(role, d1, not s.recording)
        light(REC, s.recording and OFF or RED)
      end
    end
    return
  end

  -- Encoders: CCs on ports 1/2, values span 0..127; the delta is the turn amount.
  if role == "midi" and kind == 0xB0 then
    local knob = CC[d1]
    if knob then
      local old = prev[d1] or d2
      local delta = d2 - old
      if delta > 64 then delta = delta - 128 end
      if delta < -64 then delta = delta + 128 end
      prev[d1] = d2
      -- MK3's knob filter: one count back is flicker, two count.
      if delta ~= 0 then
        local d = dir[knob] or 0
        local b = back[knob] or 0
        local moved = nil
        if d == 0 or (delta > 0 and d > 0) or (delta < 0 and d < 0) then
          local net = delta + b
          b = 0
          d = (delta > 0) and 1 or -1
          if (net > 0 and d > 0) or (net < 0 and d < 0) then
            moved = net
          else
            b = net
          end
        else
          b = b + delta
          if (b >= 2) or (b <= -2) then
            moved = b
            b = 0
            d = (moved > 0) and 1 or -1
          end
        end
        dir[knob], back[knob] = d, b
        if moved then deckard.turn_knob(knob, moved / 127.0, false) end
      end
    end
    return
  end

  -- DAW port: note-based buttons use note-on with velocity 0 as a release.
  if role ~= "daw" or kind ~= 0x90 then return end
  if d2 == 0 then return end

  if d1 >= 1 and d1 <= 16 then
    light(d1, GREEN)
    return
  end

  if d1 == PLAY then
    deckard.play()
    light(PLAY, GREEN)
    light(STOP, OFF)
  elseif d1 == STOP then
    deckard.stop()
    light(STOP, RED)
    light(PLAY, OFF)
  elseif d1 == REC then
    deckard.record(true, false)
    light(REC, RED)
  elseif d1 == LEFT then
    deckard.previous_page()
    light(LEFT, BLUE)
  elseif d1 == RIGHT then
    deckard.next_page()
    light(RIGHT, BLUE)
  end
end

function M.tick()
  local s = st.sess
  local now = deckard.now()
  if s.pending then
    if now - s.sent > TIMEOUT then
      -- Restart from the identity query, but not in this tick.
      s.pending = nil
      s.state = "query"
    end
    return
  end
  if (s.state == "query" or s.state == "state") and now >= s.next_at then
    send_request(s.state)
  end
end

function M.leds()
end

return M