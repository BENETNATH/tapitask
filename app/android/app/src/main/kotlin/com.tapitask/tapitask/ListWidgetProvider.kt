package com.tapitask.tapitask

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * Tapitask home-screen widget (multi-list).
 * - Shows the title and up to 5 unchecked items of the pinned list at `list_index`.
 * - Tapping the title cycles to the next pinned list (stored in home_widget data).
 * - Tapping an item toggles it locally (instant feedback); the app syncs on next open.
 */
class ListWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val data = HomeWidgetPlugin.getData(context)
        val total = data.getInt("list_count_lists", 0)
        if (total == 0) {
            for (appWidgetId in appWidgetIds) {
                val views = RemoteViews(context.packageName, R.layout.list_widget)
                views.setTextViewText(R.id.widget_title, "Pin a list in Tapitask")
                for (i in 0 until 5) hideItem(views, i)
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

    private fun render(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        index: Int,
        total: Int
    ) {
        val data = HomeWidgetPlugin.getData(context)
        val views = RemoteViews(context.packageName, R.layout.list_widget)
        val title = data.getString("list_${index}_title", "Tapitask")
        views.setTextViewText(R.id.widget_title, if (total > 1) "$title (${index + 1}/$total)" else title)
        val count = data.getInt("list_${index}_count", 0)
        var visible = 0
        for (i in 0 until 5) {
            val label = data.getString("list_${index}_item_$i", "") ?: ""
            if (i < count && label.isNotEmpty()) {
                setItem(views, i, label)
                visible++
            } else {
                hideItem(views, i)
            }
        }
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    private fun setItem(views: RemoteViews, i: Int, label: String) {
        val id = when (i) {
            0 -> R.id.widget_item_0
            1 -> R.id.widget_item_1
            2 -> R.id.widget_item_2
            3 -> R.id.widget_item_3
            else -> R.id.widget_item_4
        }
        views.setViewVisibility(id, android.view.View.VISIBLE)
        views.setTextViewText(id, "☐ $label")
    }

    private fun hideItem(views: RemoteViews, i: Int) {
        val id = when (i) {
            0 -> R.id.widget_item_0
            1 -> R.id.widget_item_1
            2 -> R.id.widget_item_2
            3 -> R.id.widget_item_3
            else -> R.id.widget_item_4
        }
        views.setViewVisibility(id, android.view.View.GONE)
    }
}
