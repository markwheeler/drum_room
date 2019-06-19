-- Drum Room
-- 1.0.0 @markeats
-- llllllll.co/t/drum-room
--
-- MIDI-triggered drum kits.
--
-- E1 : Page
--
-- ROOM:
--  K2 : Kit
--  K3 : Quality
--  E2 : Filter
--  E3 : Compression
--
-- SAMPLES:
--  K2 : Focus
--  K3 : Mute
--  K1+K3 : Trigger
--  E2/3 : Params
--

-- Mapping based on General MIDI Percussion Key Map
-- https://www.midi.org/specifications-old/item/gm-level-1-sound-set


local ControlSpec = require "controlspec"
local ParamSet = require "paramset"
local Formatters = require "formatters"
local MusicUtil = require "musicutil"
local UI = require "ui"

engine.name = "Timber"

local SCREEN_FRAMERATE = 15
local screen_dirty = true

local midi_in_device

local NUM_SAMPLES = 31

local DRUM_ANI_TIMEOUT = 0.2
local SHAKE_ANI_TIMEOUT = 0.4

local GlobalView = {}
local SampleView = {}

local num_global_params
local pages
local global_view
local sample_view
local shift_mode = false

local current_kit
local current_sample_id = 0
local clear_kit, set_kit, set_quality

local count = 0 --TODO remove

local samples_meta = {}
for i = 0, NUM_SAMPLES - 1 do
  samples_meta[i] = {
    ready = false,
    error_status = "",
    playing = false,
    length = 0
  }
end

local kits = {}

local specs = {}
specs.UNIPOLAR_DEFAULT_MAX = ControlSpec.new(0, 1, "lin", 0, 1, "")
specs.FILTER_FREQ = ControlSpec.new(60, 20000, "exp", 0, 20000, "Hz")
specs.TUNE = ControlSpec.new(-12, 12, "lin", 0.5, 0, "ST")
specs.AMP = ControlSpec.new(-48, 32, "db", 0, 0, "dB")

local options = {}
options.OFF_ON = {"Off", "On"}
options.QUALITY = {"Low", "High"}

local function add_global_params()
  
  local kit_names = {}
  for _, v in ipairs(kits) do table.insert(kit_names, v.name) end
  params:add{type = "option", id = "kit", name = "Kit", options = kit_names, default = 1, action = function(value)
    clear_kit()
    set_kit(value)
  end}
  
  params:add{type = "number", id = "midi_in_device", name = "MIDI In Device", min = 1, max = 4, default = 1, action = reconnect_midi_ins}
  local channels = {"All"}
  for i = 1, 16 do table.insert(channels, i) end
  params:add{type = "option", id = "midi_in_channel", name = "MIDI In Channel", options = channels}
  
  params:add{type = "number", id = "bend_range", name = "Pitch Bend Range", min = 1, max = 48, default = 2}
  
  params:add{type = "option", id = "follow", name = "Follow", options = options.OFF_ON, default = 1}
  
  params:add_separator()
  
  params:add{type = "control", id = "filter_cutoff", name = "Filter Cutoff", controlspec = specs.FILTER_FREQ, formatter = Formatters.format_freq, action = function(value)
    for k, v in ipairs(current_kit.samples) do
      engine.filterFreq(k - 1, value)
    end
    screen_dirty = true
  end}
  
  params:add{type = "control", id = "compression", name = "Compression", controlspec = ControlSpec.UNIPOLAR, action = function(value)
    if value == 0 then
      audio.comp_off()
    else
      audio.comp_on()
    end
    audio.comp_mix(util.linlin(0, 0.25, 0, 1, value))
    audio.comp_param("ratio", 8)
    audio.comp_param("threshold", util.linlin(0, 0.66, 0, -32, value))
    audio.comp_param("attack", util.linlin(0.66, 1, 0.0001, 0.02, value))
    audio.comp_param("release", 0.05)
    audio.comp_param("gain_pre", 0)
    audio.comp_param("gain_post", util.linlin(0, 0.66, 0, 22, value) - util.linlin(0.66, 0.75, 0, 8, value))
    
    screen_dirty = true
  end}
  
  params:add{type = "option", id = "quality", name = "Quality", options = options.QUALITY, default = 2, action = function(value)
    for k, v in ipairs(current_kit.samples) do
      set_quality(k - 1, value)
    end
    screen_dirty = true
  end}
  
  params:add_separator()
  
  num_global_params = params.count
  
