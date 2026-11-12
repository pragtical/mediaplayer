#!/usr/bin/env python3
"""Build a minimal libmpv with private static dependencies, then stage it."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def license_notice(path):
    """Read a license file or the leading license comments of an upstream source."""
    content = path.read_bytes()
    if path.suffix in (".c", ".h"):
        match = re.match(rb"(?:\s*/\*.*?\*/)+", content, re.S)
        if not match:
            raise ValueError(f"Missing license header: {path}")
        content = match.group() + b"\n"
    return content


def check_license_notices(sources, pins):
    """Keep the repository's bundled notices aligned with the pinned sources."""
    directory = ROOT / "licenses"
    for name, spec in pins.items():
        for filename in spec["licenses"]:
            notice = directory / name / filename
            expected = license_notice(sources[name] / filename).replace(b"\r\n", b"\n")
            if not notice.is_file() or notice.read_bytes().replace(b"\r\n", b"\n") != expected:
                raise SystemExit(f"Update the bundled license notice: {notice}")


def install_audio_samples(source_dir):
    """Integrate our optional, nonblocking PCM snapshot API into pinned mpv."""
    for suffix in ("c", "h"):
        shutil.copyfile(ROOT / "native" / ("audio_samples." + suffix),
                        source_dir / "audio" / ("pragtical_samples." + suffix))

    def replace(filename, before, after):
        path = source_dir / filename
        text = path.read_text()
        if after in text:
            return
        if text.count(before) != 1:
            raise RuntimeError(f"mpv audio integration no longer matches {filename}")
        path.write_text(text.replace(before, after))

    replace("common/global.h", "    struct curl_ctx *curl;",
            "    struct curl_ctx *curl;\n    struct pragtical_audio_samples *pragtical_audio;")
    replace("player/main.c", '#include "common/global.h"',
            '#include "common/global.h"\n#include "audio/pragtical_samples.h"')
    replace("player/main.c", "    mpctx->global = talloc_zero(mpctx, struct mpv_global);",
            "    mpctx->global = talloc_zero(mpctx, struct mpv_global);\n"
            "    pragtical_audio_samples_init(mpctx->global);")
    replace("audio/out/buffer.c", '#include "audio/format.h"',
            '#include "audio/format.h"\n#include "audio/pragtical_samples.h"')
    replace("audio/out/buffer.c", "    ao_post_process_data(ao, data, pos);",
            "    ao_post_process_data(ao, data, pos);\n"
            "    pragtical_audio_samples_push(ao, data, pos);")
    replace("meson.build", "    'audio/aframe.c',",
            "    'audio/aframe.c',\n    'audio/pragtical_samples.c',")


def host_arch():
    """Return the native PPM architecture tuple; cross builds are not inferred."""
    cpu = platform.machine().lower()
    cpu = {"amd64": "x86_64", "arm64": "aarch64"}.get(cpu, cpu)
    system = {"Darwin": "darwin", "Windows": "windows", "Linux": "linux"}.get(platform.system())
    if system is None or cpu not in ("x86_64", "aarch64"):
        raise SystemExit("Unsupported native build platform")
    return f"{cpu}-{system}"


def run(args, cwd, env):
    """Run an argument vector and stop immediately if a build step fails."""
    print("+ " + " ".join(str(arg) for arg in args), flush=True)
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)


