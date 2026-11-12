#!/usr/bin/env bash
# Build a test copy of libobs + libobs-opengl + image-source from upstream OBS
# for the headless harness.
#
# Two small test-only patches are applied:
#   * obs_source_video_tick() is exported, so the harness can drive frames with
#     fixed time steps (deterministic elapsed_time) instead of the wall clock.
#   * only the image-source core module is built (others need many deps).
# On distributions with an older FFmpeg the version floor is relaxed; libobs
# only uses FFmpeg for media I/O, which the harness never touches.
#
#   tests/setup/build-libobs.sh <workdir> [obs-tag]
#
# Installs into <workdir>/prefix.
set -euo pipefail

WORK=${1:?usage: build-libobs.sh <workdir> [obs-tag]}
TAG=${2:-33.0.1}
mkdir -p "$WORK"
cd "$WORK"

if [ ! -d obs-studio ]; then
	git clone --depth 1 --branch "$TAG" https://github.com/obsproject/obs-studio obs-studio
fi
cd obs-studio

# Export obs_source_video_tick (test-only).
sed -i 's/^extern void obs_source_video_tick(obs_source_t \*source, float seconds);/EXPORT void obs_source_video_tick(obs_source_t *source, float seconds);/' libobs/obs-internal.h
grep -q "EXPORT void obs_source_video_tick" libobs/obs-internal.h

# Accept the distribution FFmpeg.
sed -i -E 's/find_package\(FFmpeg [0-9.]+ REQUIRED/find_package(FFmpeg REQUIRED/' libobs/CMakeLists.txt

# Make sure glad's EGL loader is compiled (OpenGL::EGL is only defined when
# requested as a component with some CMake versions).
sed -i 's/^find_package(OpenGL REQUIRED)$/find_package(OpenGL REQUIRED COMPONENTS OpenGL EGL)/' deps/glad/CMakeLists.txt

# Only build the image-source core module.
python3 - <<'EOF'
import re, pathlib
p = pathlib.Path("plugins/CMakeLists.txt")
s = p.read_text()
marker = "# Add plugins in alphabetical order"
if marker in s:
    head = s.partition(marker)[0]
    p.write_text(head + "add_core_module(image-source)\n\nset_obs_core_modules()\n")
EOF
sed -i 's#^add_subdirectory(test/test-input)#\# test-input disabled for the harness#' CMakeLists.txt

cmake -S . -B build -G Ninja \
	-DCMAKE_BUILD_TYPE=RelWithDebInfo \
	-DCMAKE_INSTALL_PREFIX="$WORK/prefix" \
	-DENABLE_FRONTEND=OFF -DENABLE_SCRIPTING=OFF -DENABLE_PULSEAUDIO=OFF \
	-DENABLE_WAYLAND=OFF -DENABLE_HEVC=OFF -DENABLE_AJA=OFF -DENABLE_WEBRTC=OFF \
	-DENABLE_NVENC=OFF -DENABLE_VLC=OFF -DENABLE_BROWSER=OFF -DENABLE_WEBSOCKET=OFF \
	-DENABLE_NEW_MPEGTS_OUTPUT=OFF -DENABLE_PLUGINS=ON
cmake --build build
cmake --install build
echo "libobs installed to $WORK/prefix"
