-- M-Vave SMC-PAD, mapped to DECKARD's MK3 controls.
-- Measured MIDI: docs/HARDWARE.md in SDR3078/mvave-smc-pad-ableton.
-- Encoders are on ports 1/2, relative CCs (63 = -1, 65 = +1).
-- Transport and pads are on port 3 (notes 17-21, 1-16); buttons are not notes
-- to play (the manifest declares that port exclusive).

local M = {}

local PLAY, STOP, REC = 17, 18, 19
local LEFT, RIGHT = 20, 21

-- Service session on the Private port: 00 59 | cmd | len24 LE | payload | ~sum,
-- packed LSB-first 8→7 into one F0 … F7. Everything is driven from tick().
local LOGO = { 0x00, 0x59 }
local QUERY, READ, WRITE = 0x11, 0x23, 0x22
local RETRY, TIMEOUT, KEEPALIVE = 0.04, 5.0, 0.5

-- Region 5: eight slots of 3539 bytes. Pad records start at 211, sixteen per
-- bank (416 bytes), each 26 bytes; the RGB triple sits at record offset 5.
local CHUNK, CHUNKS = 1009, 29
local SLOT_BYTES, BANK_BYTES, RECORD_BYTES = 3539, 16 * 26, 26
local PADS_AT, RGB_AT = 211, 5

-- Region 5: five 23-byte button records per slot, with the arm byte at 22.
-- The note selector written there is 25..29; the same note on the DAW port
-- lights (velocity 5) or extinguishes (velocity 0) the physical LED.
local BUTTON_BYTES, BUTTON_AT, BUTTON_NOTE = 23, 22, 25
local BUTTONS = 5
local PAD_NUMBER = { 13, 14, 15, 16, 9, 10, 11, 12, 5, 6, 7, 8, 1, 2, 3, 4 }
local DIM = 0.35
local EMPTY_SLOT = { 255, 255, 255 }

local st = { sess = { state = "query", sent = 0, next_at = 0, chunk = 0, cursor = 1 } }

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
  elseif kind == "state" or kind == "keepalive" then
    bytes = pack7(logical(READ, { 4, 0, 0, 0, 0, 12, 0, 0 }))
    pending = { kind = kind, cmd = READ, region = 4, addr = 0, len = 12 }
  elseif kind == "config" then
    local addr = s.chunk * CHUNK
    local len = s.chunk < CHUNKS - 1 and CHUNK or 60
    bytes = pack7(logical(READ, {
      5,
      addr & 0xFF, (addr >> 8) & 0xFF, (addr >> 16) & 0xFF, (addr >> 24) & 0xFF,
      len & 0xFF, (len >> 8) & 0xFF, (len >> 16) & 0xFF,
    }))
    pending = { kind = "config", cmd = READ, region = 5, addr = addr, len = len }
  else
    return
  end
  local now = deckard.now()
  s.pending = pending
  s.sent = now
  s.next_at = now + RETRY
  deckard.midi_send("service", bytes)
end

local function write_request(addr, data)
  local payload = {
    5,
    addr & 0xFF, (addr >> 8) & 0xFF, (addr >> 16) & 0xFF, (addr >> 24) & 0xFF,
    #data & 0xFF, (#data >> 8) & 0xFF, (#data >> 16) & 0xFF,
  }
  for i = 1, #data do payload[#payload + 1] = data[i] end
  return pack7(logical(WRITE, payload))
end

local function reply_header(payload)
  if #payload < 8 then return end
  local region = payload[1]
  local addr = payload[2] | (payload[3] << 8) | (payload[4] << 16) | (payload[5] << 24)
  local len = payload[6] | (payload[7] << 8) | (payload[8] << 16)
  return region, addr, len
end

-- The state block's byte 6 is the base bank, byte 10 the slot, byte 11 the
-- bank toggle; toggle 1 selects image bank 8 (index 7) regardless of base bank.
local function block_state(block)
  local bank, slot, toggle = block[7], block[11], block[12]
  if toggle == 1 then bank = 7 end
  return bank, slot, toggle
end

-- An edited preset may no longer carry notes 36..51 in the bank the state
-- bytes name. Accept the state-derived bank only when no other bank has that
-- exact run (or when several do), so we never write to an arbitrary record.
local function scanned_bank(s, slot)
  local found, count = nil, 0
  for bank = 0, 7 do
    local match = true
    for record = 0, 15 do
      local at = slot * SLOT_BYTES + PADS_AT + bank * BANK_BYTES + record * RECORD_BYTES + 2
      if s.config[at + 1] ~= 36 + record then match = false; break end
    end
    if match then found, count = bank, count + 1 end
  end
  return count == 1 and found or nil
end

