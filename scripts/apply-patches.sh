#!/usr/bin/env bash
# Clone upstream repos and apply Android patches
#
# Usage: ./scripts/apply-patches.sh
#
# This script:
# 1. Clones oven-sh/bun at the pinned tag
# 2. Clones oven-sh/WebKit at the pinned commit
# 3. Applies patches from patches/
# 4. The Zig vendor patch is applied later by build-bun.sh after Bun's
#    build system downloads Zig

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

echo "=== Applying Patches ==="

# --- Clone Bun ---
if [ ! -d "$BUN_SRC/.git" ]; then
    echo ">>> Cloning Bun v${BUN_VERSION}..."
    git clone --depth 1 --branch "${BUN_TAG}" https://github.com/oven-sh/bun.git "$BUN_SRC"
else
    echo ">>> Bun source already exists at $BUN_SRC"
fi

# Apply Bun patch
echo ">>> Applying Bun Android patches..."
cd "$BUN_SRC"
git checkout -- . 2>/dev/null || true  # Reset any previous patches
git apply --stat "$REPO_ROOT/patches/bun/android-support.patch"
git apply "$REPO_ROOT/patches/bun/android-support.patch"
# Apply armeabi-v7a toolchain patch (adds cmake/toolchains/android-armv7a.cmake)
if [ "${ANDROID_ABI}" = "armeabi-v7a" ]; then
    echo ">>> Applying Bun armeabi-v7a toolchain patch..."
    git apply "$REPO_ROOT/patches/bun/android-armv7a-toolchain.patch"
    # 32-bit JSC (USE(JSVALUE32_64)) has no JSValue::ValueDeleted member
    echo ">>> Applying Bun JSVALUE32_64 sentinel patch..."
    git apply "$REPO_ROOT/patches/bun/android-jsvalue32-64.patch"
    # Highway falls back to the single EMU128 target on 32-bit ARM; the
    # HWY_DYNAMIC_DISPATCH macro expands to a wrongly-nested namespace
    echo ">>> Applying Bun Highway EMU128 dispatch patch..."
    git apply "$REPO_ROOT/patches/bun/android-highway-emu128.patch"
    # JSC on 32-bit ARM is interpreter-only (ENABLE(JIT)=0); guard the two
    # unguarded JIT references in the bindings
    echo ">>> Applying Bun JIT-disabled guard patch..."
    git apply "$REPO_ROOT/patches/bun/android-jit-disabled.patch"
    # JSVALUE32_64 JIT operations return ExceptionOperationResultTag, not the
    # JSVALUE64 aggregate-init struct; and ASCIILiteral::operator[] is
    # ambiguous with the built-in const char* subscript on 32-bit
    echo ">>> Applying Bun JSBuffer JSVALUE32_64 patch..."
    git apply "$REPO_ROOT/patches/bun/android-jsbuffer32.patch"
    # std::bit_cast<double>/<uintptr_t> requires equal sizes (8 != 4 on 32-bit);
    # a 32-bit pointer fits exactly in a double's mantissa so a plain numeric
    # conversion round-trips losslessly
    echo ">>> Applying Bun pointer-in-double JSVALUE32_64 patch..."
    git apply "$REPO_ROOT/patches/bun/android-ptr-double.patch"
    # JSBigInt::Digit is uint32_t on 32-bit (JSVALUE32_64), not uint64_t, so
    # NAPI bigint functions must convert between 32-bit digits and 64-bit words
    echo ">>> Applying Bun NAPI bigint 32-bit word-conversion patch..."
    git apply "$REPO_ROOT/patches/bun/android-napi-bigint32.patch"
    # On 32-bit size_t==uint32_t and ssize_t==int32_t, so the explicit
    # template instantiations collide; keep size_t/ssize_t for 64-bit only
    echo ">>> Applying Bun NodeValidator validateInteger 32-bit patch..."
    git apply "$REPO_ROOT/patches/bun/android-nodevalidator-32.patch"
    # The V8 compatibility shim emulates V8's 64-bit tagged-pointer ABI
    # (Smi in the upper 32 bits, fixed Map/HandleScope sizes matching
    # real_v8::internal::Internals); it only compiles under USE(JSVALUE64).
    # Exclude it and its Zig-side extern references on 32-bit Android.
    echo ">>> Applying Bun V8 shim exclusion for 32-bit patch..."
    git apply "$REPO_ROOT/patches/bun/android-v8-shim-32.patch"
    # EncodedJSValue is a scalar (not an aggregate) on JSVALUE32_64, so the
    # brace-init in the JIT operation is a -Wbraced-scalar-init error; and
    # DFG::AbstractHeapKind / DOMJIT::Effect::forWriteKinds only exist under
    # ENABLE(DFG_JIT), which is off on 32-bit. Drop the braces and pass
    # nullptr as the DOMJIT signature when DFG is disabled.
    echo ">>> Applying Bun JSPerformance JSVALUE32_64 patch..."
    git apply "$REPO_ROOT/patches/bun/android-jperformance32.patch"
    # TextEncoder__encodeInto8/16 return a u64 packing {read, written} as
    # [2]u32 (see src/bun.js/webcore/TextEncoder.zig). The C++ extern declared
    # them as size_t, which on 32-bit ARM is a 4-byte ABI mismatch (u64 returns
    # in r0:r1) and made `res >> 32` a -Wshift-count-overflow. Declare the true
    # u64 return and store into uint64_t so both words survive on 32-bit.
    echo ">>> Applying Bun JSTextEncoder encodeInto u64 return patch..."
    git apply "$REPO_ROOT/patches/bun/android-jstextencoder32.patch"
    # SerializedScriptValue.cpp: two latent 32-bit-only code paths. (1) The
    # #if !ASSUME_LITTLE_ENDIAN branch of readIdentifier() assigned a String
    # to an Identifier& (no such operator=); ASSUME_LITTLE_ENDIAN is 0 on
    # armv7 because CPU(NEEDS_ALIGNED_ACCESS) is set, so this branch only
    # compiles on 32-bit. Build a String first, then intern it via
    # Identifier::fromString(vm, string). (2) ArrayBuffer::tryCreate span
    # brace-init narrowed uint64_t length to size_t (32-bit) — explicit cast.
    echo ">>> Applying Bun SerializedScriptValue 32-bit patch..."
    git apply "$REPO_ROOT/patches/bun/android-ssv32.patch"
    # android-support.patch's build.zig sysroot plumbing hardcodes the
    # aarch64-linux-android header dir, which doesn't exist on armv7 (bionic
    # keeps ifaddrs.h in the per-arch dir arm-linux-androideabi), so translate-c
    # failed with "ifaddrs.h not found". Derive the arch dir from the target
    # triple (aarch64-linux-android on arm64, arm-linux-androideabi on armv7)
    # and match BOTH Android ABIs: 32-bit ARM renders .androideabi, 64-bit .android.
    echo ">>> Applying Bun Zig NDK sysroot triple-based include patch..."
    git apply "$REPO_ROOT/patches/bun/android-zig-ndk-sysroot.patch"
    # 32-bit ZigString ABI: on armv7 pointers have no spare bits for the UTF-16/
    # UTF-8/global/static tags, so the tags move into a flags byte on both the
    # Zig extern struct and the C++ ZigString; plus armv7 ZigString/tagged-pointer/
    # PathString/EnvStr layouts and the Android ABI fix (.androideabi)
    echo ">>> Applying Bun 32-bit ZigString/tagged-pointer/EnvStr foundations patch..."
    git apply "$REPO_ROOT/patches/bun/android-arm32-zig-foundations.patch"
    # 32-bit integer width fixes: u64/usize/u53/u52 cast and bitCast sites,
    # 32-bit allocator tags, crash-handler u64 VLQ writer, SemverString error removal
    echo ">>> Applying Bun 32-bit integer-cast fixes patch..."
    git apply "$REPO_ROOT/patches/bun/android-arm32-zig-casts.patch"
    # 32-bit architecture fixes: CPUFeatures .arm case + AVX guard, and the
    # bun.String/Symbol size assertions (bun.String is 32 bytes on 64-bit with
    # the unconditional ZigString flags field, 16 bytes on 32-bit)
    echo ">>> Applying Bun 32-bit arch/assert fixes patch..."
    git apply "$REPO_ROOT/patches/bun/android-arm32-zig-arch.patch"
