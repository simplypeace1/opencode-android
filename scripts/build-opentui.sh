#!/usr/bin/env bash
# Build libopentui.so for Android aarch64
#
# Usage: ./scripts/build-opentui.sh
#
# OpenCode's TUI renderer (@opentui/core) uses a native Zig library.
# The upstream build targets aarch64-linux (musl), which fails on Android
# because getauxval cannot be resolved. We build for aarch64-linux-android.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ZIG_BIN="${ZIG_BIN:-zig}"

echo "=== Building libopentui.so for Android aarch64 ==="

# Clone opentui if needed
if [ ! -d "$OPENTUI_SRC/.git" ]; then
    echo ">>> Cloning opentui..."
    git clone --depth 1 https://github.com/anomalyco/opentui.git "$OPENTUI_SRC"
else
    echo ">>> opentui source exists at $OPENTUI_SRC"
fi

# Pin to the known-good commit (see OPENTUI_COMMIT in env.sh). Upstream main
# is a moving target (it restructured to packages/native on 2026-08-20, which
# our patches don't target), so always check out the pinned revision.
cd "$OPENTUI_SRC"
CURRENT_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
if [ -n "${OPENTUI_COMMIT:-}" ] && [ "$CURRENT_HEAD" != "$OPENTUI_COMMIT" ]; then
    echo ">>> Pinning opentui to ${OPENTUI_COMMIT} (was ${CURRENT_HEAD:-<empty>})..."
    git fetch --quiet --depth 1 origin "${OPENTUI_COMMIT}" || {
        echo "ERROR: Could not fetch pinned opentui commit ${OPENTUI_COMMIT}"
        exit 1
    }
    git checkout --quiet --detach "${OPENTUI_COMMIT}" || {
        echo "ERROR: Could not checkout pinned opentui commit ${OPENTUI_COMMIT}"
        exit 1
    }
fi

# Apply opentui Android patches. Note: `zig build --libc` only affects the
# linking phase (b.libc_file); the translate-c pass ignores it, so we also add
# the NDK sysroot include dir to the translate-c steps via a separate patch.
apply_opentui_patch() {
    local patch_path="$1"
    if [ -f "$patch_path" ]; then
        echo ">>> Applying opentui Android patch: $(basename "$patch_path")"
        cd "$OPENTUI_SRC"
        if ! git apply --check "$patch_path" 2>/dev/null; then
            # With the commit pin in place, a clean apply is expected. A skip
            # here means the pinned tree doesn't match the patches (wrong pin)
            # or the patch was already applied by a prior resume — refuse to
            # continue silently, since an unpatched build produces a broken .so
            # (missing libc.so NEEDED, translate-c failures, 64-bit atomics).
            echo "ERROR: opentui patch does not apply cleanly at pinned commit ${OPENTUI_COMMIT:-<unset>}."
            echo "       Expected the patch to apply. Check OPENTUI_COMMIT in scripts/env.sh."
            git apply --check --verbose "$patch_path" 2>&1 | head -10
            exit 1
        else
            git apply "$patch_path"
            echo "    Patch applied successfully"
        fi
    fi
}

# Without this patch, the .so won't have NEEDED: libc.so, and Android's
# dlopen() will fail because it can't resolve symbols like getauxval.
apply_opentui_patch "$REPO_ROOT/patches/opentui/android-libc-link.patch"
# Without this patch, translate-c fails on bionic headers (pthread.h/math.h).
apply_opentui_patch "$REPO_ROOT/patches/opentui/android-translatec-include.patch"
# Applies -Dcpu features (ZIG_CPU) to the Zig target query for armeabi-v7a.
apply_opentui_patch "$REPO_ROOT/patches/opentui/android-cpu-features.patch"
# Downgrades the u64 telemetry counters in audio.zig to u32 atomics: Zig
# rejects 64-bit @atomicRmw/@atomicLoad on 32-bit ARM targets
# (Zcu.atomicPtrAlignment caps max_atomic_bits at ptrBitWidth()=32).
apply_opentui_patch "$REPO_ROOT/patches/opentui/android-atomics.patch"

OPENTUI_ZIG_DIR="$OPENTUI_SRC/packages/core/src/zig"