end

local function load_kits()
  local search_path = _path.code .. "drum_room/lib/"
  for _, v in ipairs(util.scandir(search_path)) do
    local kit_path = search_path .. v .. "kit.lua"
    if util.file_exists(kit_path) then
      table.insert(kits, include("drum_room/lib/" .. v .. "kit"))
    end
  end
end

function set_kit(id)
  if #kits > 0 then
    if kits[id].samples then
      
      for k, v in ipairs(kits[id].samples) do
        
        if k > NUM_SAMPLES then break end
        
        local sample_id = k - 1
        
        if v.note < 0 or v.note > 127 then
          samples_meta[sample_id].error_status = "Invalid note number"
        else
          engine.loadSample(sample_id, _path.dust .. v.file)
        end
        
        local file = string.sub(v.file, string.find(v.file, "/[^/]*$") + 1, string.find(v.file, ".[^.]*$") - 1)
        local name_prefix = string.sub(file, 1, 7)
        
        -- Add params
        
        params:add{type = "control", id = "tune_" .. sample_id, name = name_prefix .. " Tune", controlspec = specs.TUNE, formatter = Formatters.round(0.1), action = function(value)
          engine.originalFreq(sample_id, MusicUtil.note_num_to_freq(60 - value))
          screen_dirty = true
        end}
        
        params:add{type = "control", id = "decay_" .. sample_id, name = name_prefix .. " Decay", controlspec = specs.UNIPOLAR_DEFAULT_MAX, formatter = Formatters.unipolar_as_percentage, action = function(value)
          engine.ampDecay(sample_id, util.linlin(0, 0.9, 0.01, math.min(5, samples_meta[sample_id].length), value))
          engine.ampSustain(sample_id, util.linlin(0.9, 1, 0, 1, value))
          screen_dirty = true
        end}
        
        params:add{type = "control", id = "pan_" .. sample_id, name = name_prefix .. " Pan", controlspec = ControlSpec.PAN, formatter = Formatters.bipolar_as_pan_widget, action = function(value)
          engine.pan(sample_id, value)
          screen_dirty = true
        end}
        
        params:add{type = "control", id = "amp_" .. sample_id, name = name_prefix .. " Amp", controlspec = specs.AMP, action = function(value)
          engine.amp(sample_id, value)
          screen_dirty = true
        end}
        
        params:add_separator()
        
      end
      
      current_kit = kits[id]
      sample_view = SampleView.new()
      pages = UI.Pages.new(1, math.min(#current_kit.samples, NUM_SAMPLES) + 1)
      screen_dirty = true
      
    end
  end
end

function clear_kit()
  current_sample_id = 0
  engine.clearSamples(0, NUM_SAMPLES - 1)
  for i = 0, NUM_SAMPLES - 1 do
    samples_meta[i].ready = false
    samples_meta[i].error_status = ""
    samples_meta[i].length = 0
    samples_meta[i].playing = false
    samples_meta[i].mute = false
  end
  
  -- Remove previous kit params
  for i = #params.params, num_global_params + 1, -1 do
    table.remove(params.params, i)
    params.count = params.count - 1
  end
  
  screen_dirty = true
end

local function sample_loaded(id, streaming, num_frames, num_channels, sample_rate)
  samples_meta[id].ready = true
  samples_meta[id].error_status = ""
  samples_meta[id].length = num_frames / sample_rate
  
  -- Set sample defaults
  engine.playMode(id, 3)
  engine.ampAttack(id, 0)
  engine.filterReso(id, 0.15)
  engine.filterFreq(id, params:get("filter_cutoff"))
  set_quality(id, params:get("quality"))
  
  screen_dirty = true
end

local function sample_load_failed(id, error_status)
  samples_meta[id].ready = false
  samples_meta[id].error_status = error_status or "?"
  samples_meta[id].length = 0
  samples_meta[id].playing = false
  print("Sample load failed", id, error_status)
  screen_dirty = true
end

local function play_position(sample_id, voice_id, position)
  if not samples_meta[sample_id].playing then
    samples_meta[sample_id].playing = true
    screen_dirty = true
  end
end

local function voice_freed(sample_id, voice_id)
  samples_meta[sample_id].playing = false
  screen_dirty = true
end

local function set_sample_id(id)
   current_sample_id = util.clamp(id, 0, NUM_SAMPLES - 1)
end

local function note_on(voice_id, sample_id, vel)
  
  if samples_meta[sample_id].ready and not samples_meta[sample_id].mute then
    vel = vel or 1
    
    -- Choke group
    local grouped_voice_id = voice_id
    if current_kit.samples[sample_id + 1].group then
      grouped_voice_id = 128 + current_kit.samples[sample_id + 1].group
    end
    
    -- print("note_on", grouped_voice_id, sample_id, vel)
    engine.noteOn(grouped_voice_id, sample_id, MusicUtil.note_num_to_freq(60), vel)
    
    if voice_id == 35 or voice_id == 36 then
      global_view.timeouts.bd = DRUM_ANI_TIMEOUT
    elseif voice_id == 38 or voice_id == 40 then
      global_view.timeouts.sd = DRUM_ANI_TIMEOUT
    elseif voice_id == 39 then
      global_view.timeouts.hc = DRUM_ANI_TIMEOUT
    elseif voice_id == 42 or voice_id == 44 then
      global_view.timeouts.ch = DRUM_ANI_TIMEOUT
    elseif voice_id == 46 then
      global_view.timeouts.oh = DRUM_ANI_TIMEOUT
    elseif voice_id == 49 or voice_id == 51 or voice_id == 55 or voice_id == 57 or voice_id == 59 then
      global_view.timeouts.cy = DRUM_ANI_TIMEOUT
      global_view.timeouts.cy_shake = SHAKE_ANI_TIMEOUT
    elseif voice_id == 41 or voice_id == 43 or voice_id == 45 then
      global_view.timeouts.lt = DRUM_ANI_TIMEOUT
    elseif voice_id == 47 or voice_id == 48 then
      global_view.timeouts.mt = DRUM_ANI_TIMEOUT
    elseif voice_id == 50 then
      global_view.timeouts.ht = DRUM_ANI_TIMEOUT
    elseif voice_id == 56 then
      global_view.timeouts.cb = DRUM_ANI_TIMEOUT
    end
    
    if params:get("follow") > 1 and pages.index > 1 then
      pages:set_index(sample_id + 2)
      set_sample_id(sample_id)
    end
    
    screen_dirty = true
  end
end

local function set_pitch_bend_voice(voice_id, bend_st)
  engine.pitchBendVoice(voice_id, MusicUtil.interval_to_ratio(bend_st))
end

local function set_pitch_bend_sample(sample_id, bend_st)
  engine.pitchBendSample(sample_id, MusicUtil.interval_to_ratio(bend_st))
end

local function set_pitch_bend_all(bend_st)
  engine.pitchBendAll(MusicUtil.interval_to_ratio(bend_st))
end

function set_quality(sample_id, quality)
  local downSampleTo = 48000
  local bitDepth = 24
  if quality == 1 then
    downSampleTo = 16000
    bitDepth = 8
  end
  engine.downSampleTo(sample_id, downSampleTo)
  engine.bitDepth(sample_id, bitDepth)
end


-- Encoder input
function enc(n, delta)
  
  -- Global
  if n == 1 then
    pages:set_index_delta(delta, false)
    if pages.index > 1 then
      set_sample_id(pages.index - 2)
    end
  
  else
    
    if pages.index == 1 then
      global_view:enc(n, delta)
    else
      sample_view:enc(n, delta)
    end
    
  end
  screen_dirty = true
end

-- Key input
function key(n, z)
  
  if n == 1 then
    shift_mode = z == 1
    
  else
    if pages.index == 1 then
      global_view:key(n, z)
    else
      sample_view:key(n, z)
    end
    screen_dirty = true
  end
  
end

-- OSC events
local function osc_event(path, args, from)
  
  if path == "/engineSampleLoaded" then
    sample_loaded(args[1], args[2], args[3], args[4], args[5])
    
  elseif path == "/engineSampleLoadFailed" then
    sample_load_failed(args[1], args[2])
    
  elseif path == "/enginePlayPosition" then
    play_position(args[1], args[2], args[3])
    
  elseif path == "/engineVoiceFreed" then
    voice_freed(args[1], args[2])
    
  end
end

-- MIDI input
local function midi_event(device_id, data)
  
  local msg = midi.to_msg(data)
  local channel_param = params:get("midi_in_channel")
  
  -- MIDI In
  if device_id == params:get("midi_in_device") then
    if channel_param == 1 or (channel_param > 1 and msg.ch == channel_param - 1) then
      
      -- Note on
      if msg.type == "note_on" then
        
        local sample_id
        for k, v in ipairs(current_kit.samples) do
          if v.note == msg.note then
            sample_id = k - 1
            break
          end
        end
        
        if sample_id then
          note_on(msg.note, sample_id, msg.vel / 127)
        end
      
      -- Pitch bend
      elseif msg.type == "pitchbend" then
        local bend_st = (util.round(msg.val / 2)) / 8192 * 2 -1 -- Convert to -1 to 1
        local bend_range = params:get("bend_range")
        set_pitch_bend_all(bend_st * bend_range)
        
      end
    end
  end
  
end

local function reconnect_midi_ins()
  midi_in_device.event = nil
  midi_in_device = midi.connect(params:get("midi_in_device"))
  midi_in_device.event = function(data) midi_event(params:get("midi_in_device"), data) end
end


local function update()
  global_view:update()
  
  --TODO test pattern
  -- if count % 8 == 0 then
  --   -- note_on(current_kit.samples[2].note, 1, 1)
  --   note_on(current_kit.samples[1].note, 0, 1)
  -- end
  -- if count % 16 == 0 then
  --   note_on(current_kit.samples[4].note, 3, 1)
  -- end
  -- if count % 6 == 0 then
  --   note_on(current_kit.samples[6].note, 5, 1)
  -- end
  -- -- if count % 32 == 0 then
  -- --   note_on(current_kit.samples[10].note, 9, 1)
  -- -- end
  -- count = count + 1
end


-- Views

GlobalView.__index = GlobalView

function GlobalView.new()
  local global = {
    timeouts = {
      bd = 0,
      sd = 0,
      hc = 0,
      ch = 0,
      oh = 0,
      cy = 0,
      cy_shake = 0,
      lt = 0,
      mt = 0,
      ht = 0,
      cb = 0
    }
  }
  setmetatable(GlobalView, {__index = GlobalView})
  setmetatable(global, GlobalView)
  return global
end

function GlobalView:enc(n, delta)
  if n == 2 then
    params:delta("filter_cutoff", delta * 2)
    
  elseif n == 3 then
    params:delta("compression", delta * 2)
    
  end
  screen_dirty = true
end

function GlobalView:key(n, z)
  if z == 1 then
    if n == 2 then
      
      if #kits > 0 then
        params:set("kit", params:get("kit") % #kits + 1)
      end
      
    elseif n == 3 then
      params:set("quality", params:get("quality") % #options.QUALITY + 1)
      
    end
    screen_dirty = true
  end
end

function GlobalView:update()
  
  for k, v in pairs(self.timeouts) do
    self.timeouts[k] = math.max(v - 1 / SCREEN_FRAMERATE, 0)
  end
  
  screen_dirty = true
end

function GlobalView:redraw()
  
  -- Title
  screen.level(15)
  screen.move(63, 60)
  screen.text_center(current_kit.name)
  screen.fill()
  
  -- Draw walls
  
  screen.level(2)
  local walls_margin_v, walls_margin_h = 8, 4
  local walls_num_lines = 7
  local filter_mod = util.explin(specs.FILTER_FREQ.minval, specs.FILTER_FREQ.maxval, 18, 6, params:get("filter_cutoff"))
  for i = 1, walls_num_lines do
    local wall_height_mod = 0
    if math.ceil(params:get("compression") * walls_num_lines) == i then
      wall_height_mod = 2
      screen.level(6)
    else
      screen.level(2)
    end
    
    local wall_top = walls_margin_v - wall_height_mod + util.linlin(1, walls_num_lines, 0, filter_mod, i)
    local wall_bottom = 64 - walls_margin_v + wall_height_mod - util.linlin(1, walls_num_lines, 0, filter_mod, i)
    -- Filter mod
    screen.move(walls_margin_h * i + 0.5, wall_top)
    screen.line(walls_margin_h * i + 0.5, wall_bottom)
    screen.stroke()
    screen.move(127 - walls_margin_h * i + 0.5, wall_top)
    screen.line(127 - walls_margin_h * i + 0.5,  wall_bottom)
    screen.stroke()
  end
  
  -- Draw drum kit

  local drum_active = 15
  local drum_outline = 6
  local drum_outline_angled = drum_outline + 1
  local drum_innner = 2
  local drum_innner_angled = drum_innner + 1
  local cx, cy = 62, 29
  
  local nod = 0
  local hair = 0
  if self.timeouts.bd > 0 or self.timeouts.sd > 0 then nod = 1 end
  if self.timeouts.cy > 0 or self.timeouts.hc > 0 then
    hair = 1.5
    nod = -1
  end
  
  -- Hair outline
  screen.level(drum_outline)
  screen.move(cx - 4.5 - hair, cy - 11)
  screen.line(cx - 4.5, cy - 16 + nod * 0.5)
  screen.arc(cx, cy - 16 + nod * 0.5, 4.5, math.pi, math.pi * 2)
  screen.line(cx + 4.5 + hair, cy - 11)
  screen.stroke()
  -- Bangs / glasses
  local glasses_line = 1
  if params:get("quality") == 1 then glasses_line = 2 end
  screen.rect(cx - 3, cy - 16 + nod, 6, glasses_line)
  screen.fill()
  -- Cheeks
  screen.move(cx + 1.5, cy - 13 + nod)
  screen.line(cx + 1.5, cy - 15.5 + nod)
  screen.stroke()
  screen.move(cx - 1.5, cy - 13 + nod)
  screen.line(cx - 1.5, cy - 15.5 + nod)
  screen.stroke()
  -- Jaw
  screen.arc(cx, cy - 13.5 + nod, 1.5, math.pi * 2, math.pi)
  screen.stroke()
  
  -- HC
  if self.timeouts.hc > 0 then
    screen.level(drum_active)
    screen.move(cx, cy - 10)
    screen.line(cx + 6, cy - 17)
    screen.stroke()
    screen.move(cx + 5, cy - 10)
    screen.line(cx + 9, cy - 17)
    screen.stroke()
  end
  
  -- SD
  if self.timeouts.sd > 0 then screen.level(drum_active) else screen.level(drum_outline) end
  screen.rect(cx + 10.5, cy + 0.5, 12, 5)
  screen.stroke()
  -- Stand
  screen.move(cx + 16.5, cy + 5.5)
  screen.line(cx + 16.5, cy + 14)
  if self.timeouts.sd > 0 then screen.level(drum_active) else screen.level(drum_outline_angled) end
  screen.move(cx + 16.5, cy + 14)
  screen.line(cx + 20.5, cy + 19)
  screen.stroke()
  screen.move(cx + 16.5, cy + 14)
  screen.line(cx + 12.5, cy + 19)
  screen.stroke()
  
  -- HH
  screen.level(drum_outline)
  if self.timeouts.ch > 0 or self.timeouts.oh > 0 then
    if self.timeouts.hc <= 0 then
      -- Arm
      screen.level(drum_outline_angled)
      screen.move(cx + 14, cy - 7.5)
      local hand_y = -9
      if self.timeouts.oh > 0 then hand_y = -10.5 end
      screen.line(cx + 20.5, cy + hand_y)
      screen.stroke()
    end
    screen.level(drum_active)
  end
  local mod_y_l, mod_y_r = 0, 0
  if self.timeouts.oh > 0 then
    mod_y_l = math.random(-2, -1)
    mod_y_r = math.random(-2, -1)
  end
  screen.move(cx + 19, cy - 5.5 + mod_y_l)
  screen.line(cx + 32, cy - 5.5 + mod_y_r)
  screen.stroke()
  screen.move(cx + 19, cy - 3.5)
  screen.line(cx + 32, cy - 3.5)
  screen.stroke()
  -- Stand
  screen.move(cx + 25.5, cy - 3.5)
  screen.line(cx + 25.5, cy + 14)
  screen.stroke()
  if self.timeouts.ch > 0 or self.timeouts.oh > 0 then screen.level(drum_active) else screen.level(drum_outline_angled) end
  screen.move(cx + 25.5, cy + 14)
  screen.line(cx + 29.5, cy + 19)
  screen.stroke()
  screen.move(cx + 25.5, cy + 14)
  screen.line(cx + 21.5, cy + 19)
  screen.stroke()
  
  -- LT
  if self.timeouts.lt > 0 then screen.level(drum_active) else screen.level(drum_outline) end
  screen.rect(cx - 19.5, cy + 2.5, 10, 13)
  screen.stroke()
  -- Feet
  screen.move(cx - 19.5, cy + 16)
  screen.line(cx - 19.5, cy + 19)
  screen.stroke()
  screen.move(cx - 13.5, cy + 16)
  screen.line(cx - 13.5, cy + 19)
  screen.stroke()
  -- Stripe
  screen.level(drum_innner)
  screen.move(cx - 18, cy + 4.5)
  screen.line(cx - 11, cy + 4.5)
  screen.stroke()
  screen.move(cx - 15.5, cy + 5)
  screen.line(cx - 15.5, cy + 14)
  screen.stroke()
  
  -- MT
  if self.timeouts.mt > 0 then screen.level(drum_active) else screen.level(drum_outline) end
  screen.rect(cx - 12.5, cy - 7.5, 10, 7)
  screen.stroke()
  screen.level(drum_innner)
  screen.move(cx - 11, cy - 5.5)
  screen.line(cx - 4, cy - 5.5)
  screen.stroke()
  
  -- HT
  if self.timeouts.ht > 0 then screen.level(drum_active) else screen.level(drum_outline) end
  screen.rect(cx + 2.5, cy - 7.5, 10, 6)
  screen.stroke()
  screen.level(drum_innner)
  screen.move(cx + 11, cy - 5.5)
  screen.line(cx + 4, cy - 5.5)
  screen.stroke()
  
  -- CY
  screen.level(drum_outline)
  if self.timeouts.cy > 0 then
    if self.timeouts.hc <= 0 then
      -- Arm
      screen.level(drum_outline_angled)
      screen.move(cx - 8, cy - 9.5)
      screen.line(cx - 17, cy - 16)
      screen.stroke()
    end
    screen.level(drum_active)
  end
  local cym_rotation = 0
  if params:get("quality") ~= 1 then
    cym_rotation = math.pi * 2 * 0.06
  end
  if self.timeouts.cy_shake > 0 then
    cym_rotation = cym_rotation + math.sin(self.timeouts.cy_shake * 40) * 0.7 * util.linlin(0, SHAKE_ANI_TIMEOUT, 0, 1, self.timeouts.cy_shake)
  end
  local cos_cym_rotation = math.cos(cym_rotation) * 7.5
  local sin_cym_rotation = math.sin(cym_rotation) * 7.5
  screen.move(cx - 23.5 - cos_cym_rotation, cy - 16.5 - sin_cym_rotation)
  screen.line(cx - 23.5 + cos_cym_rotation, cy - 16.5 + sin_cym_rotation)
  screen.stroke()
  -- Stand
  screen.move(cx - 23.5, cy - 16.5)
  screen.line(cx - 23.5, cy + 14)
  screen.stroke()
  if self.timeouts.cy > 0 then screen.level(drum_active) else screen.level(drum_outline_angled) end
  screen.move(cx - 23.5, cy + 14)
  screen.line(cx - 27.5, cy + 19)
  screen.stroke()
  screen.move(cx - 23.5, cy + 14)
  screen.line(cx - 19.5, cy + 19)
  screen.stroke()
  
  -- BD
  if params:get("quality") == 1 then
    screen.level(0)
    screen.rect(cx - 11, cy - 2, 22, 22)
    screen.fill()
    if self.timeouts.bd > 0 then screen.level(drum_active) else screen.level(drum_outline) end
    screen.rect(cx - 9.5, cy - 0.5, 19, 19)
    screen.stroke()
    screen.level(drum_innner)
    screen.rect(cx + 0.5, cy + 9.5, 5, 5)
    screen.stroke()
  else
    screen.aa(0)
    screen.level(0)
    screen.circle(cx, cy + 9, 13)
    screen.fill()
    screen.aa(1)
    if self.timeouts.bd > 0 then screen.level(drum_active) else screen.level(drum_outline_angled) end
    screen.circle(cx, cy + 9, 10.5)
    screen.stroke()
    screen.level(drum_innner_angled)
    screen.circle(cx + 3, cy + 12, 2.5)
    screen.stroke()
  end
  
  -- CB
  if self.timeouts.cb > 0 then
    screen.level(drum_active)
    screen.move(cx + 21, cy - 18)
    screen.text("Donk!")
    screen.fill()
  end
  
end


SampleView.__index = SampleView

function SampleView.new()
  local sample_view = {
    tab_id = 1,
    tune_dial = UI.Dial.new(4.5, 18, 22, 0, -12, 12, 0.1, 0, {0}, "ST"),
    decay_dial = UI.Dial.new(36, 31, 22, params:get("decay_" .. current_sample_id) * 100, 0, 100, 1, 0, nil, "%", "Decay"),
    pan_dial = UI.Dial.new(67.5, 18, 22, params:get("pan_" .. current_sample_id) * 100, -100, 100, 1, 0, {0}, nil, "Pan"),
    amp_dial = UI.Dial.new(99, 31, 22, params:get("amp_" .. current_sample_id), specs.AMP.minval, specs.AMP.maxval, 0.1, nil, {0}, "dB")
  }
  sample_view.pan_dial.active = false
  sample_view.amp_dial.active = false
  
  setmetatable(SampleView, {__index = SampleView})
  setmetatable(sample_view, SampleView)
  return sample_view
end

function SampleView:enc(n, delta)
  
  if not samples_meta[current_sample_id].mute then
    
    if n == 2 then
      if self.tab_id == 1 then
        params:delta("tune_" .. current_sample_id, delta)
      else
        params:delta("pan_" .. current_sample_id, delta)
      end
      
    elseif n == 3 then
      if self.tab_id == 1 then
        params:delta("decay_" .. current_sample_id, delta * 2)
      else
        params:delta("amp_" .. current_sample_id, delta)
      end
      
    end
    screen_dirty = true
  end
end

function SampleView:key(n, z)
  if z == 1 then
    if n == 2 then
      self.tab_id = self.tab_id % 2 + 1
      self.tune_dial.active = self.tab_id == 1
      self.decay_dial.active = self.tab_id == 1
      self.pan_dial.active = self.tab_id == 2
      self.amp_dial.active = self.tab_id == 2
      
    elseif n == 3 then
      if shift_mode then
        note_on(current_kit.samples[current_sample_id + 1].note, current_sample_id, 1)
      else
        samples_meta[current_sample_id].mute = not samples_meta[current_sample_id].mute
      end
      
    end
    screen_dirty = true
  end
end

function SampleView:redraw()
  
  if samples_meta[current_sample_id].playing then screen.level(15) else screen.level(3) end
  screen.move(4, 9)
  screen.text(MusicUtil.note_num_to_name(current_kit.samples[current_sample_id + 1].note, true))
  
  local title = current_kit.samples[current_sample_id + 1].file
  title = string.sub(title, string.find(title, "/[^/]*$") + 1, string.find(title, ".[^.]*$") - 1)
  if string.len(title) > 19 then
    title = string.sub(title, 1, 16) .. "..."
  end
  
  screen.level(15)
  screen.move(63, 9)
  screen.text_center(title)
  screen.fill()
  
  if samples_meta[current_sample_id].mute then
    
    screen.level(4)
    screen.move(46, 19)
    screen.line(82, 55)
    screen.stroke()
    screen.move(46, 55)
    screen.line(82, 19)
    screen.stroke()
    
  elseif samples_meta[current_sample_id].ready then
  
    self.tune_dial:set_value(params:get("tune_" .. current_sample_id))
    self.decay_dial:set_value(params:get("decay_" .. current_sample_id) * 100)
    self.pan_dial:set_value(params:get("pan_" .. current_sample_id) * 100)
    self.amp_dial:set_value(params:get("amp_" .. current_sample_id))
    
    self.tune_dial:redraw()
    self.decay_dial:redraw()
    self.pan_dial:redraw()
    self.amp_dial:redraw()
    
    if params:get("amp_" .. current_sample_id) > 2 then
      screen.level(15)
      screen.move(110, 45)
      screen.text_center("!")
      screen.fill()
    end
    
  else
    
    screen.level(3)
    screen.move(63, 38)
    screen.text_center(samples_meta[current_sample_id].error_status)
    screen.fill()
    
  end
  
end


-- Drawing functions

local function draw_background_rects()
  -- 4px edge margins. 8px gutter.
  screen.level(1)
  screen.rect(4, 22, 56, 38)
  screen.rect(68, 22, 56, 38)
  screen.fill()
end

function redraw()
  
  screen.clear()
  
  -- draw_background_rects()
  
  if #kits == 0 then
    screen.level(15)
    screen.move(64, 30)
    screen.text_center("No kits found in")
    screen.move(64, 41)
    screen.level(3)
    screen.text_center("code/drum_room/lib/")
    screen.fill()
    screen.update()
    return
  end
  
  pages:redraw()
  
  if pages.index == 1 then
    global_view:redraw()
  else
    sample_view:redraw()
  end
  
  screen.update()
end


function init()
  
  osc.event = osc_event
  
  midi_in_device = midi.connect(1)
  midi_in_device.event = function(data) midi_event(1, data) end
  
  -- UI
  global_view = GlobalView.new()
  
  screen.aa(1)
  
  local screen_redraw_metro = metro.init()
  screen_redraw_metro.event = function()
    update()
    if screen_dirty then
      redraw()
      screen_dirty = false
    end
  end
  
  screen_redraw_metro:start(1 / SCREEN_FRAMERATE)
  
  engine.generateWaveforms(0)
  
  load_kits()
  add_global_params()
  set_kit(1)
  
end
