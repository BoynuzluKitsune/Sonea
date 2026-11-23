package com.sonea.app.widget

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

data class SoneaWidgetQueueItem(
    val queueIndex: Int,
    val title: String,
    val artist: String
)

data class SoneaWidgetPlaylistItem(
    val id: Int,
    val name: String,
    val trackCount: Int,
    val coverPath: String?
)

data class SoneaWidgetSnapshot(
    val title: String,
    val artist: String,
    val album: String,
    val format: String,
    val coverPath: String?,
    val isPlaying: Boolean,
    val isShuffleEnabled: Boolean,
    val upNext: List<SoneaWidgetQueueItem>,
    val playlists: List<SoneaWidgetPlaylistItem>,
    val bgColor: Int,
    val surfaceColor: Int,
    val elevatedColor: Int,
    val accentColor: Int,
    val onAccentColor: Int,
    val textColor: Int,
    val subtextColor: Int,
    val borderColor: Int,
    val isLight: Boolean
)

object SoneaWidgetStore {
    private const val TAG = "SoneaWidgetStore"
    private const val PREFS_NAME = "sonea_widget_prefs"
    private const val MAX_TEXT_LEN = 200
    private const val MAX_PATH_LEN = 512

    // Default Sanzo Wada No. 255 (Kuro & Asagi) palette
    const val DEFAULT_BG = 0xFF0B0C0E.toInt()
    const val DEFAULT_SURFACE = 0xFF121518.toInt()
    const val DEFAULT_ELEVATED = 0xFF1A1E23.toInt()
    const val DEFAULT_ACCENT = 0xFF78C7C7.toInt()
    const val DEFAULT_ON_ACCENT = 0xFF0B0C0E.toInt()
    const val DEFAULT_TEXT = 0xFFF2F5F5.toInt()
    const val DEFAULT_SUBTEXT = 0xFF8FA3A3.toInt()
    const val DEFAULT_BORDER = 0xFF242B30.toInt()

    private fun cleanText(raw: String?, fallback: String, maxLen: Int = MAX_TEXT_LEN): String {
        val trimmed = raw?.replace('\u0000', ' ')?.trim().orEmpty()
        if (trimmed.isEmpty()) return fallback
        return if (trimmed.length > maxLen) trimmed.substring(0, maxLen) else trimmed
    }

