-- Drummer
-- 1.0.0 @markeats
-- llllllll.co/t/drummer
--
-- Description.
--
-- E1 : Sound
--

-- Mapping based on General MIDI Percussion Key Map
-- https://www.midi.org/specifications-old/item/gm-level-1-sound-set

local ControlSpec = require "controlspec"
local Formatters = require "formatters"
local MusicUtil = require "musicutil"
local UI = require "ui"

engine.name = "Timber"

local SCREEN_FRAMERATE = 15
local screen_dirty = true

local midi_in_device

local NUM_SAMPLES = 46

local GlobalView = {}
local SampleView = {}

local pages
local global_view
local sample_view

local current_kit_id = 1
local current_sample_id = 0

local samples_meta = {}
for i = 0, NUM_SAMPLES - 1 do
  samples_meta[i] = {
    ready = false,
    length = 0
  }
end

local kits = {}

local specs = {}
specs.UNIPOLAR_DEFAULT_MAX = ControlSpec.new(0, 1, "lin", 0, 1, "")


local function add_global_params()
  params:add{type = "number", id = "midi_in_device", name = "MIDI In Device", min = 1, max = 4, default = 1, action = reconnect_midi_ins}
  local channels = {"All"}
  for i = 1, 16 do table.insert(channels, i) end
  params:add{type = "option", id = "midi_in_channel", name = "MIDI In Channel", options = channels}
  
  params:add_separator()
  
  params:add{type = "number", id = "bend_range", name = "Pitch Bend Range", min = 1, max = 48, default = 2}
  
  params:add{type = "option", id = "follow", name = "Follow", options = {"Off", "On"}, default = 2}
  
  params:add_separator()
end

local function load_kits()
  local search_path = _path.code .. "drummer/kits/"
  for _, v in ipairs(util.scandir(search_path)) do
    local kit_path = search_path .. v .. "kit.lua"
    if util.file_exists(kit_path) then
      table.insert(kits, include("drummer/kits/" .. v .. "kit"))
    end
  end
end

