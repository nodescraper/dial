package app.dial.data

/**
 * Live streams that play through YouTube's own embedded player (the supported way, nothing is taken out of the page).
 * Lofi Girl's radio streams are listed under Tune In > Lo-fi with the stream's own YouTube picture, the same as on iPhone and Mac.
 */
object YouTubeLive {
    data class Stream(val id: String, val name: String)

    /** The live streams on Lofi Girl's channel (youtube.com/@LofiGirl/streams). Their video ids change now and then. */
    val lofiGirl = listOf(
        Stream("rFZHOHl-L8A", "lofi hip hop radio · beats to relax/study to"),
        Stream("JD-kMIpDfnY", "lofi hip hop radio · beats to sleep/chill to"),
        Stream("4xDzrJKXOOY", "synthwave radio · beats to chill/game to"),
        Stream("E2vONfzoyRI", "jazz lofi radio · beats to chill/study to"),
        Stream("A8jDx9TLMQc", "relaxing jazz radio · cozy music to study to"),
        Stream("CwPCy1GLS38", "sad lofi radio · beats for rainy days"),
        Stream("1Tl2FtV06qo", "asian lofi radio · beats to relax/study to"),
        Stream("3PFJ9SETS4M", "lofi house radio · lounge music to chill to"),
        Stream("0muHFBSiybw", "summer lofi radio · music for a better mood"),
        Stream("VAlMDl00mYY", "sleep lofi radio · relaxing music to dream to"),
        Stream("E_XmwjgRLz8", "chill guitar radio · music to study/relax to"),
        Stream("N0snMcR6aaA", "relaxing piano radio · calm music to focus to"),
        Stream("jXAEIWcGXwE", "classical music radio · songs to read/study to"),
        Stream("GSfT7H87zq4", "synth ambient radio · deep space music to sleep to"),
        Stream("S_MOd40zlYU", "dark ambient radio · music to escape/dream to"),
        Stream("xORCbIptqcc", "sleep ambient music · relaxing radio to fall asleep to"),
        Stream("IxPANmjPaek", "medieval lofi radio · beats to scribe manuscripts to"),
        Stream("4t4AQ15yj1M", "christmas lofi radio · cozy ambience to relax to"),
        Stream("0sfDth4lMLc", "halloween ambience · spooky lofi to get chills to"),
        Stream("-OekvEFm1lo", "gentle rain ambience · cozy sound to chill to"),
        Stream("q_4KI-ChIIs", "fireplace ambience · cozy sound to chill to"),
        Stream("qGohtGC5Rtk", "Study With Me · Pomodoro"),
    )

    /** The stream's own live picture, from YouTube (no key needed). */
    fun thumbnail(id: String) = "https://i.ytimg.com/vi/$id/maxresdefault_live.jpg"

    fun stations(): List<Station> = lofiGirl.map {
        Station(id = "yt-${it.id}", name = it.name, streamUrl = "youtube:${it.id}", favicon = thumbnail(it.id), country = "Lofi Girl", tags = "lofi")
    }
}

/** The YouTube video this station plays, when it is one of the YouTube streams. */
val Station.youtubeId: String? get() = streamUrl.takeIf { it.startsWith("youtube:") }?.removePrefix("youtube:")