    private fun cleanPath(raw: String?): String? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty() || trimmed.length > MAX_PATH_LEN || trimmed.contains('\u0000')) {
            return null
        }
        return trimmed
    }

    fun defaultSnapshot(): SoneaWidgetSnapshot = SoneaWidgetSnapshot(
        title = "Sonea",
        artist = "Tap to play",
        album = "",
        format = "",
        coverPath = null,
        isPlaying = false,
        isShuffleEnabled = false,
        upNext = emptyList(),
        playlists = emptyList(),
        bgColor = DEFAULT_BG,
        surfaceColor = DEFAULT_SURFACE,
        elevatedColor = DEFAULT_ELEVATED,
        accentColor = DEFAULT_ACCENT,
        onAccentColor = DEFAULT_ON_ACCENT,
        textColor = DEFAULT_TEXT,
        subtextColor = DEFAULT_SUBTEXT,
        borderColor = DEFAULT_BORDER,
        isLight = false
    )

    @Synchronized
    fun read(context: Context): SoneaWidgetSnapshot {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val upNext = parseUpNext(prefs.getString("up_next_json", "[]") ?: "[]")
        val playlists = parsePlaylists(prefs.getString("playlists_json", "[]") ?: "[]")
        return SoneaWidgetSnapshot(
            title = cleanText(prefs.getString("title", "Sonea"), "Sonea"),
            artist = cleanText(prefs.getString("artist", "Tap to play"), "Tap to play"),
            album = cleanText(prefs.getString("album", ""), ""),
            format = cleanText(prefs.getString("format", ""), "", maxLen = 40),
            coverPath = cleanPath(prefs.getString("cover_path", null)),
            isPlaying = prefs.getBoolean("is_playing", false),
            isShuffleEnabled = prefs.getBoolean("is_shuffle", false),
            upNext = upNext,
            playlists = playlists,
            bgColor = prefs.getInt("bg_color", DEFAULT_BG),
            surfaceColor = prefs.getInt("surface_color", DEFAULT_SURFACE),
            elevatedColor = prefs.getInt("elevated_color", DEFAULT_ELEVATED),
            accentColor = prefs.getInt("accent_color", DEFAULT_ACCENT),
            onAccentColor = prefs.getInt("on_accent_color", DEFAULT_ON_ACCENT),
            textColor = prefs.getInt("text_color", DEFAULT_TEXT),
            subtextColor = prefs.getInt("subtext_color", DEFAULT_SUBTEXT),
            borderColor = prefs.getInt("border_color", DEFAULT_BORDER),
            isLight = prefs.getBoolean("is_light", false)
        )
    }

    @Synchronized
    fun writePlayback(
        context: Context,
        title: String,
        artist: String,
        album: String,
        format: String,
        coverPath: String?,
        isPlaying: Boolean,
        isShuffleEnabled: Boolean,
        upNext: List<Map<String, Any?>>
    ) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        putPlaybackFields(editor, title, artist, album, format, coverPath, isPlaying, isShuffleEnabled, upNext)
        editor.apply()
    }

    @Synchronized
    fun writeThemeAndPlaylists(
        context: Context,
        playlists: List<Map<String, Any?>>?,
        bgColor: Int?,
        surfaceColor: Int?,
        elevatedColor: Int?,
        accentColor: Int?,
        onAccentColor: Int?,
        textColor: Int?,
        subtextColor: Int?,
        borderColor: Int?,
        isLight: Boolean?
    ) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        putThemeAndPlaylistFields(
            editor,
            playlists,
            bgColor,
            surfaceColor,
            elevatedColor,
            accentColor,
            onAccentColor,
            textColor,
            subtextColor,
            borderColor,
            isLight
        )
        editor.apply()
    }

    @Synchronized
    fun writeFullState(
        context: Context,
        title: String,
        artist: String,
        album: String,
        format: String,
        coverPath: String?,
        isPlaying: Boolean,
        isShuffleEnabled: Boolean,
        upNext: List<Map<String, Any?>>,
        playlists: List<Map<String, Any?>>?,
        bgColor: Int?,
        surfaceColor: Int?,
        elevatedColor: Int?,
        accentColor: Int?,
        onAccentColor: Int?,
        textColor: Int?,
        subtextColor: Int?,
        borderColor: Int?,
        isLight: Boolean?
    ) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        putPlaybackFields(editor, title, artist, album, format, coverPath, isPlaying, isShuffleEnabled, upNext)
        putThemeAndPlaylistFields(
            editor,
            playlists,
            bgColor,
            surfaceColor,
            elevatedColor,
            accentColor,
            onAccentColor,
            textColor,
            subtextColor,
            borderColor,
            isLight
        )
        editor.apply()
    }

    private fun putPlaybackFields(
        editor: android.content.SharedPreferences.Editor,
        title: String,
        artist: String,
        album: String,
        format: String,
        coverPath: String?,
        isPlaying: Boolean,
        isShuffleEnabled: Boolean,
        upNext: List<Map<String, Any?>>
    ) {
        editor.putString("title", cleanText(title, "Sonea"))
        editor.putString("artist", cleanText(artist, "Tap to play"))
        editor.putString("album", cleanText(album, ""))
        editor.putString("format", cleanText(format, "", maxLen = 40))
        val safeCover = cleanPath(coverPath)
        if (safeCover == null) {
            editor.remove("cover_path")
        } else {
            editor.putString("cover_path", safeCover)
        }
        editor.putBoolean("is_playing", isPlaying)
        editor.putBoolean("is_shuffle", isShuffleEnabled)
        editor.putString("up_next_json", encodeUpNext(upNext))
    }

    private fun putThemeAndPlaylistFields(
        editor: android.content.SharedPreferences.Editor,
        playlists: List<Map<String, Any?>>?,
        bgColor: Int?,
        surfaceColor: Int?,
        elevatedColor: Int?,
        accentColor: Int?,
        onAccentColor: Int?,
        textColor: Int?,
        subtextColor: Int?,
        borderColor: Int?,
        isLight: Boolean?
    ) {
        if (playlists != null) {
            editor.putString("playlists_json", encodePlaylists(playlists))
        }
        if (bgColor != null) editor.putInt("bg_color", bgColor)
        if (surfaceColor != null) editor.putInt("surface_color", surfaceColor)
        if (elevatedColor != null) editor.putInt("elevated_color", elevatedColor)
        if (accentColor != null) editor.putInt("accent_color", accentColor)
        if (onAccentColor != null) editor.putInt("on_accent_color", onAccentColor)
        if (textColor != null) editor.putInt("text_color", textColor)
        if (subtextColor != null) editor.putInt("subtext_color", subtextColor)
        if (borderColor != null) editor.putInt("border_color", borderColor)
        if (isLight != null) editor.putBoolean("is_light", isLight)
    }

    private fun encodeUpNext(upNext: List<Map<String, Any?>>): String {
        return JSONArray().apply {
            for (entry in upNext.take(3)) {
                val idx = (entry["index"] as? Number)?.toInt() ?: -1
                if (idx !in 0..100000) continue
                put(JSONObject().apply {
                    put("index", idx)
                    put("title", cleanText(entry["title"] as? String, ""))
                    put("artist", cleanText(entry["artist"] as? String, ""))
                })
            }
        }.toString()
    }

    private fun encodePlaylists(playlists: List<Map<String, Any?>>): String {
        return JSONArray().apply {
            for (entry in playlists.take(3)) {
                val id = (entry["id"] as? Number)?.toInt() ?: -1
                if (id <= 0) continue
                put(JSONObject().apply {
                    put("id", id)
                    put("name", cleanText(entry["name"] as? String, ""))
                    put("trackCount", ((entry["trackCount"] as? Number)?.toInt() ?: 0).coerceAtLeast(0))
                    put("coverPath", cleanPath(entry["coverPath"] as? String) ?: "")
                })
            }
        }.toString()
    }

    private fun parseUpNext(raw: String): List<SoneaWidgetQueueItem> {
        return try {
            val arr = JSONArray(raw)
            List(arr.length().coerceAtMost(3)) { i ->
                val obj = arr.getJSONObject(i)
                SoneaWidgetQueueItem(
                    queueIndex = obj.optInt("index", -1),
                    title = cleanText(obj.optString("title", ""), ""),
                    artist = cleanText(obj.optString("artist", ""), "")
                )
            }.filter { it.queueIndex in 0..100000 && it.title.isNotEmpty() }
        } catch (e: Exception) {
            Log.e(TAG, "parseUpNext failed", e)
            emptyList()
        }
    }

    private fun parsePlaylists(raw: String): List<SoneaWidgetPlaylistItem> {
        return try {
            val arr = JSONArray(raw)
            List(arr.length().coerceAtMost(3)) { i ->
                val obj = arr.getJSONObject(i)
                SoneaWidgetPlaylistItem(
                    id = obj.optInt("id", -1),
                    name = cleanText(obj.optString("name", ""), ""),
                    trackCount = obj.optInt("trackCount", 0).coerceAtLeast(0),
                    coverPath = cleanPath(obj.optString("coverPath", ""))
                )
            }.filter { it.id > 0 && it.name.isNotEmpty() }
        } catch (e: Exception) {
            Log.e(TAG, "parsePlaylists failed", e)
            emptyList()
        }
    }
}
