package app.dial.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/** Playback settings, the same ones as on iPhone. */
data class PlaybackSettings(
    /** Seconds songs overlap; 0 plays them back to back with no gap. */
    val crossfadeSeconds: Int = 0,
    /** Plays loud and quiet songs at a similar loudness. */
    val volumeLeveling: Boolean = true,
    val equalizerOn: Boolean = false,
    /** Gains per equalizer band, in millibels (the phone decides how many bands there are). */
    val equalizerBands: List<Int> = emptyList(),
    val equalizerPreset: String? = null,
    /** "original" sends your files as they are; "high" (320 kbps) and "saver" (128 kbps) have the server convert them. */
    val quality: String = "original",
) {
    /** nil means "send the original file". */
    val maxBitrate: Int? get() = when (quality) { "high" -> 320_000; "saver" -> 128_000; else -> null }
}

class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("dial.settings", Context.MODE_PRIVATE)
    private val _settings = MutableStateFlow(load())
    val settings: StateFlow<PlaybackSettings> = _settings

    private fun load() = PlaybackSettings(
        crossfadeSeconds = prefs.getInt("crossfade", 0),
        volumeLeveling = prefs.getBoolean("leveling", true),
        equalizerOn = prefs.getBoolean("eqOn", false),
        equalizerBands = prefs.getString("eqBands", "")!!.split(',').mapNotNull { it.toIntOrNull() },
        equalizerPreset = prefs.getString("eqPreset", null),
        quality = prefs.getString("quality", "original")!!,
    )

    init { JellyfinClient.streamMaxBitrate = _settings.value.maxBitrate }

    fun update(change: (PlaybackSettings) -> PlaybackSettings) {
        _settings.update(change)
        val s = _settings.value
        prefs.edit().putInt("crossfade", s.crossfadeSeconds).putBoolean("leveling", s.volumeLeveling)
            .putBoolean("eqOn", s.equalizerOn).putString("eqBands", s.equalizerBands.joinToString(","))
            .putString("eqPreset", s.equalizerPreset).putString("quality", s.quality).apply()
        JellyfinClient.streamMaxBitrate = s.maxBitrate
    }
}
