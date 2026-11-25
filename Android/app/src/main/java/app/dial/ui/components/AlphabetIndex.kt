package app.dial.ui.components

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.Normalizer

/** Groups a sorted list under A to Z (and #), the way the iPhone's lists do. "The Weeknd" is filed under W. */
object AlphaGroups {
    val letters: List<String> = ('A'..'Z').map { it.toString() } + "#"

    fun letter(name: String): String {
        var text = Normalizer.normalize(name, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase().trim()
        for (article in listOf("the ", "a ", "an ")) if (text.startsWith(article) && text.length > article.length + 1) { text = text.drop(article.length); break }
        val first = text.firstOrNull { it.isLetterOrDigit() } ?: return "#"
        val letter = first.uppercaseChar().toString()
        return if (letter in letters && letter != "#") letter else "#"
    }

    /** The items under their letters, A to Z and then #, keeping the order they came in within each letter. */
    fun <T> group(items: List<T>, name: (T) -> String): List<Pair<String, List<T>>> {
        val buckets = items.groupBy { letter(name(it)) }
        return letters.mapNotNull { l -> buckets[l]?.let { l to it } }
    }

    /** Where each letter's header sits in a list that shows a header and then the items of every group. */
    fun <T> positions(groups: List<Pair<String, List<T>>>, itemsPerRow: Int = 1): Map<String, Int> {
        var position = 0
        val map = LinkedHashMap<String, Int>()
        for ((letter, items) in groups) { map[letter] = position; position += 1 + items.size }
        return map
    }
}

/** The letters down the right edge: touch or drag along them to jump through a long list. */
@Composable
fun AlphabetIndexBar(available: Set<String>, onSelect: (String) -> Unit, modifier: Modifier = Modifier) {
    val rowHeight = 14.dp
    val density = LocalDensity.current
    val rowPx = with(density) { rowHeight.toPx() }
    Column(modifier.padding(end = 2.dp).width(22.dp).pointerInput(available) {
        awaitEachGesture {
            var last: String? = null
            fun handle(y: Float) {
                val index = (y / rowPx).toInt().coerceIn(0, AlphaGroups.letters.size - 1)
                // A letter with nothing under it jumps to the next one that has something.
                val target = AlphaGroups.letters.drop(index).firstOrNull { it in available } ?: AlphaGroups.letters.take(index).lastOrNull { it in available }
                if (target != null && target != last) { last = target; onSelect(target) }
            }
            val down = awaitFirstDown()
            handle(down.position.y)
            do {
                val event = awaitPointerEvent()
                event.changes.firstOrNull()?.let { handle(it.position.y); it.consume() }
            } while (event.changes.any { it.pressed })
        }
    }, horizontalAlignment = Alignment.CenterHorizontally) {
        AlphaGroups.letters.forEach { letter ->
            Text(letter, Modifier.height(rowHeight), fontSize = 10.sp, fontWeight = FontWeight.Bold,
                color = if (letter in available) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f))
        }
    }
}
