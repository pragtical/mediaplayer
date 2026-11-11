-- mod-version:3.14.0
-- Video playback using LuaJIT and bundled or system libmpv.
-- @license MIT
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local Widget = require "widget"
local Button = require "widget.button"
local ToggleButton = require "widget.togglebutton"
local renderer = require "renderer"
local system = require "system"
local thread = require "thread"
local runtime = require "plugins.mediaplayer.runtime"
local Playlist = require "plugins.mediaplayer.playlist"
local Visualizer = require "plugins.mediaplayer.visualizer"

---@class config.plugins.mediaplayer
---@field library string Optional path to the libmpv shared library
---@field hardware_decoding boolean Try copy-back hardware decoding with software fallback
---@field max_fps number Maximum video frames per second; 0 follows the editor's configured limit
---@field max_height number Maximum rendered frame height in pixels
---@field scaler "auto"|"lanczos"|"fast_bilinear" Scaling quality and CPU cost
---@field cache_mode "auto"|"yes"|"no" Automatic, always enabled or disabled read-ahead caching
---@field cache_size number Maximum forward packet cache in MiB per player
---@field cache_wait number Seconds to buffer before resuming after a cache underrun
---@field cache_initial boolean Buffer before playback starts and after seeking
---@field volume number Initial volume from 0 to 100
---@field audio_display "artwork"|"visualizer"|"both" Audio-only presentation
---@field audio_effect string Audio visualization effect
---@field audio_visualizer_fps number Maximum audio visualization refresh rate
---@field audio_effect_speed number Visualization animation speed
---@field audio_effect_color renderer.color? Optional single-color palette
config.plugins.mediaplayer = common.merge({
  library = "", hardware_decoding = true, max_fps = 0, max_height = 1080, volume = 80,
  scaler = "auto", cache_mode = "yes", cache_size = 200, cache_wait = 20, cache_initial = true,
  audio_display = "both", audio_effect = "warp", audio_visualizer_fps = 30,
  audio_effect_speed = 1, audio_effect_color = nil,
  config_spec = {
    name = "Media Player",
    {
      label = "libmpv Library", path = "library", type = "file", default = "",
      description = "Overrides bundled and system libmpv discovery. Requires LuaJIT."
    },
    {
      label = "Hardware Decoding", path = "hardware_decoding", type = "toggle",
      default = true,
      description = "Try supported hardware decoders, with automatic software fallback."
    },
    {
      label = "Maximum Frame Rate", path = "max_fps", type = "number",
      default = 0, min = 0, max = 300,
      description = "0 follows the editor's frame rate. A positive value limits video rendering. Audio keeps its original timing."
    },
    {
      label = "Maximum Video Height", path = "max_height", type = "number",
      default = 1080, min = 144, max = 2160, step = 1,
      description = "Maximum displayed height in pixels. Lower values reduce CPU use."
    },
    {
      label = "Scaling", path = "scaler", type = "selection", default = "auto",
      values = {{"Automatic", "auto"}, {"Lanczos (sharper)", "lanczos"},
        {"Performance (faster)", "fast_bilinear"}},
      description = "Automatic uses Lanczos up to 30 FPS and faster bilinear scaling above that."
    },
    {
      label = "Cache Mode", path = "cache_mode", type = "selection", default = "yes",
      values = {{"Automatic", "auto"}, {"Always", "yes"}, {"Disabled", "no"}},
      description = "Automatic detects network shares. Always also enables caching for local files and unrecognized shares."
    },
    {
      label = "Cache Size (MiB)", path = "cache_size", type = "number",
      default = 200, min = 1, max = 8192, step = 1,
      description = "Maximum memory for compressed packets buffered ahead per video. Increasing this allows more read-ahead on network shares."
    },
    {
      label = "Buffer Duration (seconds)", path = "cache_wait", type = "number",
      default = 20, min = 0, max = 300, step = 0.5,
      description = "Time to buffer before resuming after an underrun; 0 skips the wait. Limited by the cache size and remaining media."
    },
    {
      label = "Buffer Before Playback", path = "cache_initial", type = "toggle", default = true,
      description = "Wait for the buffer duration before starting playback and after seeking. Requires caching."
    },
    {
      label = "Audio Display", path = "audio_display", type = "selection", default = "both",
      values = {{"Artwork", "artwork"}, {"Visualization", "visualizer"}, {"Both", "both"}},
      description = "Choose what audio tracks show in the player area. Visualizations require the bundled libmpv runtime."
    },
    {
      label = "Audio Effect", path = "audio_effect", type = "selection", default = "warp",
      values = Visualizer.effects, description = "Visualization used for audio tracks."
    },
    {
      label = "Visualization Frame Rate", path = "audio_visualizer_fps", type = "number",
      default = 30, min = 1, max = 60,
      description = "Limits visualization updates while audio is playing and the player is visible."
    },
    {
      label = "Effect Speed", path = "audio_effect_speed", type = "number",
      default = 1, min = 0.1, max = 5, step = 0.1,
      description = "Animation speed for audio visualizations."
    },
    {
      label = "Effect Color", path = "audio_effect_color", type = "color", default = nil,
      get_value = function(value) return value or style.text end,
      description = "Choose a single-color palette; reset to use the effect's automatic colors."
    },
    {
      label = "Initial Volume", path = "volume", type = "number",
      default = 80, min = 0, max = 100,
      description = "Playback volume for newly opened videos."
    }
  }
}, config.plugins.mediaplayer)

local ffi, mpv

---@type {view:plugins.mediaplayer.view, root:core.rootview, window:renwindow, draw:function?, previous_draw:function, override:function, restore_window:boolean}?
local fullscreen

local filter_threads = math.max(1, math.min(4, thread.get_cpu_count()))

---Resolve the configured presentation limit independently of native frame polling.
---@return number fps
local function presentation_fps()
  local fps = config.plugins.mediaplayer.max_fps
  return math.max(1, fps > 0 and fps or config.fps)
end

---Choose a scaling filter without spending the entire high-frame-rate budget on sharpening.
---@param fps number Source frame rate; zero when not yet known
---@return "lanczos"|"fast_bilinear" scaler
local function select_scaler(fps)
  local scaler = config.plugins.mediaplayer.scaler
  if scaler == "auto" then
    return (fps <= 0 or fps > 30.5) and "fast_bilinear" or "lanczos"
  end
  return scaler == "fast_bilinear" and scaler or "lanczos"
end

---Prepare scaled RGBA in libmpv's native filter pipeline instead of the UI thread.
---@param width integer Output width; -2 preserves the input aspect ratio
---@param height integer Output height
---@param scaler string FFmpeg scaling algorithm
---@return string filter libmpv video filter description
local function scale_filter(width, height, scaler)
  return string.format("lavfi=[scale=w=%d:h=%d:flags=%s,format=rgba]:o=[threads=%d]",
    width, height, scaler, filter_threads)
end

