package com.mrdlx1f.opencode

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.io.File
import java.io.InputStream
import java.util.concurrent.TimeUnit

/**
 * Runs the opencode binary. MVP uses `opencode run` (non-interactive) per
 * turn, streaming stdout/stderr lines as they arrive. A later milestone swaps
 * this for a persistent `opencode serve`/JSON-RPC session for realtime chat.
 */
class OpenCodeRunner(private val binary: File, private val workDir: File) {

    class LineEvent(val text: String, val stderr: Boolean)

    fun prompt(message: String, apiKey: String? = null): Flow<LineEvent> = flow {
        val cmd = mutableListOf(binary.absolutePath, "run", message)
        val pb = ProcessBuilder(cmd)
            .directory(workDir)
            .redirectErrorStream(false)

        val env = pb.environment()
        // Model traffic stays local-first; keys set here are resolved by opencode.
        apiKey?.let { env["OPENCODE_API_KEY"] = it }

        val proc = try { pb.start() } catch (e: Exception) {
            emit(LineEvent("Failed to start opencode: ${e.message}", true)); return@flow
        }

        stream(proc.inputStream, false) { emit(it) }
        stream(proc.errorStream, true) { emit(it) }

        val exited = proc.waitFor(60, TimeUnit.MINUTES)
        if (!exited) proc.destroyForcibly()
        emit(LineEvent("__exit__${proc.exitValue()}", false))
    }.flowOn(Dispatchers.IO)

    private inline fun stream(input: InputStream, isErr: Boolean, emit: (LineEvent) -> Unit) {
        val reader = input.bufferedReader()
        try {
            reader.useLines { lines ->
                for (line in lines) emit(LineEvent(line, isErr))
            }
        } catch (_: Exception) {
            // stream closed at process exit
        }
    }
}