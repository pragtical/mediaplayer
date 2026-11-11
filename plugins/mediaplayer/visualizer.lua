-- Audio effects adapted from Pragtical audiovisu.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local system = require "system"
local renderer = require "renderer"
local Canvas = require "canvas"
local Object = require "core.object"
local FRAMES = 2048
local effects = {
  {"Warp", "warp"}, {"Alchemy", "alchemy"}, {"Battery", "battery"},
  {"Spikes", "spikes"}, {"Scope", "scope"}, {"Particle", "particle"},
  {"Spectrum Bars", "bars"}, {"Random", "random"}
}
local options = {bar_count = 24, height = 160, sensitivity = 1, decay = 0.25,
  random_interval = 20, effect_speed = 1, bar_spacing = 3, vertical_position = "bottom"}

local function update_options()
  local cfg = config.plugins.mediaplayer
  options.effect = cfg.audio_effect or "warp"
  options.effect_speed = cfg.audio_effect_speed or 1
  options.effect_color = cfg.audio_effect_color
  options.effect_custom_color = cfg.audio_effect_color ~= nil
end

local function settings() return options end
local function number(name, default, min, max)
  local value = options[name]
  if type(value) ~= "number" or value ~= value then value = default end
  return common.clamp(value, min, max)
end

-- Forward radix-2/4 FFT adapted from zorggn/zorg-fft's plain Lua version:
-- https://github.com/zorggn/zorg-fft/blob/master/src/lua/zfft.lua
-- Its unused FFI import, inverse transform, and other radices are omitted.
--
-- Copyright (c) 2020 zorg (ISC):
-- Permission to use, copy, modify, and/or distribute this software for any
-- purpose with or without fee is hereby granted, provided that the above
-- copyright notice and this permission notice appear in all copies.
-- THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
-- WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
-- MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
-- ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
-- WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
-- OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
-- CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
--
-- Based on luafft, Copyright (c) 2011 Benjamin von Ardenne (MIT):
-- Permission is hereby granted, free of charge, to any person obtaining a
-- copy of this software and associated documentation files (the "Software"),
-- to deal in the Software without restriction, including without limitation
-- the rights to use, copy, modify, merge, publish, distribute, sublicense,
-- and/or sell copies of the Software, and to permit persons to whom the
-- Software is furnished to do so, subject to the following conditions:
-- The above copyright notice and this permission notice shall be included
-- in all copies or substantial portions of the Software.
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
-- THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.
--
-- Based on KISS FFT, Copyright (c) 2003-2010 Mark Borgerding (BSD-3-Clause):
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
-- 1. Redistributions of source code must retain the above copyright notice,
--    this list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
-- 3. Neither the name of the copyright holder nor the names of its
--    contributors may be used to endorse or promote products derived from
--    this software without specific prior written permission.
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
local tw_re, tw_im, window, window_sum = {}, {}, {}, 0
local function initialize_fft()
  if #window > 0 then return end
  for i = 0, FRAMES - 1 do
    local phase = 2 * math.pi * i / FRAMES
    tw_re[i + 1], tw_im[i + 1] = math.cos(phase), -math.sin(phase)
    window[i + 1] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (FRAMES - 1))
    window_sum = window_sum + window[i + 1]
  end
end

