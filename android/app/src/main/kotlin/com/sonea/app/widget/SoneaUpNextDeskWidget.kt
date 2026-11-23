package com.sonea.app.widget

import android.content.Context
import android.view.View
import android.widget.RemoteViews
import com.sonea.app.R

class SoneaUpNextDeskWidget : SoneaWidgetBase() {

    override fun buildRemoteViews(
        context: Context,
        snapshot: SoneaWidgetSnapshot
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.sonea_widget_up_next_desk)

        views.setInt(R.id.sw_bg, "setColorFilter", snapshot.surfaceColor)
        views.setInt(R.id.sw_divider, "setColorFilter", snapshot.borderColor)

        views.setTextViewText(R.id.sw_title, snapshot.title)
        views.setTextColor(R.id.sw_title, snapshot.textColor)
        views.setTextViewText(R.id.sw_artist, snapshot.artist)
        views.setTextColor(R.id.sw_artist, snapshot.subtextColor)
        views.setTextColor(R.id.sw_queue_label, snapshot.subtextColor)
        views.setTextColor(R.id.sw_queue_empty, snapshot.subtextColor)

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
        val shuffleTint = if (snapshot.isShuffleEnabled) snapshot.accentColor else snapshot.subtextColor
        views.setInt(R.id.sw_btn_shuffle, "setColorFilter", shuffleTint)

        val rowIds = intArrayOf(R.id.sw_queue_row_0, R.id.sw_queue_row_1, R.id.sw_queue_row_2)
        val numIds = intArrayOf(R.id.sw_queue_num_0, R.id.sw_queue_num_1, R.id.sw_queue_num_2)
        val titleIds = intArrayOf(R.id.sw_queue_title_0, R.id.sw_queue_title_1, R.id.sw_queue_title_2)
        val artistIds = intArrayOf(R.id.sw_queue_artist_0, R.id.sw_queue_artist_1, R.id.sw_queue_artist_2)

        if (snapshot.upNext.isEmpty()) {
            views.setViewVisibility(R.id.sw_queue_empty, View.VISIBLE)
            for (rowId in rowIds) {
                views.setViewVisibility(rowId, View.GONE)
            }
        } else {
            views.setViewVisibility(R.id.sw_queue_empty, View.GONE)
            for (i in 0 until 3) {
                if (i < snapshot.upNext.size) {
                    val item = snapshot.upNext[i]
                    views.setViewVisibility(rowIds[i], View.VISIBLE)
                    views.setTextViewText(numIds[i], "${i + 1}")
                    views.setTextColor(numIds[i], snapshot.accentColor)
                    views.setTextViewText(titleIds[i], item.title)
                    views.setTextColor(titleIds[i], snapshot.textColor)
                    views.setTextViewText(artistIds[i], item.artist)
                    views.setTextColor(artistIds[i], snapshot.subtextColor)
                    attachActivityAction(
                        context = context,
                        views = views,
                        viewId = rowIds[i],
                        action = ACTION_JUMP_QUEUE,
                        requestCode = 2410 + i,
                        queueIndex = item.queueIndex
                    )
                } else {
                    views.setViewVisibility(rowIds[i], View.GONE)
                }
            }
        }

        attachOpenApp(context, views, R.id.sw_root, requestCode = 2400)
        attachTransportBroadcast(context, views, R.id.sw_btn_prev, ACTION_PREVIOUS, requestCode = 2401)
        attachTransportBroadcast(context, views, R.id.sw_btn_play, ACTION_PLAY_PAUSE, requestCode = 2402)
        attachTransportBroadcast(context, views, R.id.sw_btn_next, ACTION_NEXT, requestCode = 2403)
        attachActivityAction(context, views, R.id.sw_btn_shuffle, ACTION_TOGGLE_SHUFFLE, requestCode = 2404)

        return views
    }
}
