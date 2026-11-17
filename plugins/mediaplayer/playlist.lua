local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local system = require "system"
local renderer = require "renderer"
local Widget = require "widget"
local FilePicker = require "widget.filepicker"
local TextBox = require "widget.textbox"
local ListBox = require "widget.listbox"

local extensions = {}
local audio_extensions = {}
local image_extensions = {}
-- Keep .ts and .mts in the text editor: they also name TypeScript sources.
-- The player's explicit file picker can still open transport streams.
for ext in ("mp4 mkv webm mov avi m4v mpeg mpg mpe m2v m2ts vob ogv "
  .. "flv f4v wmv asf 3gp 3g2 mxf divx"):gmatch("%S+") do
  extensions[ext] = true
end
for ext in ("aac ac3 aif aifc aiff alac amr ape au caf dff dsf dts eac3 flac "
  .. "m4a m4b mka mp1 mp2 mp3 oga ogg opus ra shn tak tta voc w64 wav wave wma wv"):gmatch("%S+") do
  audio_extensions[ext] = true
end
-- Image support is opt-in for scans and explicit opens, leaving the editor's
-- normal ImageView routing unchanged. The bundled FFmpeg lacks SVG's
-- external renderer.
for ext in ("apng avif bmp gif jpeg jpg jfif pjpeg pjp jxl png pcx webp tif tiff tga "
  .. "pbm pgm ppm pnm pam pfm qoi"):gmatch("%S+") do
  image_extensions[ext] = true
end

---@class plugins.mediaplayer.track
---@field path string Absolute media path
---@field name string Filename
---@field folder string Containing directory, relative to the scanned folder when available
---@field index integer Position in the unfiltered playlist

---@class plugins.mediaplayer.playlist : widget
---@overload fun(parent:widget):plugins.mediaplayer.playlist
---@field tracks plugins.mediaplayer.track[] Unfiltered playback order
---@field tracks_by_path table<string,plugins.mediaplayer.track> Deduplicated tracks
---@field current plugins.mediaplayer.track? Currently playing track
---@field repeat_all boolean Restart the queue after its last track
---@field shuffle boolean Play tracks in a shuffled order with navigation history
---@field scanning boolean Whether a directory scan is running
---@field generation integer Cancellation generation for directory scans
---@field closed boolean Whether the owner has closed
---@field folder widget.filepicker Directory picker and editable path
---@field filter widget.textbox Playlist filter
---@field list widget.listbox Visible playlist rows
local Playlist = Widget:extend()

-- Keep the full column extent for scrolling, row selection and highlights.
local TrackList = ListBox:extend()
function TrackList:get_h_scrollable_size()
  local width = 0
  for _, column in ipairs(self.columns) do width = width + column.width + style.padding.x end
  return math.max(self.size.x, width + style.expanded_scrollbar_size)
end

function TrackList:get_scrollable_size()
  local height = TrackList.super.get_scrollable_size(self)
  if self:get_h_scrollable_size() > self.size.x then height = height + style.expanded_scrollbar_size end
  return height
end

function TrackList:draw()
  self.largest_row = self:get_h_scrollable_size()
  local drawn = TrackList.super.draw(self)
  self.largest_row = self:get_h_scrollable_size()
  return drawn
end

function TrackList:on_mouse_moved(x, y, dx, dy)
  self.largest_row = self:get_h_scrollable_size()
  local index = not self.mouse_is_pressed and self:mouse_on_top(x, y)
    and y >= self.position.y + self:get_font():get_height() + style.padding.y
    and not self:scrollbar_overlaps_point(x, y) and self:get_row_at_position(x, y)
  self.parent:hover_track(index and self.row_data[index] or nil, x, y)
  return TrackList.super.on_mouse_moved(self, x, y, dx, dy)
end

function TrackList:on_mouse_pressed(...)
  self.parent:hover_track(nil)
  return TrackList.super.on_mouse_pressed(self, ...)
end

function TrackList:on_mouse_leave(...)
  self.parent:hover_track(nil)
  return TrackList.super.on_mouse_leave(self, ...)
end

function TrackList:on_mouse_wheel(...)
  self.parent:hover_track(nil)
  return TrackList.super.on_mouse_wheel(self, ...)
end

