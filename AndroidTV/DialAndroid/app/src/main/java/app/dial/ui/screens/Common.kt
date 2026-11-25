package app.dial.ui.screens

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import app.dial.data.JellyfinClient
import app.dial.ui.LocalApp
import app.dial.ui.components.EmptyMessage
import app.dial.ui.components.Loading

sealed interface Load<out T> {
    data object Loading : Load<Nothing>
    data class Ready<T>(val value: T) : Load<T>
    data class Failed(val message: String) : Load<Nothing>
}

/** Loads something from your server for a screen, again whenever [key] changes. */
@Composable
fun <T> rememberLoad(key: Any?, block: suspend (JellyfinClient) -> T): Load<T> {
    val app = LocalApp.current
    val state by produceState<Load<T>>(Load.Loading, key) {
        val client = app.session.client.value
        value = if (client == null) Load.Failed("Not signed in")
        else runCatching { block(client) }.fold({ Load.Ready(it) }, { Load.Failed(it.message ?: "Something went wrong") })
    }
    return state
}

/** Shows the loading indicator, an error, or the content. */
@Composable
fun <T> LoadContent(load: Load<T>, content: @Composable (T) -> Unit) {
    when (load) {
        Load.Loading -> Loading()
        is Load.Failed -> EmptyMessage("Couldn\u2019t load this", load.message)
        is Load.Ready -> content(load.value)
    }
}

@Composable
fun client(): JellyfinClient? = LocalApp.current.session.client.value


/** Asks the Library's big search bar for the cursor (the search icon on Home): [pending] is true until the bar has taken it. */
object SearchFocus {
    val request = kotlinx.coroutines.flow.MutableStateFlow(0)
    @Volatile var pending = false

    fun ask() { pending = true; request.value = request.value + 1 }
}
