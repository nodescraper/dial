package app.dial.data

import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.jsonObject
import android.content.Context
import android.net.Uri
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.currentCoroutineContext

class JellyfinException(message: String) : Exception(message)

/** While this is in the coroutine context, [JellyfinClient.get] answers only from the saved copy ([cacheOnly]) and notes when it had none. */
class CacheMode(val cacheOnly: Boolean) : kotlin.coroutines.AbstractCoroutineContextElement(CacheMode) {
    companion object Key : kotlin.coroutines.CoroutineContext.Key<CacheMode>
    @Volatile var missed = false
}

/** Saved copies of server answers, so screens open at once and refresh behind the scenes (like the iPhone app). */
object ResponseCache {
    private var dir: java.io.File? = null
    private val memory = object : LinkedHashMap<String, String>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>) = size > 40
    }
    private val skipped = listOf("Sessions", "Dial/Ping", "Dial/Status", "Users/Me", "System", "Items/Latest")

    fun init(context: Context) {
        val folder = java.io.File(context.cacheDir, "responses-v1").apply { mkdirs() }
        dir = folder
        val limit = System.currentTimeMillis() - 14L * 24 * 3600 * 1000
        Thread { folder.listFiles()?.forEach { if (it.lastModified() < limit) it.delete() } }.start()
    }

    fun accepts(path: String) = skipped.none { path.startsWith(it) }

    private fun file(key: String) = dir?.let { java.io.File(it, java.security.MessageDigest.getInstance("SHA-1").digest(key.toByteArray()).joinToString("") { b -> "%02x".format(b) }) }

    fun read(key: String): String? {
        synchronized(memory) { memory[key]?.let { return it } }
        val text = runCatching { file(key)?.takeIf { it.exists() }?.readText() }.getOrNull() ?: return null
        synchronized(memory) { memory[key] = text }
        return text
    }

    fun write(key: String, text: String) {
        synchronized(memory) { memory[key] = text }
        runCatching { file(key)?.writeText(text) }
    }

    fun clear() {
        synchronized(memory) { memory.clear() }
        dir?.listFiles()?.forEach { it.delete() }
    }
}

/** Talks to your Jellyfin server: the same requests as the iPhone app. */
class JellyfinClient(val server: String, val token: String, val userId: String) {

