package com.tapitask.tapitask

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * S3 : service RemoteViews du ListView du widget. Le provider pose
 * setRemoteAdapter() sur R.id.widget_items ; le launcher se lie ici.
 * (API 37 : RemoteAdapter/BaseRemoteCollection retirés — implémentation
 * directe de RemoteViewsService.RemoteViewsFactory.)
 */
class WidgetItemsRemoteViewsService : RemoteViewsService() {
    override fun onGetViewFactory(
        intent: Intent
    ): RemoteViewsService.RemoteViewsFactory = WidgetItemAdapter(this)
}

/**
 * S3 : lignes du widget. Les labels sont déjà préfixés « ☐  »/« ✓  » +
 * badge côté Dart ; l'adapter n'affiche que ce qui est écrit.
 * - le titre ouvre les détails ; la case coche une tâche ouverte.
 * - ligne cochée depuis le widget (widget_done_ids) : masquée en attendant
 *   que l'app applique le cochage (feedback immédiat, même qu'avant S3).
 */
class WidgetItemAdapter(
    private val context: Context
) : RemoteViewsService.RemoteViewsFactory {

    private fun prefs() = HomeWidgetPlugin.getData(context)

    private data class Row(val label: String, val checkId: String, val openId: String, val due: String)

    private fun rows(): List<Row> {
        val d = prefs()
        val total = d.getInt("list_count_lists", 0)
        if (total == 0) return emptyList()
        var index = d.getInt("list_index", 0)
        if (index >= total) index = 0
        val count = d.getInt("list_${index}_count", 0)
        val done = ListWidgetProvider.readDoneIds(d)
        val rows = ArrayList<Row>()
        for (i in 0 until count) {
            val label = d.getString("list_${index}_item_$i", "") ?: ""
            val id = d.getString("list_${index}_item_${i}_id", "") ?: ""
            val openId = d.getString("list_${index}_item_${i}_open_id", id) ?: id
            val due = d.getString("list_${index}_item_${i}_due", "") ?: ""
            if (label.isEmpty()) continue
            if (id.isNotEmpty() && id in done) continue
            rows.add(Row(label, id, openId, due))
        }
        return rows
    }

    override fun onCreate() {}

    override fun onDataSetChanged() {
        // Le système relit getCount()/getViewAt() après cet appel —
        // les données sont lues à chaud dans rows(), rien à mettre en cache.
    }

    override fun onDestroy() {}

    override fun getCount(): Int {
        val d = prefs()
        if (d.getInt("list_count_lists", 0) == 0) return 0
        val rows = rows()
        return if (rows.isEmpty()) 1 else rows.size // 1 = ligne « ✓ … »
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewAt(position: Int): RemoteViews {
        val d = prefs()
        val views = RemoteViews(context.packageName, R.layout.widget_item_row)
        val dark = d.getString("theme", "light") == "dark"
        val text =
            if (dark) Color.rgb(226, 226, 226) else Color.parseColor("#1B1B1B")
        views.setInt(R.id.item_row_label, "setTextColor", text)
        views.setInt(R.id.item_row_check, "setTextColor", text)
        // Badge d'échéance : couleur = couleur label (même action réflexion
        // setTextColor API<31), GONE par défaut (pas de due = pas de texte).
        views.setInt(R.id.item_row_due, "setTextColor", text)
        val rows = rows()
        if (rows.isEmpty()) {
            views.setViewVisibility(R.id.item_row_check, View.GONE)
            views.setTextViewText(
                R.id.item_row_label,
                "✓  " + d.getString("label_all_done", "Tout est coché"))
            views.setOnClickFillInIntent(R.id.item_row_label, null)
        } else {
            val (label, checkId, openId, due) = rows[position]
            views.setViewVisibility(R.id.item_row_check, View.VISIBLE)
            views.setTextViewText(R.id.item_row_check, if (checkId.isEmpty()) "✓" else "☐")
            views.setTextViewText(R.id.item_row_label, label.removePrefix("✓  ").removePrefix("☐  "))
            if (due.isEmpty()) {
                views.setInt(R.id.item_row_due, "setVisibility", View.GONE)
            } else {
                views.setTextViewText(R.id.item_row_due, due)
                views.setInt(R.id.item_row_due, "setVisibility", View.VISIBLE)
            }
            views.setOnClickFillInIntent(R.id.item_row_check, rowIntent(checkId))
            views.setOnClickFillInIntent(R.id.item_row_label, rowIntent(openId, open = true))
            views.setOnClickFillInIntent(R.id.item_row_due, rowIntent(openId, open = true))
        }
        return views
    }

    private fun rowIntent(id: String, open: Boolean = false): Intent? =
        if (id.isEmpty()) null else Intent().apply {
            putExtra(ListWidgetProvider.EXTRA_ITEM_ID, id)
            putExtra(ListWidgetProvider.EXTRA_OPEN_TASK, open)
        }

    override fun getItemId(position: Int): Long = position.toLong()

    override fun getViewTypeCount(): Int = 1

    override fun hasStableIds(): Boolean = false
}