local function load_kit(id)
  if #kits > 0 then
    if kits[id].samples then
      
      params:clear()
      add_global_params()
      
      for k, v in ipairs(kits[id].samples) do
        
        local sample_id = k - 1
        
        engine.loadSample(sample_id, _path.dust .. v.file)
        
        local file = string.sub(v.file, string.find(v.file, "/[^/]*$") + 1, string.find(v.file, ".[^.]*$") - 1)
        
        -- Add params
        params:add{type = "control", id = "decay_" .. sample_id, name = string.sub(file, 1, 10) .. " Decay", controlspec = specs.UNIPOLAR_DEFAULT_MAX, formatter = Formatters.unipolar_as_percentage, action = function(value)
          engine.ampDecay(sample_id, util.linlin(0, 0.9, 0.003, math.min(5, samples_meta[sample_id].length), value))
          engine.ampSustain(sample_id, util.linlin(0.9, 1, 0, 1, value))
          screen_dirty = true
        end}
        
        params:add_separator()
        
        sample_view = SampleView.new()
      end
      
      pages = UI.Pages.new(1, #kits[current_kit_id].samples + 1)
    end
    screen_dirty = true
  end
end

local function clear_kit()
  current_sample_id = 0
  engine.clearSamples(0, NUM_SAMPLES - 1)
  for i = 0, NUM_SAMPLES - 1 do
    samples_meta[i].ready = false
    samples_meta[i].length = 0
  end
end

local function sample_loaded(id, streaming, num_frames, num_channels, sample_rate)
  samples_meta[id].ready = true
  samples_meta[id].length = num_frames / sample_rate
  
  -- Set sample defaults
  engine.playMode(id, 3)
  
  screen_dirty = false
end

local function sample_load_failed(id, error_status)
  samples_meta[id].ready = false
  samples_meta[id].length = 0
  print("Sample load failed", error_status)
  screen_dirty = true
end

local function set_sample_id(id)
   current_sample_id = util.clamp(id, 0, NUM_SAMPLES - 1)
end

local function note_on(sample_id, voice_id, vel)
  
  if samples_meta[sample_id].ready then
    
    -- print("note_on", sample_id, voice_id)
    vel = vel or 1
    engine.noteOn(sample_id, voice_id, MusicUtil.note_num_to_freq(60), vel)
    -- global_view:add_play_visual() --TODO
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
  
  if pages.index == 1 then
    global_view:key(n, z)
  else
    sample_view:key(n, z)
  end
  
  screen_dirty = true
end

-- OSC events
local function osc_event(path, args, from)
  
  if path == "/engineSampleLoaded" then
    sample_loaded(args[1], args[2], args[3], args[4], args[5])
    
  elseif path == "/engineSampleLoadFailed" then
    sample_load_failed(args[1], args[2])
    
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
        for k, v in ipairs(kit[current_kit_id].samples) do
          if v.note == msg.note then
            sample_id = k - 1
            break
          end
        end
        
        if sample_id then
          note_on(sample_id, msg.note, msg.vel / 127)
          
          if params:get("follow") > 1 then
            set_sample_id(sample_id)
          end
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
  --TODO??
  global_view:update()
end


-- Views

GlobalView.__index = GlobalView

function GlobalView.new()
  local global = {}
  setmetatable(GlobalView, {__index = GlobalView})
  setmetatable(global, GlobalView)
  return global
end

function GlobalView:enc(n, delta)
  -- TODO
  screen_dirty = true
end

function GlobalView:key(n, z)
  if z == 1 then
    if n == 2 then
      
      if #kits > 0 then
        current_kit_id = current_kit_id % #kits + 1
        clear_kit()
        load_kit(current_kit_id)
      end
      
    elseif n == 3 then
      -- TODO
      
    end
    screen_dirty = true
  end
end

function GlobalView:update()
  --TODO update animations
  screen_dirty = true
end

function GlobalView:redraw()
  
  screen.level(15)
  screen.move(64, 56)
  screen.text_center(kits[current_kit_id].name)
  screen.fill()
  
end


SampleView.__index = SampleView

function SampleView.new()
  
  local decay_dial = UI.Dial.new(68.5, 21, 22, params:get("decay_" .. current_sample_id) * 100, 0, 100, 1, 0, nil, "%", "Decay")
  
  local sample_view = {
    decay_dial = decay_dial
  }
  setmetatable(SampleView, {__index = SampleView})
  setmetatable(sample_view, SampleView)
  return sample_view
end

function SampleView:enc(n, delta)
  if n == 2 then
    params:delta("decay_" .. current_sample_id, delta * 2)
  end
  screen_dirty = true
end

function SampleView:key(n, z)
  if z == 1 then
    if n == 2 then
      --TODO
      
    elseif n == 3 then
      
      --TODO
      note_on(current_sample_id, kit[current_kit_id].samples[current_sample_id + 1].note, 1)
      
    end
    screen_dirty = true
  end
end

function SampleView:redraw()
  
  screen.level(15)
  
  screen.move(4, 9)
  screen.text(MusicUtil.note_num_to_name(kits[current_kit_id].samples[current_sample_id + 1].note, true))
  
  local title = kits[current_kit_id].samples[current_sample_id + 1].file
  title = string.sub(title, string.find(title, "/[^/]*$") + 1, string.find(title, ".[^.]*$") - 1)
  if string.len(title) > 19 then
    title = string.sub(title, 1, 19) .. "..."
  end
  
  screen.move(27, 9)
  screen.text(title)
  
  screen.fill()
  
  self.decay_dial:set_value(params:get("decay_" .. current_sample_id) * 100)
  self.decay_dial:redraw()
  
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
    screen.level(5)
    screen.text_center("code/drummer/kits/")
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
  
  add_global_params()
  
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
  
  -- Engine
  engine.generateWaveforms(0)
  
  -- Kits
  load_kits()
  load_kit(1)
  
end
