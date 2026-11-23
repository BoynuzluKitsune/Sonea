package com.sonea.app.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import com.sonea.app.MainActivity
import com.sonea.app.R

abstract class SoneaWidgetBase : AppWidgetProvider() {

    abstract fun buildRemoteViews(
        context: Context,
        snapshot: SoneaWidgetSnapshot
    ): RemoteViews

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val snapshot = try {
            SoneaWidgetStore.read(context)
        } catch (e: Exception) {
            Log.e(TAG, "Snapshot read failed", e)
            SoneaWidgetStore.defaultSnapshot()
        }
        for (appWidgetId in appWidgetIds) {
            try {
                val views = buildRemoteViews(context, snapshot)
                appWidgetManager.updateAppWidget(appWidgetId, views)
            } catch (e: Exception) {
                Log.e(TAG, "Widget render failed for #$appWidgetId (${this::class.java.simpleName})", e)
                try {
                    val fallback = RemoteViews(context.packageName, R.layout.sonea_widget_micro_pill)
                    fallback.setTextViewText(R.id.sw_title, "Sonea")
                    fallback.setTextViewText(R.id.sw_artist, "Tap to open")
                    attachOpenApp(context, fallback, R.id.sw_root, requestCode = 2999)
                    appWidgetManager.updateAppWidget(appWidgetId, fallback)
                } catch (fallbackErr: Exception) {
                    Log.e(TAG, "Fallback render failed for #$appWidgetId", fallbackErr)
                }
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val action = intent.action ?: return
        if (!isAllowedWidgetAction(action)) return

        val payload = buildValidatedActionPayload(action, intent) ?: return

        // 1. Live dispatch straight into AudioService's persistent FlutterEngine (zero BAL block).
        if (SoneaWidgetBridgePlugin.tryDispatchLive(payload)) {
            return
        }

        // 2. Cold-process fallback: forward transport keys to AudioService MediaButtonReceiver.
        val keyCode = when (action) {
            ACTION_PLAY_PAUSE -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            ACTION_NEXT -> KeyEvent.KEYCODE_MEDIA_NEXT
            ACTION_PREVIOUS -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            else -> null
        }
        if (keyCode != null) {
            sendMediaButtonKey(context, keyCode)
        }
    }

    private fun sendMediaButtonKey(context: Context, keyCode: Int) {
        val receiver = ComponentName(
            context.packageName,
            "com.ryanheise.audioservice.MediaButtonReceiver"
        )
        val now = SystemClock.uptimeMillis()
        for (evAction in intArrayOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
            val mediaIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                component = receiver
                putExtra(
                    Intent.EXTRA_KEY_EVENT,
                    KeyEvent(now, now, evAction, keyCode, 0)
                )
            }
            try {
                context.sendBroadcast(mediaIntent)
            } catch (e: Exception) {
                Log.e(TAG, "MediaButton broadcast failed for key=$keyCode", e)
            }
        }
    }

    protected fun attachOpenApp(
        context: Context,
        views: RemoteViews,
        viewId: Int,
        requestCode: Int,
        openNowPlaying: Boolean = false
    ) {
        val intent = Intent(
            if (openNowPlaying) ACTION_OPEN_NOW_PLAYING else Intent.ACTION_MAIN
        ).apply {
            component = ComponentName(context, MainActivity::class.java)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (openNowPlaying) {
                putExtra(EXTRA_WIDGET_ACTION, ACTION_OPEN_NOW_PLAYING)
            }
        }
        val pi = PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(viewId, pi)
    }

    protected fun attachTransportBroadcast(
        context: Context,
        views: RemoteViews,
        viewId: Int,
        action: String,
        requestCode: Int
    ) {
        if (!isAllowedWidgetAction(action)) return
        val intent = Intent(action).apply {
            component = ComponentName(context, this@SoneaWidgetBase::class.java)
        }
        val pi = PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(viewId, pi)
    }

