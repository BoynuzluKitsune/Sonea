package com.sonea.app.widget

import android.content.Context
import android.view.View
import android.widget.RemoteViews
import com.sonea.app.R

class SoneaStudioCardWidget : SoneaWidgetBase() {

    override fun buildRemoteViews(
        context: Context,
        snapshot: SoneaWidgetSnapshot
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.sonea_widget_studio_card)

        views.setInt(R.id.sw_bg, "setColorFilter", snapshot.surfaceColor)
        views.setTextViewText(R.id.sw_title, snapshot.title)
        views.setTextColor(R.id.sw_title, snapshot.textColor)
        views.setTextViewText(R.id.sw_artist, snapshot.artist)
        views.setTextColor(R.id.sw_artist, snapshot.subtextColor)

        applyEqualizerIndicator(views, snapshot)

        val cleanFormat = snapshot.format.trim()
        if (cleanFormat.isNotEmpty()) {
            views.setViewVisibility(R.id.sw_format_badge, View.VISIBLE)
            views.setTextViewText(R.id.sw_format_badge, cleanFormat)
            views.setTextColor(R.id.sw_format_badge, snapshot.accentColor)
        } else {
            views.setViewVisibility(R.id.sw_format_badge, View.GONE)
        }

        SoneaWidgetUpdater.bindCoverOrPlaceholder(
            context,
            views,
            R.id.sw_cover,
            snapshot.coverPath,
            maxDimPx = 160
        )

        val shuffleTint = if (snapshot.isShuffleEnabled) snapshot.accentColor else snapshot.subtextColor
        views.setInt(R.id.sw_btn_shuffle, "setColorFilter", shuffleTint)
        views.setInt(R.id.sw_btn_prev, "setColorFilter", snapshot.textColor)
        applyPlayPauseIcon(views, R.id.sw_btn_play_bg, R.id.sw_btn_play, snapshot)
        views.setInt(R.id.sw_btn_next, "setColorFilter", snapshot.textColor)

        attachOpenApp(context, views, R.id.sw_root, requestCode = 2200)
        attachActivityAction(context, views, R.id.sw_btn_shuffle, ACTION_TOGGLE_SHUFFLE, requestCode = 2201)
        attachTransportBroadcast(context, views, R.id.sw_btn_prev, ACTION_PREVIOUS, requestCode = 2202)
        attachTransportBroadcast(context, views, R.id.sw_btn_play, ACTION_PLAY_PAUSE, requestCode = 2203)
        attachTransportBroadcast(context, views, R.id.sw_btn_next, ACTION_NEXT, requestCode = 2204)

        return views
    }
}
