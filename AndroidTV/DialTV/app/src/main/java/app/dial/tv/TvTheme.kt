package app.dial.tv

import coil3.request.allowHardware
import coil3.toBitmap
import androidx.compose.ui.unit.Density
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage

/** Dial's cassette orange accent, also the focus color on a TV. */
val Accent = Color(0xFFE8742C)

/** Sizes from DESIGN.md: a 960 x 540 dp canvas, 48 dp side margins, nothing under 14 sp. */
object Tv {
    /** Everything on a TV is drawn at 70% of the size the designs were first made at (sizes and text together). */
    const val scale = 0.7f
    val marginX = 48.dp
    val marginTop = 28.dp
    val gap = 16.dp
    val coverWidth = 118.dp
    val radius = 12.dp
}

/** The same dark as the iPhone and Mac in dark mode: true black, with neutral greys for surfaces. The orange is only the accent. */
private val TvColors = darkColorScheme(
    primary = Accent, onPrimary = Color(0xFF2A1000),
    background = Color(0xFF000000), onBackground = Color(0xFFFFFFFF),
    surface = Color(0xFF1C1C1E), onSurface = Color(0xFFFFFFFF),
    surfaceVariant = Color(0xFF2C2C2E), onSurfaceVariant = Color(0xFFB4B4BC),
)

/**
 * Dial's own type, the same hierarchy as on iPhone and Android (bold screen titles, bold section headings, semibold card
 * titles), scaled up about 1.25x for a screen watched from the couch. Only the size changes, not the look.
 */
private val TvType = Typography(
    displayMedium = androidx.compose.ui.text.TextStyle(fontSize = 40.sp, fontWeight = FontWeight.Bold, lineHeight = 46.sp),
    headlineMedium = androidx.compose.ui.text.TextStyle(fontSize = 26.sp, fontWeight = FontWeight.Bold, lineHeight = 32.sp),
    titleLarge = androidx.compose.ui.text.TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
    titleMedium = androidx.compose.ui.text.TextStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold),
    bodyLarge = androidx.compose.ui.text.TextStyle(fontSize = 18.sp, fontWeight = FontWeight.Normal),
    bodyMedium = androidx.compose.ui.text.TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Normal),
    labelLarge = androidx.compose.ui.text.TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
    labelMedium = androidx.compose.ui.text.TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Normal),
)

@Composable
fun TvTheme(content: @Composable () -> Unit) {
    val density = LocalDensity.current
    CompositionLocalProvider(LocalDensity provides Density(density.density * Tv.scale, density.fontScale)) {
    MaterialTheme(colorScheme = TvColors, typography = TvType) {
        // Without this, text has no color of its own and comes out black on the dark background.
        androidx.compose.material3.Surface(color = MaterialTheme.colorScheme.background, contentColor = MaterialTheme.colorScheme.onBackground, content = content)
    }
    }
}

/** The focus outline: a 3 dp accent-colored border and nothing else (no growing, no motion). */
@Composable
fun Modifier.tvFocus(shape: Shape = RoundedCornerShape(Tv.radius), onFocus: () -> Unit = {}): Modifier {
    var focused by remember { mutableStateOf(false) }
    return this
        .onFocusChanged {
            val now = it.isFocused || it.hasFocus
            if (now && !focused) onFocus()
            focused = now
        }
        .then(if (focused) Modifier.border(3.dp, Accent, shape) else Modifier)
}

/** A square cover with a title and one line under it. The standard card of Home, Radio and Library. */
@Composable
fun CoverCard(title: String, subtitle: String?, imageUrl: String?, modifier: Modifier = Modifier, width: Dp = Tv.coverWidth,
              onFocus: () -> Unit = {}, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Tv.radius)
    val stage = LocalTvStage.current
    Column(modifier.width(width)) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).tvFocus(shape) { stage.show(TvStage(title, subtitle ?: "", backdropOf(imageUrl))); onFocus() }
            .clip(shape).clickable(onClick = onClick)) {
            AsyncImage(imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        }
        Text(title, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 8.dp))
        if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * Two colors taken from a cover, for the now-playing chip: the same idea as the phone player's background (the cover's main
 * color as a deep shade). null until the cover has been read.
 */
@Composable
fun rememberArtworkColors(url: String?): List<Color>? {
    val context = androidx.compose.ui.platform.LocalContext.current
    val colors by androidx.compose.runtime.produceState<List<Color>?>(null, url) {
        if (url == null) { value = null; return@produceState }
        val result = coil3.SingletonImageLoader.get(context).execute(
            coil3.request.ImageRequest.Builder(context).data(url).allowHardware(false).size(96).build())
        val bitmap = (result as? coil3.request.SuccessResult)?.image?.toBitmap() ?: return@produceState
        val palette = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) { androidx.palette.graphics.Palette.from(bitmap).generate() }
        val seed = palette.getVibrantColor(palette.getDominantColor(0xFFE8742C.toInt()))
        val hsl = FloatArray(3)
        androidx.core.graphics.ColorUtils.colorToHSL(seed, hsl)
        val saturation = hsl[1].coerceIn(0.25f, 0.8f)
        fun tone(lightness: Float, sat: Float) = Color(androidx.core.graphics.ColorUtils.HSLToColor(floatArrayOf(hsl[0], sat, lightness)))
        value = listOf(tone(0.34f, saturation), tone(0.14f, saturation * 0.6f))
    }
    return colors
}