    companion object {
        const val CLIENT_NAME = "Dial"
        const val VERSION = "0.1"
        private val JSON = "application/json".toMediaType()

        val http: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()

        lateinit var deviceId: String
            private set

        /** The streaming quality limit in bits per second (null: the original file), set from the playback settings. */
        @Volatile var streamMaxBitrate: Int? = null

        /** Show the .m3u playlist files that came with albums (hidden unless this is on, like on iPhone). */
        var showPlaylistFiles = false
            set(value) { field = value; prefs?.edit()?.putBoolean("showPlaylistFiles", value)?.apply() }
        private var prefs: android.content.SharedPreferences? = null

        fun init(context: Context) {
            ResponseCache.init(context)
            val prefs = context.getSharedPreferences("dial", Context.MODE_PRIVATE)
            Companion.prefs = prefs
            showPlaylistFiles = prefs.getBoolean("showPlaylistFiles", false)
            deviceId = prefs.getString("deviceId", null) ?: UUID.randomUUID().toString().also {
                prefs.edit().putString("deviceId", it).apply()
            }
        }

        fun authHeader(token: String?): String {
            val device = Build.MODEL.replace("\"", "")
            var header = "MediaBrowser Client=\"$CLIENT_NAME\", Device=\"$device\", DeviceId=\"$deviceId\", Version=\"$VERSION\""
            if (token != null) header += ", Token=\"$token\""
            return header
        }

        fun normalize(server: String): String {
            var address = server.trim().trimEnd('/')
            if (!address.startsWith("http://") && !address.startsWith("https://")) address = "http://$address"
            return address
        }

        /** Starts Quick Connect: returns a code to approve in another Jellyfin app, and a secret to wait with. */
        suspend fun quickConnectStart(server: String): Pair<String, String> = withContext(Dispatchers.IO) {
            val address = normalize(server)
            val request = Request.Builder().url("$address/QuickConnect/Initiate")
                .header("Authorization", authHeader(null)).post("".toRequestBody(JSON)).build()
            http.newCall(request).execute().use { response ->
                if (response.code == 401 || response.code == 403) throw JellyfinException("Quick Connect is turned off on this server.")
                if (!response.isSuccessful) throw JellyfinException("The server returned error ${response.code}.")
                val result = JellyfinJson.decodeFromString(QuickConnectState.serializer(), response.body!!.string())
                result.code to result.secret
            }
        }

        /** Checks whether the code was approved; signs in when it was. */
        suspend fun quickConnectFinish(server: String, secret: String): JellyfinClient? = withContext(Dispatchers.IO) {
            val address = normalize(server)
            val check = Request.Builder().url("$address/QuickConnect/Connect?secret=$secret")
                .header("Authorization", authHeader(null)).build()
            val approved = http.newCall(check).execute().use { response ->
                response.isSuccessful && JellyfinJson.decodeFromString(QuickConnectState.serializer(), response.body!!.string()).authenticated
            }
            if (!approved) return@withContext null
            val body = buildJsonObject { put("Secret", secret) }.toString()
            val auth = Request.Builder().url("$address/Users/AuthenticateWithQuickConnect")
                .header("Authorization", authHeader(null)).post(body.toRequestBody(JSON)).build()
            http.newCall(auth).execute().use { response ->
                if (!response.isSuccessful) return@withContext null
                val result = JellyfinJson.decodeFromString(AuthResult.serializer(), response.body!!.string())
                JellyfinClient(address, result.token, result.user.id)
            }
        }

        /** The server's name, or null when the address isn't a Jellyfin server. Also proves it can be reached. */
        suspend fun serverName(server: String): String? = withContext(Dispatchers.IO) {
            runCatching {
                val request = Request.Builder().url("${normalize(server)}/System/Info/Public").header("Authorization", authHeader(null)).build()
                http.newBuilder().callTimeout(8, TimeUnit.SECONDS).build().newCall(request).execute().use { response ->
                    if (!response.isSuccessful) return@use null
                    JellyfinJson.parseToJsonElement(response.body!!.string()).jsonObject["ServerName"]?.jsonPrimitive?.contentOrNull ?: "Jellyfin"
                }
            }.getOrNull()
        }

        /** Whether the server offers Quick Connect (Dashboard, General). */
        suspend fun quickConnectEnabled(server: String): Boolean = withContext(Dispatchers.IO) {
            runCatching {
                val request = Request.Builder().url("${normalize(server)}/QuickConnect/Enabled").header("Authorization", authHeader(null)).build()
                http.newCall(request).execute().use { it.isSuccessful && it.body!!.string().contains("true", ignoreCase = true) }
            }.getOrDefault(false)
        }

        suspend fun login(server: String, username: String, password: String): JellyfinClient = withContext(Dispatchers.IO) {
            val address = normalize(server)
            val body = buildJsonObject { put("Username", username); put("Pw", password) }.toString()
            val request = Request.Builder().url("$address/Users/AuthenticateByName")
                .header("Authorization", authHeader(null))
                .post(body.toRequestBody(JSON)).build()
            http.newCall(request).execute().use { response ->
                if (response.code == 401) throw JellyfinException("Wrong username or password.")
                if (!response.isSuccessful) throw JellyfinException("The server returned error ${response.code}.")
                val result = JellyfinJson.decodeFromString(AuthResult.serializer(), response.body!!.string())
                JellyfinClient(address, result.token, result.user.id)
            }
        }
    }

    // MARK: Requests

    private fun url(path: String, query: Map<String, String> = emptyMap()): String {
        val builder = Uri.parse("$server/$path").buildUpon()
        query.forEach { (key, value) -> builder.appendQueryParameter(key, value) }
        return builder.build().toString()
    }

    suspend fun get(path: String, query: Map<String, String> = emptyMap()): String {
        val cacheable = ResponseCache.accepts(path)
        val key = if (cacheable) "$userId ${url(path, query)}" else null
        val mode = currentCoroutineContext()[CacheMode]
        if (mode != null && mode.cacheOnly) {
            if (key != null) ResponseCache.read(key)?.let { return it }
            mode.missed = true
            throw JellyfinException("Not cached")
        }
        val text = withContext(Dispatchers.IO) {
            val request = Request.Builder().url(url(path, query)).header("Authorization", authHeader(token)).build()
            http.newCall(request).execute().use { response ->
                if (!response.isSuccessful) throw JellyfinException("The server returned error ${response.code}.")
                response.body?.string() ?: ""
            }
        }
        if (key != null) ResponseCache.write(key, text)
        return text
    }

