package com.paulchukwuemeka.burrow

import android.content.Intent
import android.net.Uri
import android.os.Parcelable
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /// URI strings already handed to Flutter, so repeated polls (every
    /// resume) never re-import the same share.
    private val consumedUris = mutableSetOf<String>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "burrow/share_in",
        ).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "getSharedFiles") {
                    result.success(consumeSharedFiles())
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    /// Copies the files behind the current SEND / SEND_MULTIPLE / VIEW intent
    /// into app-private storage and returns their paths. Consume-on-read:
    /// each URI is handed out once, then remembered in [consumedUris].
    private fun consumeSharedFiles(): List<String> {
        val action = intent?.action ?: return emptyList()
        val uris: List<Uri> = when (action) {
            Intent.ACTION_SEND -> listOfNotNull(
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Parcelable>(Intent.EXTRA_STREAM) as? Uri,
                intent.data,
            )
            Intent.ACTION_SEND_MULTIPLE -> buildList {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Parcelable>(Intent.EXTRA_STREAM)
                    ?.mapNotNullTo(this) { it as? Uri }
                intent.data?.let { add(it) }
            }
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            else -> return emptyList()
        }
        val fresh = uris
            .map { it.toString() }
            .filter { consumedUris.add(it) }
        if (fresh.isEmpty()) return emptyList()
        return fresh.mapNotNull { copyToSharedStorage(Uri.parse(it)) }
            .take(maxSharedFiles)
    }

    private fun copyToSharedStorage(uri: Uri): String? {
        // Plain files we can read directly need no copy.
        if (uri.scheme == "file") {
            return uri.path?.takeIf { File(it).canRead() }
        }
        return try {
            val name = sanitizeFileName(queryDisplayName(uri) ?: fallbackName(uri))
            val dir = File(filesDir, "shared").apply { mkdirs() }
            val tmp = File.createTempFile("share-", ".part", dir)
            try {
                contentResolver.openInputStream(uri)?.use { input ->
                    tmp.outputStream().use { output -> input.copyTo(output) }
                } ?: return null
                if (tmp.length() == 0L || tmp.length() > maxSharedBytes) return null
                val dest = File(dir, name)
                if (dest.exists() && dest.length() == tmp.length()) {
                    // Probable re-share of the same file: reuse the stable path
                    // so the library skips it as a duplicate instead of
                    // importing the same book twice.
                    return dest.absolutePath
                }
                val final = if (!dest.exists()) dest else uniqueDest(dir, name)
                if (!tmp.renameTo(final)) {
                    tmp.copyTo(final, overwrite = true)
                }
                final.absolutePath
            } finally {
                if (tmp.exists()) tmp.delete()
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme != "content") return null
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun fallbackName(uri: Uri): String {
        val last = uri.lastPathSegment?.substringAfterLast('/') ?: "shared-book"
        return if ('.' in last) last else "$last.epub"
    }

    private fun sanitizeFileName(name: String): String {
        val base = name.substringAfterLast('/').takeLast(120).ifBlank { "shared-book" }
        return base.replace(Regex("[^A-Za-z0-9._-]"), "_")
    }

    /// Numbered fallback when two *different* books arrive under one filename.
    private fun uniqueDest(dir: File, name: String): File {
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var candidate = File(dir, "$stem$ext")
        var i = 1
        while (candidate.exists() && i < 100) {
            candidate = File(dir, "$stem-$i$ext")
            i++
        }
        return candidate
    }

    companion object {
        private const val maxSharedFiles = 20
        private const val maxSharedBytes = 100L * 1024 * 1024
    }
}
