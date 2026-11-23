package com.sonea.app.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.widget.RemoteViews
import com.sonea.app.R
import java.io.File
import java.util.concurrent.Executors

object SoneaWidgetUpdater {
    private const val TAG = "SoneaWidgetUpdater"
    private const val MAX_CACHE_ENTRIES = 6
    private const val MAX_COVER_FILE_BYTES = 16L * 1024L * 1024L
    private val executor = Executors.newSingleThreadExecutor()

    private val bitmapLock = Any()
    private val bitmapCache = LinkedHashMap<String, Bitmap>(MAX_CACHE_ENTRIES, 0.75f, true)

    private val allProviders: List<SoneaWidgetBase> = listOf(
        SoneaMicroPillWidget(),
        SoneaStudioCardWidget(),
        SoneaCoverTileWidget(),
        SoneaUpNextDeskWidget(),
        SoneaQuickMixDockWidget()
    )

    fun refreshAllAsync(context: Context) {
        val appCtx = context.applicationContext
        executor.execute {
            refreshAllBlocking(appCtx)
        }
    }

    fun refreshAllBlocking(context: Context) {
        val appCtx = context.applicationContext
        val snapshot = try {
            SoneaWidgetStore.read(appCtx)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read snapshot", e)
            SoneaWidgetStore.defaultSnapshot()
        }
        val manager = AppWidgetManager.getInstance(appCtx)
        for (provider in allProviders) {
            try {
                val ids = manager.getAppWidgetIds(ComponentName(appCtx, provider::class.java))
                if (ids.isEmpty()) continue
                val views = provider.buildRemoteViews(appCtx, snapshot)
                for (id in ids) {
                    manager.updateAppWidget(id, views)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to update ${provider::class.java.simpleName}", e)
            }
        }
    }

    fun bindCoverOrPlaceholder(
        context: Context,
        views: RemoteViews,
        viewId: Int,
        coverPath: String?,
        maxDimPx: Int
    ) {
        val bitmap = decodeCachedCover(context, coverPath, maxDimPx)
        if (bitmap != null) {
            views.setImageViewBitmap(viewId, bitmap)
        } else {
            views.setImageViewResource(viewId, R.drawable.sonea_w_placeholder)
        }
    }

    fun decodeCachedCover(context: Context, path: String?, maxDimPx: Int): Bitmap? {
        val safeFile = resolveAllowedCoverFile(context, path) ?: return null
        val safeMax = maxDimPx.coerceIn(48, 220)
        val cacheKey = "${safeFile.absolutePath}|${safeFile.lastModified()}|$safeMax"

        synchronized(bitmapLock) {
            val hit = bitmapCache[cacheKey]
            if (hit != null && !hit.isRecycled) {
                return hit
            }
        }

        val decoded = decodeSampledBitmap(safeFile.absolutePath, safeMax) ?: return null
        synchronized(bitmapLock) {
            bitmapCache[cacheKey] = decoded
            while (bitmapCache.size > MAX_CACHE_ENTRIES) {
                val eldestKey = bitmapCache.entries.firstOrNull()?.key ?: break
                bitmapCache.remove(eldestKey)
            }
        }
        return decoded
    }

    /**
     * Restricts widget cover reads strictly to Sonea's own app storage & cache roots
     * to prevent path-traversal or arbitrary-file disclosure (CWE-22).
     */
    private fun resolveAllowedCoverFile(context: Context, rawPath: String?): File? {
        if (rawPath.isNullOrBlank() || rawPath.contains('\u0000')) return null
        return try {
            val appCtx = context.applicationContext
            val candidate = File(rawPath).canonicalFile
            if (!candidate.exists() || !candidate.isFile) return null
            val len = candidate.length()
            if (len <= 0L || len > MAX_COVER_FILE_BYTES) return null

            val allowedRoots = listOfNotNull(
                appCtx.filesDir?.canonicalPath,
                appCtx.cacheDir?.canonicalPath,
                File(appCtx.dataDir, "app_flutter").canonicalPath
            ).map { if (it.endsWith(File.separator)) it else it + File.separator }

            val canonical = candidate.path
            val insideAppDir = allowedRoots.any { canonical.startsWith(it) }
            if (!insideAppDir) null else candidate
        } catch (e: Exception) {
            Log.w(TAG, "Rejected cover path validation")
            null
        }
    }

    private fun decodeSampledBitmap(path: String, maxDimPx: Int): Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            val outW = bounds.outWidth
            val outH = bounds.outHeight
            if (outW <= 0 || outH <= 0) return null

            var inSampleSize = 1
            while ((outW / inSampleSize) > maxDimPx * 2 || (outH / inSampleSize) > maxDimPx * 2) {
                inSampleSize *= 2
            }

            val opts = BitmapFactory.Options().apply {
                this.inSampleSize = inSampleSize
                inPreferredConfig = Bitmap.Config.RGB_565
            }
            val decoded = BitmapFactory.decodeFile(path, opts) ?: return null
            if (decoded.width > maxDimPx || decoded.height > maxDimPx) {
                val scale = maxDimPx.toFloat() / maxOf(decoded.width, decoded.height).toFloat()
                val w = (decoded.width * scale).toInt().coerceAtLeast(1)
                val h = (decoded.height * scale).toInt().coerceAtLeast(1)
                val scaled = Bitmap.createScaledBitmap(decoded, w, h, true)
                if (scaled != decoded) decoded.recycle()
                scaled
            } else {
                decoded
            }
        } catch (e: Exception) {
            Log.e(TAG, "decodeSampledBitmap failed", e)
            null
        }
    }
}