local function rebuild_map(s, bank, slot)
  s.bank, s.slot = bank, slot
  s.addr, s.orig = {}, {}
  for i = 1, 16 do
    local addr = slot * SLOT_BYTES + PADS_AT + bank * BANK_BYTES + (PAD_NUMBER[i] - 1) * RECORD_BYTES + RGB_AT
    s.addr[i] = addr
    s.orig[i] = { s.config[addr + 1], s.config[addr + 2], s.config[addr + 3] }
  end
end

local function status(s)
  return "SMC-PAD: service session ready (slot=" .. s.slot .. " bank=" .. s.bank .. ")"
end

-- Buttons are slot-scoped records, not bank-scoped. Arm on a fresh session and
-- whenever keep-alive reports another slot; cache the factory bytes for close().
local function arm_buttons()
  local s = st.sess
  s.btn_orig, s.btn_last = {}, {}
  for index = 0, BUTTONS - 1 do
    local addr = s.slot * SLOT_BYTES + index * BUTTON_BYTES + BUTTON_AT
    s.btn_orig[index + 1] = s.config and s.config[addr + 1] or 0xFF
    deckard.midi_send("service", write_request(addr, { BUTTON_NOTE + index }))
  end
end

local function button_led(index, on)
  deckard.midi_send("daw", { 0x90, BUTTON_NOTE + index, on and 5 or 0 })
end

-- Mirrors MK3's transport and navigation state. page/pages are read defensively:
-- a malformed view must never throw out of a MIDI or tick handler.
local function drive_buttons()
  local s = st.sess
  local v = deckard.state()
  if type(v) ~= "table" then return end
  local control = type(v.control) == "table" and v.control or nil
  local page = control and type(control.page) == "number" and control.page or nil
  local pages = control and control.pages or nil
  local page_count = type(pages) == "table" and #pages or nil
  local want = {
    page and page > 1 or false,
    page and page_count and page < page_count or false,
    v.playing == true,
    v.playing == true,
    v.recording == true,
  }
  for index = 0, BUTTONS - 1 do
    local on = want[index + 1]
    if s.btn_last[index + 1] ~= on then
      button_led(index, on)
      s.btn_last[index + 1] = on
    end
  end
end

local function pad_colour(i, v)
  local group = v.groups[v.group]
  local sound = group and group.sounds[i]
  if not sound then return { 0, 0, 0 } end
  local held = deckard.pad_held(i)
  local chosen = sound.selected or i == v.sound
  if not sound.used and not chosen and not held and not sound.playing then return { 0, 0, 0 } end
  -- An empty but chosen slot shows the dim white empty-slot colour, never the
  -- sound's stale RGB; global.lua lights it with its EMPTY_SLOT palette.
  local colour, factor = sound.color, (chosen or held) and 1 or DIM
  if not sound.used then colour, factor = EMPTY_SLOT, DIM end
  if not colour then return { 0, 0, 0 } end
  local rgb = {}
  for k = 1, 3 do
    local c = math.floor((colour[k] or 0) * factor + 0.5)
    if sound.playing and not held then c = math.floor((c + 255) / 2 + 0.5) end
    rgb[k] = math.max(0, math.min(255, c))
  end
  return rgb
end

-- Rebuilds are rare: redraw all pads at once instead of the tick's normal
-- throttled colour mirror (Task 3).
local function redraw_pads()
  local s = st.sess
  local v = deckard.state()
  for i = 1, 16 do
    local rgb = pad_colour(i, v)
    deckard.midi_send("service", write_request(s.addr[i], rgb))
    s.last[i] = rgb
  end
  s.redraw = false
end

-- At most two changed pads per tick, starting where the last tick stopped, so
-- a full grid never blocks the UI thread and no pad is starved.
local function mirror_colours()
  local s = st.sess
  local v = deckard.state()
  local sent = 0
  for n = 1, 16 do
    if sent == 2 then break end
    local i = (s.cursor + n - 2) % 16 + 1
    local rgb = pad_colour(i, v)
    local last = s.last[i]
    if not last or last[1] ~= rgb[1] or last[2] ~= rgb[2] or last[3] ~= rgb[3] then
      deckard.midi_send("service", write_request(s.addr[i], rgb))
      s.last[i] = rgb
      s.cursor = i % 16 + 1
      sent = sent + 1
    end
  end
end

