package com.sonea.app.widget

import android.content.Context
import android.widget.RemoteViews
import com.sonea.app.R

class SoneaCoverTileWidget : SoneaWidgetBase() {

    override fun buildRemoteViews(
        context: Context,
        snapshot: SoneaWidgetSnapshot
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.sonea_widget_cover_tile)

        views.setInt(R.id.sw_bg, "setColorFilter", snapshot.bgColor)
        SoneaWidgetUpdater.bindCoverOrPlaceholder(
            context,
            views,
            R.id.sw_cover,
            snapshot.coverPath,
            maxDimPx = 220
        )

        views.setTextViewText(R.id.sw_title, snapshot.title)
        applyEqualizerIndicator(
            views,
            snapshot,
            activeTint = snapshot.accentColor,
            pausedTint = 0xCCFFFFFF.toInt()
        )
        views.setInt(R.id.sw_btn_prev, "setColorFilter", 0xFFFFFFFF.toInt())
        applyPlayPauseIcon(views, R.id.sw_btn_play_bg, R.id.sw_btn_play, snapshot)
        views.setInt(R.id.sw_btn_next, "setColorFilter", 0xFFFFFFFF.toInt())

        attachOpenApp(
            context,
            views,
            R.id.sw_root,
            requestCode = 2300,
            openNowPlaying = true
        )
        attachTransportBroadcast(context, views, R.id.sw_btn_prev, ACTION_PREVIOUS, requestCode = 2301)
        attachTransportBroadcast(context, views, R.id.sw_btn_play, ACTION_PLAY_PAUSE, requestCode = 2302)
        attachTransportBroadcast(context, views, R.id.sw_btn_next, ACTION_NEXT, requestCode = 2303)

        return views
    }
}