---@class plugins.mediaplayer.player
---@field native ffi.cdata Owned libmpv handles, released on close or garbage collection
---@field library ffi.cdata Library kept alive until the native handles are released
---@field pixels string? Last rendered RGBA frame
---@field pixel_width integer Width of the retained frame, independent of a pending resize
---@field pixel_height integer Height of the retained frame
---@field width integer Rendered frame width
---@field height integer Rendered frame height
---@field aspect number Display aspect ratio
---@field frame_rate number Source frame rate, or zero until known
---@field scaler string Scaling algorithm used by the current native filter
---@field position number Current playback time in seconds
---@field duration number Media duration in seconds
---@field paused boolean Whether playback is paused
---@field loaded boolean Whether libmpv has loaded the media
---@field ended boolean Whether playback has reached the end
---@field volume number Current volume from 0 to 100
---@field muted boolean Whether audio is muted
---@field hardware_decoding boolean Whether automatic hardware decoding is requested
---@field hardware_decoder string Active hardware decoder, or "no" for software
---@field cache_mode string? Last applied native cache mode
---@field cache_size number? Last applied forward cache limit in MiB
---@field cache_wait number? Last applied refill duration in seconds
---@field cache_initial boolean? Whether initial buffering was last requested
---@field buffering boolean Whether libmpv paused automatically to refill its cache
---@field cache_percent number Percentage of the required refill duration buffered
---@field has_video boolean Whether the selected track includes a video stream
---@field has_audio boolean Whether an audio track is selected
---@field artwork boolean Whether the video stream is embedded cover art
---@field capture_audio_fn ffi.cdata? Optional bundled-runtime capture toggle
---@field audio_samples_fn ffi.cdata? Optional bundled-runtime sample reader
---@field capture_enabled boolean Whether PCM snapshots are enabled
---@field message string? Loading or playback error
---@field force boolean Whether pixels need rendering before the next presentation
local Player = {}
Player.__index = Player

---Release the renderer before the client; safe to call more than once.
function Player:close()
  local owner, library = self.native, self.library
  if owner.context ~= nil then
    library.mpv_render_context_free(owner.context)
    owner.context = nil
  end
  if owner.handle ~= nil then
    library.mpv_terminate_destroy(owner.handle)
    owner.handle = nil
  end
  self.pixels, self.buffer, self.surface = nil, nil, nil
end

---Raise a readable error for a failed libmpv operation.
---@param result integer libmpv result code
function Player:check(result)
  if result < 0 then error(ffi.string(self.library.mpv_error_string(result)), 0) end
end

---Apply cache settings before initialization or asynchronously when they change.
---@param initializing? boolean Whether native options must be set before mpv_initialize
function Player:configure_cache(initializing)
  local cfg = config.plugins.mediaplayer
  local mode = cfg.cache_mode == "yes" and "yes" or cfg.cache_mode == "no" and "no" or "auto"
  local size = math.floor(common.clamp(cfg.cache_size, 1, 8192))
  local wait = common.clamp(cfg.cache_wait, 0, 300)
  local initial = cfg.cache_initial == true
  if mode == self.cache_mode and size == self.cache_size
    and wait == self.cache_wait and initial == self.cache_initial
  then return end
  local options = {
    cache = mode, ["demuxer-max-bytes"] = string.format("%dMiB", size),
    ["cache-pause-wait"] = tostring(wait), ["cache-pause-initial"] = initial and "yes" or "no"
  }
  for name, value in pairs(options) do
    if initializing then
      self:check(self.library.mpv_set_option_string(self.native.handle, name, value))
    else
      self:command("set", name, value)
    end
  end
  self.cache_mode, self.cache_size, self.cache_wait, self.cache_initial = mode, size, wait, initial
end

---Initialize an idle client and renderer, leaving media loading to the owning view.
---@param previous? plugins.mediaplayer.player Volume and mute state to retain
---@return plugins.mediaplayer.player
function Player.new(previous)
  mpv, ffi = runtime.load()
  local library = mpv
  -- System libmpv remains usable without our optional PCM snapshot extension.
  local snapshots, capture_audio, audio_samples = pcall(function()
    return library.mpv_pragtical_audio_capture, library.mpv_pragtical_audio_samples
  end)
  if not snapshots then capture_audio, audio_samples = nil, nil end
  local self = setmetatable({
    library = library, width = 0, height = 0, pixel_width = 0, pixel_height = 0,
    aspect = 16 / 9, frame_rate = 0,
    scaler = select_scaler(0),
    position = 0, duration = 0, paused = false, loaded = false, ended = false,
    volume = previous and previous.volume or common.clamp(config.plugins.mediaplayer.volume, 0, 100),
    muted = previous and previous.muted or false,
    hardware_decoding = config.plugins.mediaplayer.hardware_decoding ~= false,
    hardware_decoder = "no",
    has_video = false, has_audio = false, artwork = false, capture_enabled = false,
    capture_audio_fn = capture_audio, audio_samples_fn = audio_samples,
    buffering = false, cache_percent = 0,
    message = "Loading media...", force = true,
    nonblocking = ffi.new("int[1]", 0), skip = ffi.new("int[1]", 1)
  }, Player)
  self.skip_params = ffi.new("pragtical_media_param[3]", {
    {13, self.skip}, {12, self.nonblocking}, {0, nil}
  })
  -- The finalizer owns only native handles, never a view or its coroutine.
  self.native = ffi.gc(ffi.new("pragtical_media_owner"), function(owner)
    if owner.context ~= nil then library.mpv_render_context_free(owner.context) end
    if owner.handle ~= nil then library.mpv_terminate_destroy(owner.handle) end
  end)
  local ok, err = pcall(function()
    self.native.handle = library.mpv_create()
    if self.native.handle == nil then error("Could not create the video player.", 0) end
    local options = {
      vo = "libmpv", terminal = "no", config = "no", ["keep-open"] = "yes",
      ["input-default-bindings"] = "no", ["input-vo-keyboard"] = "no",
      ["load-scripts"] = "no", osc = "no", volume = tostring(self.volume),
      hwdec = self.hardware_decoding and "auto-copy" or "no",
      -- Copy-back produces CPU frames, so decoding/downloads can safely run
      -- ahead of scaling without retaining a queue of GPU decoder surfaces.
      ["vd-queue-enable"] = "yes", ["vd-queue-max-samples"] = "3",
      ["vd-queue-max-bytes"] = "64MiB",
      mute = self.muted and "yes" or "no",
      vf = scale_filter(-2, common.clamp(config.plugins.mediaplayer.max_height, 144, 2160), self.scaler)
    }
    -- The minimal Linux runtime has no system font provider; use fonts shipped
    -- with the editor for embedded subtitle tracks and native OSD text.
    options["sub-fonts-dir"] = DATADIR .. PATHSEP .. "fonts"
    options["osd-fonts-dir"] = options["sub-fonts-dir"]
    options["sub-font"], options["osd-font"] = "Fira Sans", "Fira Sans"
    for name, value in pairs(options) do
      local result = library.mpv_set_option_string(self.native.handle, name, value)
      -- Scripting options are absent from the minimal runtime's Lua-free build.
      if result ~= -5 or (name ~= "load-scripts" and name ~= "osc") then
        self:check(result)
      end
    end
    self:configure_cache(true)
    self:check(library.mpv_initialize(self.native.handle))
    local api = ffi.new("char[3]", "sw")
    local params = ffi.new("pragtical_media_param[2]", {{1, api}, {0, nil}})
    local context = ffi.new("pragtical_media_context *[1]")
    self:check(library.mpv_render_context_create(context, self.native.handle, params))
    self.native.context = context[0]
    local properties = {
      ["time-pos"] = 5, duration = 5, pause = 3, volume = 5, mute = 3,
      ["eof-reached"] = 3, ["video-params/aspect"] = 5, ["hwdec-current"] = 1,
      ["container-fps"] = 5, ["paused-for-cache"] = 3, ["cache-buffering-state"] = 5,
      ["video-format"] = 1, ["current-tracks/audio/id"] = 5,
      ["current-tracks/video/albumart"] = 3
    }
    for name, format in pairs(properties) do
      self:check(library.mpv_observe_property(self.native.handle, 0, name, format))
    end
  end)
  if not ok then self:close() error(err, 0) end
  return self
