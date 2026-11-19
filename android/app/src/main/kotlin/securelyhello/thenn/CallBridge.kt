package securelyhello.thenn

import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The Android side of calls (lib/core/calls/call_system.dart):
 *
 * - a foreground service (phoneCall | microphone | camera) with an ongoing
 *   notification, so a call keeps going in the background or with the
 *   screen off ([OngoingCallService]);
 * - Hang up / Mute from that notification, back to Dart as "action";
 * - the proximity sensor turns the screen off at the ear on voice calls;
 * - showing over the lock screen while a call rings or runs;
 * - picture-in-picture for video calls when the user leaves the app.
 */
object CallBridge {
    private const val TAG = "SecurelyHelloCall"
    private var channel: MethodChannel? = null
    private var proximity: PowerManager.WakeLock? = null

    /** Video call running: leaving the app enters picture-in-picture. */
    @Volatile var pipEnabled = false

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, "securelyhello/call")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "ongoing" -> {
                        OngoingCallService.start(
                            activity,
                            name = call.argument<String>("name") ?: "Call",
                            video = call.argument<Boolean>("video") == true,
                            muted = call.argument<Boolean>("muted") == true,
                            outgoing = call.argument<Boolean>("outgoing") == true,
                            sinceMs = (call.argument<Number>("since") ?: 0).toLong(),
                        )
                        setOverLockScreen(activity, true)
                        result.success(true)
                    }
                    "ringing" -> {
                        setOverLockScreen(activity, true)
                        result.success(true)
                    }
                    "stop" -> {
                        OngoingCallService.stop(activity)
                        setProximity(activity, false)
                        setOverLockScreen(activity, false)
                        pipEnabled = false
                        result.success(true)
                    }
                    "proximity" -> {
                        setProximity(activity, call.argument<Boolean>("on") == true)
                        result.success(null)
                    }
                    "pip" -> {
                        pipEnabled = call.argument<Boolean>("enabled") == true
                        result.success(null)
                    }
                    "canFullScreen" -> result.success(canUseFullScreenIntent(activity))
                    "openFullScreenSettings" -> {
                        if (Build.VERSION.SDK_INT >= 34) {
                            activity.startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                    Uri.parse("package:${activity.packageName}"),
                                ),
                            )
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.w(TAG, "call ${call.method} failed", e)
                result.error("call", e.message, null)
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /** Sends [action] ("hangup", "mute", "open", "pip:on"…) to Dart. */
    fun send(method: String, args: Map<String, Any?>): Boolean {
        val ch = channel ?: return false
        ch.invokeMethod(method, args)
        return true
    }

    fun canUseFullScreenIntent(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val nm = context.getSystemService(NotificationManager::class.java)
        return nm.canUseFullScreenIntent()
    }

    private fun setOverLockScreen(activity: Activity, on: Boolean) {
        activity.runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                activity.setShowWhenLocked(on)
                activity.setTurnScreenOn(on)
            } else {
                @Suppress("DEPRECATION")
                val flags = android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                if (on) activity.window.addFlags(flags) else activity.window.clearFlags(flags)
            }
        }
    }

    private fun setProximity(context: Context, on: Boolean) {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (on) {
            if (proximity?.isHeld == true) return
            if (!pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) return
            proximity = pm.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "securelyhello:proximity").also {
                it.acquire(4 * 60 * 60 * 1000L)
            }
        } else {
            proximity?.let { if (it.isHeld) it.release() }
            proximity = null
        }
    }
}