---Check extensions without opening media or initializing the native runtime.
---Audio and images are opt-in so normal opens keep the editor's own handlers.
---@param path string
---@param include_audio? boolean Include audio formats for scans and explicit player input
---@param include_images? boolean Include image formats supported by the bundled runtime
---@return boolean supported
function Playlist.is_supported(path, include_audio, include_images)
  local ext = path:match("%.([^%./\\]+)$")
  ext = ext and ext:lower()
  return ext ~= nil and (extensions[ext] == true
    or include_audio == true and audio_extensions[ext] == true
    or include_images == true and image_extensions[ext] == true)
end

---Draw the complete title and measure it when adding or scaling rows.
---@param list widget.listbox
---@param index integer
---@param x number
---@param y number
---@param font renderer.font
---@param color renderer.color
---@param only_calc boolean
---@return number width
---@return number height
local function track_column(list, index, x, y, font, color, only_calc)
  local track = list.row_data[index]
  if not only_calc then
    renderer.draw_text(font, track.name, x, y,
      track == list.parent.current and style.accent or color)
  end
  return only_calc and font:get_width(track.name) or list.columns[1].width, font:get_height()
end

---Create a directory picker, filter and cached, scrollable track list.
---@param parent widget Owning video view
function Playlist:new(parent)
  Playlist.super.new(self, parent)
  self.scrollable, self.border.width = false, 0
  self.tracks, self.tracks_by_path = {}, {}
  self.generation, self.scan_skipped, self.scanning = 0, 0, false
  self.shuffle, self.repeat_all, self.closed = false, false, false
  self:reset_shuffle()
  self.folder = FilePicker(self)
  self.folder:set_mode(FilePicker.mode.DIRECTORY_EXISTS)
  self.folder:set_editable(true)
  self.folder.picker_title = "Choose media directory"
  self.folder.button:set_tooltip("Scan a directory for audio, video and images")
  self.folder.on_change = function() self.directory_due = system.get_time() + 0.4 end
  self.filter = TextBox(self, "", "Filter tracks...", {clearable = true})
  self.filter.on_change = function() self.filter_due = system.get_time() + 0.15 end
  self.list = TrackList(self)
  self.list:add_column("Track")
  self.list.on_row_click = function(_, _, track) self:play(track) end
end

---Start the selected track in the owning player's decoder.
---@param track plugins.mediaplayer.track
---@return boolean success
function Playlist:on_play(track) return false end

---Release the owner's current decoder before replacing the queue with a directory.
function Playlist:on_reset() end

