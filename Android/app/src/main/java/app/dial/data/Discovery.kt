package app.dial.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/** Finds Jellyfin servers on your network (they answer a broadcast on port 7359), so a TV doesn't need an address typed in. */
object ServerDiscovery {
    data class Found(val name: String, val address: String)

    suspend fun find(timeoutMs: Int = 2500): List<Found> = withContext(Dispatchers.IO) {
        val found = LinkedHashMap<String, Found>()
        runCatching {
            DatagramSocket().use { socket ->
                socket.broadcast = true
                socket.soTimeout = 600
                val message = "who is JellyfinServer?".toByteArray()
                socket.send(DatagramPacket(message, message.size, InetAddress.getByName("255.255.255.255"), 7359))
                val deadline = System.currentTimeMillis() + timeoutMs
                val buffer = ByteArray(2048)
                while (System.currentTimeMillis() < deadline) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    try { socket.receive(packet) } catch (_: java.net.SocketTimeoutException) { continue }
                    runCatching {
                        val json = JellyfinJson.parseToJsonElement(String(packet.data, 0, packet.length)).jsonObject
                        val address = json["Address"]?.jsonPrimitive?.contentOrNull ?: return@runCatching
                        found[address] = Found(json["Name"]?.jsonPrimitive?.contentOrNull ?: "Jellyfin", address)
                    }
                }
            }
        }
        found.values.toList()
    }
}
