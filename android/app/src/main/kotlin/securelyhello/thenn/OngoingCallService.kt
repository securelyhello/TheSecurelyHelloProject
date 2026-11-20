package securelyhello.thenn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps a call going while the app is in the background or the screen is
 * off: a foreground service of type phoneCall | microphone (| camera for
 * video) with an ongoing notification — tap to return to the call, Hang up
 * and Mute without opening the app. Play Store builds must declare these
 * foreground-service types (see server/DEPLOY.md).
 */
class OngoingCallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val video = intent.getBooleanExtra(EXTRA_VIDEO, false)
        val notification = build(
            this,
            name = intent.getStringExtra(EXTRA_NAME) ?: "Call",
            video = video,
            muted = intent.getBooleanExtra(EXTRA_MUTED, false),
            outgoing = intent.getBooleanExtra(EXTRA_OUTGOING, false),
            sinceMs = intent.getLongExtra(EXTRA_SINCE, 0),
            hideContent = intent.getBooleanExtra(EXTRA_HIDE, true),
        )
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (video) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                startForeground(NOTIFICATION_ID, notification, types)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Not allowed from the background (Android 12+) or a permission
            // is missing: show the notification without the service.
            Log.w(TAG, "foreground service refused", e)
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    companion object {
        private const val TAG = "SecurelyHelloCall"
        const val CHANNEL = "calls_ongoing"
        const val NOTIFICATION_ID = 4711
        private const val EXTRA_NAME = "name"
        private const val EXTRA_VIDEO = "video"
        private const val EXTRA_MUTED = "muted"
        private const val EXTRA_OUTGOING = "outgoing"
        private const val EXTRA_SINCE = "since"
        private const val EXTRA_HIDE = "hide_content"
        const val EXTRA_OPEN_CALL = "securelyhello.open_call"

        fun start(
            context: Context,
            name: String,
            video: Boolean,
            muted: Boolean,
            outgoing: Boolean,
            sinceMs: Long,
            hideContent: Boolean,
        ) {
            ensureChannel(context)
            val intent = Intent(context, OngoingCallService::class.java)
                .putExtra(EXTRA_NAME, name)
                .putExtra(EXTRA_VIDEO, video)
                .putExtra(EXTRA_MUTED, muted)
                .putExtra(EXTRA_OUTGOING, outgoing)
                .putExtra(EXTRA_SINCE, sinceMs)
                .putExtra(EXTRA_HIDE, hideContent)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (e: Exception) {
                Log.w(TAG, "call service not started", e)
                context.getSystemService(NotificationManager::class.java)
                    .notify(NOTIFICATION_ID, build(context, name, video, muted, outgoing, sinceMs, hideContent))
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, OngoingCallService::class.java))
            context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) != null) return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Ongoing calls", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "The call you are on, with Hang up and Mute"
                    setSound(null, null)
                    setShowBadge(false)
                },
            )
        }

        private fun build(
            context: Context,
            name: String,
            video: Boolean,
            muted: Boolean,
            outgoing: Boolean,
            sinceMs: Long,
            hideContent: Boolean,
        ): Notification {
            val open = PendingIntent.getActivity(
                context,
                1,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra(EXTRA_OPEN_CALL, true),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            fun action(what: String, code: Int) = PendingIntent.getBroadcast(
                context,
                code,
                Intent(context, CallActionReceiver::class.java).setAction(what),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context).setPriority(Notification.PRIORITY_LOW)
            }
            val kind = if (video) "Video call" else "Voice call"
            builder
                .setSmallIcon(R.drawable.ic_stat_notify)
                // "Hide content" on: not who the call is with (review L4).
                .setContentTitle(if (hideContent) "Ongoing call" else name)
                .setContentText(if (outgoing && sinceMs == 0L) "Calling…" else "$kind · end-to-end encrypted")
                .setContentIntent(open)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_CALL)
                .setVisibility(
                    if (hideContent) Notification.VISIBILITY_PRIVATE else Notification.VISIBILITY_PUBLIC,
                )
                .setOnlyAlertOnce(true)
                .addAction(
                    Notification.Action.Builder(null, if (muted) "Unmute" else "Mute", action(ACTION_MUTE, 2)).build(),
                )
                .addAction(Notification.Action.Builder(null, "Hang up", action(ACTION_HANGUP, 3)).build())
            if (sinceMs > 0) builder.setWhen(sinceMs).setUsesChronometer(true).setShowWhen(true)
            return builder.build()
        }

        const val ACTION_MUTE = "securelyhello.call.MUTE"
        const val ACTION_HANGUP = "securelyhello.call.HANGUP"
    }
}

/** Hang up / Mute from the ongoing-call notification. */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val what = when (intent.action) {
            OngoingCallService.ACTION_HANGUP -> "hangup"
            OngoingCallService.ACTION_MUTE -> "mute"
            else -> return
        }
        if (!CallBridge.send("action", mapOf("action" to what)) && what == "hangup") {
            // The app is gone: nothing to hang up but the notification.
            OngoingCallService.stop(context)
        }
    }
}
