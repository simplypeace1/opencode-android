#!/usr/bin/env bash
# Cross-compile Bun for Android aarch64
#
# Usage: ./scripts/build-bun.sh
#
# This configures and builds Bun using CMake + Ninja with the Android NDK.
# Requires WebKit to be built first (scripts/build-webkit.sh).
#
# The Zig vendor patch (sigaction/sigprocmask bypass) must be applied AFTER
# Bun's build system downloads its custom Zig fork, but BEFORE the bun-zig
# target compiles. We accomplish this by running `ninja clone-zig` first to
# trigger the download, then applying the patch, then running the full build.
#
# The Zig cache is keyed by content hashes, and bun-src is a fresh clone at the
# SAME absolute path every run, so cached translate-c/Zig artifacts from a prior
# run (restored from the bun-build cache) stay valid. We only wipe the cache
# when it is missing, so repeated runs resume translate-c and the Zig
# compile at the latest possible point instead of re-translating every header.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

echo "=== Building Bun v${BUN_VERSION} for Android aarch64 ==="

# Skip if already built (cached output from a prior run)
if [ -f "$BUN_BUILD/bun" ]; then
    echo ">>> Bun already built at $BUN_BUILD/bun — skipping"
    exit 0
fi

# Verify prerequisites
if [ ! -d "$BUN_SRC" ]; then
    echo "ERROR: Bun source not found. Run scripts/apply-patches.sh first."
    exit 1
fi

if [ ! -d "$WEBKIT_OUTPUT/lib" ]; then
    echo "ERROR: WebKit not built. Run scripts/build-webkit.sh first."
    exit 1
fi

# Zig cache directory setup.
#
# Zig uses two cache locations:
#   1. --cache-dir (explicit): $BUN_BUILD/cache/zig/local (set by CMake)
#   2. .zig-cache (implicit): $BUN_SRC/.zig-cache (Zig's default CWD-local cache)
#
# On successful builds, Zig hardlinks files between them. The translate-c step
# writes c-headers-for-zig.zig to one location, and build-obj looks it up from
# the other. If they're separate directories and one is missing/stale, we get
# "file_hash FileNotFound" errors.
#
# Fix: Symlink .zig-cache -> the explicit cache dir so both paths resolve to
# the same physical location. Clear both first to avoid stale entries.
echo ">>> Setting up Zig cache directories..."
if [ -d "$BUN_BUILD/cache/zig/local" ]; then
    echo "    Resuming cached Zig artifacts from a prior run"
else
    echo "    No cached Zig artifacts — starting fresh"
    rm -rf "$BUN_BUILD/cache/zig" "$BUN_SRC/.zig-cache"
fi
mkdir -p "$BUN_BUILD/cache/zig/local"
mkdir -p "$BUN_BUILD/cache/zig/global"
ln -sfn "$BUN_BUILD/cache/zig/local" "$BUN_SRC/.zig-cache"
echo "    Symlinked $BUN_SRC/.zig-cache -> $BUN_BUILD/cache/zig/local"

# Create build directory
mkdir -p "$BUN_BUILD"

# CMake toolchain is inside the patched Bun source
case "${ANDROID_ABI}" in
  armeabi-v7a) BUN_TOOLCHAIN="$BUN_SRC/cmake/toolchains/android-armv7a.cmake" ;;
  *)           BUN_TOOLCHAIN="$BUN_SRC/cmake/toolchains/android-aarch64.cmake" ;;
esac
if [ ! -f "$BUN_TOOLCHAIN" ]; then
    echo "ERROR: Android toolchain not found at $BUN_TOOLCHAIN"
    echo "       Did apply-patches.sh run successfully?"
    exit 1
fi

# Configure
echo ">>> Configuring Bun..."
cd "$BUN_BUILD"

cmake \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$(command -v ninja)" \
    -DCMAKE_TOOLCHAIN_FILE="$BUN_TOOLCHAIN" \
    -DANDROID_NDK_HOME="$ANDROID_NDK_HOME" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_LTO=OFF \
    -DBUN_LINK_ONLY=OFF \
    -DWEBKIT_LOCAL=ON \
    -DWEBKIT_PATH="$WEBKIT_OUTPUT" \
    "$BUN_SRC"