if [ ! -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_ZIG_DIR"
    echo "       Expected the pre-2026-08-20 opentui layout (packages/core/src/zig)."
    echo "       Upstream moved Zig code to packages/native; our Android patches"
    echo "       (patches/opentui/*.patch) and this script have not been ported yet."
    echo "       Check OPENTUI_COMMIT in scripts/env.sh."
    exit 1
fi

# Skip if already built (cached output from a prior run).
# Note: build.zig installs to ../lib/{output_name} where output_name is the
# -Dtarget string (ZIG_TARGET), NOT the NDK/clang triple (ANDROID_TRIPLE).
ZIG_TARGET="${ZIG_TARGET:-${ANDROID_TRIPLE}}"
LIBOPENTUI_CACHED="$OPENTUI_ZIG_DIR/../lib/${ZIG_TARGET}/libopentui.so"
CACHE_DIR="$WORK_DIR/opentui-lib"
CACHED_LIB="$CACHE_DIR/${ZIG_TARGET}/libopentui.so"
if [ -f "$CACHED_LIB" ]; then
    echo ">>> Restoring cached libopentui.so from $CACHED_LIB"
    mkdir -p "$(dirname "$LIBOPENTUI_CACHED")"
    cp "$CACHED_LIB" "$LIBOPENTUI_CACHED"
    echo ">>> libopentui.so restored from cache — skipping"
    exit 0
fi
if [ -f "$LIBOPENTUI_CACHED" ]; then
    echo ">>> libopentui.so already built at $LIBOPENTUI_CACHED — skipping"
    exit 0
fi

echo ">>> Building with Zig (target: ${ZIG_TARGET:-${ANDROID_TRIPLE}})..."
cd "$OPENTUI_ZIG_DIR"

NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"
NDK_SYSROOT="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
# NDK sysroot lib dirs use arm-linux-androideabi (not the armv7a- clang prefix)
LIBC_TRIPLE="${ANDROID_TRIPLE/armv7a-/arm-}"
LIBC_FILE="$BUN_BUILD/zig-android-libc.txt"
mkdir -p "$(dirname "$LIBC_FILE")"
# Zig 0.16's LibCInstallation parser requires ALL 6 keys present as lines
# (only value-emptiness is OS-conditional). Missing keys => ParseError.
cat > "$LIBC_FILE" <<EOF
include_dir=$NDK_SYSROOT/usr/include
# Zig's LibCDirs.detectFromInstallation adds include_dir and sys_include_dir
# (only when they differ). NDK r28b keeps arch-specific headers like
# asm/types.h under usr/include/<triple>, so point sys_include_dir there to
# get both the generic and the arch-triple dir on the -isystem path.
sys_include_dir=$NDK_SYSROOT/usr/include/${LIBC_TRIPLE}
crt_dir=$NDK_SYSROOT/usr/lib/${LIBC_TRIPLE}/${ANDROID_API}
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF
echo ">>> NDK libc file: $LIBC_FILE"
cat "$LIBC_FILE"

# The libc file is passed ONLY to the cross-compiled lib via setLibCFile in
# android-libc-link.patch (reads ANDROID_NDK_LIBC_FILE). Do NOT use the global
# `zig build --libc` flag: it propagates into dependency sub-builds (uucode's
# native host tool uucode_generate) and breaks them.
export ANDROID_NDK_LIBC_FILE="$LIBC_FILE"

# ZIG_CPU is consumed inside build.zig via android-cpu-features.patch
# (reads the ZIG_CPU env var). Do NOT pass -Dcpu on the CLI: opentui's
# build.zig doesn't call standardTargetOptions, so -Dcpu is an unregistered
# option and `zig build` would reject it.
"$ZIG_BIN" build \
    -Dtarget="${ZIG_TARGET:-${ANDROID_TRIPLE}}" \
    -Doptimize=ReleaseSafe \
    --prefix . 2>&1

# The build.zig installs to dest_dir="../lib/{output_name}" relative to
# the --prefix dir.  With --prefix=. (= OPENTUI_ZIG_DIR), the .so ends
# up one directory above: packages/core/src/lib/aarch64-linux-android/
LIBOPENTUI="$OPENTUI_ZIG_DIR/../lib/${ZIG_TARGET}/libopentui.so"
if [ ! -f "$LIBOPENTUI" ]; then
    echo "ERROR: libopentui.so not found"
    echo "  Expected at: $LIBOPENTUI"
    echo "  Searching for any libopentui.so under opentui-src..."
    find "$OPENTUI_SRC" -name "libopentui.so" -type f 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== libopentui.so build complete ==="
echo "Output: $LIBOPENTUI"
echo "Size: $(du -h "$LIBOPENTUI" | cut -f1)"
file "$LIBOPENTUI"

# Verify the .so has NEEDED: libc.so (required for Android dlopen)
if readelf -d "$LIBOPENTUI" 2>/dev/null | grep -q "NEEDED.*libc.so"; then
    echo "OK: libopentui.so has NEEDED: libc.so (required for Android)"
else
    echo "ERROR: libopentui.so is missing NEEDED: libc.so dependency"
    echo "       Android dlopen() will fail without this."
    echo "       Ensure ANDROID_NDK_HOME is set and the opentui patch was applied."
    readelf -d "$LIBOPENTUI" 2>/dev/null | grep NEEDED || echo "       (no NEEDED entries found)"
    exit 1
fi

# Stage the built .so into the cache dir so a resumed run skips the rebuild
mkdir -p "$CACHE_DIR/${ZIG_TARGET}"
cp "$LIBOPENTUI" "$CACHED_LIB"
echo ">>> Staged libopentui.so into $CACHED_LIB for cache resume"
