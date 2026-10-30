package com.paulchukwuemeka.burrow

import android.content.Intent
import android.net.Uri
import android.os.Bundle
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

    /// Definition word received through a dictionary intent (the system
    /// Define menu picking Burrow, or another app sending Burrow a lookup)
    /// and not yet drained by Flutter. Consumed exactly once.
    private var pendingDefineWord: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingDefineWord = extractDefineWord(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "burrow/share_in",
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSharedFiles" -> result.success(consumeSharedFiles())
                    "getDefineWord" ->
                        result.success(
                            pendingDefineWord.also { pendingDefineWord = null },
                        )
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "burrow/dictionary_out",
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "listDefineApps" -> result.success(listDefineApps())
                    "defineWith" ->
                        result.success(
                            launchDefine(
                                call.argument<String>("packageName")!!,
                                call.argument<String>("word")!!,
                            ),
                        )
                    "showDefineChooser" ->
                        result.success(
                            showDefineChooser(call.argument<String>("word")!!),
                        )
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Keep an undrained share intact: consumeSharedFiles() reads the
        // stored intent and ignores definition actions.
        extractDefineWord(intent)?.let { pendingDefineWord = it }
    }

    /// The lookup word carried by a definition intent: the Android 14
    /// DEFINE contract carries it as android.intent.extra.WORD, the
    /// ColorDict family contract as EXTRA_QUERY. Blank treated as absent.
    private fun extractDefineWord(received: Intent?): String? =
        when (received?.action) {
            "android.intent.action.DEFINE",
            "colordict.intent.action.SEARCH",
            ->
                received
                    .getStringExtra("android.intent.extra.WORD")
                    ?.takeIf { it.isNotBlank() }
                    ?: received
                        .getStringExtra("EXTRA_QUERY")
                        ?.takeIf { it.isNotBlank() }

            else -> null
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

    /// Dictionary apps reachable by word-lookup intents: the Android 14
    /// ACTION_DEFINE plus the ColorDict family contract
    /// ("colordict.intent.action.SEARCH" — ColorDict, GoldenDict, Aard2, …).
    /// Literal action strings: the DEFINE SDK constant only exists on API 34+.
    /// Both actions are probed typeless and with a text/plain MIME type (some
    /// apps register typed filters). Merged by package (a DEFINE entry
    /// outranks its ColorDict double); our own package excluded.
    private fun listDefineApps(): List<HashMap<String, String>> = try {
        val contracts = listOf("android.intent.action.DEFINE", "colordict.intent.action.SEARCH")
        val entries = contracts.flatMap { action ->
            sequence {
                yield(Intent(action))
                yield(Intent(action).apply { setType("text/plain") })
            }.flatMap { request ->
                packageManager.queryIntentActivities(request, 0)
            }
        }.filter { it.activityInfo.packageName != packageName }
        entries
            .distinctBy { it.activityInfo.packageName }
            .map {
                hashMapOf<String, String>(
                    "packageName" to it.activityInfo.packageName,
                    "label" to it.loadLabel(packageManager).toString(),
                )
            }
    } catch (_: Exception) {
        emptyList()
    }

    /// True when the package's registration matches [request] typeless or
    /// with a text/plain MIME type — some apps register typed DEFINE filters
    /// (Chrome-style, Android 14+); a typeless-only probe would miss them and
    /// wrongly unpin a working dictionary.
    private fun resolves(request: Intent): Boolean =
        packageManager.resolveActivity(request, 0) != null ||
            packageManager
                .resolveActivity(
                    // The copy carries the type so the typed registration
                    // matches; resolveActivity does not mutate its argument.
                    Intent(request).setType("text/plain"),
                    0,
                ) != null

    /// Hands [word] to the dictionary app [pkg], speaking whichever lookup
    /// contract that package supports: ACTION_DEFINE with
    /// android.intent.extra.WORD first (literal strings, see above), then the
    /// ColorDict family contract with its EXTRA_QUERY extra. False when the
    /// app no longer resolves under either. Type-aware: see [resolves].
    /// FLAG_ACTIVITY_NEW_TASK: we are not the target activity's task owner.
    private fun launchDefine(pkg: String, word: String): Boolean = try {
        val define = Intent("android.intent.action.DEFINE")
            .putExtra("android.intent.extra.WORD", word)
            .setPackage(pkg)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (resolves(define)) {
            try {
                startActivity(define)
                true
            } catch (_: Exception) {
                false
            }
        } else {
            val colorDict = Intent("colordict.intent.action.SEARCH")
                .putExtra("EXTRA_QUERY", word)
                .setPackage(pkg)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (resolves(colorDict)) {
                try {
                    startActivity(colorDict)
                    true
                } catch (_: Exception) {
                    false
                }
            } else {
                false
            }
        }
    } catch (_: Exception) {
        false
    }

    /// Opens Android's own app-chooser menu titled "Define with": every app
    /// reachable by either lookup contract is listed (the alternate carries
    /// the ColorDict contract; Burrow itself is listed through its manifest
    /// filters). Returns true only when a chooser was actually started.
    private fun showDefineChooser(word: String): Boolean = try {
        val define = Intent("android.intent.action.DEFINE")
            .putExtra("android.intent.extra.WORD", word)
        val alternates = arrayListOf(
            Intent("colordict.intent.action.SEARCH")
                .putExtra("EXTRA_QUERY", word),
        )
        val chooser = Intent.createChooser(define, "Define with")
            .putParcelableArrayListExtra(
                Intent.EXTRA_ALTERNATE_INTENTS,
                alternates,
            )
        try {
            startActivity(chooser)
            true
        } catch (_: Exception) {
            false
        }
    } catch (_: Exception) {
        false
    }

    private fun queryDisplayName(uri: Uri): String? {        if (uri.scheme != "content") return null
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
