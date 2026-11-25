package app.dial.data

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Environment
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File

/**
 * Downloads songs for offline listening. Android's own download service does the work, so downloads
 * continue in the background, survive the app closing, and show progress in the notifications.
 */
class Downloads(private val context: Context) {
    @Serializable
    data class Record(val item: Item, val path: String, val bytes: Long)

    private val folder = File(context.getExternalFilesDir(Environment.DIRECTORY_MUSIC), "Dial").apply { mkdirs() }
    private val indexFile = File(folder, "index.json")
    private val pendingFile = File(folder, "pending.json")
    private val manager = context.getSystemService(DownloadManager::class.java)

    private val _records = MutableStateFlow(loadIndex())
    val records: StateFlow<Map<String, Record>> = _records
    /** Download id → song, for downloads in progress. */
    private val _pending = MutableStateFlow(loadPending())
    val pending: StateFlow<Map<Long, Item>> = _pending

    init {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
                finished(id)
            }
        }
        val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        else @Suppress("UnspecifiedRegisterReceiverFlag") context.registerReceiver(receiver, filter)
        // Downloads that finished while Dial was closed.
        _pending.value.keys.forEach { finished(it) }
    }

    fun isDownloaded(id: String) = _records.value.containsKey(id)
    fun isDownloading(id: String) = _pending.value.values.any { it.id == id }
    fun file(id: String): File? = _records.value[id]?.let { File(it.path) }?.takeIf { it.exists() }
    val totalBytes: Long get() = _records.value.values.sumOf { it.bytes }

    fun download(songs: List<Item>, client: JellyfinClient) {
        for (song in songs) {
            if (!song.isSong || isDownloaded(song.id) || isDownloading(song.id)) continue
            val ext = song.formatLabel?.lowercase()?.takeIf { it.length in 2..5 } ?: "audio"
            val target = File(folder, "${song.id}.$ext")
            val request = DownloadManager.Request(Uri.parse(client.downloadUrl(song.id)))
                .addRequestHeader("Authorization", JellyfinClient.authHeader(client.token))
                .setTitle(song.name)
                .setDescription(song.artistLine)
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
                .setDestinationUri(Uri.fromFile(target))
            val id = manager.enqueue(request)
            _pending.update { it + (id to song) }
        }
        savePending()
    }

    private fun finished(id: Long) {
        val song = _pending.value[id] ?: return
        val cursor = manager.query(DownloadManager.Query().setFilterById(id)) ?: return
        cursor.use {
            if (!it.moveToFirst()) { _pending.update { p -> p - id }; savePending(); return }
            val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            if (status != DownloadManager.STATUS_SUCCESSFUL && status != DownloadManager.STATUS_FAILED) return // still running
            _pending.update { p -> p - id }
            if (status == DownloadManager.STATUS_SUCCESSFUL) {
                val path = Uri.parse(it.getString(it.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))).path ?: return
                val bytes = File(path).length()
                _records.update { r -> r + (song.id to Record(song, path, bytes)) }
                saveIndex()
            }
            savePending()
        }
    }

    fun delete(id: String) {
        _records.value[id]?.let { File(it.path).delete() }
        _records.update { it - id }
        saveIndex()
    }

    fun deleteAll() {
        _pending.value.keys.forEach { manager.remove(it) }
        _pending.value = emptyMap()
        _records.value.values.forEach { File(it.path).delete() }
        _records.value = emptyMap()
        saveIndex(); savePending()
    }

    private fun loadIndex(): Map<String, Record> = runCatching {
        JellyfinJson.decodeFromString(MapSerializer(String.serializer(), Record.serializer()), indexFile.readText())
    }.getOrDefault(emptyMap()).filterValues { File(it.path).exists() }

    private fun loadPending(): Map<Long, Item> = runCatching {
        JellyfinJson.decodeFromString(MapSerializer(String.serializer(), Item.serializer()), pendingFile.readText())
            .mapKeys { it.key.toLong() }
    }.getOrDefault(emptyMap())

    private fun saveIndex() = runCatching {
        indexFile.writeText(JellyfinJson.encodeToString(MapSerializer(String.serializer(), Record.serializer()), _records.value))
    }

    private fun savePending() = runCatching {
        pendingFile.writeText(JellyfinJson.encodeToString(MapSerializer(String.serializer(), Item.serializer()),
            _pending.value.mapKeys { it.key.toString() }))
    }
}
