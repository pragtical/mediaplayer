# Media Player for Pragtical

Play local audio and video in an editor tab or fullscreen, with playlists,
embedded artwork and audio visualizations. Requires Pragtical 3.14 or
later with LuaJIT. libmpv handles decoding, audio and seeking; the plugin draws
video frames with Pragtical's renderer.

## Installation

Install with Pragtical's plugin manager:

```sh
pragtical pm repo add https://github.com/pragtical/mediaplayer.git:latest
pragtical pm install mediaplayer
```

PPM installs the Lua plugin and native library for your platform. Supported
binary targets are Linux and macOS on x86_64 and aarch64, and Windows x86_64.
Restart Pragtical after installing native binaries.

For manual installation, copy `plugins/mediaplayer` into your user `plugins`
directory and put the release's `mpv.<architecture>.so` or `.dll` beside
`init.lua`. macOS binaries use `.so`, following Pragtical's addon convention.
Manual Lua-only installations can use a system-installed libmpv.

Library discovery tries an explicit **libmpv Library** setting exclusively.
Otherwise it tries bundled architecture-specific and generic libraries, then
the system loader and common Homebrew locations. An incompatible bundled
binary also falls back to the system library. Other CPU architectures can use
the Lua plugin with a compatible system library.

## Usage

Supported video files open in Media Player from the treeview, file picker,
drag-and-drop and other normal editor file-open operations. Successive files
share a player tab and append to its playlist. Text, image and audio files
keep their existing handlers. You can also choose **Tools → Open Media Player**
or run `media-player:open` to create a separate player.
Opening the player creates an empty tab; use its **Open** button to choose media.
Set **Default Directory** in Settings → Plugins → Media Player to scan a media
folder automatically in new tabs, without starting playback.
Ambiguous `.ts` and `.mts` extensions keep their TypeScript editing behavior;
open transport-stream videos explicitly through the player's **Open** button.

Right-click a supported audio, video or image file in the treeview and choose
**Open with Media Player** to open it explicitly in a new player tab. Supported
images include JPEG, GIF, BMP, WebP, TIFF and AVIF. PNG and SVG are excluded
because the bundled runtime does not include their decoders.
The same action on a directory opens a new player tab and recursively scans
that folder for audio and video, without starting playback.

The playlist button shows a panel on the right. Choose or type a directory to
scan recursively for audio and video, or drop a directory on the player.
Scanning skips directory symlinks and does not start playback. Select a row
to play it, or use the filter to find a title or folder.
Enable **Scan Images** in Settings → Plugins → Media Player to include supported
images in new directory scans. It is off by default; existing playlists are
kept when you change this setting.

Previous/next, repeat and shuffle controls navigate the queue. Playback advances
at the end of each track and stops at the last entry unless repeat is enabled.
Volume and mute are retained between tracks. The playlist stays visible during
fullscreen playback until toggled off; transport controls fade independently.

With the workspace plugin enabled, player tabs restore their playlist, filter,
selection, scroll position, repeat/shuffle settings, volume and mute after an
editor restart. Playback stays idle until you press Play, then resumes at the
saved position. Missing files are skipped; folders are not rescanned on restore.

For audio tracks, **Audio Display** in the plugin settings selects **Artwork**,
**Visualization**, or **Both**. Both places embedded cover art over the effect.
Choose Warp, Alchemy, Battery, Spikes, Scope, Particle, Spectrum Bars or Random
with **Audio Effect**. The effects are built into Media Player and do not
require the separate `audiovisu` addon. Effects respond to this player's audio
and stop while hidden or paused. Fullscreen expands the same presentation.
Live visualizations require the bundled runtime; system libmpv installations
continue to support playback and embedded artwork without the sample extension.

Hover over the seek bar to see the timestamp at the pointer position.

| Key | Action |
| --- | --- |
| Space | Play/pause; restart after the end |
| Left / Right | Seek backward/forward ten seconds |
| Ctrl+Left / Ctrl+Right | Previous/next track |
| Up / Down | Select playlist row; increase/decrease volume when the panel is hidden |
| Enter | Play the selected playlist row |
| P | Show/hide playlist |
| M | Toggle mute |
| F11 | Toggle fullscreen |
| Escape | Leave fullscreen |

Fullscreen controls appear on mouse movement and hide after three seconds.
Run `media-player:toggle-controls` to show or hide transport controls while
keeping playback shortcuts available. Fullscreen controls retain their usual
three-second timeout and reveal on mouse movement.
These shortcuts apply while the player is active and no text field has focus.
Settings → Plugins → Media Player configures the library override, initial
volume, frame rate and maximum rendered height. The frame-rate limit follows the
editor's configured rate by default (`Maximum Frame Rate = 0`). Set a positive
value to override it. Other defaults are 1080 pixels high and 80% volume.

Hardware decoding is enabled by default. libmpv tries supported copy-back
decoders for each video and falls back to software when unavailable. The
playback status displays the active decoder, such as `vaapi-copy`, or
`Software`. The **Hardware Decoding** toggle also applies to playing videos.
Scaling and color conversion use CPU resources even with hardware decoding.

