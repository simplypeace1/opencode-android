package com.mrdlx1f.opencode

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

class LineAdapter(private val items: MutableList<Line>) :
    RecyclerView.Adapter<LineAdapter.VH>() {

    class VH(view: View) : RecyclerView.ViewHolder(view) {
        val text: TextView = view.findViewById(R.id.lineText)
    }

    fun add(line: Line) {
        items.add(line)
        notifyItemInserted(items.size - 1)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_line, parent, false)
        return VH(v)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        val it = items[position]
        holder.text.text = it.text
        holder.text.setTextColor(
            holder.text.context.getColor(
                if (it.isError) android.R.color.holo_red_light
                else android.R.color.white
            )
        )
    }

    override fun getItemCount() = items.size
}