local input, real, imaginary = {}, {}, {}
local function fft_work(offset, source, stride, count)
  local radix = count % 4 == 0 and 4 or 2
  local m = count / radix
  for j = 0, radix - 1 do
    if m == 1 then
      real[offset + j], imaginary[offset + j] = input[source + j * stride], 0
    else
      fft_work(offset + j * m, source + j * stride, stride * radix, m)
    end
  end
  for k = 0, m - 1 do
    local i, t = offset + k, 1 + k * stride
    local ar, ai = real[i], imaginary[i]
    local br = real[i + m] * tw_re[t] - imaginary[i + m] * tw_im[t]
    local bi = real[i + m] * tw_im[t] + imaginary[i + m] * tw_re[t]
    if radix == 2 then
      real[i], imaginary[i] = ar + br, ai + bi
      real[i + m], imaginary[i + m] = ar - br, ai - bi
    else
      local t2, t3 = 1 + k * stride * 2, 1 + k * stride * 3
      local cr = real[i + 2*m] * tw_re[t2] - imaginary[i + 2*m] * tw_im[t2]
      local ci = real[i + 2*m] * tw_im[t2] + imaginary[i + 2*m] * tw_re[t2]
      local dr = real[i + 3*m] * tw_re[t3] - imaginary[i + 3*m] * tw_im[t3]
      local di = real[i + 3*m] * tw_im[t3] + imaginary[i + 3*m] * tw_re[t3]
      real[i], imaginary[i] = ar + cr + br + dr, ai + ci + bi + di
      real[i + m], imaginary[i + m] = ar - cr + bi - di, ai - ci - br + dr
      real[i + 2*m], imaginary[i + 2*m] = ar + cr - br - dr, ai + ci - bi - di
      real[i + 3*m], imaginary[i + 3*m] = ar - cr - bi + di, ai - ci + br - dr
    end
  end
end

local function finite(value)
  return value == value and value ~= math.huge and value ~= -math.huge and value or 0
end

