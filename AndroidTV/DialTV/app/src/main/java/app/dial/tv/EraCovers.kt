package app.dial.tv

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Eco
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Headphones
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.NightsStay
import androidx.compose.material.icons.rounded.Park
import androidx.compose.material.icons.rounded.Piano
import androidx.compose.material.icons.rounded.WbSunny
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos
import kotlin.math.sin

private fun hex(value: String) = Color(android.graphics.Color.parseColor(value))

/** How a decade looks on its cover: the colors, lettering and decoration of its time (the same as on iPhone and Mac). */
private enum class Decoration { Deco, Diner, Psychedelic, Seventies, Neon, Memphis, Y2k, Pastel, Now }

private class EraStyle(val background: List<Color>, val ink: Color, val family: FontFamily, val weight: FontWeight,
                       val italic: Boolean, val decoration: Decoration)

private fun eraStyle(decade: Int): EraStyle = when {
    decade < 1950 -> EraStyle(listOf(hex("#13203A"), hex("#0A1226")), hex("#E8C468"), FontFamily.Serif, FontWeight.Bold, false, Decoration.Deco)
    decade < 1960 -> EraStyle(listOf(hex("#F6E7C8"), hex("#EBD3A3")), hex("#C2364A"), FontFamily.Serif, FontWeight.Black, true, Decoration.Diner)
    decade < 1970 -> EraStyle(listOf(hex("#FF7A18"), hex("#E4007C")), hex("#FFF4D6"), FontFamily.SansSerif, FontWeight.Black, false, Decoration.Psychedelic)
    decade < 1980 -> EraStyle(listOf(hex("#5B2A12"), hex("#3E1B0B")), hex("#F7E3B5"), FontFamily.SansSerif, FontWeight.ExtraBold, false, Decoration.Seventies)
    decade < 1990 -> EraStyle(listOf(hex("#1B0B3A"), hex("#4A1068")), Color.White, FontFamily.Default, FontWeight.Black, true, Decoration.Neon)
    decade < 2000 -> EraStyle(listOf(hex("#00A7B5"), hex("#007E8C")), hex("#FFE14D"), FontFamily.Monospace, FontWeight.Black, false, Decoration.Memphis)
    decade < 2010 -> EraStyle(listOf(hex("#C9DCFF"), hex("#5C7FE0")), Color.White, FontFamily.SansSerif, FontWeight.Bold, false, Decoration.Y2k)
    decade < 2020 -> EraStyle(listOf(hex("#FFD9E2"), hex("#C9B8FF")), hex("#2B2350"), FontFamily.Default, FontWeight.Light, false, Decoration.Pastel)
    else -> EraStyle(listOf(hex("#0E1B2C"), hex("#1D5B6B")), Color.White, FontFamily.Default, FontWeight.SemiBold, false, Decoration.Now)
}

private fun decadeLabel(decade: Int) = if (decade >= 2000) "${decade}s" else "${decade % 100}s"

/** A decade as a poster of its time, drawn relative to its size. */
@Composable
fun EraCover(decade: Int, modifier: Modifier = Modifier, corner: Dp = 12.dp) {
    val style = eraStyle(decade)
    val label = decadeLabel(decade)
    BoxWithConstraints(modifier.aspectRatio(1f).clip(RoundedCornerShape(corner))) {
        val width = maxWidth
        Canvas(Modifier.fillMaxSize()) {
            drawRect(Brush.verticalGradient(style.background))
            decorate(style.decoration)
        }
        val shadow = when (style.decoration) {
            Decoration.Neon -> Shadow(hex("#FF3CAC"), Offset.Zero, width.value * 0.9f)
            Decoration.Y2k -> Shadow(hex("#2B4BB5").copy(alpha = 0.55f), Offset(width.value * 0.012f * 3, width.value * 0.012f * 3), 0f)
            Decoration.Seventies -> Shadow(hex("#E0701A"), Offset(width.value * 0.018f * 3, width.value * 0.018f * 3), 0f)
            Decoration.Memphis -> Shadow(hex("#E83E8C"), Offset(width.value * 0.02f * 3, width.value * 0.02f * 3), 0f)
            else -> null
        }
        Text(label, maxLines = 1, overflow = TextOverflow.Clip, color = style.ink,
            style = TextStyle(fontFamily = style.family, fontWeight = style.weight,
                fontStyle = if (style.italic) FontStyle.Italic else FontStyle.Normal,
                fontSize = (width.value * (if (label.length > 3) 0.27f else 0.36f)).sp, shadow = shadow),
            modifier = Modifier.align(Alignment.TopStart).padding(width * 0.08f))
    }
}

