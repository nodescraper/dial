package app.dial.playback

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebView
import org.json.JSONObject

/**
 * One long-lived YouTube player page, for the live streams that only exist on YouTube (Lofi Girl). It has to be in the window
 * to play, so the app root keeps it there, small and nearly clear (see `DialRoot`).
 */
object YouTubeEmbed {
    private const val TAG = "DialYouTube"
    private val main = Handler(Looper.getMainLooper())
    private var webView: WebView? = null
    private var ready = false
    private var pendingId: String? = null
    private var active = false

    /** Playing or not, and whether it is buffering, as the page reports it. */
    var onState: ((playing: Boolean, buffering: Boolean) -> Unit)? = null
    /** YouTube's error code when it refuses to play a stream. */
    var onError: ((Int) -> Unit)? = null

    // The page believes it is always on screen, so it carries on when the app is in the background.
    private const val PAGE = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:#000;height:100%}#p{width:100%;height:100%}</style>
        <script>
        Object.defineProperty(document,'hidden',{get:function(){return false}});
        Object.defineProperty(document,'visibilityState',{get:function(){return 'visible'}});
        document.addEventListener('visibilitychange',function(e){e.stopImmediatePropagation()},true);
        </script></head>
        <body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function post(m){ DialBridge.post(JSON.stringify(m)) }
        window.onerror = function(m){ post({t:'js', m:String(m)}) };
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('p', {width:'100%', height:'100%',
            playerVars:{playsinline:1, controls:0, autoplay:1, mute:1, rel:0, modestbranding:1, fs:0},
            events:{onReady:function(){ post({t:'ready'}) },
                    onStateChange:function(e){ if(e.data===1 && player.isMuted()){ player.unMute(); player.setVolume(100) } post({t:'state', s:e.data}) },
                    onError:function(e){ post({t:'error', c:e.data}) }}});
        }
        function load(id){ if(player && player.loadVideoById) player.loadVideoById(id); }
        function play(){ if(player) player.playVideo() }
        function pause(){ if(player) player.pauseVideo() }
        function stop(){ if(player) player.stopVideo() }
        </script></body></html>
    """

    private class Bridge {
        @JavascriptInterface
        fun post(json: String) { main.post { handle(json) } }
    }

    private fun handle(json: String) {
        val message = runCatching { JSONObject(json) }.getOrNull() ?: return
        val kind = message.optString("t")
        Log.i(TAG, json)
        when (kind) {
            "ready" -> { ready = true; pendingId?.let { run("load('$it')") } }
            "state" -> if (active) {
                val state = message.optInt("s", -2)
                onState?.invoke(state == 1 || state == 3, state == 3)
            }
            "error" -> if (active) onError?.invoke(message.optInt("c", -1))
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    fun view(context: Context): WebView {
        webView?.let { existing ->
            (existing.parent as? ViewGroup)?.removeView(existing)
            return existing
        }
        val created = WebView(context.applicationContext).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            addJavascriptInterface(Bridge(), "DialBridge")
            setBackgroundColor(0)
            loadDataWithBaseURL("http://localhost", PAGE, "text/html", "utf-8", null)
        }
        webView = created
        return created
    }

    fun load(context: Context, id: String) {
        view(context) // makes sure the page exists, even before the app root has shown it
        active = true
        pendingId = id
        if (ready) run("load('$id')")
    }

    fun play() = run("play()")
    fun pause() = run("pause()")

    fun stop() {
        if (!active) return
        active = false
        pendingId = null
        run("stop()")
    }

    private fun run(script: String) { main.post { webView?.evaluateJavascript(script, null) } }
}