end

---Enable a bounded snapshot of this client's output only, without blocking audio.
---@param enabled boolean
function Player:set_audio_capture(enabled)
  enabled = enabled == true
  if not self.capture_audio_fn or enabled == self.capture_enabled then return end
  local result = self.capture_audio_fn(self.native.handle, enabled and 1 or 0)
  self:check(result)
  if result == 1 then self.capture_enabled = enabled end
end

---Read new interleaved PCM into reusable Lua/FFI buffers on the editor thread.
---@return number[]? samples Nil when unchanged, busy, or unavailable
---@return table? spec Channels and sample_rate for these normalized samples
function Player:get_audio_samples()
  if not self.capture_enabled then return end
  if not self.sample_buffer then
    self.sample_buffer = ffi.new("float[4096]")
    self.sample_channels, self.sample_rate = ffi.new("int[1]"), ffi.new("int[1]")
    self.sample_sequence = ffi.new("uint64_t[1]")
    self.audio_samples, self.audio_spec = {}, {}
  end
  local frames = self.audio_samples_fn(self.native.handle, self.sample_buffer, 2048,
    self.sample_channels, self.sample_rate, self.sample_sequence)
  self:check(frames)
  if frames == 0 then return end
  local samples, count = self.audio_samples, frames * self.sample_channels[0]
  for i = 1, count do samples[i] = tonumber(self.sample_buffer[i - 1]) end
  for i = #samples, count + 1, -1 do samples[i] = nil end
  self.audio_spec.channels = tonumber(self.sample_channels[0])
  self.audio_spec.sample_rate = tonumber(self.sample_rate[0])
  return samples, self.audio_spec
end

