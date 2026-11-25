package app.dial

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import app.dial.ui.DialRoot

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Nothing tinted behind the gesture line: the bar below the tabs is the tab bar's own colour.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) window.isNavigationBarContrastEnforced = false
        // Android 13 and later ask before showing the playback notification.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
                .launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        val app = application as DialApplication
        setContent { DialRoot(app) }
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
