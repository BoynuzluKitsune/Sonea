package com.sonea.app.widget

import android.content.Context
import android.view.View
import android.widget.RemoteViews
import com.sonea.app.R

class SoneaQuickMixDockWidget : SoneaWidgetBase() {

    override fun buildRemoteViews(
        context: Context,
        snapshot: SoneaWidgetSnapshot
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.sonea_widget_quick_mix_dock)

        views.setInt(R.id.sw_bg, "setColorFilter", snapshot.surfaceColor)

        // Left Top: Theme-accented One-Tap Shuffle Card
        views.setInt(R.id.sw_quick_shuffle_bg, "setColorFilter", snapshot.accentColor)
        views.setInt(R.id.sw_quick_shuffle_icon, "setColorFilter", snapshot.onAccentColor)
        views.setTextColor(R.id.sw_quick_shuffle_label, snapshot.onAccentColor)
        attachActivityAction(
            context = context,
            views = views,
            viewId = R.id.sw_btn_quick_shuffle,
            action = ACTION_PLAY_SHUFFLED_ALL,
            requestCode = 2501
        )

        // Left Bottom: Quick Play/Pause + Live Playing Wave
        views.setInt(R.id.sw_btn_play_bg, "setColorFilter", snapshot.elevatedColor)
        val playIcon = if (snapshot.isPlaying) R.drawable.sonea_w_ic_pause else R.drawable.sonea_w_ic_play
        views.setImageViewResource(R.id.sw_btn_play, playIcon)
        views.setInt(R.id.sw_btn_play, "setColorFilter", snapshot.accentColor)
        applyEqualizerIndicator(views, snapshot)
        attachTransportBroadcast(
            context = context,
            views = views,
            viewId = R.id.sw_btn_play_area,
            action = ACTION_PLAY_PAUSE,
            requestCode = 2502
        )
        attachTransportBroadcast(
            context = context,
            views = views,
            viewId = R.id.sw_btn_play,
            action = ACTION_PLAY_PAUSE,
            requestCode = 2503
        )

        // Right Column: Up to 3 Playlist Shortcuts (custom cover art supported)
        val rowIds = intArrayOf(R.id.sw_pl_row_0, R.id.sw_pl_row_1, R.id.sw_pl_row_2)
        val bgIds = intArrayOf(R.id.sw_pl_bg_0, R.id.sw_pl_bg_1, R.id.sw_pl_bg_2)
        val iconIds = intArrayOf(R.id.sw_pl_icon_0, R.id.sw_pl_icon_1, R.id.sw_pl_icon_2)
        val nameIds = intArrayOf(R.id.sw_pl_name_0, R.id.sw_pl_name_1, R.id.sw_pl_name_2)
        val countIds = intArrayOf(R.id.sw_pl_count_0, R.id.sw_pl_count_1, R.id.sw_pl_count_2)

        views.setTextColor(R.id.sw_playlists_empty, snapshot.subtextColor)

        if (snapshot.playlists.isEmpty()) {
            views.setViewVisibility(R.id.sw_playlists_empty, View.VISIBLE)
            for (rowId in rowIds) {
                views.setViewVisibility(rowId, View.GONE)
            }
        } else {
            views.setViewVisibility(R.id.sw_playlists_empty, View.GONE)
            for (i in 0 until 3) {
                if (i < snapshot.playlists.size) {
                    val pl = snapshot.playlists[i]
                    views.setViewVisibility(rowIds[i], View.VISIBLE)
                    views.setInt(bgIds[i], "setColorFilter", snapshot.elevatedColor)

                    val customBmp = SoneaWidgetUpdater.decodeCachedCover(
                        context,
                        pl.coverPath,
                        maxDimPx = 96
                    )
                    if (customBmp != null) {
                        views.setInt(iconIds[i], "setColorFilter", 0)
                        views.setImageViewBitmap(iconIds[i], customBmp)
                    } else {
                        views.setImageViewResource(iconIds[i], R.drawable.sonea_w_ic_playlist)
                        views.setInt(iconIds[i], "setColorFilter", snapshot.accentColor)
                    }

                    views.setTextViewText(nameIds[i], pl.name)
                    views.setTextColor(nameIds[i], snapshot.textColor)
                    views.setTextViewText(countIds[i], "${pl.trackCount}")
                    views.setTextColor(countIds[i], snapshot.subtextColor)

                    attachActivityAction(
                        context = context,
                        views = views,
                        viewId = rowIds[i],
                        action = ACTION_PLAY_PLAYLIST,
                        requestCode = 2510 + i,
                        playlistId = pl.id
                    )
                } else {
                    views.setViewVisibility(rowIds[i], View.GONE)
                }
            }
        }

        attachOpenApp(context, views, R.id.sw_root, requestCode = 2500)
        return views
    }
}
