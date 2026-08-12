package com.mrdlx1f.opencode

import android.content.Context
import java.io.File
import java.util.concurrent.atomic.AtomicLong

/**
 * Locates and prepares the opencode native binary embedded in the APK.
 *
 * The cross-compiled `opencode` standalone binary (Bun runtime + opencode
 * bundle, JSC + ICU + libopentui + TinyCC statically woven in) is shipped via
 * ABI-specific jniLibs dirs. jniLibs .so files get installed to the native
 * lib dir with their leading `lib` stripped/`_and.so`-haps applied by the
 * packager, so we copy the raw .so out to an app-private exec dir and chmod +x.
 */
object NativeBinary {

    private val counter = AtomicLong(0)

    /** The runner lib name, expected as `libopencode.so` in jniLibs. */
    const val RUNNER_SO = "libopencode.so"

    /** Installs the embedded opencode binary to an app-private dir and returns its path. */
    fun install(context: Context): File {
        val nativeLib = findNativeLib(context) ?: error(
            "No opencode native binary found in lib dir for this ABI."
        )
        val execDir = File(context.getDir("opencode-bin", Context.MODE_PRIVATE))
        execDir.mkdirs()

        val target = File(execDir, "opencode")
        val stamp = File(execDir, "opencode.build.timestamp")
        // Only re-copy if the stamp bytes don't match the source size (cheap idempotence)
        if (!target.exists() ||
            !stamp.exists() ||
            stamp.readText().toLongOrNull() != nativeLib.length()
        ) {
            nativeLib.copyTo(target, overwrite = true)
            target.setExecutable(true, false)
            stamp.writeText(nativeLib.length().toString())
        }
        return target
    }

    /** Current executing ABI (arm64-v8a or armeabi-v7a). */
    fun abi(): String = android.os.Build.SUPPORTED_ABIS.firstOrDefault("")

    private fun findNativeLib(context: Context): File? {
        // jniLibs land under <codeDir>/lib/<abi>/
        val codeDir = File(context.applicationInfo.nativeLibraryDir)
        if (codeDir.exists()) {
            codeDir.listFiles()?.forEach { f ->
                if (f.isFile && (f.name == RUNNER_SO || f.name == "opencode")) return f
            }
        }
        // Some configs land directly under codeDir parent
        val parent = codeDir.parentFile
        parent?.listFiles()?.forEach { f ->
            if (f.isFile && (f.name == RUNNER_SO || f.name == "opencode")) return f
        }
        return null
    }
}