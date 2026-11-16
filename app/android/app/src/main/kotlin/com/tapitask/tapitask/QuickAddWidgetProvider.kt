package com.tapitask.tapitask

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * Tapitask quick-add widget (1x1): a single button that opens the app
 * straight into the quick-add flow (tapitask://quickadd).
 */
class QuickAddWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        HomeWidgetPlugin.getData(context)
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.quickadd_widget)
            views.setOnClickPendingIntent(
                R.id.quickadd_button,
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("tapitask://quickadd")))
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