def source(name, spec, downloads, sources):
    """Fetch a checksum-pinned archive and extract only validated data members."""
    archive = downloads / spec["filename"]
    if not archive.exists():
        temporary = archive.with_name(archive.name + ".partial")
        for attempt in range(3):
            try:
                request = urllib.request.Request(spec["url"], headers={"User-Agent": "Pragtical-MediaPlayer"})
                with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
                    shutil.copyfileobj(response, output)
                temporary.replace(archive)
                break
            except OSError:
                temporary.unlink(missing_ok=True)
                if attempt == 2:
                    raise
                time.sleep(2)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != spec["sha256"]:
        raise SystemExit(f"Source checksum mismatch: {archive}")
    destination = sources / name
    marker = destination / ".source-sha256"
    if marker.exists():
        if marker.read_text().strip() != digest:
            raise SystemExit(f"Source pin changed; remove {destination} before rebuilding")
        return destination
    unpack = sources / (name + ".extract")
    if unpack.exists():
        shutil.rmtree(unpack)
    unpack.mkdir()

    def extract_member(member, target):
        # SDL's unused Ant examples have relative links rejected by older
        # Python data filters. Keep validation for every extracted member.
        if name == "sdl2" and member.name.split("/", 2)[1:2] == ["android-project-ant"]:
            return None
        return tarfile.data_filter(member, target)

    with tarfile.open(archive) as data:
        data.extractall(unpack, filter=extract_member)
    directories = list(unpack.iterdir())
    if len(directories) != 1 or not directories[0].is_dir():
        raise SystemExit(f"Expected one top-level directory in {archive}")
    directories[0].rename(destination)
    unpack.rmdir()
    marker.write_text(digest + "\n")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=ROOT / ".build")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--arch", default=host_arch())
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 2))
    parser.add_argument("--source-bundle", action="store_true", help="also package pinned sources and this build recipe")
    args = parser.parse_args()
    if args.arch != host_arch():
        parser.error("Use a native runner for the requested architecture")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    build, output = args.build_dir.resolve(), args.output.resolve()
    prefix = build / "prefix"
    for directory in (build / "downloads", build / "src", build / "work", prefix, output):
        directory.mkdir(parents=True, exist_ok=True)
    pins = json.loads((ROOT / "sources.json").read_text())
    sources = {name: source(name, spec, build / "downloads", build / "src") for name, spec in pins.items()}
    check_license_notices(sources, pins)
    install_audio_samples(sources["mpv"])
    audio_recipe = hashlib.sha256(b"".join(
        path.read_bytes() for path in sorted((ROOT / "native").iterdir()) if path.is_file()
    )).hexdigest()
    env = os.environ.copy()
    # Never let a host FFmpeg/font/GPU library leak into the release binary.
    pkgpath = os.pathsep.join((str(prefix / "lib/pkgconfig"), str(prefix / "share/pkgconfig")))
    env["PKG_CONFIG_PATH"] = pkgpath
    env["PKG_CONFIG_LIBDIR"] = pkgpath
    env["CMAKE_PREFIX_PATH"] = str(prefix)
    # Upstream archives must not discover the enclosing plugin's Git tags.
    env["GIT_CEILING_DIRECTORIES"] = str(build / "src")
    if platform.system() == "Darwin":
        env.setdefault("MACOSX_DEPLOYMENT_TARGET", "11.0")
    flags = "-O2 -ffunction-sections -fdata-sections -ffile-prefix-map=" + build.as_posix() + "=."
    if platform.system() != "Windows":
        flags += " -fPIC"
    for key in ("CFLAGS", "CXXFLAGS"):
        env[key] = (env.get(key, "") + " " + flags).strip()
    recipe = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    fingerprint = json.dumps([pins, recipe, args.arch, {key: env.get(key) for key in
        ("CC", "CXX", "CFLAGS", "CXXFLAGS", "LDFLAGS", "MACOSX_DEPLOYMENT_TARGET")}], sort_keys=True)

    def current(directory, signature):
        """Invalidate only this script's build outputs when its recipe changes."""
        stamp = directory / ".installed"
        if stamp.exists():
            if stamp.read_text() == signature:
                return True
            shutil.rmtree(directory)
        return False

    def meson(name, options=(), shared=False):
        """Configure, build and install one isolated Meson dependency."""
        directory = build / "work" / name
        stamp = directory / ".installed"
        signature = json.dumps([fingerprint, list(options), shared,
                                audio_recipe if name == "mpv" else None])
        if current(directory, signature):
            return directory
        command = ["meson", "setup", directory, sources[name], "--buildtype=release", "--wrap-mode=nodownload",
                   "--prefix=" + prefix.as_posix(), "--libdir=lib", "--auto-features=disabled",
                   "-Db_staticpic=true", "-Ddefault_library=" + ("shared" if shared else "static")]
        if (directory / "meson-private/coredata.dat").exists():
            command.append("--reconfigure")
        run(command + list(options), ROOT, env)
        run(["meson", "compile", "-C", directory, "-j", args.jobs], ROOT, env)
        run(["meson", "install", "-C", directory, "--no-rebuild"], ROOT, env)
        stamp.write_text(signature)
        return directory

    meson("freetype", ["-Dtests=disabled", "-Dharfbuzz=disabled", "-Dzlib=internal",
                       "-Dbrotli=disabled", "-Dbzip2=disabled", "-Dpng=disabled"])
    meson("harfbuzz", ["-Dfreetype=enabled", "-Dtests=disabled", "-Dutilities=disabled",
                      "-Dsubset=disabled", "-Draster=disabled", "-Dvector=disabled"])
    meson("fribidi", ["-Ddocs=false", "-Dbin=false", "-Dtests=false"])
    fonts = ["-Drequire-system-font-provider=false", "-Dasm=enabled"]
    if args.arch.endswith("-darwin"):
        fonts.append("-Dcoretext=enabled")
    elif args.arch.endswith("-windows"):
        fonts.append("-Ddirectwrite=enabled")
    meson("libass", fonts)
    # Codeload archives omit submodules. libc++ needs this header-only parser.
    shutil.copytree(sources["fast_float"] / "include",
                    sources["libplacebo"] / "3rdparty/fast_float/include",
                    dirs_exist_ok=True)
    # Vulkan stubs still include Vulkan types when the backend is disabled.
    shutil.copytree(sources["vulkan_headers"],
                    sources["libplacebo"] / "3rdparty/Vulkan-Headers",
                    dirs_exist_ok=True)
    placebo = ["-Ddemos=false", "-Dtests=false"]
    if args.arch.endswith("-darwin"):
        # Floating-point to_chars is unavailable on older supported macOS.
        placebo.append("-Dcpp_args=-DHAS_STD_TO_CHARS_FP=0")
    meson("libplacebo", placebo)
    # libplacebo's static pkg-config metadata omits its C++ standard library.
    # mpv links with the C compiler, so supply that transitive dependency.
    metadata = prefix / "lib/pkgconfig/libplacebo.pc"
    content = metadata.read_text()
    if "Libs.private:" not in content:
        library = "c++" if args.arch.endswith("-darwin") else "stdc++"
        metadata.write_text(content + "Libs.private: -l" + library + "\n")

    # Linux audio uses SDL's runtime-loaded PulseAudio/ALSA backends. No SDL
    # video, window system or shared SDL library is included in the package.
    if args.arch.endswith("-linux"):
        directory = build / "work/sdl2"
        if not current(directory, fingerprint):
            sdl_env = env.copy()
            # SDL uses system headers for its runtime-loaded audio backends.
            sdl_env.pop("PKG_CONFIG_PATH", None)
            sdl_env.pop("PKG_CONFIG_LIBDIR", None)
            run(["cmake", "-S", sources["sdl2"], "-B", directory, "-G", "Ninja",
                 "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_PREFIX=" + prefix.as_posix(),
                 "-DCMAKE_INSTALL_LIBDIR=lib", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
                 "-DSDL_SHARED=OFF", "-DSDL_STATIC=ON", "-DSDL_TEST=OFF",
                 "-DSDL_VIDEO=OFF", "-DSDL_RENDER=OFF", "-DSDL_JOYSTICK=OFF",
                 "-DSDL_HAPTIC=OFF", "-DSDL_SENSOR=OFF", "-DSDL_ALSA=ON",
                 "-DSDL_ALSA_SHARED=ON", "-DSDL_PULSEAUDIO=ON", "-DSDL_PULSEAUDIO_SHARED=ON"], ROOT, sdl_env)
            run(["cmake", "--build", directory, "--parallel", args.jobs], ROOT, sdl_env)
            run(["cmake", "--install", directory], ROOT, sdl_env)
            (directory / ".installed").write_text(fingerprint)

    if args.arch.endswith("-linux"):
        meson("libdrm", ["-Dtests=false", "-Dinstall-test-programs=false"])
        # libva's Meson recipe hardcodes shared libraries. Its Autotools build
        # supports static loaders, with GPU drivers supplied by the host OS.
        directory = build / "work/libva"
        if not current(directory, fingerprint):
            directory.mkdir(exist_ok=True)
            run(["autoreconf", "-fi"], sources["libva"], env)
            driver_paths = ":".join(["/usr/lib/x86_64-linux-gnu/dri",
                                     "/usr/lib/aarch64-linux-gnu/dri",
                                     "/usr/lib64/dri", "/usr/lib/dri"])
            run([sources["libva"] / "configure", "--prefix=" + prefix.as_posix(),
                 "--libdir=" + (prefix / "lib").as_posix(), "--enable-static",
                 "--disable-shared", "--with-pic", "--enable-drm", "--disable-x11",
                 "--disable-glx", "--disable-wayland", "--disable-docs",
                 "--with-legacy=", "--with-drivers-path=" + driver_paths], directory, env)
            run(["make", "-j", args.jobs], directory, env)
            run(["make", "install"], directory, env)
            (directory / ".installed").write_text(fingerprint)
        metadata = prefix / "lib/pkgconfig/libva-drm.pc"
        content = metadata.read_text()
        if "Requires.private:" not in content:
            metadata.write_text(content + "Requires.private: libdrm\n")
    if not args.arch.endswith("-darwin"):
        directory = build / "work/nvcodec"
        if not current(directory, fingerprint):
            directory.mkdir(exist_ok=True)
            run(["make", "install", "PREFIX=" + prefix.as_posix()], sources["nvcodec"], env)
            (directory / ".installed").write_text(fingerprint)

    # FFmpeg's built-in AV1 decoder requires hardware; dav1d supplies software fallback.
    meson("dav1d", ["-Denable_tools=false", "-Denable_tests=false"])

    ffmpeg = build / "work/ffmpeg"
    if not current(ffmpeg, fingerprint):
        ffmpeg.mkdir(exist_ok=True)
        options = ["--prefix=" + prefix.as_posix(), "--pkg-config-flags=--static", "--enable-static",
                   "--disable-shared", "--enable-pic", "--disable-autodetect", "--disable-programs",
                   "--disable-doc", "--disable-debug", "--disable-network", "--disable-avdevice",
                   "--disable-encoders", "--disable-muxers", "--disable-devices", "--disable-hwaccels",
                   "--disable-filters", "--enable-filter=abuffer,abuffersink,buffer,buffersink,aformat,format,aresample,scale,volume",
                   "--disable-gpl", "--disable-nonfree", "--disable-version3", "--enable-runtime-cpudetect",
                   "--enable-libdav1d"]
        if args.arch.startswith("x86_64-"):
            options += ["--arch=x86_64", "--cpu=x86-64"]
        else:
            options += ["--arch=aarch64", "--cpu=generic"]
        if args.arch.endswith("-linux"):
            options += ["--enable-vaapi", "--enable-libdrm", "--enable-ffnvcodec",
                        "--enable-cuda", "--enable-nvdec",
                        "--enable-hwaccel=*_vaapi,*_nvdec"]
        elif args.arch.endswith("-darwin"):
            options += ["--enable-videotoolbox", "--enable-hwaccel=*_videotoolbox"]
        if args.arch.endswith("-windows"):
            options += ["--target-os=mingw32", "--disable-pthreads", "--enable-w32threads",
                        "--enable-d3d11va", "--enable-ffnvcodec", "--enable-cuda",
                        "--enable-nvdec", "--enable-hwaccel=*_d3d11va*,*_nvdec"]
        run(["bash", sources["ffmpeg"] / "configure", *options], ffmpeg, env)
        run(["make", "-j", args.jobs], ffmpeg, env)
        run(["make", "install"], ffmpeg, env)
        (ffmpeg / ".installed").write_text(fingerprint)

    # FFmpeg can silently disable a requested component after a failed probe.
    hardware = {
        "linux": ["HAVE_VAAPI_DRM", "CONFIG_H264_VAAPI_HWACCEL",
                  "CONFIG_VP9_VAAPI_HWACCEL", "CONFIG_H264_NVDEC_HWACCEL"],
        "darwin": ["CONFIG_H264_VIDEOTOOLBOX_HWACCEL", "CONFIG_HEVC_VIDEOTOOLBOX_HWACCEL"],
        "windows": ["CONFIG_H264_D3D11VA2_HWACCEL", "CONFIG_H264_NVDEC_HWACCEL"]
    }[args.arch.split("-", 1)[1]]
    configuration = (ffmpeg / "config.h").read_text() + (ffmpeg / "config_components.h").read_text()
    for feature in hardware:
        if "#define " + feature + " 1\n" not in configuration:
            raise SystemExit("Required hardware decoding component is missing: " + feature)
    if "#define CONFIG_LIBDAV1D_DECODER 1\n" not in configuration:
        raise SystemExit("Required AV1 software decoder is missing: libdav1d")

    audio = {"linux": "sdl2-audio", "darwin": "coreaudio", "windows": "wasapi"}[args.arch.split("-", 1)[1]]
    options = ["-Dcplayer=false", "-Dlibmpv=true", "-Dgpl=false", "-Dlua=disabled", "-Dgl=disabled",
               "-Dprefer_static=true", "-Db_lundef=true", "-Dbuild-date=false", "-D" + audio + "=enabled"]
    if args.arch.endswith("-windows"):
        options += ["-Dwin32-threads=enabled", "-Dc_link_args=-static"]
    directory = meson("mpv", options, shared=True)
    targets = json.loads(subprocess.check_output(["meson", "introspect", "--targets", str(directory)], env=env))
    candidates = [Path(filename) for target in targets if target["type"] == "shared library" and target["name"] == "mpv"
                  for filename in target["filename"]]
    if len(candidates) != 1:
        raise SystemExit("Cannot identify the built libmpv through Meson introspection")
    suffix = ".dll" if args.arch.endswith("-windows") else ".so"
    staged = output / ("mpv." + args.arch + suffix)
    shutil.copy2(candidates[0], staged)
    strip = os.environ.get("STRIP", "strip")
    run([strip, *( ["-S", "-x"] if args.arch.endswith("-darwin") else ["--strip-unneeded"]), staged], ROOT, env)
    if args.arch.endswith("-darwin"):
        run(["install_name_tool", "-id", "@rpath/" + staged.name, staged], ROOT, env)

    (output / ("build-info." + args.arch + ".json")).write_text(json.dumps({
        "arch": args.arch, "sources": pins, "mpv_options": options, "hardware_features": hardware,
        "ffmpeg_features": "local-file playback, software decoding including AV1 via dav1d, and copy-back hardware decoding; no encoding or network",
        "audio_samples": {"frames": 2048, "channels": 2, "nonblocking": True}
    }, indent=2) + "\n")
    if args.source_bundle:
        with tarfile.open(output / "sources.tar.gz", "w:gz") as archive:
            for spec in pins.values():
                archive.add(build / "downloads" / spec["filename"], arcname="mediaplayer/.build/downloads/" + spec["filename"])
            for filename in ("sources.json", "manifest.json", "README.md", "LICENSE"):
                archive.add(ROOT / filename, arcname="mediaplayer/" + filename)
            archive.add(ROOT / "scripts", arcname="mediaplayer/scripts", filter=lambda entry: None if "__pycache__" in entry.name else entry)
            archive.add(ROOT / "native", arcname="mediaplayer/native")
            archive.add(ROOT / "licenses", arcname="mediaplayer/licenses")
            for path in (ROOT / "plugins").rglob("*"):
                if path.is_file() and (path.suffix == ".lua" or path.name.startswith("LICENSE")):
                    archive.add(path, arcname="mediaplayer/" + path.relative_to(ROOT).as_posix())
    print(f"Staged {staged} ({staged.stat().st_size / 1024 / 1024:.1f} MiB)")


if __name__ == "__main__":
    main()