private fun DrawScope.decorate(kind: Decoration) {
    val w = size.width
    val h = size.height
    when (kind) {
        Decoration.Seventies -> {
            // Rainbow arcs rising from the bottom-right corner: mustard, orange, rust, cream.
            val colors = listOf("#F2B531", "#E0701A", "#B8431C", "#F7E3B5").map(::hex)
            val band = w * 0.075f
            colors.forEachIndexed { index, color ->
                val radius = w * 0.88f - index * band
                drawArc(color, 180f, 90f, false, Offset(w - radius, h - radius), Size(radius * 2, radius * 2), style = Stroke(band * 0.85f))
            }
            drawCircle(hex("#F2B531"), w * 0.155f, Offset(w * 0.845f, h * 0.845f))
        }
        Decoration.Neon -> {
            val horizon = h * 0.64f
            val sunTop = h * 0.30f
            val sunSize = w * 0.5f
            clipRect(0f, 0f, w, horizon) {
                drawCircle(Brush.verticalGradient(listOf(hex("#FFE14D"), hex("#FF3CAC")), sunTop, sunTop + sunSize),
                    sunSize / 2, Offset(w / 2, sunTop + sunSize / 2))
                for (index in 0 until 5) {
                    val y = sunTop + sunSize / 2 + index * w * 0.045f
                    drawRect(hex("#2A0F4F"), Offset(0f, y), Size(w, w * 0.012f + index * w * 0.006f))
                }
            }
            val grid = hex("#2DE2E6")
            drawLine(grid.copy(alpha = 0.85f), Offset(0f, horizon), Offset(w, horizon), w * 0.006f)
            for (index in 1..5) {
                val t = (index / 5f) * (index / 5f)
                val y = horizon + (h - horizon) * t
                drawLine(grid.copy(alpha = 0.6f), Offset(0f, y), Offset(w, y), w * 0.005f)
            }
            for (index in -6..6) {
                drawLine(grid.copy(alpha = 0.6f), Offset(w / 2 + index * w * 0.03f, horizon), Offset(w / 2 + index * w * 0.28f, h), w * 0.005f)
            }
        }
        Decoration.Psychedelic -> {
            val colors = listOf("#E4007C", "#FF7A18", "#FFD23F", "#6A1B9A", "#E4007C").map(::hex)
            colors.forEachIndexed { index, color ->
                drawCircle(color.copy(alpha = 0.9f), w * (0.78f - index * 0.15f), Offset(w * 0.78f, h * 0.82f))
            }
        }
        Decoration.Diner -> {
            val teal = hex("#2A9D8F").copy(alpha = 0.55f)
            val center = Offset(w / 2, -h * 0.1f)
            for (index in 0 until 14 step 2) {
                val a0 = Math.toRadians(index * 180.0 / 14).toFloat()
                val a1 = Math.toRadians((index + 1) * 180.0 / 14).toFloat()
                val ray = Path().apply {
                    moveTo(center.x, center.y)
                    lineTo(center.x + cos(a0) * w * 2, center.y + sin(a0) * w * 2)
                    lineTo(center.x + cos(a1) * w * 2, center.y + sin(a1) * w * 2)
                    close()
                }
                drawPath(ray, teal)
            }
            drawRect(hex("#C2364A"), Offset(0f, h * 0.82f), Size(w, h * 0.18f))
            drawRect(hex("#FFF4D6"), Offset(0f, h * 0.80f), Size(w, h * 0.02f))
        }
        Decoration.Deco -> {
            val gold = hex("#E8C468")
            val center = Offset(w / 2, h * 1.05f)
            for (index in 0..8) {
                val angle = Math.toRadians(200.0 + index * 17.5).toFloat()
                drawLine(gold.copy(alpha = 0.75f), center, Offset(center.x + cos(angle) * w, center.y + sin(angle) * w), w * 0.01f)
            }
            for (index in 1..3) {
                val radius = w * 0.2f * index
                drawArc(gold.copy(alpha = 0.8f), 180f, 180f, false, Offset(center.x - radius, center.y - radius), Size(radius * 2, radius * 2), style = Stroke(w * 0.012f))
            }
        }
        Decoration.Memphis -> {
            drawCircle(hex("#E83E8C"), w * 0.13f, Offset(w * 0.75f, h * 0.58f + w * 0.13f))
            val triangle = Path().apply {
                moveTo(w * 0.1f, h * 0.9f); lineTo(w * 0.34f, h * 0.9f); lineTo(w * 0.22f, h * 0.66f); close()
            }
            drawPath(triangle, hex("#5B2C9F"))
            val squiggle = Path().apply {
                moveTo(w * 0.42f, h * 0.76f)
                for (step in 0 until 5) {
                    val x = w * (0.42f + 0.1f * step)
                    quadraticTo(x + w * 0.05f, h * (if (step % 2 == 0) 0.68f else 0.84f), x + w * 0.1f, h * 0.76f)
                }
            }
            drawPath(squiggle, hex("#FFE14D"), style = Stroke(w * 0.026f, cap = androidx.compose.ui.graphics.StrokeCap.Round))
            for ((x, y) in listOf(0.82f to 0.2f, 0.9f to 0.32f, 0.74f to 0.36f)) drawCircle(hex("#FFE14D"), w * 0.02f, Offset(w * x, h * y))
        }
        Decoration.Y2k -> {
            val center = Offset(w * 0.73f, h * 0.71f)
            drawCircle(Brush.radialGradient(listOf(Color.White, hex("#8FB0FF"), hex("#2B4BB5")),
                Offset(center.x - w * 0.1f, center.y - w * 0.12f), w * 0.5f), w * 0.31f, center)
            for ((x, y, s) in listOf(Triple(0.12f, 0.62f, 0.1f), Triple(0.26f, 0.84f, 0.06f), Triple(0.9f, 0.32f, 0.07f))) {
                val c = Offset(w * x, h * y)
                val r = w * s
                val star = Path().apply {
                    moveTo(c.x, c.y - r); quadraticTo(c.x, c.y, c.x + r, c.y); quadraticTo(c.x, c.y, c.x, c.y + r)
                    quadraticTo(c.x, c.y, c.x - r, c.y); quadraticTo(c.x, c.y, c.x, c.y - r)
                }
                drawPath(star, Color.White.copy(alpha = 0.9f))
            }
        }
        Decoration.Pastel -> {
            drawCircle(Color.White.copy(alpha = 0.55f), w * 0.31f, Offset(w * 0.81f, h * 0.76f))
            drawCircle(hex("#FFB3C7").copy(alpha = 0.55f), w * 0.25f, Offset(w * 0.35f, h * 0.8f))
            drawCircle(hex("#A8C8FF").copy(alpha = 0.55f), w * 0.275f, Offset(w * 0.825f, h * 0.895f))
        }
        Decoration.Now -> {
            drawCircle(Brush.radialGradient(listOf(hex("#2FD4A6").copy(alpha = 0.8f), Color.Transparent), Offset(w * 0.75f, h * 0.8f), w * 0.55f),
                w * 0.45f, Offset(w * 0.75f, h * 0.8f))
            drawCircle(Brush.radialGradient(listOf(hex("#5B7CFF").copy(alpha = 0.7f), Color.Transparent), Offset(w * 0.15f, h * 0.95f), w * 0.5f),
                w * 0.4f, Offset(w * 0.2f, h * 0.9f))
        }
    }
}

