package com.sonea.app.widget

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Engine-scoped widget bridge attached to the persistent FlutterEngine shared
 * between AudioService and MainActivity. Keeps all 5 home-screen widgets live
 * across track advances, pause/resume, lock-screen controls, and theme changes
 * even after MainActivity is closed.
 */
class SoneaWidgetBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var appContext: Context? = null
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attach(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        if (activeChannel === channel) {
            activeChannel = null
        }
        channel = null
        appContext = null
    }

    private fun attach(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        val ch = MethodChannel(messenger, CHANNEL_NAME)
        ch.setMethodCallHandler(this)
        channel = ch
        activeChannel = ch
    }

    @Suppress("UNCHECKED_CAST")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) {
            result.error("no_context", "Widget bridge context unavailable", null)
            return
        }

        when (call.method) {
            "syncPlaybackState" -> {
                val title = call.argument<String>("title") ?: "Sonea"
                val artist = call.argument<String>("artist") ?: "Tap to play"
                val album = call.argument<String>("album") ?: ""
                val format = call.argument<String>("format") ?: ""
                val coverPath = call.argument<String>("coverPath")
                val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                val isShuffleEnabled = call.argument<Boolean>("isShuffleEnabled") ?: false
                val upNext = (call.argument<List<*>>("upNext") ?: emptyList<Any>())
                    .mapNotNull { it as? Map<String, Any?> }

                SoneaWidgetStore.writePlayback(
                    context = ctx,
                    title = title,
                    artist = artist,
                    album = album,
                    format = format,
                    coverPath = coverPath,
                    isPlaying = isPlaying,
                    isShuffleEnabled = isShuffleEnabled,
                    upNext = upNext
                )
                SoneaWidgetUpdater.refreshAllAsync(ctx)
                result.success(null)
            }

            "syncThemeAndPlaylists" -> {
                val playlists = call.argument<List<*>>("playlists")
                    ?.mapNotNull { it as? Map<String, Any?> }
                SoneaWidgetStore.writeThemeAndPlaylists(
                    context = ctx,
                    playlists = playlists,
                    bgColor = call.argument<Number>("bgColor")?.toInt(),
                    surfaceColor = call.argument<Number>("surfaceColor")?.toInt(),
                    elevatedColor = call.argument<Number>("elevatedColor")?.toInt(),
                    accentColor = call.argument<Number>("accentColor")?.toInt(),
                    onAccentColor = call.argument<Number>("onAccentColor")?.toInt(),
                    textColor = call.argument<Number>("textColor")?.toInt(),
                    subtextColor = call.argument<Number>("subtextColor")?.toInt(),
                    borderColor = call.argument<Number>("borderColor")?.toInt(),
                    isLight = call.argument<Boolean>("isLight")
                )
                SoneaWidgetUpdater.refreshAllAsync(ctx)
                result.success(null)
            }

            "syncFullWidgetState" -> {
                val title = call.argument<String>("title") ?: "Sonea"
                val artist = call.argument<String>("artist") ?: "Tap to play"
                val album = call.argument<String>("album") ?: ""
                val format = call.argument<String>("format") ?: ""
                val coverPath = call.argument<String>("coverPath")
                val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                val isShuffleEnabled = call.argument<Boolean>("isShuffleEnabled") ?: false
                val upNext = (call.argument<List<*>>("upNext") ?: emptyList<Any>())
                    .mapNotNull { it as? Map<String, Any?> }
                val playlists = (call.argument<List<*>>("playlists") ?: emptyList<Any>())
                    .mapNotNull { it as? Map<String, Any?> }

                SoneaWidgetStore.writeFullState(
                    context = ctx,
                    title = title,
                    artist = artist,
                    album = album,
                    format = format,
                    coverPath = coverPath,
                    isPlaying = isPlaying,
                    isShuffleEnabled = isShuffleEnabled,
                    upNext = upNext,
                    playlists = playlists,
                    bgColor = call.argument<Number>("bgColor")?.toInt(),
                    surfaceColor = call.argument<Number>("surfaceColor")?.toInt(),
                    elevatedColor = call.argument<Number>("elevatedColor")?.toInt(),
                    accentColor = call.argument<Number>("accentColor")?.toInt(),
                    onAccentColor = call.argument<Number>("onAccentColor")?.toInt(),
                    textColor = call.argument<Number>("textColor")?.toInt(),
                    subtextColor = call.argument<Number>("subtextColor")?.toInt(),
                    borderColor = call.argument<Number>("borderColor")?.toInt(),
                    isLight = call.argument<Boolean>("isLight")
                )
                SoneaWidgetUpdater.refreshAllAsync(ctx)
                result.success(null)
            }

            "getPendingWidgetAction" -> {
                val queued = pendingAction
                pendingAction = null
                result.success(queued)
            }

            else -> result.notImplemented()
        }
    }

    companion object {
        private const val TAG = "SoneaWidgetBridge"
        const val CHANNEL_NAME = "com.sonea.app/widgets"

        @Volatile
        private var activeChannel: MethodChannel? = null

        @Volatile
        private var pendingAction: Map<String, Any>? = null

        private val mainHandler = Handler(Looper.getMainLooper())

        fun ensureAttached(flutterEngine: FlutterEngine) {
            if (flutterEngine.plugins.get(SoneaWidgetBridgePlugin::class.java) == null) {
                flutterEngine.plugins.add(SoneaWidgetBridgePlugin())
            }
        }

        fun queuePendingAction(payload: Map<String, Any>) {
            val action = payload["action"] as? String
            if (SoneaWidgetBase.isAllowedWidgetAction(action)) {
                pendingAction = payload
            }
        }

        fun tryDispatchLive(payload: Map<String, Any>): Boolean {
            val action = payload["action"] as? String
            if (!SoneaWidgetBase.isAllowedWidgetAction(action)) return false
            val ch = activeChannel ?: return false
            mainHandler.post {
                try {
                    ch.invokeMethod("onWidgetAction", payload)
                } catch (e: Exception) {
                    Log.w(TAG, "Live widget dispatch failed, queueing for startup", e)
                    pendingAction = payload
                }
            }
            return true
        }
    }
}
