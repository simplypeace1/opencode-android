package com.mrdlx1f.opencode

import androidx.appcompat.app.AppCompatActivity
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.io.File

class MainActivity : AppCompatActivity() {

    private lateinit var output: RecyclerView
    private lateinit var input: EditText
    private lateinit var send: Button
    private lateinit var status: TextView
    private lateinit var adapter: LineAdapter

    private var runJob: Job? = null
    private var runner: OpenCodeRunner? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        output = findViewById(R.id.output)
        input = findViewById(R.id.input)
        send = findViewById(R.id.send)
        status = findViewById(R.id.statusBar)

        adapter = LineAdapter(mutableListOf())
        output.layoutManager = LinearLayoutManager(this)
        output.adapter = adapter

        lifecycleScope.launch {
            val bin = try { NativeBinary.install(this@MainActivity) } catch (e: Exception) {
                appendLine("FAILED: ${e.message}", true)
                return@launch
            }
            runner = OpenCodeRunner(bin, File(filesDir, "work").apply { mkdirs() })
            status.text = "OpenCode ready (${NativeBinary.abi()})"
        }

        send.setOnClickListener { submit() }
        input.setOnEditorActionListener { _, _, _ -> submit(); true }
    }

    private fun submit(): Boolean {
        val msg = input.text.toString().trim()
        if (msg.isEmpty()) return false
        val r = runner ?: run {
            appendLine("OpenCode not ready", true); return false
        }
        input.setText("")
        runJob?.cancel()
        appendLine("> $msg", false)
        appendLine("", false)
        runJob = lifecycleScope.launch {
            r.prompt(msg).collect { ev ->
                if (ev.text.startsWith("__exit__")) {
                    status.text = "Done (exit ${ev.text.removePrefix("__exit__")})"
                } else {
                    appendLine(ev.text, ev.stderr)
                }
            }
        }
        return true
    }

    private fun appendLine(text: String, isErr: Boolean) {
        adapter.add(Line(text, isErr))
        output.scrollToPosition(adapter.itemCount - 1)
    }

    override fun onDestroy() {
        runJob?.cancel()
        super.onDestroy()
    }
}

data class Line(val text: String, val isError: Boolean)