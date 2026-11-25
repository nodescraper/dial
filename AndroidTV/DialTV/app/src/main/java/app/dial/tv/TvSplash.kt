package app.dial.tv

import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.dial.R
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.crossfade
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay

/** What the splash waits for. Set once per launch, so the splash only shows at start. */
object TvBoot {
    var homeReady by mutableStateOf(false)
    /** Home's covers are in the image cache. */
    var coversReady by mutableStateOf(false)
    var coversTotal by mutableStateOf(0)
    var coversDone by mutableStateOf(0)
}

private const val PREFS = "dial.tv"
private const val KEY_LONG_STARTUP = "longStartup"

/** Whether the startup screen waits for Home's covers too (on by default; Settings turns it off). */
fun longStartupEnabled(context: Context): Boolean =
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_LONG_STARTUP, true)

fun setLongStartup(context: Context, on: Boolean) {
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_LONG_STARTUP, on).apply()
}

/**
 * Loads these covers into the image cache, a few at a time, so Home's rows appear with their pictures.
 * The splash counts them while it waits.
 */
suspend fun warmCovers(context: Context, urls: List<String>) {
    val loader: ImageLoader = SingletonImageLoader.get(context)
    TvBoot.coversTotal = urls.size
    TvBoot.coversDone = 0
    coroutineScope {
        urls.distinct().chunked(6).forEach { batch ->
            batch.map { url ->
                async {
                    runCatching { loader.execute(ImageRequest.Builder(context).data(url).crossfade(false).build()) }
                    TvBoot.coversDone++
                }
            }.awaitAll()
        }
    }
    TvBoot.coversReady = true
}

/**
 * The splash over the app while Home loads. With the longer startup on, it also stays until Home's covers are cached
 * (so the first start does not show empty tiles). It fades out when ready, and by the cap at the latest, so a slow or
 * unreachable server never keeps it up.
 */
@Composable
fun TvSplashGate(signedIn: Boolean) {
    val context = LocalContext.current
    val long = remember { longStartupEnabled(context) }
    var capped by remember { mutableStateOf(false) }
    LaunchedEffect(signedIn) {
        if (signedIn) { delay(if (long) LONG_CAP_MS else CAP_MS); capped = true }
    }
    val ready = TvBoot.homeReady && (!long || TvBoot.coversReady)
    val showing = signedIn && !ready && !capped
    AnimatedVisibility(visible = showing, exit = fadeOut(tween(350))) { TvSplash(long) }
}

private const val CAP_MS = 8000L
private const val LONG_CAP_MS = 45000L

@Composable
private fun TvSplash(long: Boolean) {
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Image(painterResource(R.drawable.ic_launcher_foreground), "Dial",
                Modifier.size(120.dp).clip(RoundedCornerShape(26.dp)).background(Color(0xFF1B1030)))
            Text("Dial", style = MaterialTheme.typography.headlineMedium)
            CircularProgressIndicator(Modifier.size(28.dp), color = MaterialTheme.colorScheme.primary, strokeWidth = 3.dp)
            if (long && TvBoot.homeReady && TvBoot.coversTotal > 0) {
                Text("Getting your covers ready: ${TvBoot.coversDone} of ${TvBoot.coversTotal}",
                    style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
