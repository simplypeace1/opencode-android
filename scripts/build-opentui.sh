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

# Apply opentui Android patches. Note: `zig build --libc` only affects the
# linking phase (b.libc_file); the translate-c pass ignores it, so we also add
# the NDK sysroot include dir to the translate-c steps via a separate patch.
apply_opentui_patch() {
    local patch_path="$1"
    if [ -f "$patch_path" ]; then
        echo ">>> Applying opentui Android patch: $(basename "$patch_path")"
        cd "$OPENTUI_SRC"
        if ! git apply --check "$patch_path" 2>/dev/null; then
            echo "    Patch already applied or does not apply cleanly, skipping"
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

OPENTUI_ZIG_DIR="$OPENTUI_SRC/packages/core/src/zig"

if [ ! -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_ZIG_DIR"
    exit 1
fi

# Skip if already built (cached output from a prior run)
LIBOPENTUI_CACHED="$OPENTUI_ZIG_DIR/../lib/${ANDROID_TRIPLE}/libopentui.so"
if [ -f "$LIBOPENTUI_CACHED" ]; then
    echo ">>> libopentui.so already built at $LIBOPENTUI_CACHED — skipping"
    exit 0
fi

echo ">>> Building with Zig (target: ${ANDROID_TRIPLE})..."
cd "$OPENTUI_ZIG_DIR"

# `zig build --libc` tells the linker where bionic crt/libc live (via
# b.libc_file). Translate-c ignores it — handled by the patch above.
NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"
NDK_SYSROOT="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
# NDK sysroot lib dirs use arm-linux-androideabi (not the armv7a- clang prefix)
LIBC_TRIPLE="${ANDROID_TRIPLE/armv7a-/arm-}"
LIBC_FILE="$BUN_BUILD/zig-android-libc.txt"
mkdir -p "$(dirname "$LIBC_FILE")"
cat > "$LIBC_FILE" <<EOF
include_dir=$NDK_SYSROOT/usr/include
sys_include_dir=$NDK_SYSROOT/usr/include
crt_dir=$NDK_SYSROOT/usr/lib/${LIBC_TRIPLE}/${ANDROID_API}
static_crt_dir=$NDK_SYSROOT/usr/lib/${LIBC_TRIPLE}/${ANDROID_API}
EOF
echo ">>> NDK libc file: $LIBC_FILE"
cat "$LIBC_FILE"

"$ZIG_BIN" build \
    --libc "$LIBC_FILE" \
    -Dtarget=${ANDROID_TRIPLE} \
    -Doptimize=ReleaseSafe \
    --prefix . 2>&1

# The build.zig installs to dest_dir="../lib/{output_name}" relative to
# the --prefix dir.  With --prefix=. (= OPENTUI_ZIG_DIR), the .so ends
# up one directory above: packages/core/src/lib/aarch64-linux-android/
LIBOPENTUI="$OPENTUI_ZIG_DIR/../lib/${ANDROID_TRIPLE}/libopentui.so"
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