/** A genre: its colors, a big faded symbol that suits it, and its name in a heavy face. */
@Composable
fun GenreCover(title: String, palette: List<String>, modifier: Modifier = Modifier, corner: Dp = 12.dp) {
    val name = title.lowercase()
    val table: List<Pair<String, ImageVector>> = listOf(
        "hip" to Icons.Rounded.Headphones, "rap" to Icons.Rounded.Headphones, "rock" to Icons.Rounded.Bolt, "metal" to Icons.Rounded.Bolt,
        "punk" to Icons.Rounded.Bolt, "jazz" to Icons.Rounded.MusicNote, "blues" to Icons.Rounded.MusicNote, "electronic" to Icons.Rounded.GraphicEq,
        "dance" to Icons.Rounded.GraphicEq, "house" to Icons.Rounded.GraphicEq, "pop" to Icons.Rounded.AutoAwesome, "classical" to Icons.Rounded.Piano,
        "folk" to Icons.Rounded.Park, "country" to Icons.Rounded.Park, "soul" to Icons.Rounded.Favorite, "r&b" to Icons.Rounded.Favorite,
        "latin" to Icons.Rounded.LocalFireDepartment, "reggae" to Icons.Rounded.WbSunny, "ambient" to Icons.Rounded.NightsStay,
        "indie" to Icons.Rounded.Eco, "alternative" to Icons.Rounded.Eco, "funk" to Icons.Rounded.MusicNote,
    )
    val icon = table.firstOrNull { name.contains(it.first) }?.second ?: Icons.Rounded.MusicNote
    val colors = palette.map(::hex).ifEmpty { listOf(Color.DarkGray, Color.Black) }
    BoxWithConstraints(modifier.aspectRatio(1f).clip(RoundedCornerShape(corner)).background(Brush.linearGradient(colors))) {
        val width = maxWidth
        Icon(icon, null, tint = Color.White.copy(alpha = 0.18f),
            modifier = Modifier.align(Alignment.TopEnd).padding(top = width * 0.02f).size(width * 0.62f).rotate(-12f))
        Text(title, maxLines = 2, overflow = TextOverflow.Ellipsis, color = Color.White,
            style = TextStyle(fontWeight = FontWeight.ExtraBold, fontSize = (width.value * 0.17f).sp),
            modifier = Modifier.align(Alignment.BottomStart).padding(width * 0.08f))
    }
}
