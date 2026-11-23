package com.sonea.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import com.sonea.app.widget.SoneaWidgetBase
import com.sonea.app.widget.SoneaWidgetBridgePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : AudioServiceActivity() {
    private val channelName = "com.sonea.app/library"
    private val audioRequestCode = 7301
    private val notifRequestCode = 7302
    private val pickCoverRequestCode = 7303

    private var pendingAudioResult: MethodChannel.Result? = null
    private var pendingNotifResult: MethodChannel.Result? = null
    private var pendingCoverResult: MethodChannel.Result? = null
    private var pendingCoverOutputPath: String? = null

    private val audioPermission: String
        get() = if (Build.VERSION.SDK_INT >= 33) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Attach the engine-scoped widget bridge so background AudioService playback
        // keeps updating all 5 home-screen widgets even if MainActivity is destroyed.
        SoneaWidgetBridgePlugin.ensureAttached(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "permissionStatus" -> result.success(permissionStatus())
                "requestAudioPermission" -> requestAudioPermission(result)
                "notificationPermissionStatus" -> result.success(notificationPermissionStatus())
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "openAppSettings" -> {
                    startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName")
                        )
                    )
                    result.success(null)
                }
                "pickPlaylistCoverImage" -> {
                    val outputPath = call.argument<String>("outputPath")
                    val validated = validatePlaylistCoverOutputPath(outputPath)
                    if (validated == null) {
                        result.error("invalid_arg", "Invalid playlist cover destination path", null)
                    } else {
                        launchCoverPicker(validated.absolutePath, result)
                    }
                }
                "queryAudio" -> {
                    if (ContextCompat.checkSelfPermission(this, audioPermission) != PackageManager.PERMISSION_GRANTED) {
                        result.error("permission_denied", "READ_MEDIA_AUDIO is not granted", null)
                    } else {
                        Thread {
                            try {
                                val files = queryAudioFiles()
                                runOnUiThread { result.success(files) }
                            } catch (e: SecurityException) {
                                runOnUiThread { result.error("permission_revoked", e.message, null) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("query_failed", e.message, null) }
                            }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }

        handleWidgetIntent(intent, coldStart = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleWidgetIntent(intent, coldStart = false)
    }

    private fun handleWidgetIntent(intent: Intent?, coldStart: Boolean) {
        val safeIntent = intent ?: return
        val rawAction = safeIntent.getStringExtra(SoneaWidgetBase.EXTRA_WIDGET_ACTION)
            ?: safeIntent.action
        val action = rawAction?.takeIf { SoneaWidgetBase.isAllowedWidgetAction(it) } ?: return

        val payload = SoneaWidgetBase.buildValidatedActionPayload(action, safeIntent)
        safeIntent.removeExtra(SoneaWidgetBase.EXTRA_WIDGET_ACTION)
        safeIntent.removeExtra(SoneaWidgetBase.EXTRA_QUEUE_INDEX)
        safeIntent.removeExtra(SoneaWidgetBase.EXTRA_PLAYLIST_ID)
        if (payload == null) return

        if (coldStart) {
            SoneaWidgetBridgePlugin.queuePendingAction(payload)
        } else if (!SoneaWidgetBridgePlugin.tryDispatchLive(payload)) {
            SoneaWidgetBridgePlugin.queuePendingAction(payload)
        }
    }

    /**
     * Ensures playlist cover output stays strictly within Sonea's own playlist_covers
     * directory (CWE-22 path traversal prevention).
     */
    private fun validatePlaylistCoverOutputPath(rawPath: String?): File? {
        if (rawPath.isNullOrBlank() || rawPath.contains('\u0000')) return null
        return try {
            val allowedDir = File(applicationContext.filesDir, "playlist_covers").canonicalFile
            val allowedPrefix = allowedDir.path + File.separator
            val candidate = File(rawPath).canonicalFile
            val validExt = candidate.name.endsWith(".jpg", ignoreCase = true) ||
                candidate.name.endsWith(".jpeg", ignoreCase = true)
            if (validExt && candidate.path.startsWith(allowedPrefix)) candidate else null
        } catch (_: Exception) {
            null
        }
    }

    private fun launchCoverPicker(outputPath: String, result: MethodChannel.Result) {
        if (pendingCoverResult != null) {
            result.error("picker_busy", "Image picker already active", null)
            return
        }
        pendingCoverResult = result
        pendingCoverOutputPath = outputPath
        val pickIntent = if (Build.VERSION.SDK_INT >= 33) {
            Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                type = "image/*"
            }
        } else {
            Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(pickIntent, pickCoverRequestCode)
        } catch (e: Exception) {
            pendingCoverResult = null
            pendingCoverOutputPath = null
            result.error("picker_error", e.message, null)
        }
    }

    @Suppress("OVERRIDE_DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickCoverRequestCode) return

        val callback = pendingCoverResult
        val outPath = pendingCoverOutputPath
        pendingCoverResult = null
        pendingCoverOutputPath = null

        if (callback == null || outPath == null) return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            callback.success(null)
            return
        }

        Thread {
            try {
                val saved = copyAndResizePickedImage(uri, outPath, maxDimPx = 512)
                runOnUiThread { callback.success(saved) }
            } catch (e: Exception) {
                runOnUiThread { callback.error("cover_save_failed", e.message, null) }
            }
        }.start()
    }

    private fun copyAndResizePickedImage(uri: Uri, outputPath: String, maxDimPx: Int): String {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream, null, bounds)
        }
        val outW = bounds.outWidth
        val outH = bounds.outHeight
        if (outW <= 0 || outH <= 0) {
            throw IllegalArgumentException("Selected file is not a valid image")
        }

        var inSampleSize = 1
        while ((outW / inSampleSize) > maxDimPx * 2 || (outH / inSampleSize) > maxDimPx * 2) {
            inSampleSize *= 2
        }

        val decodeOpts = BitmapFactory.Options().apply {
            this.inSampleSize = inSampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = contentResolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream, null, decodeOpts)
        } ?: throw IllegalStateException("Failed to decode picked image")

        val finalBitmap = if (decoded.width > maxDimPx || decoded.height > maxDimPx) {
            val scale = maxDimPx.toFloat() / maxOf(decoded.width, decoded.height).toFloat()
            val w = (decoded.width * scale).toInt().coerceAtLeast(1)
            val h = (decoded.height * scale).toInt().coerceAtLeast(1)
            val scaled = Bitmap.createScaledBitmap(decoded, w, h, true)
            if (scaled != decoded) decoded.recycle()
            scaled
        } else {
            decoded
        }

        val targetFile = File(outputPath)
        targetFile.parentFile?.mkdirs()
        val tmpFile = File("$outputPath.tmp")
        try {
            FileOutputStream(tmpFile).use { fos ->
                if (!finalBitmap.compress(Bitmap.CompressFormat.JPEG, 82, fos)) {
                    throw IllegalStateException("JPEG compression failed")
                }
            }
            if (targetFile.exists()) targetFile.delete()
            if (!tmpFile.renameTo(targetFile)) {
                tmpFile.copyTo(targetFile, overwrite = true)
                tmpFile.delete()
            }
        } finally {
            finalBitmap.recycle()
            if (tmpFile.exists()) tmpFile.delete()
        }
        return targetFile.absolutePath
    }

    private fun permissionStatus(): String {
        if (ContextCompat.checkSelfPermission(this, audioPermission) == PackageManager.PERMISSION_GRANTED) return "granted"
        val requested = getPreferences(MODE_PRIVATE).getBoolean("audio_permission_requested", false)
        return if (requested && !shouldShowRequestPermissionRationale(audioPermission)) "permanentlyDenied" else "denied"
    }

    private fun notificationPermissionStatus(): String {
        if (Build.VERSION.SDK_INT < 33) return "granted"
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return "granted"
        val requested = getPreferences(MODE_PRIVATE).getBoolean("notif_permission_requested", false)
        return if (requested && !shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) "permanentlyDenied" else "denied"
    }

    private fun requestAudioPermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, audioPermission) == PackageManager.PERMISSION_GRANTED) {
            result.success("granted")
            return
        }
        if (pendingAudioResult != null) {
            result.error("permission_busy", "Audio permission request already in progress", null)
            return
        }
        pendingAudioResult = result
        getPreferences(MODE_PRIVATE).edit().putBoolean("audio_permission_requested", true).apply()
        requestPermissions(arrayOf(audioPermission), audioRequestCode)
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success("granted")
            return
        }
        if (pendingNotifResult != null) {
            result.error("permission_busy", "Notification permission request already in progress", null)
            return
        }
        pendingNotifResult = result
        getPreferences(MODE_PRIVATE).edit().putBoolean("notif_permission_requested", true).apply()
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notifRequestCode)
    }

    @Suppress("OVERRIDE_DEPRECATION")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        @Suppress("DEPRECATION")
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == audioRequestCode) {
            pendingAudioResult?.success(permissionStatus())
            pendingAudioResult = null
        } else if (requestCode == notifRequestCode) {
            pendingNotifResult?.success(notificationPermissionStatus())
            pendingNotifResult = null
        }
    }

    private val supportedAudioExtensions = setOf(
        "mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "aiff", "wv"
    )

    private fun queryAudioFiles(): List<Map<String, Any>> {
        val seenPaths = LinkedHashSet<String>()
        val files = mutableListOf<Map<String, Any>>()

        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        @Suppress("DEPRECATION")
        val dataCol = MediaStore.Audio.Media.DATA
        val projection = arrayOf(dataCol, MediaStore.Audio.Media.DATE_MODIFIED)
        val selection = "COALESCE(${MediaStore.Audio.Media.IS_RINGTONE}, 0) = 0 AND COALESCE(${MediaStore.Audio.Media.IS_ALARM}, 0) = 0 AND COALESCE(${MediaStore.Audio.Media.IS_NOTIFICATION}, 0) = 0"
        val cursor: Cursor? = try {
            contentResolver.query(uri, projection, selection, null, "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC")
        } catch (_: Exception) {
            contentResolver.query(uri, projection, null, null, null)
        }

        cursor?.use {
            val pathColumn = it.getColumnIndex(dataCol)
            val modifiedColumn = it.getColumnIndex(MediaStore.Audio.Media.DATE_MODIFIED)
            if (pathColumn >= 0) {
                while (it.moveToNext()) {
                    val path = it.getString(pathColumn)?.takeIf(String::isNotBlank) ?: continue
                    val mod = if (modifiedColumn >= 0) it.getLong(modifiedColumn) else 0L
                    if (seenPaths.add(path)) {
                        files += mapOf("path" to path, "fileModified" to mod)
                    }
                }
            }
        }

        if (files.isEmpty()) {
            val fallbackDirs = listOf(
                android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_MUSIC),
                android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS),
                File("/storage/emulated/0/Music"),
                File("/storage/emulated/0/Download")
            ).distinctBy { it.absolutePath }

            for (dir in fallbackDirs) {
                if (!dir.exists() || !dir.isDirectory || !dir.canRead()) continue
                collectAudioFilesRecursively(dir, seenPaths, files, depth = 0)
            }
        }

        return files
    }

    private fun collectAudioFilesRecursively(
        dir: File,
        seenPaths: MutableSet<String>,
        out: MutableList<Map<String, Any>>,
        depth: Int
    ) {
        if (depth > 6) return
        val children = dir.listFiles() ?: return
        for (child in children) {
            if (child.name.startsWith(".")) continue
            if (child.isDirectory) {
                collectAudioFilesRecursively(child, seenPaths, out, depth + 1)
            } else if (child.isFile) {
                val ext = child.extension.lowercase()
                if (ext in supportedAudioExtensions && seenPaths.add(child.absolutePath)) {
                    out += mapOf(
                        "path" to child.absolutePath,
                        "fileModified" to (child.lastModified() / 1000L)
                    )
                }
            }
        }
    }
}
