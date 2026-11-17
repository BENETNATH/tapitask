package com.tapitask.tapitask

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * Tapitask quick-add widget (1x1): a single button that opens the app
 * straight into the quick-add flow (tapitask://quickadd).
 */
class QuickAddWidgetProvider : AppWidgetProvider() {

    // Distinct from the 2x2 widget codes: avoids FLAG_UPDATE_CURRENT
    // collisions between the PendingIntents.
    private companion object {
        const val QUICKADD_REQUEST_CODE = 3
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = HomeWidgetPlugin.getData(context)
        // Liste AFFICHÉE dans le widget liste (index clamped, comme le
        // render) : le « + » ouvre l'app directement sur le champ d'ajout
        // de cette liste. Sans liste, fallback quickadd nu (validation
        // stricte côté Dart inchangée).
        val total = prefs.getInt("list_count_lists", 0)
        val listId: String? = if (total > 0) {
            var index = prefs.getInt("list_index", 0)
            if (index >= total) index = 0
            prefs.getString("list_${index}_id", null)
        } else null
        val uri = if (listId.isNullOrEmpty()) "tapitask://quickadd"
            else "tapitask://quickadd?list=$listId"
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.quickadd_widget)
            // Action privée (au lieu de l'action publique du plugin
            // home_widget) : MainActivity ne lit que celle-ci ; le reste
            // est validé côté Dart.
            val intent = Intent(context, MainActivity::class.java).apply {
                action = TapitaskActions.ACTION_LAUNCH
                data = Uri.parse(uri)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            views.setOnClickPendingIntent(
                R.id.quickadd_button,
                PendingIntent.getActivity(
                    context, QUICKADD_REQUEST_CODE, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
