package com.sonea.app.widget

import android.content.Context
import android.widget.RemoteViews
import com.sonea.app.R

class SoneaMicroPillWidget : SoneaWidgetBase() {

    override fun buildRemoteViews(
        context: Context,
        snapshot: SoneaWidgetSnapshot
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.sonea_widget_micro_pill)

        views.setInt(R.id.sw_bg, "setColorFilter", snapshot.surfaceColor)
        views.setInt(R.id.sw_accent_bar, "setColorFilter", snapshot.accentColor)

        views.setTextViewText(R.id.sw_title, snapshot.title)
        views.setTextColor(R.id.sw_title, snapshot.textColor)
        views.setTextViewText(R.id.sw_artist, snapshot.artist)
        views.setTextColor(R.id.sw_artist, snapshot.subtextColor)

        applyEqualizerIndicator(views, snapshot)

        SoneaWidgetUpdater.bindCoverOrPlaceholder(
            context,
            views,
            R.id.sw_cover,
            snapshot.coverPath,
            maxDimPx = 160
        )
        views.setInt(R.id.sw_btn_prev, "setColorFilter", snapshot.textColor)
        applyPlayPauseIcon(views, R.id.sw_btn_play_bg, R.id.sw_btn_play, snapshot)
        views.setInt(R.id.sw_btn_next, "setColorFilter", snapshot.textColor)

        attachOpenApp(context, views, R.id.sw_root, requestCode = 2100)
        attachTransportBroadcast(context, views, R.id.sw_btn_prev, ACTION_PREVIOUS, requestCode = 2101)
        attachTransportBroadcast(context, views, R.id.sw_btn_play, ACTION_PLAY_PAUSE, requestCode = 2102)
        attachTransportBroadcast(context, views, R.id.sw_btn_next, ACTION_NEXT, requestCode = 2103)

        return views
    }
}