    suspend fun post(path: String, query: Map<String, String> = emptyMap(), json: String? = null): String = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(url(path, query)).header("Authorization", authHeader(token))
            .post((json ?: "").toRequestBody(JSON)).build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw JellyfinException("The server returned error ${response.code}.")
            response.body?.string() ?: ""
        }
    }

    suspend fun delete(path: String, query: Map<String, String> = emptyMap()) = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(url(path, query)).header("Authorization", authHeader(token)).delete().build()
        http.newCall(request).execute().close()
    }

    /** A DELETE that answers with a body (the wishlist endpoints answer the full list). */
    private suspend fun deleteResult(path: String, query: Map<String, String> = emptyMap()): String = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(url(path, query)).header("Authorization", authHeader(token)).delete().build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw JellyfinException("The server returned error ${response.code}.")
            response.body?.string() ?: ""
        }
    }

    private suspend fun items(query: Map<String, String>, path: String = "Items"): List<Item> {
        val text = get(path, query + ("userId" to userId))
        // Big lists (thousands of songs) take a while to read; never on the thread that draws the screen.
        return withContext(Dispatchers.Default) { JellyfinJson.decodeFromString(ItemsResponse.serializer(), text).items }
    }

    // MARK: Library

    suspend fun recentAlbums(limit: Int = 12) = items(mapOf(
        "IncludeItemTypes" to "MusicAlbum", "Recursive" to "true", "SortBy" to "DateCreated", "Fields" to "DateCreated",
        "SortOrder" to "Descending", "Limit" to "$limit"))

    suspend fun recentlyPlayed(limit: Int = 20) = items(mapOf(
        "IncludeItemTypes" to "Audio", "Recursive" to "true", "SortBy" to "DatePlayed",
        "SortOrder" to "Descending", "Filters" to "IsPlayed", "Limit" to "$limit"))

    suspend fun favoriteAlbums() = items(mapOf(
        "IncludeItemTypes" to "MusicAlbum", "Recursive" to "true", "Filters" to "IsFavorite", "SortBy" to "SortName"))

    suspend fun favoriteSongs() = items(mapOf(
        "IncludeItemTypes" to "Audio", "Recursive" to "true", "Filters" to "IsFavorite", "SortBy" to "SortName", "Limit" to "2000"))

    suspend fun albums(limit: Int = 2000) = items(mapOf(
        "IncludeItemTypes" to "MusicAlbum", "Recursive" to "true", "SortBy" to "SortName", "Limit" to "$limit"))

    suspend fun artists(): List<Item> = ArtistNames.distinct(items(mapOf("SortBy" to "SortName", "Limit" to "3000"), "Artists/AlbumArtists"))

    suspend fun songs(limit: Int = 3000) = items(mapOf(
        "IncludeItemTypes" to "Audio", "Recursive" to "true", "SortBy" to "SortName", "Limit" to "$limit"))

    /** Playlists made in Jellyfin. The .m3u files that came with your albums are left out (they can't be edited or deleted). */
    suspend fun playlists() = allPlaylists().filter { (showPlaylistFiles || !it.isPlaylistFile) && !MixCatalog.isGenerated(it.name) }

    suspend fun allPlaylists() = items(mapOf("IncludeItemTypes" to "Playlist", "Recursive" to "true", "SortBy" to "SortName",
        "Fields" to "Path,ChildCount"))

    suspend fun playlistTracks(id: String) = items(mapOf("Fields" to "MediaSources"), "Playlists/$id/Items")

    suspend fun albumTracks(albumId: String) = items(mapOf(
        "ParentId" to albumId, "IncludeItemTypes" to "Audio", "Recursive" to "true",
        "SortBy" to "ParentIndexNumber,IndexNumber,SortName", "Fields" to "MediaSources"))

    suspend fun artistAlbums(artistId: String) = items(mapOf(
        "IncludeItemTypes" to "MusicAlbum", "Recursive" to "true", "AlbumArtistIds" to artistId,
        "SortBy" to "ProductionYear,SortName", "SortOrder" to "Descending", "Fields" to "ProviderIds"))

    suspend fun genres() = items(mapOf("SortBy" to "SortName", "Limit" to "300"), "MusicGenres")

    /** Every song with its genre tags, to find the genres the library really has. */
    suspend fun songsWithGenres() = items(mapOf("IncludeItemTypes" to "Audio", "Recursive" to "true", "Fields" to "Genres", "Limit" to "50000"))

    /** Every song with its file (format, quality, size), genres, ids, when it was added and whether you played it: Library Stats. */
    suspend fun songsForLibraryStats() = items(mapOf("IncludeItemTypes" to "Audio", "Recursive" to "true",
        "Fields" to "MediaSources,Genres,DateCreated,ProviderIds", "EnableUserData" to "true", "Limit" to "50000"))

    /** Every album with its cover, year, genres and when it was added: Library Stats. */
    suspend fun albumsForLibraryStats() = items(mapOf("IncludeItemTypes" to "MusicAlbum", "Recursive" to "true",
        "Fields" to "Genres,DateCreated,ProviderIds", "Limit" to "20000"))

    /** A broad sample of albums with genres and years, to build Search's categories from. */
    suspend fun albumsForBrowsing(limit: Int = 600) = items(mapOf(
        "IncludeItemTypes" to "MusicAlbum", "Recursive" to "true", "SortBy" to "Random", "Fields" to "Genres", "Limit" to "$limit"))

    /** How many albums came out in a decade (counted by the server, so every album is included, not a sample),
     *  and a few of the most recently added for the cover collage. */
    suspend fun albumsInDecade(decade: Int, covers: Int = 4): Pair<Int, List<Item>> {
        val years = (decade..decade + 9).joinToString(",")
        val text = get("Items", mapOf("userId" to userId, "IncludeItemTypes" to "MusicAlbum", "Recursive" to "true", "Years" to years,
            "SortBy" to "DateCreated", "SortOrder" to "Descending", "Limit" to "$covers"))
        return withContext(Dispatchers.Default) {
            val total = JellyfinJson.parseToJsonElement(text).jsonObject["TotalRecordCount"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: 0
            total to JellyfinJson.decodeFromString(ItemsResponse.serializer(), text).items
        }
    }

    /** How many albums have any of these genres (counted by the server), and a few of the most recently added for covers. */
    suspend fun albumsInGenres(genreNames: List<String>, covers: Int = 4): Pair<Int, List<Item>> {
        // By name: names are separated with "|" on every Jellyfin version, while id lists changed to commas in 10.9
        // (a "|" there is quietly ignored, which would count the whole library for every genre).
        if (genreNames.isEmpty()) return 0 to emptyList()
        val text = get("Items", mapOf("userId" to userId, "IncludeItemTypes" to "MusicAlbum", "Recursive" to "true",
            "Genres" to genreNames.joinToString("|"), "SortBy" to "DateCreated", "SortOrder" to "Descending", "Limit" to "$covers"))
        return withContext(Dispatchers.Default) {
            val total = JellyfinJson.parseToJsonElement(text).jsonObject["TotalRecordCount"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: 0
            total to JellyfinJson.decodeFromString(ItemsResponse.serializer(), text).items
        }
    }

    /** The release years the library has, from the server's own list (one small request, no counting). */
    suspend fun libraryYears(): List<Int> =
        items(mapOf("IncludeItemTypes" to "MusicAlbum", "Recursive" to "true", "SortBy" to "SortName"), "Years").mapNotNull { it.name.toIntOrNull() }

    /** Songs sorted by something (play count, date added, random), with your play counts and dates on them. */
    suspend fun songsSorted(sort: String, order: String = "Descending", filters: String? = null, artistId: String? = null, limit: Int): List<Item> {
        val query = mutableMapOf("IncludeItemTypes" to "Audio", "Recursive" to "true", "SortBy" to sort, "SortOrder" to order,
            "Limit" to "$limit", "Fields" to "Genres,DateCreated", "EnableUserData" to "true")
        if (filters != null) query["Filters"] = filters
        if (artistId != null) query["ArtistIds"] = artistId
        return items(query)
    }

    /** Random songs with any of these genres (by name) in these release years, with your play counts and dates on them. */
    suspend fun songsByGenres(genres: List<String>, years: List<Int>, limit: Int): List<Item> {
        val query = mutableMapOf("IncludeItemTypes" to "Audio", "Recursive" to "true", "SortBy" to "Random", "Limit" to "$limit",
            "Fields" to "Genres", "EnableUserData" to "true")
        if (genres.isNotEmpty()) query["Genres"] = genres.joinToString("|")
        if (years.isNotEmpty()) query["Years"] = years.joinToString(",")
        return items(query)
    }

    suspend fun albums(years: List<Int>, limit: Int = 500) = items(mapOf(
        "IncludeItemTypes" to "MusicAlbum", "Recursive" to "true", "Years" to years.joinToString(","),
        "SortBy" to "ProductionYear,SortName", "SortOrder" to "Descending", "Limit" to "$limit"))

    /**
     * Every song from these years. Albums carry the year, but many songs on them have none of their own, so asking for songs by
     * year finds only a few. This takes those, plus every song on an album from the years.
     */
    suspend fun songsFromYears(years: List<Int>, limit: Int = 1500): List<Item> = kotlinx.coroutines.coroutineScope {
        val tagged = async { runCatching { songs(years, limit) }.getOrDefault(emptyList()) }
        val albums = runCatching { albums(years, 3000) }.getOrDefault(emptyList())
        val ids = albums.map { it.id }.toHashSet()
        val onAlbums = albums.chunked(40).map { chunk ->
            async {
                runCatching { items(mapOf("IncludeItemTypes" to "Audio", "Recursive" to "true", "AlbumIds" to chunk.joinToString(",") { it.id },
                    "Limit" to "3000")) }.getOrDefault(emptyList()).filter { it.albumId in ids }
            }
        }
        (tagged.await() + onAlbums.awaitAll().flatten()).distinctBy { it.id }
    }

    // MARK: The Dial plugin

    suspend fun hasDialPlugin(): Boolean = runCatching { get("Dial/Ping"); true }.getOrDefault(false)

    /** The Discovery feed from the plugin: null if it is not there; ready is false while the server makes the first one. */
    suspend fun dialDiscovery(): Pair<PluginFeed, Boolean>? {
        val text = runCatching { get("Dial/Discovery") }.getOrNull() ?: return null
        if (text.contains("\"ready\":false")) return PluginFeed() to false
        val feed = runCatching { JellyfinJson.decodeFromString(PluginFeed.serializer(), text) }.getOrNull() ?: return null
        return feed to true
    }

    suspend fun dialMixtapes(): List<PluginMixtape>? {
        val text = runCatching { get("Dial/Mixtapes") }.getOrNull() ?: return null
        return runCatching { JellyfinJson.decodeFromString(PluginMixtapeSet.serializer(), text).mixes }.getOrNull()
    }

    suspend fun dialStatus(): PluginStatus? {
        val text = runCatching { get("Dial/Status") }.getOrNull() ?: return null
        return runCatching { JellyfinJson.decodeFromString(PluginStatus.serializer(), text) }.getOrNull()
    }

    suspend fun albums(genreId: String) = items(mapOf(
        "IncludeItemTypes" to "MusicAlbum", "Recursive" to "true", "GenreIds" to genreId, "SortBy" to "SortName", "Limit" to "500"))

    suspend fun songs(years: List<Int>, limit: Int = 200) = items(mapOf(
        "IncludeItemTypes" to "Audio", "Recursive" to "true", "Years" to years.joinToString(","), "SortBy" to "Random", "Limit" to "$limit"))

    suspend fun songs(genreId: String, limit: Int = 200) = items(mapOf(
        "IncludeItemTypes" to "Audio", "Recursive" to "true", "GenreIds" to genreId, "SortBy" to "Random", "Limit" to "$limit"))

    /** Random songs filtered by genre ids and release years (either may be empty). */
    suspend fun songsMatching(genreIds: List<String>, years: List<Int>, limit: Int): List<Item> {
        val query = mutableMapOf("IncludeItemTypes" to "Audio", "Recursive" to "true", "SortBy" to "Random",
            "Limit" to "$limit", "Fields" to "Genres")
        if (genreIds.isNotEmpty()) query["GenreIds"] = genreIds.joinToString(",")
        if (years.isNotEmpty()) query["Years"] = years.joinToString(",")
        return items(query)
    }

    /** Songs on albums by these artists, in chunks so the request stays short. */
    suspend fun songsByAlbumArtists(artistIds: List<String>, years: List<Int>, limit: Int): List<Item> =
        artistIds.chunked(40).flatMap { chunk ->
            val query = mutableMapOf("IncludeItemTypes" to "Audio", "Recursive" to "true", "SortBy" to "Random",
                "Limit" to "$limit", "Fields" to "Genres", "AlbumArtistIds" to chunk.joinToString(","))
            if (years.isNotEmpty()) query["Years"] = years.joinToString(",")
            items(query)
        }

    suspend fun artistTopSongs(artistId: String, limit: Int = 20) = items(mapOf(
        "IncludeItemTypes" to "Audio", "Recursive" to "true", "ArtistIds" to artistId,
        "SortBy" to "PlayCount,SortName", "SortOrder" to "Descending", "Limit" to "$limit"))

    suspend fun artistSongs(artistId: String, limit: Int = 200) = items(mapOf(
        "IncludeItemTypes" to "Audio", "Recursive" to "true", "ArtistIds" to artistId, "SortBy" to "Random", "Limit" to "$limit"))

    /** Songs you played most, with their play counts and last-played dates. */
    suspend fun songsMostPlayed(limit: Int) = items(mapOf(
        "IncludeItemTypes" to "Audio", "Recursive" to "true", "SortBy" to "PlayCount", "SortOrder" to "Descending",
        "Filters" to "IsPlayed", "Limit" to "$limit"))

    suspend fun randomSongs(limit: Int) = items(mapOf(
        "IncludeItemTypes" to "Audio", "Recursive" to "true", "SortBy" to "Random", "Limit" to "$limit"))

    suspend fun randomArtists(limit: Int) = ArtistNames.distinct(items(mapOf("SortBy" to "Random", "Limit" to "${limit * 2}"), "Artists/AlbumArtists")).take(limit)

    suspend fun search(term: String) = items(mapOf(
        "searchTerm" to term, "IncludeItemTypes" to "Audio,MusicAlbum,MusicArtist,Playlist", "Recursive" to "true", "Limit" to "60"))

    /**
     * Searches your library the forgiving way: "passion fruit" finds "Passionfruit", "the weekend" finds "The Weeknd", "end of begg"
     * finds "End of Beginning". Asks the server for a few versions of what you typed at once, looks through everything Dial has
     * indexed itself, and ranks it all by how well it really matches. [types] narrows it to one kind (the search filters).
     */
    suspend fun searchForgiving(term: String, types: String = "Audio,MusicAlbum,MusicArtist,Playlist"): List<Item> {
        val trimmed = term.trim()
        val variants = mutableListOf(trimmed)
        val joined = trimmed.replace(" ", "")
        if (joined != trimmed) variants += joined
        val words = trimmed.split(" ").filter { it.length >= 4 }.sortedByDescending { it.length }
        for (w in words.take(2)) if (w !in variants) variants += w
        words.firstOrNull()?.takeIf { it.length >= 6 }?.let { variants += it.take(it.length - 2) }
        val limit = if (types.contains(",")) "60" else "200"
        val found = kotlinx.coroutines.coroutineScope {
            variants.map { v -> async { runCatching { items(mapOf("searchTerm" to v, "IncludeItemTypes" to types, "Recursive" to "true", "Limit" to limit)) }.getOrDefault(emptyList()) } }
                .flatMap { it.await() }
        }
        val best = LinkedHashMap<String, Pair<Item, Double>>()
        for (item in found.distinctBy { it.id }) best[item.id] = item to SearchRanking.score(item, trimmed)
        val wantedTypes = types.split(",").toSet()
        for ((item, fuzzy) in LibraryIndex.search(trimmed, this)) {
            if (item.type !in wantedTypes) continue
            val score = fuzzy * 80 + when (item.type) { "MusicArtist" -> 3.0; "MusicAlbum" -> 2.0; else -> 0.0 }
            if ((best[item.id]?.second ?: -1.0) < score) best[item.id] = item to score
        }
        return best.values.filter { it.second >= 22 }.sortedByDescending { it.second }.map { it.first }
    }

    suspend fun details(id: String): Item = JellyfinJson.decodeFromString(
        Item.serializer(), get("Items/$id", mapOf("userId" to userId, "Fields" to "Overview,Genres,Studios,MediaSources,ProviderIds,PremiereDate")))

    suspend fun items(ids: List<String>): List<Item> {
        if (ids.isEmpty()) return emptyList()
        val found = items(mapOf("Ids" to ids.joinToString(",")))
        val byId = found.associateBy { it.id }
        return ids.mapNotNull { byId[it] }
    }

    /** Songs like this one. With the AudioMuse plugin on the server, by how they sound. */
    suspend fun instantMix(id: String, limit: Int = 40) = items(mapOf("Limit" to "$limit"), "Items/$id/InstantMix")

    suspend fun setFavorite(id: String, favorite: Boolean) {
        if (favorite) post("UserFavoriteItems/$id", mapOf("userId" to userId)) else delete("UserFavoriteItems/$id", mapOf("userId" to userId))
    }

    /** Your star rating (0 to 5) for a song; Jellyfin stores it as 0 to 10. */
    suspend fun setRating(id: String, stars: Int) {
        post("UserItems/$id/UserData", mapOf("userId" to userId), """{"Rating": ${stars * 2.0}}""")
    }

    suspend fun createPlaylist(name: String, ids: List<String>) {
        val json = kotlinx.serialization.json.buildJsonObject {
            put("Name", name)
            put("UserId", userId)
            put("MediaType", "Audio")
            put("Ids", kotlinx.serialization.json.JsonArray(ids.map { kotlinx.serialization.json.JsonPrimitive(it) }))
        }.toString()
        post("Playlists", json = json)
    }

    suspend fun addToPlaylist(playlistId: String, ids: List<String>) {
        post("Playlists/$playlistId/Items", query = mapOf("ids" to ids.joinToString(","), "userId" to userId))
    }

    suspend fun removeFromPlaylist(playlistId: String, entryIds: List<String>) {
        delete("Playlists/$playlistId/Items", mapOf("entryIds" to entryIds.joinToString(",")))
    }

    /** Renames a playlist (the server leaves everything else about it as it is). */
    suspend fun renamePlaylist(playlistId: String, name: String) {
        post("Playlists/$playlistId", json = kotlinx.serialization.json.buildJsonObject { put("Name", name) }.toString())
    }

    suspend fun deletePlaylist(playlistId: String) = delete("Items/$playlistId")

    /** Whether this account may delete files from the server (Jellyfin's "Allow media deletion" in the user's settings). */
    suspend fun canDelete(): Boolean {
        val text = runCatching { get("Users/$userId") }.getOrNull() ?: return false
        val policy = runCatching { JellyfinJson.parseToJsonElement(text).jsonObject["Policy"] as? kotlinx.serialization.json.JsonObject }.getOrNull() ?: return false
        if ((policy["EnableContentDeletion"] as? kotlinx.serialization.json.JsonPrimitive)?.content == "true") return true
        return (policy["EnableContentDeletionFromFolders"] as? kotlinx.serialization.json.JsonArray)?.isNotEmpty() == true
    }

    /** Moves a song (by its place in this playlist, not its song id) to a new position. */
    suspend fun movePlaylistItem(playlistId: String, entryId: String, index: Int) {
        post("Playlists/$playlistId/Items/$entryId/Move/$index")
    }

    /** Lyrics your server has for a song (synced when the file had timestamps). */
    suspend fun lyrics(id: String): List<LyricLine> = runCatching {
        val text = get("Audio/$id/Lyrics")
        JellyfinJson.decodeFromString(LyricsResponse.serializer(), text).lyrics
    }.getOrDefault(emptyList())

    // MARK: Wishlist (the Dial plugin keeps it, so every device shows the same list)

    /** The wishlist the plugin keeps for this user (null when the plugin can't be reached). */
    suspend fun dialWishlist(): List<WishItem>? {
        val text = runCatching { get("Dial/Wishlist") }.getOrNull() ?: return null
        return wishItems(text)
    }

    suspend fun dialWishlistAdd(item: WishItem): List<WishItem>? {
        val body = JellyfinJson.encodeToString(WishItem.serializer(), item)
        val text = runCatching { post("Dial/Wishlist", json = body) }.getOrNull() ?: return null
        return wishItems(text)
    }

    suspend fun dialWishlistRemove(id: String): List<WishItem>? {
        val text = runCatching { deleteResult("Dial/Wishlist/$id") }.getOrNull() ?: return null
        return wishItems(text)
    }

    /** Items another version of the app wrote in a shape this one can't read are skipped, not the whole list. */
    private fun wishItems(text: String): List<WishItem>? {
        val raw = runCatching { JellyfinJson.parseToJsonElement(text) as? kotlinx.serialization.json.JsonArray }.getOrNull() ?: return null
        return raw.mapNotNull { runCatching { JellyfinJson.decodeFromJsonElement(WishItem.serializer(), it) }.getOrNull() }
    }

    // MARK: Pictures and audio

    /** Any of an item's pictures (Backdrop/0, Logo...) at a given width, keeping its shape. */
    fun imageUrl(itemId: String, type: String, width: Int): String =
        url("Items/$itemId/Images/$type", mapOf("maxWidth" to "$width", "quality" to "90"))

    fun imageUrl(itemId: String, size: Int = 600): String =
        url("Items/$itemId/Images/Primary", mapOf("fillWidth" to "$size", "fillHeight" to "$size", "quality" to "90"))

    /** The song as your server stores it when the phone can play it, converted otherwise. */
    fun streamUrl(itemId: String): String = url("Audio/$itemId/universal", mapOf(
        "UserId" to userId, "DeviceId" to deviceId, "ApiKey" to token, "MaxStreamingBitrate" to "${streamMaxBitrate ?: 999999999}",
        "Container" to "flac,mp3,aac,m4a|aac,m4b|aac,opus,ogg,webma,wav",
        "TranscodingContainer" to "mp3", "TranscodingProtocol" to "http", "AudioCodec" to "mp3"))

    /** The original file, for downloads. */
    fun downloadUrl(itemId: String): String = url("Items/$itemId/Download", mapOf("ApiKey" to token))

    // MARK: Telling the server what's playing (play counts, other devices)

    /** Marks a song as played at a given time (counts one play, sets "last played"): for plays made offline. */
    suspend fun markPlayed(itemId: String, atMs: Long) {
        val date = java.time.Instant.ofEpochMilli(atMs).toString()
        post("UserPlayedItems/$itemId", mapOf("userId" to userId, "datePlayed" to date))
    }

    /** Returns whether the server took the report (false: no connection or an error). */
    suspend fun reportPlayback(event: String, itemId: String, positionMs: Long, paused: Boolean,
                               queue: List<String> = emptyList(), volume: Int = 100, repeat: String = "RepeatNone",
                               shuffled: Boolean = false): Boolean {
        val json = buildJsonObject {
            put("ItemId", itemId)
            put("PositionTicks", positionMs * 10_000)
            put("IsPaused", paused)
            put("CanSeek", true)
            put("PlayMethod", "DirectPlay")
            put("VolumeLevel", volume)
            put("IsMuted", volume == 0)
            put("RepeatMode", repeat)
            put("ShuffleMode", if (shuffled) "Shuffle" else "Sorted")
            if (queue.isNotEmpty()) put("NowPlayingQueue", kotlinx.serialization.json.JsonArray(queue.mapIndexed { i, id ->
                buildJsonObject { put("Id", id); put("PlaylistItemId", "q$i") }
            }))
        }.toString()
        val path = when (event) {
            "start" -> "Sessions/Playing"
            "stop" -> "Sessions/Playing/Stopped"
            else -> "Sessions/Playing/Progress"
        }
        return runCatching { post(path, json = json) }.isSuccess
    }

    // MARK: AudioMuse (optional, on the server)

    /** Whether the AudioMuse plugin offers sound search (mood stations). */
    suspend fun audioMuseCanSearch(): Boolean = runCatching {
        get("AudioMuseAI/info").contains("clap/search")
    }.getOrDefault(false)

    /** Whether the AudioMuse plugin can make "Your Sound": songs that match the sound of what you play most. */
    suspend fun audioMuseCanYourSound(): Boolean = runCatching {
        get("AudioMuseAI/info").contains("sonic_fingerprint/generate")
    }.getOrDefault(false)

    suspend fun yourSound(count: Int = 60): List<Item> {
        val text = get("AudioMuseAI/sonic_fingerprint/generate", mapOf("jellyfin_user_identifier" to userId, "jellyfin_token" to token, "n" to "$count"))
        val rows = runCatching { kotlinx.serialization.json.Json.parseToJsonElement(text) as? kotlinx.serialization.json.JsonArray }.getOrNull() ?: return emptyList()
        val ids = rows.mapNotNull { (it as? kotlinx.serialization.json.JsonObject)?.get("item_id")?.jsonPrimitive?.contentOrNull }
        return items(ids)
    }

    suspend fun songsMatching(description: String, limit: Int = 50): List<Item> =
        songsMatchingScored(description, limit).map { it.first }

    /** The same search with how well each song fits (higher is closer), best first; null if the server sends no score. */
    suspend fun songsMatchingScored(description: String, limit: Int = 50): List<Pair<Item, Double?>> {
        val json = buildJsonObject { put("query", description); put("limit", limit) }.toString()
        val text = post("AudioMuseAI/clap/search", json = json)
        val results = runCatching {
            kotlinx.serialization.json.Json.parseToJsonElement(text).jsonObject["results"] as? kotlinx.serialization.json.JsonArray
        }.getOrNull() ?: return emptyList()
        val scores = LinkedHashMap<String, Double?>()
        for (row in results) {
            val o = row as? kotlinx.serialization.json.JsonObject ?: continue
            val id = o["item_id"]?.jsonPrimitive?.contentOrNull ?: continue
            scores.putIfAbsent(id, o["similarity"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull())
        }
        return items(scores.keys.toList()).map { it to scores[it.id] }
    }
}