echo ""
echo ">>> Configure complete."

# Download Zig vendor BEFORE the full build.
# The clone-zig target downloads Bun's custom Zig fork to $BUN_SRC/vendor/zig/,
# and fetches the vendored deps (mimalloc, etc.) into $BUN_SRC/vendor/.
# We need Zig downloaded first so we can patch posix.zig before compilation starts.
#
# If vendor/ was restored from cache (apply-patches.sh stashes and restores it
# around the git clone), skip the expensive download entirely — DownloadUrl.cmake
# unconditionally deletes and re-downloads, which destroys the cache benefit.
if [ -d "$BUN_SRC/vendor/zig" ]; then
    echo ">>> Vendor already cached — skipping clone-zig download"
    # Backdate all vendor SOURCE files to epoch so ninja considers cached .o
    # files (which have real timestamps) newer than vendor sources, and skips
    # recompiling unchanged vendor translation units.
    #
    # IMPORTANT: Do NOT backdate ninja output artifacts (executables, stamp
    # files, .ref markers). Ninja decides whether to re-run a build rule by
    # comparing output mtime vs input mtime. If we backdate outputs like
    # vendor/zig/zig to epoch, ninja sees output(mtime=0) < input(cmake
    # script mtime) and re-triggers the download, destroying the cache.
    # We only backdate source/header files (.c, .cpp, .h, .zig, .S, etc.).
    echo "    Backdating vendor sources to epoch for ninja incremental resume..."
    find "$BUN_SRC/vendor" -type f \( \
        -name '*.c' -o -name '*.cpp' -o -name '*.cc' -o -name '*.cxx' \
        -o -name '*.h' -o -name '*.hpp' -o -name '*.hh' \
        -o -name '*.zig' -o -name '*.S' -o -name '*.s' -o -name '*.asm' \
        -o -name '*.cmake' -o -name '*.txt' -o -name '*.md' \
        -o -name '*.json' -o -name '*.toml' -o -name '*.yaml' -o -name '*.yml' \
        -o -name '*.py' -o -name '*.sh' -o -name '*.pl' \
        -o -name '*.inc' -o -name '*.def' -o -name '*.in' \
    \) -exec touch -h -d '@0' {} + 2>/dev/null || true
else
    echo ">>> Downloading Zig vendor (clone-zig target)..."
    cd "$BUN_BUILD"
    ninja clone-zig || true  # May not exist as a standalone target in all versions
fi

# 32-bit: mimalloc's segment-map computes MI_SEGMENT_MAP_PART_SPAN in
# 32-bit size_t arithmetic, where 31744 * 16MiB wraps to exactly zero —
# a division by zero and a variable-length array at file scope. The deps
# are fetched into $BUN_SRC/vendor by `ninja clone-zig`, so patch the
# vendored copy AFTER the fetch, before ninja compiles it.
MIMALLOC_SEGMAP="$BUN_SRC/vendor/mimalloc/src/segment-map.c"
if [ "${ANDROID_ABI}" = "armeabi-v7a" ] && [ -f "$MIMALLOC_SEGMAP" ]; then
    echo ">>> Applying mimalloc 32-bit segment-map patch..."
    cd "$BUN_SRC/vendor/mimalloc"
    if patch --dry-run -p1 < "$REPO_ROOT/patches/bun/android-arm32-mimalloc-segmap.patch" >/dev/null 2>&1; then
        patch -p1 < "$REPO_ROOT/patches/bun/android-arm32-mimalloc-segmap.patch"
        echo "    mimalloc segment-map patch applied successfully."
    else
        # Check if already applied by looking for the 32-bit fallback
        if grep -q "MI_SEGMENT_MAP_MAX_PARTS      (1)" "$MIMALLOC_SEGMAP" 2>/dev/null; then
            echo "    mimalloc segment-map patch already applied."
        else
            echo "WARNING: mimalloc patch doesn't match cleanly. Trying with --fuzz..."
            patch -p1 --fuzz=3 < "$REPO_ROOT/patches/bun/android-arm32-mimalloc-segmap.patch" || {
                echo "ERROR: Could not apply mimalloc segment-map patch. Manual intervention required."
                exit 1
            }
        fi
    fi
