package securelyhello.thenn

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * The native half of the in-app updater (lib/core/update/app_updater.dart):
 * reads version and signing certificate of the installed app and of a
 * downloaded APK, and installs an APK through PackageInstaller. The Dart
 * side decides whether to install; [install] repeats the package and
 * certificate check so nothing else can be installed through this channel.
 */
class UpdaterChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "securelyhello/updater")

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> result.success(describe(installedInfo()))
                    "apkInfo" -> {
                        val info = archiveInfo(call.argument<String>("path")!!)
                        if (info == null) result.error("bad_apk", "Not a readable APK", null)
                        else result.success(describe(info))
                    }
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            activity.packageManager.canRequestPackageInstalls(),
                    )
                    "openInstallSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            activity.startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:${activity.packageName}"),
                                ),
                            )
                        }
                        result.success(null)
                    }
                    "install" -> result.success(install(call.argument<String>("path")!!))
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.w(TAG, "updater ${call.method} failed", e)
                result.error("updater", e.message, null)
            }
        }
    }

    private fun installedInfo(): PackageInfo {
        val pm = activity.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageInfo(activity.packageName, PackageManager.PackageInfoFlags.of(signingFlag().toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(activity.packageName, signingFlag())
        }
    }

    private fun archiveInfo(path: String): PackageInfo? {
        val pm = activity.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(signingFlag().toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageArchiveInfo(path, signingFlag())
        }
    }

    @Suppress("DEPRECATION")
    private fun signingFlag(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES
        else PackageManager.GET_SIGNATURES

    private fun describe(info: PackageInfo): Map<String, Any?> = mapOf(
        "packageName" to info.packageName,
        "versionCode" to versionCode(info),
        "versionName" to info.versionName,
        "certSha256" to certSha256(info),
    )

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    /** SHA-256 of the signing certificate as AA:BB:…, or null if it has more than one. */
    @Suppress("DEPRECATION")
    private fun certSha256(info: PackageInfo): String? {
        val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val s = info.signingInfo ?: return null
            if (s.hasMultipleSigners()) return null
            s.signingCertificateHistory
        } else {
            info.signatures
        } ?: return null
        // With key rotation the current certificate is the last one.
        val cert = sigs.lastOrNull() ?: return null
        return MessageDigest.getInstance("SHA-256").digest(cert.toByteArray())
            .joinToString(":") { "%02X".format(it) }
    }

    private fun install(path: String): Boolean {
        val file = File(path)
        val apk = archiveInfo(path) ?: return false
        val own = installedInfo()
        if (apk.packageName != own.packageName ||
            versionCode(apk) <= versionCode(own) ||
            certSha256(apk) == null ||
            certSha256(apk) != certSha256(own)
        ) {
            Log.w(TAG, "refusing to install ${apk.packageName} ${versionCode(apk)}")
            return false
        }
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(own.packageName)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("securelyhello.apk", 0, file.length()).use { out ->
                file.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val intent = Intent(activity, InstallResultReceiver::class.java)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
            val pending = PendingIntent.getBroadcast(activity, id, intent, flags)
            session.commit(pending.intentSender)
        }
        return true
    }

    companion object {
        private const val TAG = "SecurelyHelloUpdater"
    }
}

/** Shows Android's install confirmation, which PackageInstaller asks for. */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (confirm != null) context.startActivity(confirm)
            }
            PackageInstaller.STATUS_SUCCESS -> Unit
            else -> Log.w(
                "SecurelyHelloUpdater",
                "install failed ($status): ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}",
            )
        }
    }
}
