#!/usr/bin/env python3
"""Check a staged libmpv without depending on an editor or media executables."""

import argparse
import ctypes as c
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import struct
import tempfile
import time
import wave


class Param(c.Structure):
    _fields_ = [("type", c.c_int), ("data", c.c_void_p)]


class Event(c.Structure):
    _fields_ = [("event_id", c.c_int), ("error", c.c_int), ("reply", c.c_uint64), ("data", c.c_void_p)]


class Property(c.Structure):
    _fields_ = [("name", c.c_char_p), ("format", c.c_int), ("data", c.c_void_p)]


def check_dependencies(path):
    """Reject private build libraries accidentally left as dynamic dependencies."""
    if platform.system() == "Linux":
        output = subprocess.check_output(["ldd", str(path)], text=True)
        allowed = {"libc.so.6", "libm.so.6", "libmvec.so.1", "libpthread.so.0", "libdl.so.2", "librt.so.1", "libgcc_s.so.1", "libstdc++.so.6"}
        linked = set(re.findall(r"^\s*(\S+)\s+=>", output, re.M))
        assert "not found" not in output and not linked - allowed, output
    elif platform.system() == "Darwin":
        output = subprocess.check_output(["otool", "-L", str(path)], text=True)
        for line in output.splitlines()[2:]:
            name = line.strip().split(" ", 1)[0]
            assert name.startswith(("/System/Library/", "/usr/lib/")), output
    else:
        output = subprocess.check_output(["objdump", "-p", str(path)], text=True)
        for name in re.findall(r"DLL Name:\s*(\S+)", output, re.I):
            assert not re.search(r"(libgcc|libstdc|libwinpthread|libav|libass|freetype|harfbuzz|fribidi|placebo|sdl)", name, re.I), output
    print("Verified only platform runtime libraries are dynamically linked")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    args = parser.parse_args()
    path = args.library.resolve()
    check_dependencies(path)
    lib = c.CDLL(str(path))
    signatures = {
        "mpv_client_api_version": (c.c_ulong, []), "mpv_create": (c.c_void_p, []),
        "mpv_set_option_string": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p]),
        "mpv_initialize": (c.c_int, [c.c_void_p]),
        "mpv_command_async": (c.c_int, [c.c_void_p, c.c_uint64, c.POINTER(c.c_char_p)]),
        "mpv_observe_property": (c.c_int, [c.c_void_p, c.c_uint64, c.c_char_p, c.c_int]),
        "mpv_wait_event": (c.POINTER(Event), [c.c_void_p, c.c_double]),
        "mpv_render_context_create": (c.c_int, [c.POINTER(c.c_void_p), c.c_void_p, c.POINTER(Param)]),
        "mpv_render_context_update": (c.c_uint64, [c.c_void_p]),
        "mpv_render_context_render": (c.c_int, [c.c_void_p, c.POINTER(Param)]),
        "mpv_render_context_free": (None, [c.c_void_p]),
        "mpv_terminate_destroy": (None, [c.c_void_p]),
        "mpv_error_string": (c.c_char_p, [c.c_int]),
        "mpv_pragtical_audio_capture": (c.c_int, [c.c_void_p, c.c_int]),
        "mpv_pragtical_audio_samples": (c.c_int, [c.c_void_p, c.POINTER(c.c_float), c.c_int,
            c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_uint64)])
    }
    for name, (result, arguments) in signatures.items():
        function = getattr(lib, name)
        function.restype, function.argtypes = result, arguments
    assert lib.mpv_client_api_version() >> 16 == 2

    def check(result):
        assert result >= 0, lib.mpv_error_string(result).decode()

    def capture_audio(enabled):
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            result = lib.mpv_pragtical_audio_capture(handle, int(enabled))
            check(result)
            if result == 1:
                return
            time.sleep(0.001)
        raise AssertionError("Audio snapshot toggle remained busy")

    def param(kind, data):
        return Param(kind, c.cast(data, c.c_void_p))

    handle, context = lib.mpv_create(), c.c_void_p()
    assert handle
    try:
        audio = "null"
        if platform.system() == "Linux":
            os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
            audio = "sdl"
        for name, value in {"vo": "libmpv", "ao": audio, "terminal": "no", "config": "no", "keep-open": "yes", "video-timing-offset": "0", "hwdec": "auto-copy", "cache": "yes", "demuxer-max-bytes": "209715200", "cache-pause-wait": "20", "cache-pause-initial": "yes"}.items():
            check(lib.mpv_set_option_string(handle, name.encode(), value.encode()))
        check(lib.mpv_initialize(handle))
        check(lib.mpv_observe_property(handle, 2, b"hwdec-current", 1))
        api = c.create_string_buffer(b"sw")
        check(lib.mpv_render_context_create(c.byref(context), handle, (Param * 2)(param(1, api), Param())))
        size, stride = (c.c_int * 2)(96, 64), (c.c_size_t * 1)(96 * 4)
        allocation = c.create_string_buffer(96 * 64 * 4 + 63)
        pixels = c.c_void_p((c.addressof(allocation) + 63) & ~63)
        format, block = c.create_string_buffer(b"rgba"), (c.c_int * 1)(0)
        params = (Param * 6)(param(17, size), param(18, format), param(19, stride), Param(20, pixels), param(12, block), Param())
        with tempfile.TemporaryDirectory(prefix="mediaplayer-runtime-") as directory:
            media = Path(directory) / "colors.y4m"
            with media.open("wb") as output:
                output.write(b"YUV4MPEG2 W96 H64 F12:1 Ip A1:1 C420jpeg\n")
                for frame in range(18):
                    output.write(b"FRAME\n" + bytes([32 + frame * 10]) * (96 * 64) + bytes([128]) * (96 * 64 // 2))
            command = (c.c_char_p * 4)(b"loadfile", str(media).encode(), b"replace", None)
            check(lib.mpv_command_async(handle, 0, command))
            colors, frames, decoder, deadline = set(), 0, None, time.monotonic() + 6
            while time.monotonic() < deadline and (len(colors) < 12 or decoder is None):
                for _ in range(100):
                    event = lib.mpv_wait_event(handle, 0).contents
                    if event.event_id == 0:
                        break
                    check(event.error)
                    if event.event_id == 22 and event.data:
                        prop = c.cast(event.data, c.POINTER(Property)).contents
                        if prop.name == b"hwdec-current" and prop.format == 1 and prop.data:
                            decoder = c.cast(prop.data, c.POINTER(c.c_char_p)).contents.value.decode()
                if lib.mpv_render_context_update(context):
                    check(lib.mpv_render_context_render(context, params))
                    frames += 1
                    colors.add(c.string_at(pixels, 3))
                time.sleep(0.01)
            assert len(colors) >= 12, f"Video stalled: {frames} renders, {len(colors)} distinct frames"
            assert decoder == "no", f"Raw video must fall back to software decoding: {decoder}"
            alpha = c.string_at(pixels, 96 * 64 * 4)[3::4]
            assert alpha == bytes([255]) * (96 * 64), "RGBA output must supply opaque alpha"
            print(f"Verified automatic software fallback: {frames} renders, {len(colors)} distinct frames")
            sound = Path(directory) / "tone.wav"
            with wave.open(str(sound), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(48000)
                output.writeframes(b"".join(struct.pack("<h", int(math.sin(i * math.tau * 440 / 48000) * 6000))
                                           for i in range(48000)))
            capture_audio(True)
            samples, channels, sample_rate, sequence = (c.c_float * 4096)(), c.c_int(), c.c_int(), c.c_uint64()
            captured = 0
            check(lib.mpv_observe_property(handle, 1, b"time-pos", 5))
            command = (c.c_char_p * 4)(b"loadfile", str(sound).encode(), b"replace", None)
            check(lib.mpv_command_async(handle, 0, command))
            loaded, position, deadline = False, 0, time.monotonic() + 5
            while time.monotonic() < deadline and position < 0.2:
                for _ in range(100):
                    event = lib.mpv_wait_event(handle, 0).contents
                    if event.event_id == 0:
                        break
                    check(event.error)
                    if event.event_id == 8:
                        loaded, position = True, 0
                    elif event.event_id == 22 and loaded and event.data:
                        prop = c.cast(event.data, c.POINTER(Property)).contents
                        if prop.name == b"time-pos" and prop.format == 5 and prop.data:
                            position = c.cast(prop.data, c.POINTER(c.c_double)).contents.value
                if lib.mpv_render_context_update(context):
                    check(lib.mpv_render_context_render(context, params))
                frames = lib.mpv_pragtical_audio_samples(handle, samples, 2048,
                    c.byref(channels), c.byref(sample_rate), c.byref(sequence))
                check(frames)
                if frames:
                    assert 1 <= channels.value <= 2 and sample_rate.value > 0
                    assert all(math.isfinite(value) and abs(value) <= 1 for value in samples[:frames * channels.value])
                    if any(abs(value) > 0.01 for value in samples[:frames * channels.value]):
                        captured += frames
                time.sleep(0.01)
            assert loaded and position >= 0.2, "Audio decoding or output did not advance"
            assert captured > 0, "Native PCM snapshots did not contain decoded audio"
            capture_audio(False)
            assert lib.mpv_pragtical_audio_samples(handle, samples, 2048,
                c.byref(channels), c.byref(sample_rate), c.byref(sequence)) == 0
            print(f"Verified audio decoding/output through {audio}")
            print(f"Verified bounded PCM snapshots: {captured} non-silent frames")
    finally:
        if context:
            lib.mpv_render_context_free(context)
        lib.mpv_terminate_destroy(handle)


if __name__ == "__main__":
    main()
