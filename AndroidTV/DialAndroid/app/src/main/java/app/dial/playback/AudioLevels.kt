package app.dial.playback

import kotlinx.coroutines.flow.MutableStateFlow

/** Shared between the app and the playback service (same process): volume set from another device. */
object AudioLevels {
    /** 0 to 1, set by a device controlling this one. */
    val userVolume = MutableStateFlow(1f)
}
