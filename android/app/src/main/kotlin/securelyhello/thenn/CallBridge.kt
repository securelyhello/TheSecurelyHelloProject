package securelyhello.thenn

import android.app.Activity
import android.app.KeyguardManager
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
 * - showing over the lock screen while a call rings or runs, and then only
 *   while the call screen is what the app shows (security review H1);
 * - dismissing the lock screen (the user unlocks) before the call screen
 *   may be left, and telling Dart whether the phone is locked;
 * - picture-in-picture for video calls when the user leaves the app.
 *
 * MainActivity is the whole app, so showWhenLocked on it would put every
 * chat over the lock screen. The flags are therefore on only while a call
 * rings or runs AND Dart reports the call screen shown ("callScreen"); Dart
 * keeps the call screen from being left until [dismissKeyguard] succeeds.
 */
object CallBridge {
    private const val TAG = "SecurelyHelloCall"
    private var channel: MethodChannel? = null
    private var proximity: PowerManager.WakeLock? = null

    /** Video call running: leaving the app enters picture-in-picture. */
    @Volatile var pipEnabled = false

    /** A call rings or runs. */
    private var callActive = false

    /** Dart shows the call screen (and nothing else) on top. */
    private var callScreenShown = false

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
                            hideContent = call.argument<Boolean>("hideContent") != false,
                        )
                        callActive = true
                        applyLockScreen(activity)
                        result.success(true)
                    }
                    "ringing" -> {
                        callActive = true
                        applyLockScreen(activity)
                        result.success(true)
                    }
                    "stop" -> {
                        OngoingCallService.stop(activity)
                        setProximity(activity, false)
                        callActive = false
                        applyLockScreen(activity)
                        pipEnabled = false
                        result.success(true)
                    }
                    "callScreen" -> {
                        callScreenShown = call.argument<Boolean>("shown") == true
                        applyLockScreen(activity)
                        result.success(null)
                    }
                    "keyguardLocked" -> result.success(isLocked(activity))
                    "dismissKeyguard" -> dismissKeyguard(activity, result)
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
        callScreenShown = false
    }

    private fun isLocked(context: Context): Boolean {
        val km = context.getSystemService(KeyguardManager::class.java) ?: return true
        return km.isKeyguardLocked
    }

    /**
     * Asks the user to unlock; replies true once the lock screen is gone
     * (or wasn't there), false if they cancelled or it can't be dismissed.
     */
    private fun dismissKeyguard(activity: Activity, result: MethodChannel.Result) {
        if (!isLocked(activity)) {
            result.success(true)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(false)
            return
        }
        val km = activity.getSystemService(KeyguardManager::class.java)
        if (km == null) {
            result.success(false)
            return
        }
        activity.runOnUiThread {
            var replied = false
            fun reply(ok: Boolean) {
                if (replied) return
                replied = true
                result.success(ok)
            }
            try {
                km.requestDismissKeyguard(activity, object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() = reply(true)
                    override fun onDismissCancelled() = reply(false)
                    override fun onDismissError() = reply(false)
                })
            } catch (e: Exception) {
                Log.w(TAG, "dismissKeyguard failed", e)
                reply(false)
            }
        }
    }

    /** Over the lock screen only while a call is up on the call screen. */
    private fun applyLockScreen(activity: Activity) {
        setOverLockScreen(activity, callActive && callScreenShown)
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
