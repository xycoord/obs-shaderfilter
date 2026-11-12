#!/usr/bin/env bash
# One-stop runner for the parity and performance tests (Ubuntu 24.04).
#
#   tests/run.sh setup              install packages, build test libobs, harness,
#                                   reference plugin (REF) and this plugin
#   tests/run.sh parity [args...]   compare this build with the reference
#                                   (args go to shadertest.py parity, e.g. --opaque)
#   tests/run.sh bench  [args...]   time this build (args to shadertest.py bench)
#   tests/run.sh bench-ref [args]   time the reference build
#
# WORK (default: ~/.cache/obs-shaderfilter-tests) holds everything built.
# REF (default: 73fb5c2, release 2.6.1) is the commit compared against.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/.cache/obs-shaderfilter-tests}
REF=${REF:-73fb5c2}
OBS_TAG=${OBS_TAG:-33.0.1}
export OBS_PREFIX=$WORK/libobs/prefix
export HARNESS_BUILD=$WORK/harness-build

setup() {
	if command -v apt-get >/dev/null && [ "$(id -u)" = 0 ]; then
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
			build-essential cmake ninja-build git pkg-config python3-numpy python3-pil xvfb \
			libgl1-mesa-dri libegl-mesa0 libegl-dev libgl-dev libopengl-dev libglx-dev libpng-dev \
			libsimde-dev uthash-dev libjansson-dev libavformat-dev libavcodec-dev libavutil-dev \
			libswscale-dev libswresample-dev uuid-dev libx11-dev libx11-xcb-dev libxcb1-dev \
			libxcb-xinput-dev libglib2.0-dev libdrm-dev libgbm-dev extra-cmake-modules \
			libxkbcommon-dev nlohmann-json3-dev libpci-dev
	fi
	mkdir -p "$WORK"
	[ -f "$OBS_PREFIX/lib/libobs.so" ] || "$REPO/tests/setup/build-libobs.sh" "$WORK/libobs" "$OBS_TAG"
	cmake -S "$REPO/tests/harness" -B "$HARNESS_BUILD" -DCMAKE_PREFIX_PATH="$OBS_PREFIX" -DCMAKE_BUILD_TYPE=Release
	cmake --build "$HARNESS_BUILD" -j"$(nproc)"

	rm -rf "$WORK/ref-src"
	git -C "$REPO" archive --prefix=ref-src/ "$REF" | tar -x -C "$WORK"
	cmake -S "$WORK/ref-src" -B "$WORK/ref-build" -DCMAKE_PREFIX_PATH="$OBS_PREFIX" -DCMAKE_BUILD_TYPE=RelWithDebInfo
	cmake --build "$WORK/ref-build" -j"$(nproc)"
	build_new
}

build_new() {
	cmake -S "$REPO" -B "$WORK/new-build" -DCMAKE_PREFIX_PATH="$OBS_PREFIX" -DCMAKE_BUILD_TYPE=RelWithDebInfo
	cmake --build "$WORK/new-build" -j"$(nproc)"
}

cmd=${1:-}
shift || true
case "$cmd" in
setup) setup ;;
parity)
	build_new
	python3 "$REPO/tests/shadertest.py" parity --ref "$WORK/ref-build/obs-shaderfilter.so" \
		--ref-data "$WORK/ref-src/data" --new "$WORK/new-build/obs-shaderfilter.so" --new-data "$REPO/data" \
		--out "$WORK/parity" "$@"
	;;
bench)
	build_new
	python3 "$REPO/tests/shadertest.py" bench --plugin "$WORK/new-build/obs-shaderfilter.so" --data "$REPO/data" \
		--out "$WORK/bench" "$@"
	;;
bench-ref)
	python3 "$REPO/tests/shadertest.py" bench --plugin "$WORK/ref-build/obs-shaderfilter.so" \
		--data "$WORK/ref-src/data" --out "$WORK/bench-ref" "$@"
	;;
*)
	sed -n '2,13p' "$0"
	exit 2
	;;
esac
