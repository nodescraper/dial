package app.dial.tv

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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.dial.R
import kotlinx.coroutines.delay

/** Whether Home's first things have arrived. Set once per launch, so the splash only shows at start. */
object TvBoot {
    var homeReady by mutableStateOf(false)
}

/**
 * The splash over the app while Home's data loads, so the rows don't pop in one by one. It fades out when Home is ready,
 * and by [CAP_MS] at the latest, so a slow or unreachable server never keeps it up.
 */
@Composable
fun TvSplashGate(signedIn: Boolean) {
    var capped by remember { mutableStateOf(false) }
    LaunchedEffect(signedIn) {
        if (signedIn) { delay(CAP_MS); capped = true }
    }
    val showing = signedIn && !TvBoot.homeReady && !capped
    AnimatedVisibility(visible = showing, exit = fadeOut(tween(350))) { TvSplash() }
}

private const val CAP_MS = 8000L

@Composable
private fun TvSplash() {
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Image(painterResource(R.drawable.ic_launcher_foreground), "Dial",
                Modifier.size(120.dp).clip(RoundedCornerShape(26.dp)).background(Color(0xFF1B1030)))
            Text("Dial", style = MaterialTheme.typography.headlineMedium)
            CircularProgressIndicator(Modifier.size(28.dp), color = MaterialTheme.colorScheme.primary, strokeWidth = 3.dp)
        }
    }
}