local function analyze(samples, spec, power, bars)
  local channels = spec.channels
  local frames = math.min(FRAMES, math.floor(#samples / channels))
  if frames < 2 then return 0, 1 end
  local top = math.min(16000, spec.sample_rate / 2)
  local bottom = math.min(40, top / 2)
  local factor = 4 / (window_sum * window_sum * channels)
  local span, strongest = 0, 1
  for channel = 1, channels do
    local sum, low, high = 0, math.huge, -math.huge
    for i = 1, frames do
      local sample = finite(samples[(i - 1) * channels + channel])
      sum, low, high = sum + sample, math.min(low, sample), math.max(high, sample)
    end
    if high - low > span then span, strongest = high - low, channel end
    if high - low > 1e-7 then
      local mean = sum / frames
      for i = 1, FRAMES do
        input[i] = i <= frames
          and (finite(samples[(i - 1) * channels + channel]) - mean) * window[i] or 0
      end
      fft_work(1, 1, 1, FRAMES)
      for bar = 1, bars do
        local first = math.max(1, math.floor(bottom * (top / bottom)^((bar - 1) / bars) * FRAMES / spec.sample_rate))
        local last = math.min(FRAMES / 2, math.max(first,
          math.floor(bottom * (top / bottom)^(bar / bars) * FRAMES / spec.sample_rate) - 1))
        local peak = 0
        for bin = first, last do
          peak = math.max(peak, real[bin + 1]^2 + imaginary[bin + 1]^2)
        end
        power[bar] = power[bar] + peak * factor
      end
    end
  end
  return span, strongest
end

---Smooth an analysis result independently of its sample source or presentation.
local function smooth_signal(levels, pixels, powers, signal, wave_target, dt, enabled, strongest)
  local bars, changed = #levels, false
  local height = number("height", 160, 16, 1024) * SCALE
  local sensitivity = number("sensitivity", 1, 0.1, 10)
  local release = number("decay", 0.25, 0.05, 2)
  local moving = false
  for i = 1, bars do
    local amplitude = math.sqrt(powers[i]) * sensitivity
    local target = enabled and amplitude > 1e-6
      and common.clamp((20 * math.log(amplitude) / math.log(10) + 60) / 60, 0, 1) or 0
    local level = levels[i]
    level = target + (level - target) * math.exp(-dt / (target > level and 0.035 or release))
    if level < 0.001 then level = 0 end
    local pixel = math.floor(level * height + 0.5)
    changed = changed or pixel ~= pixels[i]
    levels[i], pixels[i] = level, pixel
    moving = moving or level > 0
  end
  local bass, middle, treble = 0, 0, 0
  local lower, upper = math.max(1, math.floor(bars / 3)), math.floor(bars * 2 / 3)
  for i = 1, bars do
    if i <= lower then bass = bass + levels[i]
    elseif i <= upper then middle = middle + levels[i]
    else treble = treble + levels[i] end
  end
  bass, middle, treble = bass / lower, middle / math.max(1, upper - lower), treble / math.max(1, bars - upper)
  signal.beat = math.max(signal.beat * math.exp(-dt / 0.18), math.min(1, math.max(0, bass - signal.bass) * 8))
  signal.bass, signal.middle, signal.treble = bass, middle, treble
  signal.energy = (bass + middle + treble) / 3
  for i = 1, 256 do
    local old = signal.wave[i] or 0
    local target = enabled and common.clamp(wave_target[i] * sensitivity, -1, 1) or 0
    signal.wave[i] = target + (old - target) * math.exp(-dt / (strongest > 0 and 0.02 or release))
  end
  return changed, moving
end

local scene_serial = 0
local function new_scene()
  scene_serial = scene_serial + 1
  return {
    time = 0, age = 0, frame = 0, seed = 12345 + scene_serial * 1777,
    audio = { bass = 0, middle = 0, treble = 0, energy = 0, beat = 0, wave = {}, levels = {} }
  }
end

local function random(scene)
  scene.seed = scene.seed * 48271 % 2147483647
  return scene.seed / 2147483647
end

local function choose_effect(scene, force)
  local requested = settings().effect or "warp"
  if not force and scene.requested == requested
    and (requested ~= "random" or scene.age < number("random_interval", 20, 5, 300)) then
    return
  end
  local selected = requested
  if selected == "random" then
    local choices = {}
    for i = 1, #effects - 1 do
      if effects[i][2] ~= scene.effect then choices[#choices + 1] = effects[i][2] end
    end
    selected = choices[math.floor(random(scene) * #choices) + 1]
  else
    local valid = false
    for i = 1, #effects - 1 do if effects[i][2] == selected then valid = true end end
    if not valid then selected = "warp" end
  end
  scene.requested, scene.effect, scene.age = requested, selected, 0
  scene.field, scene.previous, scene.image, scene.canvas = nil, nil, nil, nil
  scene.rendered_frame = nil
end

local function effect_color(scene, hue, brightness, alpha)
  brightness = common.clamp(brightness, 0, 1)
  local custom = settings()
  local color = custom.effect_color or style.text
  if custom.effect_custom_color and type(color) == "table" then
    return {
      math.floor(color[1] * brightness), math.floor(color[2] * brightness),
      math.floor(color[3] * brightness), alpha or color[4] or 255
    }
  end
  local h = ((hue + scene.time * 0.025) % 1) * 6
  local sector, f = math.floor(h), h % 1
  local low, falling, rising = 0.1, 1 - f * 0.9, 0.1 + f * 0.9
  local r, g, b
  if sector == 0 then r, g, b = 1, rising, low
  elseif sector == 1 then r, g, b = falling, 1, low
  elseif sector == 2 then r, g, b = low, 1, rising
  elseif sector == 3 then r, g, b = low, falling, 1
  elseif sector == 4 then r, g, b = rising, low, 1
  else r, g, b = 1, low, falling end
  return { math.floor(r * brightness * 255), math.floor(g * brightness * 255),
    math.floor(b * brightness * 255), alpha or 255 }
end

-- A filled strip keeps a glowing curve to a few draw calls instead of one per segment.
local function draw_path(points, width, color, target)
  local polygon, count = {}, #points
  for i = 1, count do
    local before, after = points[math.max(1, i - 1)], points[math.min(count, i + 1)]
    local dx, dy = after[1] - before[1], after[2] - before[2]
    local length = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    local nx, ny = -dy / length * width / 2, dx / length * width / 2
    polygon[i] = { points[i][1] + nx, points[i][2] + ny }
    polygon[count * 2 - i + 1] = { points[i][1] - nx, points[i][2] - ny }
  end
  if target then target:draw_poly(polygon, color) else renderer.draw_poly(polygon, color) end
end

local function glow_path(scene, points, hue, width, brightness)
  draw_path(points, width * 4, effect_color(scene, hue, brightness, 24), scene.target)
  draw_path(points, width * 2, effect_color(scene, hue, brightness, 70), scene.target)
  draw_path(points, width, effect_color(scene, hue, brightness), scene.target)
end

local function inject(field, w, h, x, y, radius, strength)
  local r2 = radius * radius
  for py = math.max(0, math.floor(y - radius)), math.min(h - 1, math.ceil(y + radius)) do
    for px = math.max(0, math.floor(x - radius)), math.min(w - 1, math.ceil(x + radius)) do
      local distance = ((px - x)^2 + (py - y)^2) / r2
      if distance < 1 then
        local index = py * w + px + 1
        field[index] = math.min(255, field[index] + strength * (1 - distance)^2)
      end
    end
  end
end

-- Bounded feedback surfaces reproduce the low-resolution, flowing XP-era look.
-- Field motion runs in Lua; scaling and presentation use the native canvas API.
local function feedback_image(scene, width, height)
  local signal, levels = scene.audio, scene.audio.levels
  local scale = math.min(1, 240 / width, 160 / height)
  local w, h = math.max(16, math.floor(width * scale)), math.max(16, math.floor(height * scale))
  if scene.field_w ~= w or scene.field_h ~= h or not scene.field then
    scene.field_w, scene.field_h = w, h
    scene.field, scene.previous = {}, {}
    for i = 1, w * h do scene.field[i], scene.previous[i] = 0, 0 end
    scene.canvas = Canvas.new(w, h, { 0, 0, 0, 255 })
    scene.rendered_frame = nil
  end
  local options = settings()
  local palette_key = tostring(options.effect_custom_color) .. table.concat(options.effect_color or style.text, ",")
  if scene.rendered_frame == scene.frame and scene.image_w == width and scene.image_h == height
    and scene.palette_key == palette_key then
    return scene.image
  end
  local time, energy = scene.time, signal.energy
  local twist = scene.effect == "alchemy" and 0.025 or 0.006
  local angle = twist + math.sin(time * 0.45) * 0.015 + signal.beat * 0.008
  local zoom = scene.effect == "alchemy" and 0.982 or 0.955 - signal.bass * 0.012
  local cosine, sine = math.cos(angle) * zoom, math.sin(angle) * zoom
  local cx, cy = (w - 1) / 2, (h - 1) / 2
  local field, previous = scene.previous, scene.field
  local shifts = {}
  for px = 0, w - 1 do shifts[px] = math.sin(px / w * 7 + time * 0.7) * (0.2 + energy) end
  for py = 0, h - 1 do
    local dx, dy = -cx, py - cy
    local shift = math.sin(py / h * 6 - time * 0.6) * (0.2 + energy)
    local sx, sy = cx + dx * cosine - dy * sine + shift, cy + dx * sine + dy * cosine
    for px = 0, w - 1 do
      local ix, iy = math.floor(sx + 0.5), math.floor(sy + shifts[px] + 0.5)
      local value = ix >= 0 and ix < w and iy >= 0 and iy < h and previous[iy * w + ix + 1] or 0
      field[py * w + px + 1] = value * 0.965
      sx, sy = sx + cosine, sy + sine
    end
  end
  local radius = 1.3 + energy * 2.2 + signal.beat
  local strength = 35 + signal.middle * 85 + signal.beat * 90
  if scene.effect == "warp" then
    for ribbon = 1, 3 do
      for i = 1, 128 do
        local t = (i - 1) / 127
        local sample = signal.wave[(i - 1) * 2 + 1] or 0
        local x = cx + (t - 0.5) * w * (0.5 + ribbon * 0.06)
        local y = cy + math.sin(t * math.pi * (2 + ribbon) + time * 0.7 + ribbon) * h * 0.08
          + sample * h * 0.26 + math.cos(t * 8 - time) * signal.bass * h * 0.06
        inject(field, w, h, x, y, radius, strength)
      end
    end
  else
    for ribbon = 1, 3 do
      for i = 0, 159 do
        local a = i / 159 * math.pi * 2
        local band = levels[math.floor(i / 160 * #levels) + 1] or 0
        local r = (0.2 + math.sin(a * (3 + ribbon) + time * 0.8) * 0.08 + band * 0.06)
          * math.min(w, h)
        inject(field, w, h, cx + math.cos(a + time * 0.15 + ribbon) * r * 1.5,
          cy + math.sin(a * 2 - time * 0.11 + ribbon) * r, radius, strength * 0.7)
      end
    end
  end
  scene.field, scene.previous = field, previous
  local palette = {}
  local fade = math.min(1, 0.3 + scene.age * 1.5)
  for i = 0, 255 do
    palette[i] = effect_color(scene, 0.58 + i / 255 * 0.48,
      (i / 255)^0.7 * fade)
  end
  local rows, row = {}, {}
  for py = 0, h - 1 do
    for px = 0, w - 1 do
      local color = palette[math.floor(field[py * w + px + 1])]
      local offset = px * 4
      row[offset + 1], row[offset + 2], row[offset + 3], row[offset + 4] = color[1], color[2], color[3], 255
    end
    rows[py + 1] = string.char(table.unpack(row, 1, w * 4))
  end
  scene.canvas:set_pixels(table.concat(rows), 0, 0, w, h)
  scene.canvas:render()
  scene.image = scene.canvas:scaled(width, height, "linear")
  scene.image_w, scene.image_h, scene.rendered_frame = width, height, scene.frame
  scene.palette_key = palette_key
  return scene.image
end

local function draw_battery(scene, x, y, w, h)
  local signal, levels = scene.audio, scene.audio.levels
  local cx, cy, time = x + w / 2, y + h / 2, scene.time
  for trail = 2, 0, -1 do
    for ribbon = 1, 3 do
      local points = {}
      local phase = time * 0.6 - trail * 0.07 + ribbon * 2.1
      for i = 0, 128 do
        local a = i / 128 * math.pi * 2
        local band = levels[i % math.max(1, #levels) + 1] or 0
        local wave = signal.wave[math.floor(i / 128 * 255) + 1] or 0
        local radius = 0.3 + math.sin(a * 3 + phase) * 0.07 + band * 0.06
        points[i + 1] = {
          cx + math.cos(a + phase * 0.35) * w * radius,
          cy + math.sin(a * 2 - phase) * h * 0.24 + wave * h * 0.12
        }
      end
      local brightness = (0.45 + signal.energy * 0.55) * (1 - trail / 6)
      glow_path(scene, points, ribbon / 3 + trail * 0.03, math.max(1, h / 250), brightness)
    end
  end
end

local function draw_spikes(scene, x, y, w, h)
  local signal, levels = scene.audio, scene.audio.levels
  local cx, cy, radius = x + w / 2, y + h / 2, math.min(w, h) * 0.22
  local ring = {}
  for i = 0, 96 do
    local angle = i / 96 * math.pi * 2 + scene.time * 0.12
    local band = levels[i % math.max(1, #levels) + 1] or 0
    local inner = radius * (0.8 + signal.bass * 0.35)
    local outer = inner + radius * (0.15 + band * 0.85 + signal.beat * 0.25)
    local cosine, sine = math.cos(angle), math.sin(angle)
    ring[i + 1] = { cx + cosine * inner, cy + sine * inner }
    if i < 96 then
      glow_path(scene, { ring[i + 1], { cx + cosine * outer, cy + sine * outer } },
        i / 96, math.max(1, w / 650), 0.5 + band * 0.5)
    end
  end
  glow_path(scene, ring, 0.55, math.max(1, w / 500), 0.8)
end

local function draw_scope(scene, x, y, w, h)
  local signal = scene.audio
  for trail = 3, 0, -1 do
    local points = {}
    for i = 1, 256 do
      local sample = signal.wave[i] or 0
      points[i] = { x + w * (i - 1) / 255,
        y + h / 2 + sample * h * (0.32 - trail * 0.025) + math.sin(i / 25 + scene.time) * trail * h / 300 }
    end
    glow_path(scene, points, 0.32 + trail * 0.05, math.max(1, h / 250), 1 - trail / 7)
  end
end

local function draw_particles(scene, x, y, w, h)
  local signal = scene.audio
  local cx, cy = x + w / 2, y + h / 2
  local rotation = scene.time * 0.06
  for i = 1, 180 do
    local angle = i * 2.399963 + rotation
    local z = (i * 0.618034 - scene.time * (0.15 + signal.bass * 0.2)) % 1
    local spread = 0.08 + ((i * 73) % 97) / 97 * 0.4
    local radius = spread / (0.15 + z)
    local px, py = cx + math.cos(angle) * w * radius, cy + math.sin(angle) * h * radius
    local trail = 0.012 + signal.beat * 0.035 + signal.treble * 0.015
    local tail = spread / (0.15 + z + trail)
    glow_path(scene, { {cx + math.cos(angle) * w * tail, cy + math.sin(angle) * h * tail}, {px, py} },
      i / 180 + scene.time * 0.03, math.max(1, (1 - z) * 2 * SCALE), (1 - z) * 0.8 + 0.2)
  end
end

local function vector_image(scene, width, height, draw)
  local options = settings()
  local palette_key = tostring(options.effect_custom_color) .. table.concat(options.effect_color or style.text, ",")
  if scene.image and scene.rendered_frame == scene.frame and scene.image_w == width
    and scene.image_h == height and scene.palette_key == palette_key then return scene.image end
  local scale = math.min(1, 560 / width, 320 / height)
  local w, h = math.max(1, math.floor(width * scale)), math.max(1, math.floor(height * scale))
  local cw, ch
  if scene.canvas then cw, ch = scene.canvas:get_size() end
  if cw ~= w or ch ~= h then scene.canvas = Canvas.new(w, h, {2, 4, 8, 255}) end
  scene.canvas:draw_rect(0, 0, w, h, {2, 4, 8, 255}, true)
  scene.target = scene.canvas
  draw(scene, 0, 0, w, h)
  scene.target = nil
  scene.canvas:render()
  scene.image = scene.canvas:scaled(width, height, "linear")
  scene.image_w, scene.image_h, scene.rendered_frame = width, height, scene.frame
  scene.palette_key = palette_key
  return scene.image
end

local function draw_scene(scene, x, y, w, h)
  local levels = scene.audio.levels
  if w < 1 or h < 1 then return end
  choose_effect(scene)
  renderer.draw_rect(x, y, w, h, { 2, 4, 8, 255 })
  core.push_clip_rect(x, y, w, h)
  if scene.effect == "warp" or scene.effect == "alchemy" then
    renderer.draw_canvas(feedback_image(scene, math.max(1, math.floor(w)), math.max(1, math.floor(h))), x, y)
  elseif scene.effect ~= "bars" then
    local draw = scene.effect == "battery" and draw_battery
      or scene.effect == "spikes" and draw_spikes
      or scene.effect == "scope" and draw_scope or draw_particles
    renderer.draw_canvas(vector_image(scene, math.max(1, math.floor(w)), math.max(1, math.floor(h)), draw), x, y)
  else
    local count = math.max(1, #levels)
    local gap = math.min(number("bar_spacing", 3, 0, 64) * SCALE, math.max(0, w / count - 1))
    for i = 1, #levels do
      local width = math.max(1, math.floor(w / count - gap))
      local height = math.floor(levels[i] * h * 0.8)
      local vertical = settings().vertical_position
      local top = vertical == "top" and y or vertical == "center" and y + (h - height) / 2 or y + h - height
      renderer.draw_rect(math.floor(x + (i - 1) * w / count), top, width, height,
        effect_color(scene, (i - 1) / count, 0.9))
    end
  end
  core.pop_clip_rect()
end

---Advance one effect from its own analysis state without choosing a window or tab.
local function advance_scene(scene, signal, levels, dt)
  local snapshot = scene.audio
  snapshot.bass, snapshot.middle, snapshot.treble = signal.bass, signal.middle, signal.treble
  snapshot.energy, snapshot.beat = signal.energy, signal.beat
  for i = 1, 256 do snapshot.wave[i] = signal.wave[i] end
  for i = 1, #levels do snapshot.levels[i] = levels[i] end
  for i = #snapshot.levels, #levels + 1, -1 do snapshot.levels[i] = nil end
  local delta = math.min(dt, 0.1)
  scene.time = scene.time + delta * number("effect_speed", 1, 0.1, 5)
  scene.age = scene.age + delta
  scene.frame = scene.frame + 1
  choose_effect(scene)
end

---@class plugins.mediaplayer.visualizer : core.object
---@overload fun():plugins.mediaplayer.visualizer
---@field scene table Effect state and cached rendering resources
local Visualizer = Object:extend()

---Create an independently fed visualizer, without opening a view or audio device.
---The caller owns sample delivery, visibility and redraw scheduling. Embedded
---visualizers never open their own view or capture system audio.
function Visualizer:new()
  initialize_fft()
  self:reset()
end

---Clear analysis history and release cached images when changing sources.
function Visualizer:reset()
  self.scene, self.last_time = new_scene(), system.get_time()
  self.levels, self.pixels, self.powers, self.wave = {}, {}, {}, {}
  self.signal = {bass = 0, middle = 0, treble = 0, energy = 0, beat = 0, wave = {}}
end

---Analyze an interleaved floating-point PCM snapshot and advance the effect.
---@param samples number[] Normalized samples; channels remain interleaved
---@param spec {channels:integer,sample_rate:integer} Snapshot format
---@param dt? number Elapsed seconds; defaults to time since the previous update
---@return boolean changed Whether the caller should redraw
function Visualizer:update(samples, spec, dt)
  update_options()
  local bars = math.floor(number("bar_count", 24, 2, 128))
  local resized = #self.levels ~= bars
  for i = #self.levels, bars + 1, -1 do
    self.levels[i], self.pixels[i], self.powers[i] = nil, nil, nil
  end
  for i = 1, bars do
    self.levels[i], self.pixels[i], self.powers[i] = self.levels[i] or 0, self.pixels[i] or 0, 0
  end
  for i = 1, 256 do self.wave[i] = 0 end
  local span, channel = analyze(samples, spec, self.powers, bars)
  local frames = math.floor(#samples / spec.channels)
  if frames > 0 then
    for i = 1, 256 do
      local frame = math.min(frames - 1, math.floor((i - 1) * frames / 256))
      self.wave[i] = finite(samples[frame * spec.channels + channel])
    end
  end
  local now = system.get_time()
  dt, self.last_time = math.max(0, dt or now - self.last_time), now
  local changed, moving = smooth_signal(self.levels, self.pixels, self.powers,
    self.signal, self.wave, dt, true, span)
  if span > 0 or moving then advance_scene(self.scene, self.signal, self.levels, dt) end
  return resized or changed or span > 0 or moving
end

---Draw the selected effect inside the caller's bounds; no audio is sampled here.
---@param x number
---@param y number
---@param width number
---@param height number
function Visualizer:draw(x, y, width, height)
  update_options()
  draw_scene(self.scene, x, y, width, height)
end

---Animate between PCM callbacks without repeating the FFT for an unchanged snapshot.
---@param dt? number Elapsed seconds; defaults to time since the previous update
function Visualizer:advance(dt)
  update_options()
  local now = system.get_time()
  dt, self.last_time = math.max(0, dt or now - self.last_time), now
  advance_scene(self.scene, self.signal, self.levels, dt)
end

Visualizer.effects = effects
return Visualizer