else
    echo "WARNING: mimalloc vendor not found at $MIMALLOC_SEGMAP (may be fetched later)."
fi

# Apply Zig vendor patch AFTER download, BEFORE build
ZIG_POSIX="$BUN_SRC/vendor/zig/lib/std/posix.zig"
if [ -f "$ZIG_POSIX" ]; then
    echo ">>> Applying Zig vendor patch (sigaction/sigprocmask Android bypass)..."
    cd "$BUN_SRC"
    if patch --dry-run -p1 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch" >/dev/null 2>&1; then
        patch -p1 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch"
        echo "    Zig patch applied successfully."
    else
        # Check if already applied by looking for the Android bypass code
        if grep -q "comptime builtin.abi.isAndroid()" "$ZIG_POSIX" 2>/dev/null; then
            echo "    Zig patch already applied."
        else
            echo "WARNING: Zig patch doesn't match cleanly. Trying with --fuzz..."
            patch -p1 --fuzz=3 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch" || {
                echo "ERROR: Could not apply Zig patch. Manual intervention required."
                exit 1
            }
        fi
    fi
else
    echo "WARNING: Zig vendor not yet downloaded ($ZIG_POSIX not found)."
    echo "         Zig may be downloaded during the build. If the build fails,"
    echo "         re-run this script to apply the patch and retry."
fi

# Build
echo ">>> Building Bun (this will take 30-45 minutes)..."
echo "    .zig-cache -> $(readlink -f "$BUN_SRC/.zig-cache" 2>/dev/null || echo 'NOT A SYMLINK')"
cd "$BUN_BUILD"
ninja -j"$JOBS" 2>&1 || {
    echo ""
    echo ">>> Build failed. Checking if Zig was downloaded during the build..."
    # If Zig was just downloaded during the build and the patch wasn't applied,
    # apply it now and retry
    if [ -f "$ZIG_POSIX" ] && ! grep -q "comptime builtin.abi.isAndroid()" "$ZIG_POSIX" 2>/dev/null; then
        echo ">>> Zig downloaded during build but patch not applied. Applying now..."
        cd "$BUN_SRC"
        patch -p1 < "$REPO_ROOT/patches/zig/posix-android-sigaction.patch" || {
            echo "ERROR: Zig patch failed to apply"
            exit 1
        }
        echo "    Zig patch applied. Clearing Zig cache and rebuilding..."
        rm -rf "$BUN_BUILD/cache/zig" "$BUN_SRC/.zig-cache"
        mkdir -p "$BUN_BUILD/cache/zig/local" "$BUN_BUILD/cache/zig/global"
        ln -sfn "$BUN_BUILD/cache/zig/local" "$BUN_SRC/.zig-cache"
        cd "$BUN_BUILD"
        ninja -j"$JOBS"
    elif [ "${ANDROID_ABI}" = "armeabi-v7a" ] && [ -f "$MIMALLOC_SEGMAP" ] && ! grep -q "MI_SEGMENT_MAP_MAX_PARTS      (1)" "$MIMALLOC_SEGMAP" 2>/dev/null; then
        echo ">>> mimalloc segment-map patch not applied. Applying now and rebuilding..."
        cd "$BUN_SRC/vendor/mimalloc"
        patch -p1 --fuzz=3 < "$REPO_ROOT/patches/bun/android-arm32-mimalloc-segmap.patch" || {
            echo "ERROR: mimalloc patch failed to apply"
            exit 1
        }
        cd "$BUN_BUILD"
        ninja -j"$JOBS"
    else
        echo "ERROR: Build failed (Zig patch was already applied — different error)"
        exit 1
    fi
}

# Verify output
BUN_BINARY="$BUN_BUILD/bun"
if [ ! -f "$BUN_BINARY" ]; then
    # Try bun-profile (unstripped)
    BUN_BINARY="$BUN_BUILD/bun-profile"
fi

if [ ! -f "$BUN_BINARY" ]; then
    echo "ERROR: Bun binary not found after build"
    exit 1
fi

echo ""
echo "=== Bun build complete ==="
echo "Binary: $BUN_BINARY"
echo "Size: $(du -h "$BUN_BINARY" | cut -f1)"
file "$BUN_BINARY"
