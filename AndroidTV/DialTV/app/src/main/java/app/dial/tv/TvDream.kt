package app.dial.tv

import android.graphics.Color
import android.service.dreams.DreamService
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import app.dial.DialApplication
import app.dial.playback.PlaybackState
import coil3.SingletonImageLoader
import coil3.asDrawable
import coil3.request.ImageRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Dial as the TV's screensaver: when the TV idles while music plays, it shows the cover, the title and the artist, as Spotify does.
 * The TV's own standby timer still decides when it starts. You pick Dial in the TV's Screen saver settings.
 */
class TvDreamService : DreamService() {
    private var scope: CoroutineScope? = null
    private var cover: ImageView? = null
    private var title: TextView? = null
    private var subtitle: TextView? = null
    private var shownCover: String? = null

    override fun onDreamingStarted() {
        super.onDreamingStarted()
        isFullscreen = true
        isInteractive = false
        isScreenBright = true
        setContentView(buildView())
        val app = application as DialApplication
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main).also { s ->
            s.launch { app.player.state.collect { show(it) } }
        }
    }

    override fun onDreamingStopped() {
        scope?.cancel()
        scope = null
        super.onDreamingStopped()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun buildView(): FrameLayout {
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            setPadding(dp(96), dp(64), dp(96), dp(64))
        }
        cover = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            layoutParams = LinearLayout.LayoutParams(dp(480), dp(480))
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(56), 0, 0, 0)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        title = TextView(this).apply {
            textSize = 48f
            setTextColor(Color.WHITE)
            maxLines = 2
        }
        subtitle = TextView(this).apply {
            textSize = 30f
            setTextColor(Color.rgb(0xCC, 0xCC, 0xCC))
            maxLines = 2
        }
        column.addView(title)
        column.addView(subtitle)
        row.addView(cover)
        row.addView(column)
        root.addView(row)
        return root
    }

    private fun show(state: PlaybackState) {
        val track = state.current
        val station = state.station
        if (track == null && station == null && state.pendingTitle == null) {
            title?.text = "Dial"
            subtitle?.text = ""
            return
        }
        title?.text = track?.name ?: station?.name ?: state.pendingTitle.orEmpty()
        subtitle?.text = track?.artistLine ?: if (station != null) "Live radio" else ""
        val client = (application as DialApplication).session.client.value
        val url = track?.let { client?.imageUrl(it.imageItemId, 1000) } ?: station?.favicon
        if (url != shownCover) {
            shownCover = url
            val image = cover ?: return
            val request = ImageRequest.Builder(this)
                .data(url)
                .target(onSuccess = { result -> image.setImageDrawable(result.asDrawable(resources)) })
                .build()
            SingletonImageLoader.get(this).enqueue(request)
        }
    }
}
