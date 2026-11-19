package securelyhello.thenn

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity is required by local_auth (biometric prompt).
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        UpdaterChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        CallBridge.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        // Screen security: blocks screenshots, recordings and the recents thumbnail.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "securelyhello/screen")
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        CallBridge.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        openCallIfAsked(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        openCallIfAsked(intent)
    }

    /** The ongoing-call notification was tapped: show the call. */
    private fun openCallIfAsked(intent: Intent?) {
        if (intent?.getBooleanExtra(OngoingCallService.EXTRA_OPEN_CALL, false) == true) {
            CallBridge.send("action", mapOf("action" to "open"))
        }
    }

    /** Leaving the app during a video call: keep it in a small window. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (CallBridge.pipEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                enterPictureInPictureMode(
                    PictureInPictureParams.Builder().setAspectRatio(Rational(9, 16)).build(),
                )
            } catch (_: Exception) {
                // Picture-in-picture turned off for this app.
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        CallBridge.send("pip", mapOf("on" to isInPictureInPictureMode))
    }
}
