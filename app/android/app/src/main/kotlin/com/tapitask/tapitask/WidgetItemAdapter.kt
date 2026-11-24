package com.tapitask.tapitask

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
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
 * - ligne cochée (id vide côté Dart) : non cliquable — toggle unidirectionnel.
 * - ligne cochée depuis le widget (widget_done_ids) : masquée en attendant
 *   que l'app applique le cochage (feedback immédiat, même qu'avant S3).
 */
class WidgetItemAdapter(
    private val context: Context
) : RemoteViewsService.RemoteViewsFactory {

    private fun prefs(): SharedPreferences = HomeWidgetPlugin.getData(context)

    // C2.6 : snapshot pris dans onDataSetChanged() — le système relit
    // getCount()/getViewAt() après, et re-lire prefs à chaque appel pouvait
    // mélanger deux états (n de lignes ≠ lignes servies).
    private var snapshotRows: List<Triple<String, String, String>> = emptyList()
    private var snapshotHasLists = false
    private var snapshotDark = false
    private var snapshotAllDone = ""

    /** Ligne = (label, id cliquable, badge d'échéance brut — "" si absent). */
    private fun buildRows(d: SharedPreferences): List<Triple<String, String, String>> {
        val total = d.getInt("list_count_lists", 0)
        if (total == 0) return emptyList()
        var index = d.getInt("list_index", 0)
        if (index >= total) index = 0
        val count = d.getInt("list_${index}_count", 0)
        val done = ListWidgetProvider.readDoneIds(d)
        val rows = ArrayList<Triple<String, String, String>>()
        for (i in 0 until count) {
            val label = d.getString("list_${index}_item_$i", "") ?: ""
            val id = d.getString("list_${index}_item_${i}_id", "") ?: ""
            val due = d.getString("list_${index}_item_${i}_due", "") ?: ""
            if (label.isEmpty()) continue
            if (id.isNotEmpty() && id in done) continue
            rows.add(Triple(label, id, due))
        }
        return rows
    }

    override fun onCreate() {}

    override fun onDataSetChanged() {
        // C2.6 : snapshot unique (lignes + thème + label « tout coché ») —
        // le système relit getCount()/getViewAt() après ; re-lire prefs
        // séparément aurait pu mélanger deux états.
        val d = prefs()
        snapshotHasLists = d.getInt("list_count_lists", 0) > 0
        snapshotRows = buildRows(d)
        snapshotDark = d.getString("theme", "light") == "dark"
        snapshotAllDone = d.getString("label_all_done", "Tout est coché") ?: "Tout est coché"
    }

    override fun onDestroy() {}

    override fun getCount(): Int {
        if (!snapshotHasLists) return 0
        return if (snapshotRows.isEmpty()) 1 else snapshotRows.size // 1 = ligne « ✓ … »
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewAt(position: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_item_row)
        val text =
            if (snapshotDark) Color.rgb(226, 226, 226) else Color.parseColor("#1B1B1B")
        views.setInt(R.id.item_row_label, "setTextColor", text)
        // Badge d'échéance : couleur = couleur label (même action réflexion
        // setTextColor API<31), GONE par défaut (pas de due = pas de texte).
        views.setInt(R.id.item_row_due, "setTextColor", text)
        if (snapshotRows.isEmpty()) {
            // Une seule ligne (getCount() = 1) : le « ✓ … » ne dépend pas du
            // position — pas besoin de guard.
            views.setTextViewText(
                R.id.item_row_label,
                "✓  " + snapshotAllDone)
            views.setOnClickFillInIntent(R.id.item_row_label, null)
            // 2.1 (prod3) : une ligne recyclée peut montrer l'ancien badge
            // d'échéance — toujours masqué dans l'état « tout coché ».
            views.setInt(R.id.item_row_due, "setVisibility", View.GONE)
        } else if (position in snapshotRows.indices) {
            // C2.6 : guard — position hors snapshot (changement pendant le
            // bind du launcher) → ligne vide plutôt qu'IndexOutOfBounds.
            val (label, id, due) = snapshotRows[position]
            views.setTextViewText(R.id.item_row_label, label)
            if (due.isEmpty()) {
                views.setInt(R.id.item_row_due, "setVisibility", View.GONE)
            } else {
                views.setTextViewText(R.id.item_row_due, due)
                views.setInt(R.id.item_row_due, "setVisibility", View.VISIBLE)
            }
            // Ligne cochée : Dart n'a pas écrit d'id → non cliquable
            // (le widget reste unidirectionnel « cocher »).
            if (id.isNotEmpty()) {
                views.setOnClickFillInIntent(
                    R.id.item_row_label,
                    Intent(context, ListWidgetProvider::class.java).apply {
                        action = ListWidgetProvider.ACTION_TOGGLE
                        putExtra(ListWidgetProvider.EXTRA_ITEM_ID, id)
                    })
            } else {
                // 2.1 (prod3) / MD-4 : une ligne recyclée hérite du clic de
                // l'item précédent si on ne pose rien — un Intent() vide
                // (sans action) réinitialise le fill-in.
                views.setOnClickFillInIntent(R.id.item_row_label, Intent())
            }
        }
        return views
    }

    override fun getItemId(position: Int): Long = position.toLong()

    override fun getViewTypeCount(): Int = 1

    override fun hasStableIds(): Boolean = false
}