**HDR to SDR** is off by default. When enabled, it tone-maps PQ/HLG HDR video to sRGB
using the native scaling filter. It applies during playback and while paused;
SDR video is unchanged. Tone mapping uses extra CPU. The player draws 8-bit SDR
pixels, so disabling this option does not enable HDR display output. System
libmpv installations need FFmpeg's scale color-mapping options; the bundled
runtime includes them.

**Scaling** defaults to Automatic: Lanczos for video up to 30 FPS, and faster
bilinear scaling for higher frame rates. Choose Lanczos for sharper scaling,
or Performance to reduce CPU cost at any frame rate.

Network-share buffering is configurable in **Settings → Plugins → Media Player**:

| Setting | Default | Effect |
| --- | --- | --- |
| Cache Mode | Always | Enable caching for all files, including unrecognized network shares. Automatic detects network shares; Disabled keeps only normal demuxer read-ahead. |
| Cache Size (MiB) | 200 | Maximum compressed data buffered ahead per player. A larger limit can cover longer network interruptions. |
| Buffer Duration (seconds) | 20 | How much media to buffer before resuming after an underrun. |
| Buffer Before Playback | On | Also wait for that duration before starting and after seeking. |

These settings apply to playing videos. For a less reliable share, increase
Cache Size to **512 MiB** to allow more read-ahead. Playback displays
**Buffering...** and progress while libmpv refills.
The byte limit and remaining media can shorten the requested wait. The cache
stores compressed packets; decoded frames and libmpv's backward cache use
additional memory. A larger cache can absorb interruptions once filled, but
cannot compensate for a connection that stays slower than the video bitrate.

## Plugin API

```lua
local MediaPlayer = require "plugins.mediaplayer"
local view = MediaPlayer.open("/path/to/video.webm") -- a new tab
view:open_file("/path/to/another.mp4")              -- append and play
view:scan("/path/to/videos")                       -- recursive playlist
view:set_playlist_visible(true)
view:advance(1)                                    -- next; -1 for previous
view:toggle_play()
view:seek_to(30)                                   -- seconds
view:change_volume(-5)                             -- percentage points
view:toggle_mute()
view:toggle_fullscreen()
```

`MediaPlayer.open(directory)` opens a new tab and scans that directory.
`MediaPlayer.open()` scans the configured default directory, or creates an empty
player if none is set. `MediaPlayer.open("")` always creates an empty player.
Its **Open** button shows the file picker. `MediaPlayer.is_supported(path)`
checks video extensions without loading libmpv; pass `true` as the second
argument to include audio, and as the third to include images.
`MediaPlayer.exit_fullscreen()` restores the editor if one of its players owns
the fullscreen presentation.

For a view managed by another plugin, construct `MediaPlayer.MediaView()` and
add it to a node. `view:set_controls_enabled(false)` hides transport and playlist
UI, disables player shortcuts and mouse actions, and prevents fullscreen mouse
movement from revealing controls. Playback methods remain available. Reenable
with `view:set_controls_enabled(true)`. `view:set_controls_visible(false)` only
hides transport temporarily; fullscreen mouse movement can reveal it again.
Call `view:close()` when removing an embedded view to cancel scanning and release
the native decoder. Normal tab closure handles this automatically.

## Native runtime

The bundled libmpv supports local audio and video, including AV1 software
decoding. Network URLs are unsupported; files on mounted network shares work.
A full system libmpv can provide additional codecs and features through the
library override.

Hardware decoding supports VAAPI and NVIDIA on Linux, D3D11VA and NVIDIA on
Windows, and VideoToolbox on macOS. Suitable GPU drivers are required; software
decoding is used when hardware is unavailable. NVIDIA requires driver
550.54.14 or newer on Linux, or 551.76 or newer on Windows. No CUDA toolkit is
needed. Linux audio requires PulseAudio or ALSA; macOS and Windows use their
native audio services.

The bundled Linux runtime gives each player tab its own audio device. Pausing,
replacing media or closing one tab leaves other players' audio running.

## Building

Native builds require Python 3.10 or later with tarfile extraction filters,
a C/C++ toolchain, Meson ≥1.3, Ninja, CMake, Make, pkg-config, NASM on x86_64,
and Python Jinja2. Linux additionally needs ALSA and PulseAudio development
headers, Autoconf, Automake and Libtool. macOS needs Xcode command-line tools;
Windows uses MSYS2 UCRT64.

```sh
python3 scripts/build.py --jobs 8
python3 scripts/check-runtime.py dist/mpv.x86_64-linux.so
python3 scripts/check-release.py dist --arch x86_64-linux
cp dist/mpv.x86_64-linux.so plugins/mediaplayer/
```

`sources.json` pins and verifies every upstream archive. Extracted sources,
private static dependencies and work directories stay under `.build/`; staged
binaries go into `dist/`. The build targets the native architecture. No files
are installed into the host's system prefix.

## Releases

Releases provide native libraries for all five supported platforms, build
information, and `SHA256SUMS`. Dependency source URLs and checksums are recorded
in `sources.json`; build scripts and local patches are included in this repository.

The Lua plugin and build scripts are MIT licensed. The LGPL native runtime and its
dependencies retain their upstream licenses, included in
[licenses/](licenses/) in this repository.
The FFT retains its upstream notices in the source comments.