---Queue a command without waiting for the decoder on the editor's main thread.
---@param ... string Command and string arguments
function Player:command(...)
  local values = {...}
  local args = ffi.new("const char *[?]", #values + 1)
  for i, value in ipairs(values) do args[i - 1] = value end
  self:check(self.library.mpv_command_async(self.native.handle, 0, args))
end

---Consume a bounded batch of native events, copying event data before polling again.
---@return boolean changed Whether the UI needs refreshing
function Player:poll()
  local changed = false
  self:configure_cache()
  local hardware = config.plugins.mediaplayer.hardware_decoding ~= false
  if hardware ~= self.hardware_decoding then
    self:command("set", "hwdec", hardware and "auto-copy" or "no")
    self.hardware_decoding = hardware
  end
  for _ = 1, 100 do
    local event = self.library.mpv_wait_event(self.native.handle, 0)
    local id = event.event_id
    if id == 0 then break end
    if id == 22 then
      local property = ffi.cast("pragtical_media_property *", event.data)
      local name = ffi.string(property.name)
      if property.data ~= nil then
        local value
        if property.format == 1 then
          value = ffi.string(ffi.cast("char **", property.data)[0])
        elseif property.format == 3 then
          value = ffi.cast("int *", property.data)[0] ~= 0
        elseif property.format == 5 then
          value = tonumber(ffi.cast("double *", property.data)[0])
        end
        if name == "time-pos" then self.position = value
        elseif name == "duration" then self.duration = value
        elseif name == "pause" then self.paused = value
        elseif name == "volume" then self.volume = value
        elseif name == "mute" then self.muted = value
        elseif name == "eof-reached" then self.ended = value
        elseif name == "hwdec-current" then self.hardware_decoder = value
        elseif name == "paused-for-cache" then self.buffering = value
        elseif name == "cache-buffering-state" then self.cache_percent = value
        elseif name == "video-format" then self.has_video = value ~= ""
        elseif name == "current-tracks/audio/id" then self.has_audio = value > 0
        elseif name == "current-tracks/video/albumart" then self.artwork = value
        elseif name == "container-fps" and value > 0 then self.frame_rate = value
        elseif name == "video-params/aspect" and value > 0 then
          self.aspect, self.force = value, true
        end
        changed = true
      elseif name == "video-format" then self.has_video, changed = false, true
      elseif name == "current-tracks/audio/id" then self.has_audio, changed = false, true
      elseif name == "current-tracks/video/albumart" then self.artwork, changed = false, true
      end
    elseif id == 8 then
      self.loaded, self.message, self.force, changed = true, nil, true, true
    elseif id == 7 then
      local ending = ffi.cast("pragtical_media_end *", event.data)
      if ending.reason == 4 then
        self.message = "Cannot play video: " .. ffi.string(self.library.mpv_error_string(ending.error))
        self.loaded = false
        core.error("Media Player: %s", self.message)
      end
      changed = true
    elseif (id == 4 or id == 5) and event.error < 0 then
      self.message = ffi.string(self.library.mpv_error_string(event.error))
      core.error("Media Player: %s", self.message)
      changed = true
    end
  end
  return changed
end

---Resize the aligned surface and request matching RGBA frames from the native filters.
---@param width integer Multiple of 16, for a 64-byte aligned row pitch
---@param height integer Frame height in pixels
function Player:resize(width, height)
  local scaler = select_scaler(self.frame_rate)
  local resized = self.width ~= width or self.height ~= height
  if not resized and self.scaler == scaler then return end
  if resized then
    self.width, self.height = width, height
    local bytes = width * height * 4
    self.buffer = ffi.new("uint8_t[?]", bytes + 63)
    local address = ffi.cast("uintptr_t", self.buffer)
    self.surface = ffi.cast("uint8_t *", address + (64 - tonumber(address % 64)) % 64)
    self.dimensions = ffi.new("int[2]", {width, height})
    self.stride = ffi.new("size_t[1]", width * 4)
    self.format = ffi.new("char[5]", "rgba")
    self.params = ffi.new("pragtical_media_param[6]", {
      {17, self.dimensions}, {18, self.format}, {19, self.stride},
      {20, self.surface}, {12, self.nonblocking}, {0, nil}
    })
  end
  -- Filtering runs on libmpv's native pipeline. The software render context
  -- normally receives ready-sized RGBA and only copies it into our surface.
  self:command("vf", "set", scale_filter(width, height, scaler))
  self.scaler = scaler
  self.force = true
end

---Present a frame scheduled by libmpv, skipping conversion for hidden video.
---@param visible boolean Whether the player tab can be seen
---@return boolean rendered Whether a new RGBA frame is ready
function Player:render(visible)
  local library, context = self.library, self.native.context
  if not self.force and library.mpv_render_context_update(context) == 0 then return false end
  if visible and self.surface and self.loaded then
    self:check(library.mpv_render_context_render(context, self.params))
    -- Render RGBA directly so libmpv supplies alpha without a second pixel pass.
    local bytes = self.width * self.height * 4
    self.pixels = ffi.string(self.surface, bytes)
    self.pixel_width, self.pixel_height = self.width, self.height
    self.force = false
    return true
  end
  self:check(library.mpv_render_context_render(context, self.skip_params))
  -- The view requests a fresh render when this tab becomes visible again.
  self.force = false
  return false
end

---Format a media timestamp as minutes and seconds, with hours when needed.
---@param seconds number Time in seconds
---@return string
local function timestamp(seconds)
  seconds = math.max(0, math.floor(seconds))
  if seconds >= 3600 then
    return string.format("%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
  end
  return string.format("%d:%02d", seconds / 60, seconds % 60)
end

---Center a transport glyph, retaining the button's normal hover colors.
---@param button widget.button Icon-only transport button
---@return boolean drawn Whether the visible button was drawn
local function draw_transport_button(button)
  button.background_color = button.hover_back or button.enabled and style.line_highlight or style.background
  if not Widget.draw(button) then return false end
  local font, icon = style.icon_font, button.icon.code
  renderer.draw_text(font, icon,
    button.position.x + (button.size.x - font:get_width(icon)) / 2,
    button.position.y + (button.size.y - font:get_height()) / 2,
    button.enabled and style.accent or button.hover_text or style.text)
  return true
end

---@class plugins.mediaplayer.view : widget
---@overload fun():plugins.mediaplayer.view
---@field player plugins.mediaplayer.player? Decoder and software renderer
---@field filename string? Absolute path of the current media
---@field closed boolean Whether the tab has been closed
---@field message string? Message shown when the player is unavailable
---@field controls_visible boolean Whether transport and seek controls are shown
---@field controls_enabled boolean Whether interactive controls may be shown
---@field playlist plugins.mediaplayer.playlist Queue, directory scanner and right panel
---@field playlist_visible boolean Whether the right panel is requested
---@field video_width number Presentation width remaining beside the playlist
---@field controls_until number? Monotonic time at which fullscreen controls hide
---@field render_at number? Earliest time to present the next video frame
---@field visualizer plugins.mediaplayer.visualizer? Audio effect drawn inside this view
---@field visualizer_at number? Next permitted audio visualization update
---@field visualizer_player plugins.mediaplayer.player? Source of the current effect history
---@field seek_hover number? Timestamp under the pointer on the seek bar
---@field seek_hover_x number? Screen X coordinate of the seek tooltip
local MediaView = Widget:extend()

---Create an empty video tab and start a weakly owned event pump.
function MediaView:new()
  MediaView.super.new(self, nil, false)
  self.name, self.type_name = "Media Player", "plugins.mediaplayer.view"
  self.border.width, self.scrollable, self.closed = 0, false, false
  self.message = "Open audio or video, or drop a file here. Requires LuaJIT."
  self.controls, self.controls_visible, self.controls_enabled = {}, true, true
  self.playlist_visible = false
  self.playlist = Playlist(self)
  self.playlist:hide()
  self.playlist.on_play = function(_, track) return self:play(track) end
  self.playlist.on_reset = function()
    if self.player then self.player:close() self.player = nil end
    self.filename, self.name, self.message = nil, "Media Player", "Select a video from the playlist."
  end
  local show_picker = self.playlist.folder.show_picker
  self.playlist.folder.show_picker = function(picker)
    self:exit_fullscreen()
    return show_picker(picker)
  end
  ---Create one transport button and bind its action once.
  ---@param label string Button label
  ---@param icon string? Glyph from the editor's icon font
  ---@param tooltip string Tooltip text
  ---@param action function Click action
  ---@return widget.button
  local function button(label, icon, tooltip, action)
    local item = Button(self, label)
    if icon then
      item:set_icon(icon)
      if label == "" then item.draw = draw_transport_button end
    end
    item:set_tooltip(tooltip)
    item.on_click = function(_, mouse) if mouse == "left" then action() end end
    self.controls[#self.controls + 1] = item
    return item
  end
  self.open_button = button("Open", "D", "Open an audio or video file", function() self:choose_file() end)
  self.play_button = button("", "▶", "Play / pause (Space)", function() self:toggle_play() end)
  button("", "■", "Pause and rewind", function() self:stop() end)
  button("", "⏮", "Previous video (Ctrl+Left)", function() self:advance(-1) end)
  button("", "⏭", "Next video (Ctrl+Right)", function() self:advance(1) end)
  self.mute_button = button("Mute", nil, "Mute / unmute (M)", function() self:toggle_mute() end)
  button("Vol -", nil, "Decrease volume (Down)", function() self:change_volume(-5) end)
  button("Vol +", nil, "Increase volume (Up)", function() self:change_volume(5) end)
  self.fullscreen_button = button("", "n", "Toggle fullscreen (F11 / Escape)",
    function() self:toggle_fullscreen() end)
  ---Add an icon toggle bound to persistent playlist settings.
  ---@param icon string Icon font glyph
  ---@param tooltip string Tooltip text
  ---@param action fun(enabled:boolean) Toggle callback
  ---@return widget.togglebutton
  local function toggle(icon, tooltip, action)
    local item = ToggleButton(self, false, "", icon)
    item.draw = draw_transport_button
    item:set_tooltip(tooltip)
    item.on_change = function(_, enabled) action(enabled) end
    self.controls[#self.controls + 1] = item
    return item
  end
  self.repeat_button = toggle("↻", "Repeat playlist", function(enabled) self.playlist.repeat_all = enabled end)
  self.shuffle_button = toggle("⤨", "Shuffle playlist", function(enabled)
    self.playlist.shuffle = enabled
    self.playlist:reset_shuffle()
  end)
  self.playlist_button = toggle("l", "Show playlist (P)", function(enabled) self:set_playlist_visible(enabled) end)
  self:show()
  local reference = setmetatable({self}, {__mode = "v"})
  core.add_background_thread(function()
    while reference[1] and not reference[1].closed do
      local ok, delay = pcall(reference[1].pump, reference[1])
      if not ok then
        reference[1]:report_error(delay)
      end
      coroutine.yield(ok and delay or 0.2)
    end
  end)
end

---Stop a failed decoder and report its error without interrupting editor drawing.
---@private
---@param err any Playback failure
function MediaView:report_error(err)
  self.message = "Video playback failed: " .. tostring(err)
  if self.player then self.player:close() self.player = nil end
  core.error("%s", self.message)
  core.redraw = true
end

---Return the tab title.
---@return string
function MediaView:get_name() return self.name end

---Return presentation bounds without changing the tab's node-owned geometry.
---@return number x Screen X coordinate
---@return number y Screen Y coordinate
---@return number width Presentation width
---@return number height Presentation height
function MediaView:get_bounds()
  if fullscreen and fullscreen.view == self then
    local width, height = fullscreen.window:get_size()
    return 0, 0, width, height
  end
  return self.position.x, self.position.y, self.size.x, self.size.y
end

---Position child controls relative to the presentation instead of the hidden tab.
---@return number x Content X coordinate
---@return number y Content Y coordinate
function MediaView:get_content_offset()
  if fullscreen and fullscreen.view == self then return 0, 0 end
  return MediaView.super.get_content_offset(self)
end

---Accept pointer input throughout the fullscreen presentation or normal tab.
---@param x number Screen X coordinate
---@param y number Screen Y coordinate
---@return boolean inside Whether the pointer lies within this player
function MediaView:mouse_on_top(x, y)
  local bx, by, width, height = self:get_bounds()
  return self.visible and x >= bx and y >= by and x < bx + width and y < by + height
end

---Enable or disable transport and playlist UI for embedded players.
---Programmatic playback methods remain usable when controls are disabled.
---@param enabled boolean
function MediaView:set_controls_enabled(enabled)
  self.controls_enabled = enabled == true
  self:set_controls_visible(self.controls_enabled)
  if self.controls_enabled and self.playlist_visible then self.playlist:show()
  else self.playlist:hide() end
  self:layout()
  core.redraw = true
end

---Show or hide the right playlist panel independently of fullscreen transport fading.
---@param visible boolean
function MediaView:set_playlist_visible(visible)
  self.playlist_visible, self.playlist_button.enabled = visible == true, visible == true
  if self.playlist_visible and self.controls_enabled then self.playlist:show()
  else self.playlist:hide() end
  self:layout()
  core.redraw = true
end

---Show or hide controls, clearing hidden widgets' hover and pointer state.
---@param visible boolean Whether controls should be visible
function MediaView:set_controls_visible(visible)
  if not visible then self.seek_hover, self.seek_hover_x = nil, nil end
  visible = visible and self.controls_enabled
  if self.controls_visible == visible then return end
  if not visible then
    self:on_mouse_left()
    self:on_mouse_capture_lost()
  end
  self.controls_visible = visible
  for _, item in ipairs(self.controls) do
    if visible then item:show() else item:hide() end
  end
  core.redraw = true
end

---Restore editor drawing and the window mode used before exclusive playback.
function MediaView:exit_fullscreen()
  if not fullscreen or fullscreen.view ~= self then return end
  local state = fullscreen
  fullscreen = nil
  self:on_mouse_capture_lost()
  self:on_mouse_left()
  if state.root.draw == state.override then state.root.draw = state.draw end
  if core.window == state.window and state.restore_window
    and core.update_window_state() == "fullscreen"
  then
    command.perform("core:toggle-fullscreen")
  end
  self.controls_until = nil
  self.fullscreen_button.icon.code = "n"
  self:set_controls_visible(true)
  self:layout()
  if self.player then self.player.force = true end
  core.redraw = true
end

---Toggle native fullscreen with exclusive video drawing and input routing.
function MediaView:toggle_fullscreen()
  if fullscreen then
    local previous = fullscreen.view
    previous:exit_fullscreen()
    if previous == self then return end
  end
  -- Other exclusive presentations restore their draw hooks before ours is saved.
  for _, name in ipairs({"plugins.matrix", "plugins.audiovisu"}) do
    local plugin = package.loaded[name]
    if type(plugin) == "table" and plugin.exit_fullscreen then plugin.exit_fullscreen() end
  end
  local root = core.root_view
  local node = root.root_node:get_node_for_view(self)
  if not node or self.closed then return end
  node:set_active_view(self)
  local state = {
    view = self, root = root, window = core.window,
    draw = rawget(root, "draw"), previous_draw = root.draw,
    restore_window = core.update_window_state() ~= "fullscreen"
  }
  ---Draw only this player, discarding deferred draws from hidden editor views.
  ---@param current core.rootview Root whose normal drawing is temporarily replaced
  state.override = function(current)
    if fullscreen ~= state then return state.previous_draw(current) end
    for i = #current.deferred_draws, 1, -1 do current.deferred_draws[i] = nil end
    self:draw()
    if core.cursor_change_req then
      system.set_cursor(core.cursor_change_req)
      core.cursor_change_req = nil
    end
  end
  fullscreen = state
  if state.restore_window then command.perform("core:toggle-fullscreen") end
  root.draw = state.override
  self.fullscreen_button.icon.code = "N"
  self:set_controls_visible(false)
  self:layout()
  system.set_cursor("arrow")
  if self.player then self.player.force = true end
  core.redraw = true
end

---Append and open local media, preserving the current player when dependency loading fails.
---@param filename string Media filename
---@return boolean success
function MediaView:open_file(filename)
  if self.closed then return false end
  filename = system.absolute_path(common.home_expand(filename))
  local info = filename and system.get_file_info(filename)
  if not info or info.type ~= "file" then
    core.error("Media Player: file does not exist: %s", filename or "")
    return false
  end
  return self.playlist:play(self.playlist:add_file(filename))
end

---Replace playback, releasing the old audio device before starting the new file.
---Initialize the replacement first so library/configuration failures preserve playback.
---@param track plugins.mediaplayer.track
---@return boolean success
function MediaView:play(track)
  if self.closed then return false end
  local ok, player = pcall(Player.new, self.player)
  if not ok then
    self.message = tostring(player)
    core.error("Media Player: %s", self.message)
    core.redraw = true
    return false
  end
  if self.player then self.player:close() end
  self.player, self.filename, self.message = player, track.path, nil
  self.visualizer, self.visualizer_player, self.visualizer_at, self.seek_hover = nil, nil, nil, nil
  self.render_at = nil
  local started, err = pcall(player.command, player, "loadfile", track.path, "replace")
  if not started then self:report_error(err) return false end
  self.name, self.visible_last = track.name .. " — Media", false
  core.redraw = true
  return true
end

---Populate the playlist recursively from a directory without starting playback.
---@param path string Directory path
---@return boolean started
function MediaView:scan(path)
  if self.closed or not self.playlist:scan(path) then return false end
  self:set_playlist_visible(true)
  return true
end

---Start the previous or next video in the playback queue.
---@param direction integer -1 for previous, 1 for next
---@param automatic? boolean Whether this follows the end of a video
---@return boolean success
function MediaView:advance(direction, automatic)
  return self.playlist:advance(direction, automatic)
end

---Choose local media through the native picker or the command view.
function MediaView:choose_file()
  self:exit_fullscreen()
  if config.use_system_file_picker then
    core.open_file_dialog(core.window, function(status, result)
      if status == "accept" and result[1] and not self.closed then self:open_file(result[1]) end
    end, {
      title = "Open Media", filters = {
        {name = "Video files", pattern = "mp4;mkv;webm;mov;avi;m4v;mpeg;mpg;ogv;ts"},
        {name = "Audio files", pattern = "aac;aif;aiff;ape;flac;m4a;m4b;mka;mp2;mp3;oga;ogg;opus;wav;wma;wv"},
        {name = "All files", pattern = "*"}
      }
    })
  else
    core.command_view:enter("Open Media", {
      text = self.filename or "",
      select_text = true,
      suggest = function(text) return common.path_suggest(common.home_expand(text)) end,
      submit = function(text) if not self.closed then self:open_file(text) end end
    })
  end
end

---Toggle playback, restarting a completed video from its beginning.
function MediaView:toggle_play()
  local player = self.player
  if not player then
    if self.playlist.shuffle then self:advance(1) else self.playlist:play_selected() end
    return
  end
  if not player.loaded then return end
  if player.ended then
    player:command("seek", "0", "absolute+exact")
    player:command("set", "pause", "no")
  else
    player:command("cycle", "pause")
  end
end

---Pause the video and return to the beginning.
function MediaView:stop()
  if not self.player or not self.player.loaded then return end
  self.player:command("set", "pause", "yes")
  self:seek_to(0)
end

---Seek to an absolute playback time, clamped to the media duration.
---@param seconds number Playback time in seconds
function MediaView:seek_to(seconds)
  local player = self.player
  if not player or not player.loaded then return end
  seconds = math.max(0, seconds)
  if player.duration > 0 then seconds = math.min(seconds, player.duration) end
  player:command("seek", tostring(seconds), "absolute+exact")
  -- Audio-only playback may not publish time-pos until output resumes.
  player.position = seconds
  core.redraw = true
end

---Seek relative to the current playback position.
---@param seconds number Signed offset in seconds
function MediaView:seek_by(seconds)
  if self.player then self:seek_to(self.player.position + seconds) end
end

---Adjust volume within the unamplified 0–100 range.
---@param amount number Signed volume adjustment
function MediaView:change_volume(amount)
  if self.player then
    self.player:command("set", "volume", tostring(common.clamp(self.player.volume + amount, 0, 100)))
  end
end

---Toggle audio muting without changing the volume.
function MediaView:toggle_mute()
  if self.player then self.player:command("cycle", "mute") end
end

---Center each row of controls, wrapping when needed and reserving space for video.
function MediaView:layout()
  local pad, gap = style.padding.x, style.padding.y
  local _, _, available_width, available_height = self:get_bounds()
  local panel_width = self.playlist.visible and math.min(400 * SCALE, available_width * 0.42) or 0
  self.video_width = available_width - panel_width
  self.playlist:set_position(self.video_width, 0)
  self.playlist:set_size(panel_width, available_height)
  available_width = self.video_width
  if not self.controls_enabled then
    self.video_top, self.timeline_y = 0, available_height + gap
    return
  end
  -- Square transport buttons keep their positions when play switches to pause.
  local button_height = self.play_button:get_height()
  for _, item in ipairs(self.controls) do
    if item.icon.code and item.label == "" then
      item:set_size(button_height, button_height)
    end
  end
  local first, y = 1, gap
  while first <= #self.controls do
    local last, width, height = first - 1, 0, 0
    for index = first, #self.controls do
      local item = self.controls[index]
      local next_width = width + (index > first and gap or 0) + item:get_width()
      if index > first and next_width > available_width - pad * 2 then break end
      last, width, height = index, next_width, math.max(height, item:get_height())
    end
    local x = math.max(pad, math.floor((available_width - width) / 2))
    for index = first, last do
      local item = self.controls[index]
      item:set_position(x, y + math.floor((height - item:get_height()) / 2))
      x = x + item:get_width() + gap
    end
    first, y = last + 1, y + height + gap
  end
  self.video_top = y
  self.timeline_y = math.max(self.video_top, available_height - style.font:get_height() - gap * 3)
end

---Update widget geometry, including scale-dependent transport sizes.
function MediaView:update()
  if not MediaView.super.update(self) then return end
  self:layout()
  if fullscreen and fullscreen.view == self and self.controls_visible then
    local remaining = (self.controls_until or 0) - system.get_time()
    if remaining <= 0 and not self.mouse_is_pressed and not self.captured_widget then
      self:set_controls_visible(false)
    else
      core.request_update(math.max(0.05, remaining))
    end
  end
end

---Update audio effects only while visible and playing; never sample other applications.
---@private
---@param player plugins.mediaplayer.player
---@param visible boolean
---@return boolean changed
function MediaView:update_visualizer(player, visible)
  local display = config.plugins.mediaplayer.audio_display
  local changed = self.audio_display ~= display
  self.audio_display = display
  local audio_only = player.loaded and player.has_audio and (not player.has_video or player.artwork)
  local wanted = audio_only and display ~= "artwork" and player.capture_audio_fn ~= nil
  if wanted then
    if not self.visualizer then self.visualizer, changed = Visualizer(), true end
    if self.visualizer_player ~= player then
      self.visualizer:reset()
      self.visualizer_player, self.visualizer_at, changed = player, nil, true
    end
  elseif self.visualizer then
    self.visualizer, self.visualizer_player, self.visualizer_at, changed = nil, nil, nil, true
  end
  local playing = wanted and visible and not player.paused and not player.ended and not player.buffering
  player:set_audio_capture(playing)
  local now = system.get_time()
  if playing and now >= (self.visualizer_at or 0) then
    local samples, spec = player:get_audio_samples()
    if samples then self.visualizer:update(samples, spec)
    else self.visualizer:advance() end
    local fps = math.min(presentation_fps(), common.clamp(config.plugins.mediaplayer.audio_visualizer_fps, 1, 60))
    self.visualizer_at = now + 1 / fps
    changed = true
  end
  return changed
end

---Poll events and request presentation, keeping conversion out of the coroutine budget.
---@return number delay Seconds until the next pump
function MediaView:pump()
  local node = core.root_view.root_node:get_node_for_view(self)
  if node then self.attached = true
  elseif self.attached then self:close() return 0.2 end
  if fullscreen and fullscreen.view == self
    and (core.root_view ~= fullscreen.root or not node or node.active_view ~= self
      or not self:owns_view(core.active_view) or fullscreen.root.draw ~= fullscreen.override)
  then self:exit_fullscreen() end
  local player = self.player
  if not player then return 0.2 end
  local active = node and node.active_view == self
  local _, _, available_width, available_height = self:get_bounds()
  local visible = active and available_width > 0 and available_height > 0
  local ended = player.ended
  local changed = player:poll()
  if player.ended and not ended and self:advance(1, true) then
    player, changed = self.player, true
  end
  local visual_changed = self:update_visualizer(player, visible)
  changed = changed or visual_changed
  local video_visible = visible and (player.has_video or not player.loaded)
    and (not player.artwork or self.audio_display ~= "visualizer" or not self.visualizer)
  if video_visible then
    self:layout()
    local height = fullscreen and fullscreen.view == self and available_height
      or math.max(0, self.timeline_y - self.video_top - style.padding.y)
    height = math.min(height, common.clamp(config.plugins.mediaplayer.max_height, 144, 2160))
    if player.artwork and self.visualizer then height = height * 0.55 end
    local width = math.floor(math.min(self.video_width, height * player.aspect) / 16) * 16
    height = math.floor(width / player.aspect)
    if width >= 16 and height > 0 then player:resize(width, height)
    else video_visible = false end
  end
  if video_visible and not self.visible_last then player.force = true end
  self.visible_last = video_visible
  if player.library.mpv_render_context_update(player.native.context) ~= 0 then player.force = true end
  if not video_visible then player:render(false) end
  local limited = presentation_fps() < config.fps
  local due = not limited or system.get_time() >= (self.render_at or 0)
  if active and (changed or video_visible and player.force and due) then
    self.play_button.icon.code = (player.paused or player.ended) and "▶" or "⏸"
    local mute_label = player.muted and "Unmute" or "Mute"
    if self.mute_button.label ~= mute_label then self.mute_button:set_label(mute_label) end
    core.redraw = true
  end
  -- Poll cheaply ahead of presentation; hidden frames also need acknowledgement.
  local poll_fps = math.min(math.max(240, presentation_fps()), math.max(60, player.frame_rate * 4))
  if player.force then
    -- Advance libmpv promptly, retaining its current frame for the next draw.
    -- Waiting for the editor's capped draw blocks high-frame-rate playback.
    player:check(player.library.mpv_render_context_render(player.native.context, player.skip_params))
  end
  return player.paused and 0.1 or 1 / poll_fps
end

---Draw video pixels, letterboxing, a seek bar, and transport status.
---@param color renderer.color Background color chosen by Widget
function MediaView:draw_background(color)
  self:layout()
  local x, y, width, height = self:get_bounds()
  local exclusive = fullscreen and fullscreen.view == self
  local top = exclusive and 0 or self.video_top
  local bottom = exclusive and height or self.timeline_y - style.padding.y
  renderer.draw_rect(x, y, width, height, color)
  width = self.video_width
  renderer.draw_rect(x, y + top, width, math.max(0, bottom - top), {0, 0, 0, 255})
  local player = self.player
  local now = system.get_time()
  local fps = presentation_fps()
  local limited = fps < config.fps
  if player and self.visible_last and player.force and (not limited or player.paused or now >= (self.render_at or 0)) then
    -- Conversion is drawing work. Doing it in the polling coroutine makes the
    -- editor penalize it with an extra sleep, dropping otherwise playable frames.
    local ok, rendered = pcall(player.render, player, true)
    if not ok then self:report_error(rendered) player = nil
    elseif rendered then
      self.render_at = math.max((self.render_at or now) + 1 / fps, now)
    end
  end
  core.push_clip_rect(x, y + top, width, math.max(0, bottom - top))
  if self.visualizer then self.visualizer:draw(x, y + top, width, math.max(0, bottom - top)) end
  local show_artwork = not player or not player.artwork or self.audio_display ~= "visualizer" or not self.visualizer
  if player and player.pixels and show_artwork then
    renderer.draw_pixels(player.pixels,
      x + math.floor((width - player.pixel_width) / 2),
      y + top + math.floor((bottom - top - player.pixel_height) / 2),
      player.pixel_width, player.pixel_height)
  end
  local message = self.message or player and player.message
    or player and player.buffering and string.format("Buffering... %d%%", player.cache_percent)
  if not message and player and player.loaded and not player.has_video and not self.visualizer then
    message = common.basename(self.filename or "Audio playback")
  end
  if message then
    common.draw_text(style.font, style.text, message, "center", x + style.padding.x,
      y + top, math.max(0, width - style.padding.x * 2), math.max(0, bottom - top))
  end
  core.pop_clip_rect()
  if not self.controls_visible then return end
  if exclusive then
    renderer.draw_rect(x, y, width, self.video_top, color)
    renderer.draw_rect(x, y + self.timeline_y - style.padding.y, width,
      height - self.timeline_y + style.padding.y, color)
  end
  local pad, bar_height = style.padding.x, math.max(3, math.floor(4 * SCALE))
  width = math.max(0, width - pad * 2)
  renderer.draw_rect(x + pad, y + self.timeline_y, width, bar_height, style.background3)
  if player then
    local fraction = player.duration > 0 and common.clamp(player.position / player.duration, 0, 1) or 0
    renderer.draw_rect(x + pad, y + self.timeline_y, width * fraction, bar_height, style.accent)
    local text = timestamp(player.position) .. " / " .. timestamp(player.duration)
      .. string.format("    Volume: %d%%%s", player.volume, player.muted and " (muted)" or "")
      .. "    Decoder: " .. (player.hardware_decoder == "no" and "Software" or player.hardware_decoder)
    renderer.draw_text(style.font, text, x + pad,
      y + self.timeline_y + style.padding.y, style.text)
  end
  self:draw_seek_tooltip()
end

---Return the cached media time at a point on the seek bar, without native queries.
---@private
---@param x number Screen X coordinate
---@param y number Screen Y coordinate
---@return number? seconds Nil outside the visible seek bar or before duration is known
function MediaView:get_seek_time(x, y)
  if not self.controls_enabled or not self.controls_visible or not self.player
    or self.player.duration <= 0 then return end
  local bx, by = self:get_bounds()
  local pad, width = style.padding.x, self.video_width - style.padding.x * 2
  if width <= 0 or x < bx + pad or x > bx + pad + width
    or y < by + self.timeline_y - style.padding.y
    or y >= by + self.timeline_y + style.padding.y then return end
  return common.clamp((x - bx - pad) / width, 0, 1) * self.player.duration
end

---Draw a timestamp above the seek bar in the same style as status-item tooltips.
---@private
function MediaView:draw_seek_tooltip()
  if not self.seek_hover or not self.controls_visible then return end
  local text, font = timestamp(self.seek_hover), style.font
  local bx, by = self:get_bounds()
  local width = math.min(self.video_width, math.ceil(font:get_width(text) + style.padding.x * 2))
  local height = math.ceil(font:get_height() + style.padding.y * 2)
  local x = math.floor(common.clamp(self.seek_hover_x - width / 2, bx, bx + self.video_width - width))
  local y = math.floor(math.max(by, by + self.timeline_y - style.padding.y - height))
  renderer.draw_rect(x, y, width, height, style.background3)
  core.push_clip_rect(x, y, width, height)
  renderer.draw_text(font, text, math.floor(x + style.padding.x), math.floor(y + style.padding.y), style.text)
  core.pop_clip_rect()
end

---Draw the normal widget or fullscreen video with controls overlaid on top.
---@return boolean drawn Whether the player was drawn
function MediaView:draw()
  if not fullscreen or fullscreen.view ~= self then return MediaView.super.draw(self) end
  local x, y, width, height = self:get_bounds()
  core.push_clip_rect(x, y, width, height)
  self:draw_background(style.background)
  if self.controls_visible then
    for _, item in ipairs(self.controls) do item:draw() end
  end
  if self.playlist.visible then self.playlist:draw() end
  core.pop_clip_rect()
  return true
end

---Reveal fullscreen controls on real pointer movement, then reuse widget hover routing.
---@param x number Screen X coordinate
---@param y number Screen Y coordinate
---@param dx number Horizontal pointer movement
---@param dy number Vertical pointer movement
---@return boolean? handled Whether a widget handled the movement
function MediaView:on_mouse_moved(x, y, dx, dy)
  if self.controls_enabled and fullscreen and fullscreen.view == self and self:mouse_on_top(x, y)
    and (dx ~= 0 or dy ~= 0)
  then
    self.controls_until = system.get_time() + 3
    self:set_controls_visible(true)
    self:layout()
    core.request_update(3)
  end
  local handled = MediaView.super.on_mouse_moved(self, x, y, dx, dy)
  local time = self:get_seek_time(x, y)
  if self.seek_hover ~= time or time and self.seek_hover_x ~= x then core.redraw = true end
  self.seek_hover, self.seek_hover_x = time, time and x or nil
  return handled
end

---Seek when the timeline is clicked; video clicks toggle play/pause.
---@param button string Mouse button
---@param x number Screen X coordinate
---@param y number Screen Y coordinate
function MediaView:on_click(button, x, y)
  if not self.controls_enabled or button ~= "left" or not self.player then return end
  local bx, by, width, height = self:get_bounds()
  width = self.video_width
  if x < bx or x >= bx + width then return end
  local local_y = y - by
  if self.controls_visible and local_y >= self.timeline_y - style.padding.y
    and local_y < self.timeline_y + style.padding.y
  then
    local time = self:get_seek_time(x, y)
    if time then self:seek_to(time) end
  elseif (fullscreen and fullscreen.view == self and not self.controls_visible
    and local_y >= 0 and local_y < height)
    or (local_y >= self.video_top and local_y < self.timeline_y - style.padding.y)
  then
    self:toggle_play()
  end
end

---Open a dropped video or recursively scan a dropped directory.
---@param filename string Dropped path
---@return boolean handled
function MediaView:on_file_dropped(filename)
  local info = system.get_file_info(filename)
  if info and info.type == "dir" then return self:scan(filename) end
  if Playlist.is_supported(filename, true) then return self:open_file(filename) end
  return false
end

---Release native resources when closed or removed by a workspace replacement.
function MediaView:close()
  self:exit_fullscreen()
  self.closed = true
  self.playlist:close()
  self.visualizer, self.visualizer_player = nil, nil
  if self.player then self.player:close() self.player = nil end
end

---Close playback before allowing the tab to be removed.
---@param do_close function Node callback that removes the view
function MediaView:try_close(do_close)
  self:close()
  do_close()
end

---@class plugins.mediaplayer
---@field MediaView plugins.mediaplayer.view Video player view constructor
---@field is_supported fun(path:string,include_audio?:boolean):boolean Check video extensions, optionally audio, without loading libmpv
local mediaplayer = {MediaView = MediaView, is_supported = Playlist.is_supported}

---Leave exclusive video playback, allowing other fullscreen plugins to take over.
function mediaplayer.exit_fullscreen()
  if fullscreen then fullscreen.view:exit_fullscreen() end
end

---Open a new video tab, optionally starting a file or scanning a directory.
---@param filename? string Media or directory path; omit to create an empty player
---@return plugins.mediaplayer.view
function mediaplayer.open(filename)
  local view = MediaView()
  core.root_view:get_active_node_default():add_view(view)
  local info = filename and system.get_file_info(common.home_expand(filename))
  if info and info.type == "dir" then view:scan(filename)
  elseif filename then view:open_file(filename) end
  return view
end

command.add(nil, { ["media-player:open"] = function() mediaplayer.open() end })
command.add(function()
  local view = core.active_view
  return view:is(MediaView) and view.controls_enabled and not view.child_active, view
end, {
  ["media-player:open-file"] = function(view) view:choose_file() end,
  ["media-player:play-pause"] = function(view) view:toggle_play() end,
  ["media-player:stop"] = function(view) view:stop() end,
  ["media-player:seek-backward"] = function(view) view:seek_by(-10) end,
  ["media-player:seek-forward"] = function(view) view:seek_by(10) end,
  ["media-player:volume-down"] = function(view) view:change_volume(-5) end,
  ["media-player:volume-up"] = function(view) view:change_volume(5) end,
  ["media-player:toggle-mute"] = function(view) view:toggle_mute() end,
  ["media-player:next"] = function(view) view:advance(1) end,
  ["media-player:previous"] = function(view) view:advance(-1) end,
  ["media-player:toggle-playlist"] = function(view) view:set_playlist_visible(not view.playlist_visible) end,
  ["media-player:toggle-repeat"] = function(view) view.repeat_button:toggle() end,
  ["media-player:toggle-shuffle"] = function(view) view.shuffle_button:toggle() end,
  ["media-player:toggle-fullscreen"] = function(view) view:toggle_fullscreen() end
})
command.add(function()
  local view = core.active_view
  return view:is(MediaView) and view.controls_enabled and not view.child_active and view.playlist_visible, view
end, {
  ["media-player:select-next"] = function(view) view.playlist:select_row(1) end,
  ["media-player:select-previous"] = function(view) view.playlist:select_row(-1) end,
  ["media-player:play-selected"] = function(view) view.playlist:play_selected() end
})
keymap.add {
  ["space"] = "media-player:play-pause", ["left"] = "media-player:seek-backward",
  ["right"] = "media-player:seek-forward",
  ["down"] = {"media-player:select-next", "media-player:volume-down"},
  ["up"] = {"media-player:select-previous", "media-player:volume-up"},
  ["return"] = "media-player:play-selected", ["p"] = "media-player:toggle-playlist",
  ["ctrl+right"] = "media-player:next", ["ctrl+left"] = "media-player:previous",
  ["m"] = "media-player:toggle-mute",
  ["f11"] = "media-player:toggle-fullscreen"
}
core.menu_view:register({"view"}, {
  {id = "media-player", text = "Open Media Player", command = "media-player:open"}
}, "mediaplayer")

local default_view
local open_file = core.open_file
---Route supported videos into a shared player tab, retaining other file handlers.
---@param filename string File to open through the editor
---@param ... any Arguments forwarded unchanged to the existing file handler
---@return core.view? view Opened view, or the prior handler's result
core.open_file = function(filename, ...)
  if not Playlist.is_supported(filename) then return open_file(filename, ...) end
  local view = core.active_view
  while view.parent do view = view.parent end
  if not view:is(MediaView) or view.closed or not view.controls_enabled then view = default_view end
  local node = view and not view.closed and view.controls_enabled
    and core.root_view.root_node:get_node_for_view(view)
  if not node then
    view = MediaView()
    node = core.root_view:get_active_node_default()
    node:add_view(view)
  end
  default_view = view
  view:open_file(filename)
  view:swap_active_child()
  node:set_active_view(view)
  core.set_active_view(view)
  return view
end

local on_event = core.on_event
---Route exclusive playback input to the player and restore the editor on dismissal.
---@param event string Core event name
---@param ... any Event arguments
---@return any handled Result of the player or previous event handler
core.on_event = function(event, ...)
  if fullscreen then
    local view = fullscreen.view
    if event == "keypressed" and select(1, ...) == "escape" then
      view:exit_fullscreen()
      return true
    elseif event == "focuslost" or event == "quit"
      or (event == "leavefullscreen" and core.update_window_state() ~= "fullscreen")
    then
      view:exit_fullscreen()
    elseif event == "mousemoved" then
      fullscreen.root.mouse.x, fullscreen.root.mouse.y = ...
      view:layout()
      view:on_mouse_moved(...)
      return true
    elseif event == "mousepressed" then
      view:layout()
      view:on_mouse_pressed(...)
      return true
    elseif event == "mousereleased" then
      view:layout()
      view:on_mouse_released(...)
      return true
    elseif event == "mouseleft" then
      view:set_controls_visible(false)
      return true
    elseif event == "filedropped" then
      return view:on_file_dropped(...)
    elseif event == "mousewheel" then
      view:on_mouse_wheel(...)
      return true
    elseif (event == "textinput" or event == "textediting") and view:owns_view(core.active_view)
      and core.active_view ~= view
    then
      return on_event(event, ...)
    elseif event == "textinput" or event == "textediting"
      or event == "touchpressed" or event == "touchreleased" or event == "touchmoved"
    then
      return true
    end
  end
  return on_event(event, ...)
end

return mediaplayer
