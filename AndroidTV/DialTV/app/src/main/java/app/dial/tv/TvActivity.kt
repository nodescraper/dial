package app.dial.tv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import app.dial.DialApplication

/** The one screen of Dial for TV. */
class TvActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as DialApplication
        TvRecents.init(this)
        setContent { TvTheme { TvRoot(app) } }
    }

    override fun onStart() {
        super.onStart()
        runCatching { (application as DialApplication).remote.setInBackground(false) }
    }

    override fun onStop() {
        runCatching { (application as DialApplication).remote.setInBackground(true) }
        super.onStop()
    }
}
