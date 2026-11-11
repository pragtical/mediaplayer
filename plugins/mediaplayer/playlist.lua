local core = require "core"
local common = require "core.common"
local style = require "core.style"
local system = require "system"
local renderer = require "renderer"
local Widget = require "widget"
local FilePicker = require "widget.filepicker"
local TextBox = require "widget.textbox"
local ListBox = require "widget.listbox"

local extensions = {}
local audio_extensions = {}
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

---Check extensions without opening media or initializing the native runtime.
---Audio is opt-in so normal file opens keep the editor's audio handler.
---@param path string
---@param include_audio? boolean Include audio formats for scans and explicit player input
---@return boolean supported
function Playlist.is_supported(path, include_audio)
  local ext = path:match("%.([^%./\\]+)$")
  ext = ext and ext:lower()
  return ext ~= nil and (extensions[ext] == true or include_audio == true and audio_extensions[ext] == true)
end

---Draw a clipped title, using the current track's accent without widening the row.
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
  local width = list.columns[1].width
  if not only_calc then
    core.push_clip_rect(x, y, math.max(0, width), font:get_height())
    renderer.draw_text(font, track.name, x, y,
      track == list.parent.current and style.accent or color)
    core.pop_clip_rect()
  end
  return width, font:get_height()
end

---Draw the containing folder within the remaining column space.
---@param list widget.listbox
---@param index integer
---@param x number
---@param y number
---@param font renderer.font
---@param color renderer.color
---@param only_calc boolean
---@return number width
---@return number height
local function folder_column(list, index, x, y, font, color, only_calc)
  local width = list.columns[2].width
  if not only_calc then
    core.push_clip_rect(x, y, math.max(0, width), font:get_height())
    renderer.draw_text(font, list.row_data[index].folder, x, y, color)
    core.pop_clip_rect()
  end
  return width, font:get_height()
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
  self.folder.button:set_tooltip("Scan a directory for audio and video")
  self.folder.on_change = function() self.directory_due = system.get_time() + 0.4 end
  self.filter = TextBox(self, "", "Filter tracks...")
  self.filter.on_change = function() self.filter_due = system.get_time() + 0.15 end
  self.list = ListBox(self)
  self.list:add_column("Track", 240, false)
  self.list:add_column("Folder", 100, false)
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
  self.list:add_row({track_column, ListBox.COLEND, folder_column}, track)
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
  self.generation = self.generation + 1
  local generation = self.generation
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
        elseif file and file.type == "file" and Playlist.is_supported(filename, true) then
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
  self.closed, self.scanning = true, false
  self.generation = self.generation + 1
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
  local content = math.max(0, self.list.size.x - pad * 2 - style.expanded_scrollbar_size)
  self.list.columns[1].width, self.list.columns[2].width = content * 0.7, content * 0.3
  if self.list_width ~= width or self.list_scale ~= SCALE then
    self.list_width, self.list_scale, self.list_height = width, SCALE, nil
    self.list:recalc_all_rows()
  end
  if self.list_height ~= self.list.size.y or self.list_row_count ~= #self.list.rows then
    self.list_height, self.list_row_count = self.list.size.y, #self.list.rows
    self.list.visible_rendered = false
    self.list:set_visible_rows()
  end
  return true
end

---Draw the panel separator and clipped scan status; child widgets draw their own content.
---@param color renderer.color
function Playlist:draw_background(color)
  local x, y, width, height = self.position.x, self.position.y, self.size.x, self.size.y
  renderer.draw_rect(x, y, width, height, color)
  renderer.draw_rect(x, y, math.max(1, SCALE), height, style.divider)
  local text = #self.tracks .. " tracks" .. (self.scanning and " — Scanning..." or "")
  if self.scan_skipped > 0 then text = text .. " — " .. self.scan_skipped .. " unreadable" end
  core.push_clip_rect(x, y, width, height)
  renderer.draw_text(style.font, text, x + style.padding.x,
    y + height - style.font:get_height() - style.padding.y, style.dim)
  core.pop_clip_rect()
end

return Playlist
