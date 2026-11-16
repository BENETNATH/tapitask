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
        HomeWidgetPlugin.getData(context)
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.quickadd_widget)
            // Action privée (au lieu de l'action publique du plugin
            // home_widget) : MainActivity ne lit que celle-ci ; le reste
            // est validé côté Dart.
            val intent = Intent(context, MainActivity::class.java).apply {
                action = TapitaskActions.ACTION_LAUNCH
                data = Uri.parse("tapitask://quickadd")
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
