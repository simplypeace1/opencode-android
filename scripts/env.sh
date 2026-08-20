#!/usr/bin/env bash
# Environment variables for building OpenCode for Android (dual-ABI)
# Source this file before running any build scripts:
#   TARGET_ABI=arm64-v8a source scripts/env.sh
#   TARGET_ABI=armeabi-v7a source scripts/env.sh

set -euo pipefail

export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Versions
export BUN_VERSION="${BUN_VERSION:-1.2.13}"
export BUN_TAG="bun-v${BUN_VERSION}"
export WEBKIT_COMMIT="${WEBKIT_COMMIT:-017930ebf915121f8f593bef61cbbca82d78132d}"
export ICU_VERSION="${ICU_VERSION:-75.1}"
export ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
export OPENCODE_VERSION="${OPENCODE_VERSION:-1.3.13}"
export ANDROID_API="${ANDROID_API:-24}"

# opentui is pinned to the last commit whose tree still had the old
# packages/core/src/zig layout (the structure all our opentui Android
# patches target). Upstream restructured Zig code into packages/native on
# 2026-08-20; do NOT bump this until the patches are ported to the new
# layout (see build-opentui.sh).
export OPENTUI_COMMIT="${OPENTUI_COMMIT:-0d6f2fa8fe081439e4fcdb67af5e5ae6ac6fc0b0}"

# Select target ABIs, either comma-split from TARGET_ABIS or single TARGET_ABI
# Values: arm64-v8a (aarch64), armeabi-v7a (armv7a)
export TARGET_ABI="${TARGET_ABI:-arm64-v8a}"
case "${TARGET_ABI}" in
  arm64-v8a)
    export ANDROID_ABI=arm64-v8a
    export ANDROID_ARCH=aarch64
    export ANDROID_TRIPLE="aarch64-linux-android"
    # Zig target string for the opentui build (arch name Zig 0.16 accepts).
    # arm64 generic baseline already matches the ABI, so no CPU override:
    # leave ZIG_CPU unset (build.zig reads it; null => arch default).
    export ZIG_TARGET="aarch64-linux-android"
    unset ZIG_CPU
    ;;
  armeabi-v7a)
    export ANDROID_ABI=armeabi-v7a
    export ANDROID_ARCH=arm
    export ANDROID_TRIPLE="armv7a-linux-androideabi"
    # Zig 0.16 has no "armv7a" arch name; use "arm". Baseline ARM has no
    # v7a/VFP features, so pin the NDK-matching CPU model explicitly.
    export ZIG_TARGET="arm-linux-androideabi"
    export ZIG_CPU="generic+v7a+vfp3d16"
    ;;
  *)
    echo "ERROR: Unknown TARGET_ABI '${TARGET_ABI}' (use arm64-v8a or armeabi-v7a)" >&2
    exit 1
    ;;
esac
export ANDROID_TRIPLE_API="${ANDROID_TRIPLE}${ANDROID_API}"

# WebKit toolchain env overrides (defaults to aarch64 inside the cmake file)
if [ "${ANDROID_ARCH}" = "arm" ]; then
    export WEBKIT_SYSTEM_PROCESSOR=${ANDROID_ARCH}v7a
    export WEBKIT_ANDROID_TRIPLE=${ANDROID_TRIPLE}
else
    export WEBKIT_SYSTEM_PROCESSOR=${ANDROID_ARCH}
    export WEBKIT_ANDROID_TRIPLE=${ANDROID_TRIPLE}
fi

# Android NDK
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"

# NDK toolchain paths
export NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
export NDK_SYSROOT="${NDK_TOOLCHAIN}/sysroot"
export ANDROID_CC="${NDK_TOOLCHAIN}/bin/${ANDROID_TRIPLE_API}-clang"
export ANDROID_CXX="${NDK_TOOLCHAIN}/bin/${ANDROID_TRIPLE_API}-clang++"
export ANDROID_AR="${NDK_TOOLCHAIN}/bin/llvm-ar"
export ANDROID_RANLIB="${NDK_TOOLCHAIN}/bin/llvm-ranlib"
export ANDROID_STRIP="${NDK_TOOLCHAIN}/bin/llvm-strip"
export ANDROID_NM="${NDK_TOOLCHAIN}/bin/llvm-nm"
export ANDROID_LD="${NDK_TOOLCHAIN}/bin/ld.lld"

# Build directories (ABI-suffixed so arm64 and armv7 builds don't collide)
export ABI_SLUG="${ANDROID_ABI//-/_}"
export WORK_DIR="${WORK_DIR:-${REPO_ROOT}/build-${ABI_SLUG}}"
export BUN_SRC="${WORK_DIR}/bun-src"
export WEBKIT_SRC="${WORK_DIR}/webkit-src"
export OPENTUI_SRC="${WORK_DIR}/opentui-src"
export OPENCODE_SRC="${WORK_DIR}/opencode-src"
export ICU_SRC="${WORK_DIR}/icu-src"

export DEPS_PREFIX="${WORK_DIR}/deps-android/prefix"
export WEBKIT_BUILD="${WORK_DIR}/webkit-build"
export WEBKIT_OUTPUT="${WORK_DIR}/webkit-android"
export BUN_BUILD="${WORK_DIR}/bun-build"
export DIST_DIR="${WORK_DIR}/dist"

# Number of parallel jobs (can be overridden for low-RAM machines)
export JOBS="${JOBS:-$(nproc)}"

echo "=== OpenCode Android Build Environment ==="
echo "Repo root:     ${REPO_ROOT}"
echo "Work dir:      ${WORK_DIR}"
echo "NDK:           ${ANDROID_NDK_HOME}"
echo "API Level:     ${ANDROID_API}"
echo "Target:        ${ANDROID_TRIPLE}"
echo "Bun version:   ${BUN_VERSION}"
echo "WebKit commit: ${WEBKIT_COMMIT}"
echo "OpenCode ver:  ${OPENCODE_VERSION}"
echo "Jobs:          ${JOBS}"
echo "==========================================="