local function service_reply(bytes)
  -- Parsing must never throw out of a MIDI handler and stall the session.
  local ok, cmd, payload = pcall(function() return parse_reply(unpack7(bytes)) end)
  if not ok or not cmd or not payload then return end
  if cmd == 0 then return end -- write ACK
  local s = st.sess
  local pending = s.pending
  if not pending then return end
  if cmd == QUERY and pending.kind == "query" then
    s.pending = nil
    s.state = "state"
  elseif cmd == READ and (pending.kind == "state" or pending.kind == "keepalive") then
    local region, addr, len = reply_header(payload)
    if region ~= pending.region or addr ~= pending.addr or len ~= pending.len then return end
    local block = {}
    for i = 9, #payload do block[#block + 1] = payload[i] end
    if #block < 12 then return end
    s.state_data = block
    s.pending = nil
    if pending.kind == "state" then
      s.state = "config"
    else
      local bank, slot, toggle = block_state(block)
      -- Compare with the raw state baseline, not the effective (possibly
      -- scanned) bank: an edited preset's 36..51 run can name a different bank.
      if bank ~= s.state_bank or slot ~= s.state_slot or toggle ~= s.state_toggle then
        local slot_changed = slot ~= s.slot
        s.state_bank, s.state_slot, s.state_toggle = bank, slot, toggle
        s.toggle = toggle
        rebuild_map(s, bank, slot)
        -- New slot: re-arm before the next tick redraws any pads. A bank toggle
        -- leaves the button records untouched.
        if slot_changed then arm_buttons() end
        s.last, s.redraw = {}, true
        deckard.message(status(s))
      end
      s.keepalive_at = deckard.now() + KEEPALIVE
    end
  elseif cmd == READ and pending.kind == "config" then
    local region, addr, len = reply_header(payload)
    if not region or region ~= pending.region or addr ~= pending.addr or len ~= pending.len then return end
    if #payload < 8 + len then return end
    s.config = s.config or {}
    for i = 1, len do s.config[addr + i] = payload[8 + i] end
    s.chunk = s.chunk + 1
    s.pending = nil
    if s.chunk == CHUNKS then
      local bank, slot, toggle = block_state(s.state_data)
      -- Cache the state-derived triple before the scan override. Keep-alives
      -- compare against this baseline; `s.bank` stays the effective bank.
      s.state_bank, s.state_slot, s.state_toggle = bank, slot, toggle
      local scan = scanned_bank(s, slot)
      if scan then bank = scan end
      s.toggle = toggle
      rebuild_map(s, bank, slot)
      s.last, s.redraw = {}, false
      s.state = "ready"
      arm_buttons()
      s.keepalive_at = deckard.now() + KEEPALIVE
      deckard.message(status(s))
    end
  end
end

function M.open()
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

  -- LEFT/RIGHT/transport can be configured as CCs (25..29, 127 press / 0
  -- release) on any port. Handle them before the encoder CCs consume the message.
  -- LED feedback is driven from deckard.state() in tick() once the session is ready.
  if kind == 0xB0 and d1 >= BUTTON_NOTE and d1 <= BUTTON_NOTE + 4 then
    if d2 > 0 then
      if d1 == BUTTON_NOTE then
        deckard.previous_page()
      elseif d1 == BUTTON_NOTE + 1 then
        deckard.next_page()
      elseif d1 == 27 then
        local s = deckard.state()
        if s.playing then deckard.stop() else deckard.play() end
      elseif d1 == 28 then
        deckard.stop()
      else
        local s = deckard.state()
        deckard.record(not s.recording, false)
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

  -- Pad LEDs are mirrored over the service SysEx session, not note feedback.
  if d1 >= 1 and d1 <= 16 then return end

  if d1 == PLAY then
    deckard.play()
  elseif d1 == STOP then
    deckard.stop()
  elseif d1 == REC then
    deckard.record(true, false)
  elseif d1 == LEFT then
    deckard.previous_page()
  elseif d1 == RIGHT then
    deckard.next_page()
  end
end

function M.tick()
  local s = st.sess
  local now = deckard.now()
  if s.pending then
    if now - s.sent > TIMEOUT then
      -- Restart from the identity query, but not in this tick. A partial
      -- config image must not be resumed from a stale chunk.
      s.pending = nil
      s.state = "query"
      s.chunk, s.config = 0, nil
      return
    end
    -- A malformed or unmatched reply leaves the chunk outstanding: retry it
    -- after RETRY instead of waiting for the full handshake timeout.
    if s.state == "config" and now >= s.next_at then send_request("config") end
    return
  end
  if s.state == "config" then
    if now >= s.next_at then send_request("config") end
    return
  end
  if s.state == "ready" then
    drive_buttons()
    if s.redraw and not s.pending then redraw_pads() end
    if not s.pending and now >= s.keepalive_at then
      send_request("keepalive")
      s.keepalive_at = now + KEEPALIVE
    end
    if not s.pending then mirror_colours() end
    return
  end
  if (s.state == "query" or s.state == "state") and now >= s.next_at then
    send_request(s.state)
  end
end

function M.leds()
end

return M