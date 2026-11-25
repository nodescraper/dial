package app.dial.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.core.graphics.ColorUtils

/** Dial's cassette orange, the one accent across iPhone, Mac and Android. */
val DialAccent = Color(0xFFE8742C)

private val DarkScheme = darkColorScheme(
    primary = DialAccent,
    onPrimary = Color(0xFF2A1000),
    primaryContainer = Color(0xFF7A3A12),
    onPrimaryContainer = Color(0xFFFFDBC4),
    secondary = Color(0xFFE9B64D),
    onSecondary = Color(0xFF3A2800),
    secondaryContainer = Color(0xFF5A4318),
    onSecondaryContainer = Color(0xFFFFE9B8),
    tertiary = Color(0xFFBCCC9A),
    background = Color(0xFF121212),
    onBackground = Color(0xFFE6E6E6),
    surface = Color(0xFF121212),
    onSurface = Color(0xFFE6E6E6),
    surfaceVariant = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFFA8A8AD),
    surfaceContainerLowest = Color(0xFF0C0C0C),
    surfaceContainerLow = Color(0xFF181818),
    surfaceContainer = Color(0xFF1E1E1E),
    surfaceContainerHigh = Color(0xFF242424),
    surfaceContainerHighest = Color(0xFF2E2E2E),
    outline = Color(0xFF8E8E93),
    outlineVariant = Color(0xFF3A3A3C),
)

private val LightScheme = lightColorScheme(
    primary = Color(0xFFC45A18),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFFFDBC4),
    onPrimaryContainer = Color(0xFF2A1000),
    secondary = Color(0xFF8C6A2A),
    secondaryContainer = Color(0xFFFFE9B8),
    onSecondaryContainer = Color(0xFF3A2800),
    tertiary = Color(0xFF51643F),
    background = Color(0xFFF7F7F8),
    onBackground = Color(0xFF1C1C1E),
    surface = Color(0xFFF7F7F8),
    onSurface = Color(0xFF1C1C1E),
    surfaceVariant = Color(0xFFE5E5EA),
    onSurfaceVariant = Color(0xFF58585C),
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color(0xFFF2F2F4),
    surfaceContainer = Color(0xFFEDEDF0),
    surfaceContainerHigh = Color(0xFFE8E8EB),
    surfaceContainerHighest = Color(0xFFE0E0E4),
    outline = Color(0xFF8E8E93),
    outlineVariant = Color(0xFFD1D1D6),
)

/** The same corner sizes as Dial on iPhone and Mac: 6 for artwork in rows, 12 for tiles and controls, 16 for big artwork. */
private val DialShapes = Shapes(
    extraSmall = RoundedCornerShape(4.dp),
    small = RoundedCornerShape(6.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(16.dp),
    extraLarge = RoundedCornerShape(16.dp),
)

/** Type with the iPhone's weights: bold large titles, semibold titles, regular body. */
private val DialTypography = Typography().let { base ->
    base.copy(
        headlineLarge = base.headlineLarge.copy(fontWeight = FontWeight.Bold),
        headlineMedium = base.headlineMedium.copy(fontWeight = FontWeight.Bold),
        headlineSmall = base.headlineSmall.copy(fontWeight = FontWeight.Bold),
        titleLarge = base.titleLarge.copy(fontWeight = FontWeight.Bold, fontSize = 22.sp),
        titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
        titleSmall = base.titleSmall.copy(fontWeight = FontWeight.SemiBold),
        bodyMedium = base.bodyMedium.copy(fontSize = 15.sp),
        labelMedium = base.labelMedium.copy(fontWeight = FontWeight.Medium),
    )
}

/** Dial's look on Material's plain theme: orange accent, warm brown darks, the iPhone's corners and type. */
@Composable
fun DialTheme(colorScheme: ColorScheme? = null, content: @Composable () -> Unit) {
    val scheme = colorScheme ?: if (isSystemInDarkTheme()) DarkScheme else LightScheme
    MaterialTheme(colorScheme = scheme, shapes = DialShapes, typography = DialTypography, content = content)
}

/** Bottom bar items in Material 3's current style: a soft accent pill behind the selected icon, the accent for icon and label. */
@Composable
fun dialNavigationColors() = NavigationBarItemDefaults.colors(
    selectedIconColor = MaterialTheme.colorScheme.onSurface,
    selectedTextColor = MaterialTheme.colorScheme.onSurface,
    unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
    unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
    indicatorColor = MaterialTheme.colorScheme.surfaceContainerHighest,
)

/**
 * A dark color scheme from an album cover's main color, for the player: the background is a deep
 * shade of the cover, buttons a bright tint of it. Stays readable whatever the cover looks like.
 */
fun schemeFromArtwork(seed: Int): ColorScheme {
    val hsl = FloatArray(3)
    ColorUtils.colorToHSL(seed, hsl)
    val hue = hsl[0]
    val saturation = hsl[1].coerceIn(0.25f, 0.8f)
    fun tone(lightness: Float, sat: Float = saturation) = Color(ColorUtils.HSLToColor(floatArrayOf(hue, sat, lightness)))
    val primary = tone(0.75f)
    return darkColorScheme(
        primary = primary,
        onPrimary = tone(0.12f),
        primaryContainer = tone(0.30f),
        onPrimaryContainer = tone(0.90f),
        secondary = tone(0.80f, saturation * 0.5f),
        secondaryContainer = tone(0.24f, saturation * 0.5f),
        onSecondaryContainer = tone(0.92f, saturation * 0.4f),
        background = tone(0.08f, saturation * 0.6f),
        surface = tone(0.08f, saturation * 0.6f),
        onSurface = Color(0xFFF7F1EA),
        onSurfaceVariant = Color(0xFFF7F1EA).copy(alpha = 0.72f),
        surfaceContainer = tone(0.14f, saturation * 0.6f),
        surfaceContainerHigh = tone(0.18f, saturation * 0.6f),
        surfaceContainerHighest = tone(0.22f, saturation * 0.6f),
        outlineVariant = tone(0.30f, saturation * 0.4f),
    )
}

fun Color.argb(): Int = toArgb()
