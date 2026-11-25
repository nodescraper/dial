package app.dial.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Your listening history from Jellyfin's Playback Reporting plugin: every play with its date (the same as on iPhone and Mac).
 * Without the plugin every question comes back empty, and the mixtapes lean on the server's play counts and dates instead.
 */
object ListeningHistory {
    private fun userClause(client: JellyfinClient): String {
        val id = client.userId.lowercase().replace("-", "").filter { it.isLetterOrDigit() }
        return "LOWER(REPLACE(UserId, '-', '')) = '$id'"
    }

    private fun plainId(id: String) = id.replace("-", "").lowercase()

    /** Runs a read-only query on the plugin's database; null if the plugin is not there. */
    private suspend fun query(client: JellyfinClient, sql: String): List<List<String>>? {
        val body = buildJsonObject { put("CustomQueryString", sql); put("ReplaceUserId", false) }.toString()
        val text = runCatching { client.post("user_usage_stats/submit_custom_query", json = body) }.getOrNull() ?: return null
        val rows = runCatching { JellyfinJson.parseToJsonElement(text).jsonObject["results"] as? JsonArray }.getOrNull() ?: return null
        return rows.map { row -> (row as? JsonArray)?.map { it.jsonPrimitive.content } ?: emptyList() }
    }

    /** Your most played songs over the last days, most played first, as (id, plays). */
    suspend fun topSongs(client: JellyfinClient, days: Int, limit: Int = 40): List<Pair<String, Int>> {
        val sql = """
            SELECT ItemId, COUNT(*) AS Plays FROM PlaybackActivity
            WHERE ${userClause(client)} AND ItemType = 'Audio' AND DateCreated >= DATETIME('now', 'localtime', '-$days days')
            GROUP BY ItemId ORDER BY Plays DESC LIMIT $limit
        """.trimIndent()
        return (query(client, sql) ?: emptyList()).mapNotNull { row ->
            val plays = row.getOrNull(1)?.toDoubleOrNull()?.toInt() ?: return@mapNotNull null
            plainId(row[0]) to plays
        }
    }

    /** Songs played in the last hours. */
    suspend fun recentlyPlayed(client: JellyfinClient, hours: Int): Set<String> {
        val sql = """
            SELECT DISTINCT ItemId FROM PlaybackActivity
            WHERE ${userClause(client)} AND ItemType = 'Audio' AND DateCreated >= DATETIME('now', 'localtime', '-$hours hours')
        """.trimIndent()
        return (query(client, sql) ?: emptyList()).mapNotNull { it.firstOrNull()?.let(::plainId) }.toSet()
    }
}