---Reset shuffled navigation, preserving the currently playing track as history.
function Playlist:reset_shuffle()
  self.shuffle_remaining, self.shuffle_history, self.shuffle_index = {}, {}, 0
  if not self.shuffle then return end
  for _, track in ipairs(self.tracks) do
    if track ~= self.current then self.shuffle_remaining[#self.shuffle_remaining + 1] = track end
  end
  if self.current then self.shuffle_history[1], self.shuffle_index = self.current, 1 end
end

---Add a track to the filtered rows without rebuilding existing rows.
---@param track plugins.mediaplayer.track
function Playlist:add_row(track)
  local filter = self.filter:get_text():lower()
  if filter ~= "" and not (track.name .. " " .. track.folder):lower():find(filter, 1, true) then return end
  self.list:add_row({track_column}, track)
  if track == self.current then self.list:set_selected(#self.list.rows) end
end

---Append a deduplicated track to the queue and current filter results.
---@param path string Absolute file path
---@param folder? string Display folder, relative to the scan root
---@return plugins.mediaplayer.track
function Playlist:add_file(path, folder)
  local track = self.tracks_by_path[path]
  if track then return track end
  track = {path = path, name = common.basename(path),
    folder = folder or common.dirname(path), index = #self.tracks + 1}
  self.tracks[#self.tracks + 1], self.tracks_by_path[path] = track, track
  if self.shuffle then self.shuffle_remaining[#self.shuffle_remaining + 1] = track end
  self:add_row(track)
  core.redraw = true
  return track
end

---Rebuild the filtered list after a debounced text change.
function Playlist:filter_tracks()
  self:hover_track(nil)
  self.list:clear()
  self.list.scroll.y, self.list.scroll.to.y = 0, 0
  for _, track in ipairs(self.tracks) do self:add_row(track) end
  self.list:set_visible_rows()
  core.redraw = true
end

---Replace the queue with an incremental recursive directory scan, without decoding files.
---Directory symlinks are skipped to avoid loops. Rescanning or closing cancels prior work.
---@param path string Directory path
---@return boolean started Whether a valid directory was accepted
function Playlist:scan(path)
  if self.closed then return false end
  local absolute = system.absolute_path(common.home_expand(path))
  local info = absolute and system.get_file_info(absolute)
  if not info or info.type ~= "dir" then
    core.error("Media Player: directory not found: %s", path)
    return false
  end
  self:on_reset()
  self:hover_track(nil)
  self.generation = self.generation + 1
  local generation = self.generation
  local include_images = config.plugins.mediaplayer.scan_images == true
  self.tracks, self.tracks_by_path, self.current = {}, {}, nil
  self:reset_shuffle()
  self.list:clear()
  self.list.scroll.y, self.list.scroll.to.y = 0, 0
  self.folder:set_path(absolute)
  self.directory_due, self.scanning, self.scan_skipped = nil, true, 0
  core.add_thread(function()
    local pending = {absolute}
    local deadline = system.get_time() + 0.005
    while not self.closed and generation == self.generation and #pending > 0 do
      local dir = table.remove(pending)
      local names = system.list_dir(dir)
      if not names then self.scan_skipped = self.scan_skipped + 1 end
      table.sort(names or {})
      for _, name in ipairs(names or {}) do
        if self.closed or generation ~= self.generation then return end
        local filename = dir .. PATHSEP .. name
        local file = system.get_file_info(filename)
        if file and file.type == "dir" and not file.symlink then
          pending[#pending + 1] = filename
        elseif file and file.type == "file" and Playlist.is_supported(filename, true, include_images) then
          self:add_file(filename, common.relative_path(absolute, dir))
        elseif not file then self.scan_skipped = self.scan_skipped + 1 end
        if system.get_time() >= deadline then
          coroutine.yield(0)
          deadline = system.get_time() + 0.005
        end
      end
      coroutine.yield(0)
      deadline = system.get_time() + 0.005
    end
    if not self.closed and generation == self.generation then
      self.scanning = false
      core.redraw = true
    end
  end)
  core.redraw = true
  return true
end

---Play a queue entry, updating selection and shuffled history only after success.
---@param track? plugins.mediaplayer.track
---@param history_index? integer Existing shuffled history position
---@return boolean success
function Playlist:play(track, history_index)
  if self.closed or not track or not self:on_play(track) then return false end
  self.current = track
  if self.shuffle then
    if history_index then self.shuffle_index = history_index
    else
      for i = #self.shuffle_history, self.shuffle_index + 1, -1 do self.shuffle_history[i] = nil end
      self.shuffle_index = self.shuffle_index + 1
      self.shuffle_history[self.shuffle_index] = track
    end
    for i, remaining in ipairs(self.shuffle_remaining) do
      if remaining == track then table.remove(self.shuffle_remaining, i) break end
    end
  end
  for i, row in ipairs(self.list.row_data) do
    if row == track then self:select_row(i, true) break end
  end
  core.redraw = true
  return true
end

---Navigate the playback queue, stopping automatic advancement at its end unless repeating.
---@param direction integer -1 for previous, 1 for next
---@param automatic? boolean Whether advancement follows the end of a video
---@return boolean success Whether another track started
function Playlist:advance(direction, automatic)
  if #self.tracks == 0 then return false end
  if self.shuffle then
    local index = self.shuffle_index + direction
    if self.shuffle_history[index] then return self:play(self.shuffle_history[index], index) end
    if direction < 0 then return false end
    if #self.shuffle_remaining == 0 then
      if automatic and not self.repeat_all then return false end
      for i, track in ipairs(self.tracks) do self.shuffle_remaining[i] = track end
    end
    local count = #self.shuffle_remaining
    index = math.random(count)
    if count > 1 and self.shuffle_remaining[index] == self.current then
      index = (index - 1 + math.random(count - 1)) % count + 1
    end
    return self:play(self.shuffle_remaining[index])
  end
  local index = (self.current and self.current.index or (direction > 0 and 0 or #self.tracks + 1)) + direction
  if index < 1 or index > #self.tracks then
    if automatic and not self.repeat_all then return false end
    index = (index - 1) % #self.tracks + 1
  end
  return self:play(self.tracks[index])
end

---Select a filtered row and scroll it into view.
---@param direction integer Relative step, or row number when absolute is true
---@param absolute? boolean Treat direction as a row index
function Playlist:select_row(direction, absolute)
  if #self.list.rows == 0 then return end
  local index = common.clamp(absolute and direction or (self.list:get_selected() or 0) + direction, 1, #self.list.rows)
  self.list:set_selected(index)
  local row, height = self.list.rows[index], style.font:get_height() + style.padding.y
  local y = self.list.scroll.to.y
  if row.y < y + height then y = math.max(0, row.y - height)
  elseif row.y + row.h > y + self.list.size.y then y = row.y + row.h - self.list.size.y end
  self.list.scroll.to.y = y
  core.redraw = true
end

---Play the selected filtered entry, or the first visible row.
---@return boolean success
function Playlist:play_selected()
  return self:play(self.list.row_data[self.list:get_selected() or 1])
end

---Cancel pending scans when the owning player closes.
function Playlist:close()
  self:release_mouse()
  self:hover_track(nil)
  self.closed, self.scanning = true, false
  self.generation = self.generation + 1
end

function Playlist:hide()
  self:hover_track(nil)
  return Playlist.super.hide(self)
end

---Apply debounced inputs and refresh row geometry only when the panel size changes.
---@return boolean? updated
function Playlist:update()
  if not Playlist.super.update(self) then return end
  local now = system.get_time()
  if self.filter_due and now >= self.filter_due then
    self.filter_due = nil
    self:filter_tracks()
  end
  if self.directory_due and now >= self.directory_due then
    self.directory_due = nil
    local path = system.absolute_path(common.home_expand(self.folder:get_path()))
    local info = path and system.get_file_info(path)
    if info and info.type == "dir" then self:scan(path) end
  end
  if self.filter_due then core.request_update(math.max(0, self.filter_due - now)) end
  if self.directory_due then core.request_update(math.max(0, self.directory_due - now)) end
  local pad, gap, height = style.padding.x, style.padding.y, style.font:get_height()
  local width, row = math.max(1, self.size.x - pad * 2), height + gap * 2
  self.folder:set_position(pad, gap)
  self.folder:set_size(width, row)
  local y = self.folder:get_bottom() + gap
  self.filter:set_position(pad, y)
  self.filter:set_size(width, row)
  y = self.filter:get_bottom() + gap
  self.list:set_position(pad, y)
  self.list:set_size(width, math.max(0, self.size.y - y - height - gap * 2))
  if self.list_height ~= self.list.size.y or self.list_row_count ~= #self.list.rows then
    self.list_height, self.list_row_count = self.list.size.y, #self.list.rows
    self.list.visible_rendered = false
    self.list:set_visible_rows()
  end
  if self.tooltip_due then
    if now >= self.tooltip_due then
      self.tooltip_due = nil
      self.tooltip_ready = true
      core.redraw = true
    else core.request_update(self.tooltip_due - now) end
  end
  return true
end

---Delay row details until the pointer rests, avoiding work during playback.
function Playlist:hover_track(track, x, y)
  if self.hovered_track == track then return end
  self.hovered_track, self.tooltip_lines, self.tooltip_ready = track, nil, false
  self.tooltip_due = track and system.get_time() + 0.4 or nil
  self.tooltip_x, self.tooltip_y = x, y
  if track then core.request_update(0.4) end
  core.redraw = true
end

---Draw cached, character-wrapped details within the player's presentation.
function Playlist:draw_tooltip()
  local track = self.hovered_track
  if not self.visible or not self.tooltip_ready or not track or self.resizing then return end
  local bx, by, bw, bh = self.parent:get_bounds()
  local font, pad, gap = style.font, style.padding.x, style.padding.y
  local limit = math.max(1, math.min(720 * SCALE, bw - pad * 4))
  if not self.tooltip_lines or self.tooltip_limit ~= limit or self.tooltip_scale ~= SCALE
    or self.tooltip_font ~= font or self.tooltip_font_size ~= font:get_size()
  then
    local lines, widest = {}, 0
    local line, width, split = "", 0, nil
    for char in common.utf8_chars(track.path) do
      local size = font:get_width(char)
      if line ~= "" and (width + size > limit or char == "\n") then
        local boundary = char ~= "\n" and split or #line
        local part = line:sub(1, boundary)
        lines[#lines + 1], widest = part, math.max(widest, font:get_width(part))
        line, split = line:sub((boundary or #line) + 1), nil
        width = font:get_width(line)
      end
      if char ~= "\n" then line, width = line .. char, width + size end
      if char:find("[%s/\\]") then split = #line end
    end
    lines[#lines + 1], widest = line, math.max(widest, font:get_width(line))
    self.tooltip_lines, self.tooltip_width = lines, math.ceil(widest + pad * 2)
    self.tooltip_limit, self.tooltip_scale = limit, SCALE
    self.tooltip_font, self.tooltip_font_size = font, font:get_size()
  end
  local width = self.tooltip_width
  local height = #self.tooltip_lines * font:get_height() + gap * 2
  local x = common.round(common.clamp(self.tooltip_x - width, bx, bx + bw - width))
  local y = self.tooltip_y + gap * 2
  if y + height > by + bh then y = math.max(by, self.tooltip_y - height - gap) end
  y = common.round(y)
  renderer.draw_rect(x, y, width, height, style.divider)
  renderer.draw_rect(x + 1, y + 1, width - 2, height - 2, style.background3)
  core.push_clip_rect(x, y, width, math.min(height, by + bh - y))
  for i, line in ipairs(self.tooltip_lines) do
    renderer.draw_text(font, line, x + pad, common.round(y + gap + (i - 1) * font:get_height()), style.text)
  end
  core.pop_clip_rect()
end

---Resize the owning panel using Widget's existing mouse capture.
function Playlist:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and x <= self.position.x + 6 * SCALE and self:mouse_on_top(x, y) then
    self:hover_track(nil)
    if clicks == 2 then
      self.parent.playlist_width = nil
      self.parent:layout()
    else
      self.resize_offset, self.resizing = x - self.position.x, true
      self:capture_mouse(false, button)
    end
    core.redraw = true
    return true
  end
  return Playlist.super.on_mouse_pressed(self, button, x, y, clicks)
end

function Playlist:on_mouse_moved(x, y, dx, dy)
  if self.resizing then
    local bx, _, width = self.parent:get_bounds()
    local maximum = math.max(width / 2, width - 240 * SCALE)
    self.parent.playlist_width = common.clamp(bx + width - x + self.resize_offset,
      math.min(240 * SCALE, maximum), maximum) / SCALE
    self.parent:layout()
    core.redraw = true
  else Playlist.super.on_mouse_moved(self, x, y, dx, dy) end
  if self.resizing or self:mouse_on_top(x, y) and x <= self.position.x + 6 * SCALE then
    -- RootView reapplies its top-level view's cursor after child input.
    self.parent.cursor = "sizeh"
    core.request_cursor("sizeh")
  elseif self.parent.cursor == "sizeh" then
    self.parent.cursor = "arrow"
    core.request_cursor("arrow")
  end
end

function Playlist:on_mouse_leave(...)
  if self.parent.cursor == "sizeh" then
    self.parent.cursor = "arrow"
    core.request_cursor("arrow")
  end
  return Playlist.super.on_mouse_leave(self, ...)
end

function Playlist:on_mouse_released(button, x, y)
  if self.resizing and button == "left" then self:release_mouse() return true end
  return Playlist.super.on_mouse_released(self, button, x, y)
end

function Playlist:on_mouse_capture_lost()
  self.resizing = nil
  self.parent.cursor = "arrow"
  core.request_cursor("arrow")
  Playlist.super.on_mouse_capture_lost(self)
end

---Draw the panel separator and clipped scan status; child widgets draw their own content.
---@param color renderer.color
function Playlist:draw_background(color)
  local x, y, width, height = self.position.x, self.position.y, self.size.x, self.size.y
  renderer.draw_rect(x, y, width, height, color)
  renderer.draw_rect(x, y, math.max(1, SCALE), height, self.resizing and style.accent or style.divider)
  local text = #self.tracks .. " tracks" .. (self.scanning and " — Scanning..." or "")
  if self.scan_skipped > 0 then text = text .. " — " .. self.scan_skipped .. " unreadable" end
  core.push_clip_rect(x, y, width, height)
  renderer.draw_text(style.font, text, x + style.padding.x,
    y + height - style.font:get_height() - style.padding.y, style.dim)
  core.pop_clip_rect()
end

return Playlist