fi

# Enable incremental ninja resume across runs. bun-src is freshly cloned every
# run, so all source mtimes are newer than the cached .o files restored from the
# bun-build cache, which makes ninja rebuild every translation unit from zero.
# Backdate all tracked sources to the epoch, then re-touch only the files we
# patched (which genuinely changed and must recompile), so ninja skips the
# ~440 unchanged TUs and resumes from the previous failure point.
echo ">>> Backdating bun sources to enable incremental ninja resume..."
git ls-files -z | xargs -0 -n 200 touch -h -d '@0' 2>/dev/null || true
git diff --name-only -z HEAD 2>/dev/null | xargs -0 -n 200 touch -h 2>/dev/null || true
echo "    Sources backdated; patched files re-touched."
echo "    Bun patches applied successfully"

# --- Clone WebKit ---
if [ ! -d "$WEBKIT_SRC/.git" ]; then
    echo ">>> Cloning WebKit at commit ${WEBKIT_COMMIT}..."
    mkdir -p "$WEBKIT_SRC"
    cd "$WEBKIT_SRC"
    git init
    git remote add origin https://github.com/oven-sh/WebKit.git
    git fetch --depth=1 origin "${WEBKIT_COMMIT}"
    git checkout FETCH_HEAD
else
    echo ">>> WebKit source already exists at $WEBKIT_SRC"
fi

# Apply WebKit patches
echo ">>> Applying WebKit Android patches..."
cd "$WEBKIT_SRC"
git checkout -- . 2>/dev/null || true  # Reset any previous patches
git apply "$REPO_ROOT/patches/webkit/android-support.patch"
git apply "$REPO_ROOT/patches/webkit/domjit-32bit.patch"
echo "    WebKit patches applied successfully"

echo ""
echo "=== Patches Applied ==="
echo "Bun source:    $BUN_SRC"
echo "WebKit source: $WEBKIT_SRC"
echo ""
echo "NOTE: The Zig vendor patch (patches/zig/posix-android-sigaction.patch)"
echo "      will be applied by build-bun.sh after Zig is downloaded by the"
echo "      Bun build system."