    protected fun attachActivityAction(
        context: Context,
        views: RemoteViews,
        viewId: Int,
        action: String,
        requestCode: Int,
        queueIndex: Int? = null,
        playlistId: Int? = null
    ) {
        if (!isAllowedWidgetAction(action)) return
        val intent = Intent(action).apply {
            component = ComponentName(context, MainActivity::class.java)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_WIDGET_ACTION, action)
            if (queueIndex != null && queueIndex in 0..MAX_QUEUE_INDEX) {
                putExtra(EXTRA_QUEUE_INDEX, queueIndex)
            }
            if (playlistId != null && playlistId > 0) {
                putExtra(EXTRA_PLAYLIST_ID, playlistId)
            }
        }
        val pi = PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(viewId, pi)
    }

    protected fun applyPlayPauseIcon(
        views: RemoteViews,
        bgViewId: Int,
        btnViewId: Int,
        snapshot: SoneaWidgetSnapshot
    ) {
        views.setInt(bgViewId, "setColorFilter", snapshot.accentColor)
        val iconRes = if (snapshot.isPlaying) {
            R.drawable.sonea_w_ic_pause
        } else {
            R.drawable.sonea_w_ic_play
        }
        views.setImageViewResource(btnViewId, iconRes)
        views.setInt(btnViewId, "setColorFilter", snapshot.onAccentColor)
    }

    /**
     * Crash-safe playing wave equalizer animation:
     * - API 31+: Smooth hardware AnimatedVectorDrawable inside ProgressBar tinted with theme accent.
     * - API 26..30 (or fallback): Theme-tinted 4-frame ViewFlipper equalizer wave.
     * - Paused: Calm static equalizer bars tinted with muted subtext color.
     */
    protected fun applyEqualizerIndicator(
        views: RemoteViews,
        snapshot: SoneaWidgetSnapshot,
        activeTint: Int = snapshot.accentColor,
        pausedTint: Int = snapshot.subtextColor
    ) {
        if (!snapshot.isPlaying) {
            views.setViewVisibility(R.id.sw_eq_avd, View.GONE)
            views.setViewVisibility(R.id.sw_eq_flipper, View.GONE)
            views.setViewVisibility(R.id.sw_eq_static, View.VISIBLE)
            views.setInt(R.id.sw_eq_static, "setColorFilter", pausedTint)
            return
        }

        views.setViewVisibility(R.id.sw_eq_static, View.GONE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                views.setColorStateList(
                    R.id.sw_eq_avd,
                    "setIndeterminateTintList",
                    ColorStateList.valueOf(activeTint)
                )
                views.setViewVisibility(R.id.sw_eq_avd, View.VISIBLE)
                views.setViewVisibility(R.id.sw_eq_flipper, View.GONE)
                return
            } catch (e: Exception) {
                Log.w(TAG, "AVD tint unavailable, falling back to ViewFlipper")
            }
        }

        views.setViewVisibility(R.id.sw_eq_avd, View.GONE)
        views.setInt(R.id.sw_eq_f0, "setColorFilter", activeTint)
        views.setInt(R.id.sw_eq_f1, "setColorFilter", activeTint)
        views.setInt(R.id.sw_eq_f2, "setColorFilter", activeTint)
        views.setInt(R.id.sw_eq_f3, "setColorFilter", activeTint)
        views.setViewVisibility(R.id.sw_eq_flipper, View.VISIBLE)
    }

    companion object {
        private const val TAG = "SoneaWidgetBase"
        private const val MAX_QUEUE_INDEX = 100_000

        const val EXTRA_WIDGET_ACTION = "sonea_widget_action"
        const val EXTRA_QUEUE_INDEX = "sonea_widget_queue_index"
        const val EXTRA_PLAYLIST_ID = "sonea_widget_playlist_id"

        const val ACTION_PREVIOUS = "com.sonea.app.WIDGET_PREVIOUS"
        const val ACTION_PLAY_PAUSE = "com.sonea.app.WIDGET_PLAY_PAUSE"
        const val ACTION_NEXT = "com.sonea.app.WIDGET_NEXT"
        const val ACTION_TOGGLE_SHUFFLE = "com.sonea.app.WIDGET_TOGGLE_SHUFFLE"
        const val ACTION_JUMP_QUEUE = "com.sonea.app.WIDGET_JUMP_QUEUE"
        const val ACTION_PLAY_SHUFFLED_ALL = "com.sonea.app.WIDGET_PLAY_SHUFFLED_ALL"
        const val ACTION_PLAY_PLAYLIST = "com.sonea.app.WIDGET_PLAY_PLAYLIST"
        const val ACTION_OPEN_NOW_PLAYING = "com.sonea.app.WIDGET_OPEN_NOW_PLAYING"

        val ALLOWED_WIDGET_ACTIONS: Set<String> = setOf(
            ACTION_PREVIOUS,
            ACTION_PLAY_PAUSE,
            ACTION_NEXT,
            ACTION_TOGGLE_SHUFFLE,
            ACTION_JUMP_QUEUE,
            ACTION_PLAY_SHUFFLED_ALL,
            ACTION_PLAY_PLAYLIST,
            ACTION_OPEN_NOW_PLAYING
        )

        fun isAllowedWidgetAction(action: String?): Boolean =
            action != null && action in ALLOWED_WIDGET_ACTIONS

        fun buildValidatedActionPayload(action: String, intent: Intent): Map<String, Any>? {
            if (!isAllowedWidgetAction(action)) return null
            val payload = mutableMapOf<String, Any>("action" to action)
            when (action) {
                ACTION_JUMP_QUEUE -> {
                    val idx = intent.getIntExtra(EXTRA_QUEUE_INDEX, -1)
                    if (idx !in 0..MAX_QUEUE_INDEX) return null
                    payload["queueIndex"] = idx
                }
                ACTION_PLAY_PLAYLIST -> {
                    val plId = intent.getIntExtra(EXTRA_PLAYLIST_ID, -1)
                    if (plId <= 0) return null
                    payload["playlistId"] = plId
                }
            }
            return payload
        }
    }
}
