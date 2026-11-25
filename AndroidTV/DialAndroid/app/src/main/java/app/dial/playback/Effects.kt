package app.dial.playback

import android.media.audiofx.Equalizer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** The phone's equalizer, attached to Dial's audio. The number of bands depends on the phone (usually five). */
object Effects {
    data class EqualizerInfo(val bands: List<Int>, val minLevel: Int, val maxLevel: Int, val presets: List<String>)

    private var equalizer: Equalizer? = null
    private val _info = MutableStateFlow<EqualizerInfo?>(null)
    /** What the equalizer offers, for the settings screen (null until playback has started once). */
    val info: StateFlow<EqualizerInfo?> = _info

    fun attach(audioSession: Int) {
        runCatching {
            equalizer?.release()
            val eq = Equalizer(0, audioSession)
            equalizer = eq
            val range = eq.bandLevelRange
            _info.value = EqualizerInfo(
                bands = (0 until eq.numberOfBands).map { eq.getCenterFreq(it.toShort()) / 1000 },
                minLevel = range[0].toInt(), maxLevel = range[1].toInt(),
                presets = (0 until eq.numberOfPresets).map { eq.getPresetName(it.toShort()) },
            )
        }
    }

    /** Applies the saved settings: off, a phone preset, or your own band levels (millibels). */
    fun apply(on: Boolean, preset: String?, bands: List<Int>) {
        val eq = equalizer ?: return
        runCatching {
            eq.enabled = on
            if (!on) return
            val presetIndex = _info.value?.presets?.indexOf(preset) ?: -1
            if (presetIndex >= 0) eq.usePreset(presetIndex.toShort())
            else bands.forEachIndexed { band, level -> if (band < eq.numberOfBands) eq.setBandLevel(band.toShort(), level.toShort()) }
        }
    }

    /** The levels a preset uses, to show on the sliders. */
    fun presetLevels(preset: String): List<Int>? {
        val eq = equalizer ?: return null
        val index = _info.value?.presets?.indexOf(preset)?.takeIf { it >= 0 } ?: return null
        return runCatching {
            eq.usePreset(index.toShort())
            (0 until eq.numberOfBands).map { eq.getBandLevel(it.toShort()).toInt() }
        }.getOrNull()
    }

    fun release() { equalizer?.release(); equalizer = null }
}
