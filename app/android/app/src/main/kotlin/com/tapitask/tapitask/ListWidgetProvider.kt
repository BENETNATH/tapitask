package com.tapitask.tapitask

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.util.Log
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * Tapitask list widget (resizable).
 * - Title = pinned list name; ◀ / ▶ switch to the previous / next pinned list.
 * - All items (S3 : ListView RemoteAdapter, scroll vertical, pas de plafond) ;
 *   tapping an unchecked item checks it locally (instant), the app syncs the
 *   change on next open (widget_toggled).
 * - The list color tints the widget background.
 * - "Ouvrir l'application" launches the app.
 */
class ListWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        try {
            onUpdateSafe(context, appWidgetManager, appWidgetIds)
        } catch (t: Throwable) {
            // Visible with: adb logcat -s TapitaskWidget
            Log.e("TapitaskWidget", "onUpdate failed", t)
            // Belt and braces: a broken render must never leave the launcher
            // showing "Problème lors du chargement du widget".
            for (appWidgetId in appWidgetIds) {
                try {
                    appWidgetManager.updateAppWidget(appWidgetId,
                        RemoteViews(context.packageName, R.layout.list_widget))
                } catch (_: Throwable) {
                }
            }
        }
    }

    private fun onUpdateSafe(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val data = HomeWidgetPlugin.getData(context)
        val total = data.getInt("list_count_lists", 0)
        Log.d("TapitaskWidget", "onUpdate: $total liste(s) en mémoire partagée")
        if (total == 0) {
            for (appWidgetId in appWidgetIds) {
                val views = RemoteViews(context.packageName, R.layout.list_widget)
                views.setTextViewText(R.id.widget_title,
                    data.getString("label_no_list", "Épinglez une liste"))
                views.setImageViewResource(R.id.widget_open,
                    R.drawable.ic_widget_open)
                bindOpen(context, views, null)
                views.setViewVisibility(R.id.widget_prev, android.view.View.GONE)
                views.setViewVisibility(R.id.widget_next, android.view.View.GONE)
                // 2.1 (prod3) : masquer les items ET signaler le changement —
                // sans notifyAppWidgetViewDataChanged, les anciens items
                // restent affichés (adapter non rappelé).
                views.setViewVisibility(R.id.widget_items, android.view.View.GONE)
                appWidgetManager.notifyAppWidgetViewDataChanged(
                    appWidgetId, R.id.widget_items)
                appWidgetManager.updateAppWidget(appWidgetId, views)
            }
            return
        }
        var index = data.getInt("list_index", 0)
        if (index >= total) index = 0
        for (appWidgetId in appWidgetIds) {
            render(context, appWidgetManager, appWidgetId, index, total)
        }
    }

    companion object {
        // Codes distincts par bouton : évite les collisions
        // FLAG_UPDATE_CURRENT entre les PendingIntents de lancement.
        const val OPEN_REQUEST_CODE = 1
        const val ADD_REQUEST_CODE = 2
        private val ITEM_ID_REGEX =
            Regex("^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$", RegexOption.IGNORE_CASE)

        const val ACTION_CYCLE = "com.tapitask.tapitask.action.CYCLE_LIST"
        const val ACTION_TOGGLE = "com.tapitask.tapitask.action.TOGGLE_ITEM"
        const val EXTRA_ITEM_ID = "item_id"
        const val EXTRA_LIST_INDEX = "list_index"
        const val EXTRA_DIRECTION = "direction"

        /// widget_done_ids: stored as a comma-joined String (home_widget 0.10
        /// dropped List<String> support); older installs may still hold a
        /// StringSet — read both without ever throwing.
        fun readDoneIds(prefs: android.content.SharedPreferences): Set<String> {
            val all = prefs.all["widget_done_ids"]
            return when (all) {
                is String -> if (all.isEmpty()) emptySet() else all.split(",").toSet()
                is Set<*> -> all.filterIsInstance<String>().toSet()
                else -> emptySet()
            }
        }

        /// Fond du widget : couleur de liste éclaircie (light) / assombrie (dark),
        /// sinon fond par thème. `""` (le Dart écrit `list.color ?? ""`) = liste
        /// sans couleur ; un hex illisible retombe sur le fond par thème — le fond
        /// est toujours posé, jamais le default du drawable.
        fun widgetBackground(dark: Boolean, colorHex: String?): Int {
            val themeBg = if (dark) Color.rgb(27, 27, 27) else Color.rgb(247, 250, 250)
            if (colorHex == null || colorHex.isEmpty()) return themeBg
            return try {
                val c = Color.parseColor(colorHex)
                if (dark) {
                    Color.rgb(Color.red(c) / 2, Color.green(c) / 2, Color.blue(c) / 2)
                } else {
                    Color.rgb((Color.red(c) + 255 * 3) / 4,
                              (Color.green(c) + 255 * 3) / 4,
                              (Color.blue(c) + 255 * 3) / 4)
                }
            } catch (_: Exception) {
                themeBg
            }
        }

        fun triggerUpdate(context: Context) {
            val ids = AppWidgetManager.getInstance(context)
                .getAppWidgetIds(ComponentName(context, ListWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                val intent = Intent(context, ListWidgetProvider::class.java)
                intent.action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                intent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                context.sendBroadcast(intent)
            }
        }

        /// Le PendingIntent du « + » embarque l'id de liste au moment du
        /// onUpdate du QuickAddWidgetProvider : un cycle ◀/▶ rendrait
        /// l'URI obsolète → on re-déclenche son update aussi.
        fun triggerQuickAddUpdate(context: Context) {
            val ids = AppWidgetManager.getInstance(context)
                .getAppWidgetIds(ComponentName(context, QuickAddWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                val intent = Intent(context, QuickAddWidgetProvider::class.java)
                intent.action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                intent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                context.sendBroadcast(intent)
            }
        }
    }

    private fun bindOpen(context: Context, views: RemoteViews, listId: String?) {
        // Action privée (au lieu de l'action publique du plugin home_widget) :
        // MainActivity ne lit que celle-ci ; le reste est validé côté Dart.
        views.setOnClickPendingIntent(
            R.id.widget_open,
            launchIntent(context, OPEN_REQUEST_CODE, "tapitask://home"))
        views.setOnClickPendingIntent(
            R.id.widget_add,
            launchIntent(context, ADD_REQUEST_CODE,
                "tapitask://quickadd?list=" + (listId ?: "")))
    }

    private fun launchIntent(context: Context, code: Int, uri: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = TapitaskActions.ACTION_LAUNCH
            data = Uri.parse(uri)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            context, code, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun render(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        index: Int,
        total: Int
    ) {
        val data = HomeWidgetPlugin.getData(context)
        val views = RemoteViews(context.packageName, R.layout.list_widget)
        val title = data.getString("list_${index}_title", "Tapitask") ?: "Tapitask"
        views.setTextViewText(
            R.id.widget_title,
            if (total > 1) "$title (${index + 1}/$total)" else title)
        // Localized action labels (written by the Dart side per user language)
        views.setTextViewText(R.id.widget_add,
            data.getString("label_add", "＋ Ajouter"))
        views.setImageViewResource(R.id.widget_open, R.drawable.ic_widget_open)

        // Theme (synced user setting, resolved against the OS by the app).
        val dark = data.getString("theme", "light") == "dark"
        // List color tints the background: lightened in light mode,
        // darkened in dark mode — text stays readable either way.
        val colorHex = data.getString("list_${index}_color", null)
        views.setInt(R.id.widget_root, "setBackgroundColor",
            widgetBackground(dark, colorHex))
        val titleColor = if (dark) Color.rgb(235, 235, 235) else Color.parseColor("#00695C")
        // NOTE: RemoteViews.setTextColor() requires API 31 — the reflection
        // action below works on every API level.
        views.setInt(R.id.widget_title, "setTextColor", titleColor)
        views.setInt(R.id.widget_prev, "setTextColor", titleColor)
        views.setInt(R.id.widget_next, "setTextColor", titleColor)

        bindOpen(context, views, data.getString("list_" + index + "_id", null))
        views.setViewVisibility(R.id.widget_prev,
            if (total > 1) android.view.View.VISIBLE else android.view.View.GONE)
        views.setViewVisibility(R.id.widget_next,
            if (total > 1) android.view.View.VISIBLE else android.view.View.GONE)
        bindCycle(context, views, R.id.widget_prev, index, total, -1)
        bindCycle(context, views, R.id.widget_next, index, total, +1)

        // S3 : les lignes sont générées par l'adapter RemoteAdapter (scroll
        // natif, pas de plafond). Le PendingIntent ci-dessous sert de
        // template : chaque ligne merge son fill-in intent (ACTION_TOGGLE +
        // EXTRA_ITEM_ID) avec ce template → onReceive inchangé.
        views.setPendingIntentTemplate(
            R.id.widget_items,
            PendingIntent.getBroadcast(context, 0,
                Intent(context, ListWidgetProvider::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE))
        // 2.1 (prod3) : re-afficher si le widget a passé par l'état
        // « aucune liste » (GONE dans la branche total == 0).
        views.setViewVisibility(R.id.widget_items, android.view.View.VISIBLE)
        views.setRemoteAdapter(R.id.widget_items,
            Intent(context, WidgetItemsRemoteViewsService::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
        appWidgetManager.updateAppWidget(appWidgetId, views)
        appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_items)
    }

    private fun bindCycle(
        context: Context,
        views: RemoteViews,
        viewId: Int,
        index: Int,
        total: Int,
        direction: Int
    ) {
        val intent = Intent(context, ListWidgetProvider::class.java).apply {
            action = ACTION_CYCLE
            putExtra(EXTRA_LIST_INDEX, index)
            putExtra(EXTRA_DIRECTION, direction)
        }
        views.setOnClickPendingIntent(
            viewId,
            PendingIntent.getBroadcast(
                context, viewId, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            ACTION_CYCLE -> {
                val data = HomeWidgetPlugin.getData(context)
                val total = data.getInt("list_count_lists", 0)
                if (total > 0) {
                    val current = intent.getIntExtra(EXTRA_LIST_INDEX, 0)
                    val direction = intent.getIntExtra(EXTRA_DIRECTION, 1)
                    val next = ((current + direction) % total + total) % total
                    data.edit().putInt("list_index", next).apply()
                    triggerUpdate(context)
                    triggerQuickAddUpdate(context)
                }
            }
            ACTION_TOGGLE -> {
                // Receiver exported : valider le format UUID avant d'écrire
                // les prefs partagées, un item_id factice est ignoré.
                val itemId = intent.getStringExtra(EXTRA_ITEM_ID)
                if (itemId != null && ITEM_ID_REGEX.matches(itemId)) {
                    checkItem(context, itemId)
                    triggerUpdate(context)
                }
            }
        }
    }

    private fun checkItem(context: Context, itemId: String) {
        val prefs = HomeWidgetPlugin.getData(context)
        val done = readDoneIds(prefs)
        prefs.edit().putString("widget_done_ids",
            (done + itemId).joinToString(",")).apply()
        val toggled = prefs.getString("widget_toggled", "") ?: ""
        if (itemId !in toggled.split(',')) {
            prefs.edit().putString("widget_toggled",
                if (toggled.isEmpty()) itemId else "$toggled,$itemId").apply()
        }
    }

}
