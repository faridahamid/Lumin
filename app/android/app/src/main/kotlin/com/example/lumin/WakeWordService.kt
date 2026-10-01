package com.example.lumin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import ai.picovoice.porcupine.PorcupineActivationException
import ai.picovoice.porcupine.PorcupineActivationLimitException
import ai.picovoice.porcupine.PorcupineException
import ai.picovoice.porcupine.PorcupineInvalidArgumentException
import ai.picovoice.porcupine.PorcupineManager
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

class WakeWordService : Service() {

    private var porcupineManager: PorcupineManager? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var isDetectionCooldown = false

    // ──────────────────────────────────────────────────────────────
    // Lifecycle
    // ──────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        lastStatus = "Service created"
        Log.d(TAG, "onCreate")
        acquireWakeLock()
        startForegroundCorrectly()
        initPorcupine()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand action=${intent?.action}")
        if (intent?.action == ACTION_RESTART) {
            isDetectionCooldown = false
            nukePorcupine()
            initPorcupine()
        } else if (intent?.action == ACTION_TEST_WAKE) {
            launchMainActivity()
        } else if (porcupineManager == null) {
            initPorcupine()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy")
        isRunning = false
        lastStatus = "Service stopped"
        nukePorcupine()
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ──────────────────────────────────────────────────────────────
    // Foreground — Android 14 (API 34+) requires the service type
    // passed as a third argument to startForeground, otherwise the
    // system throws validateForegroundServiceType and kills the app.
    // ──────────────────────────────────────────────────────────────

    private fun startForegroundCorrectly() {
        createNotificationChannels()
        val notification = buildPersistentNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {          // API 29+
            startForeground(
                NOTIF_PERSISTENT,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIF_PERSISTENT, notification)
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Porcupine
    // ──────────────────────────────────────────────────────────────

    private fun initPorcupine() {
        lastStatus = "Starting wakeword engine"
        val file = copyAssetToFilesDir(KEYWORD_FILENAME) ?: run {
            Log.e(TAG, "❌ Cannot copy keyword file")
            return
        }
        Log.d(TAG, "Keyword file: ${file.absolutePath}")

        try {
            porcupineManager = PorcupineManager.Builder()
                .setAccessKey(ACCESS_KEY)
                .setKeywordPath(file.absolutePath)   // absolute path — required by native SDK
                .setSensitivity(1.0f)
                .build(applicationContext) { onWakeWordDetected() }

            porcupineManager!!.start()
            Log.d(TAG, "🎧 Porcupine listening")

        } catch (e: PorcupineActivationException) {
            lastStatus = "Picovoice access key invalid or expired"
            Log.e(TAG, "❌ Access key invalid/expired: ${e.message}")
        } catch (e: PorcupineActivationLimitException) {
            lastStatus = "Picovoice device limit reached. Use a new access key or free devices in Picovoice Console."
            Log.e(TAG, "❌ Device limit reached: ${e.message}")
        } catch (e: PorcupineInvalidArgumentException) {
            lastStatus = "Wakeword configuration invalid"
            Log.e(TAG, "❌ Invalid argument: ${e.message}")
        } catch (e: PorcupineException) {
            lastStatus = "Porcupine error: ${e.message}"
            Log.e(TAG, "❌ Porcupine error: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Unexpected: ${e.message}")
        }
    }

    private fun nukePorcupine() {
        try { porcupineManager?.stop() } catch (_: Exception) {}
        try { porcupineManager?.delete() } catch (_: Exception) {}
        porcupineManager = null
        Log.d(TAG, "Porcupine released")
    }

    // ──────────────────────────────────────────────────────────────
    // Detection callback — runs on Porcupine audio thread
    // ──────────────────────────────────────────────────────────────

    private fun onWakeWordDetected() {
        if (isDetectionCooldown) {
            Log.d(TAG, "Cooldown — ignoring")
            return
        }
        isDetectionCooldown = true
        Log.d(TAG, "🔔 Wake word detected!")

        // Post to main thread — startActivity is blocked from background threads
        // on Android 10+ even with SYSTEM_ALERT_WINDOW granted
        mainHandler.post {
            launchMainActivity()
            nukePorcupine()           // release mic immediately
            stopSelf()

            // Restart the whole service after 4 s for a completely fresh
            // AudioRecord session — fixes the "stops after N detections" bug
            if (false) mainHandler.postDelayed({
                Log.d(TAG, "Restarting service")
                val i = Intent(this@WakeWordService, WakeWordService::class.java)
                i.action = ACTION_RESTART
                stopSelf()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(i)
                } else {
                    startService(i)
                }
            }, 4000)
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Launch
    // ──────────────────────────────────────────────────────────────

    private fun launchMainActivity() {
        val canOverlay = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                Settings.canDrawOverlays(this)
        Log.d(TAG, "launchMainActivity canOverlay=$canOverlay")

        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("fromWakeWord", true)
        }

        if (canOverlay) {
            try {
                startActivity(intent)
                Log.d(TAG, "✅ Activity launched")
                return
            } catch (e: Exception) {
                Log.e(TAG, "startActivity failed: ${e.message}")
            }
        }

        // Fallback: full-screen notification
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = notificationBuilder(CHANNEL_ALERT)
            .setContentTitle("Lumin heard you!")
            .setContentText("Tap to open")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setFullScreenIntent(pi, true)
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java).notify(NOTIF_ALERT, notif)
    }

    // ──────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────

    private fun copyAssetToFilesDir(name: String): File? {
        val out = File(filesDir, name)
        return try {
            openKeywordAsset(name).use { input ->
                FileOutputStream(out, false).use { output -> input.copyTo(output) }
            }
            Log.d(TAG, "Copied keyword asset to ${out.absolutePath}")
            out
        } catch (e: Exception) {
            lastStatus = "Unexpected wakeword error: ${e.message}"
            Log.e(TAG, "Copy failed: ${e.message}")
            null
        }
    }

    private fun openKeywordAsset(name: String): InputStream {
        val flutterAssetPath = "$FLUTTER_ASSET_PREFIX$name"
        return try {
            assets.open(flutterAssetPath)
        } catch (flutterAssetError: Exception) {
            Log.w(TAG, "Could not open $flutterAssetPath, trying native asset $name")
            assets.open(name)
        }
    }

    private fun acquireWakeLock() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Lumin::WakeWordLock")
        wakeLock?.acquire()
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
    }

    // ──────────────────────────────────────────────────────────────
    // Notifications
    // ──────────────────────────────────────────────────────────────

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_PERSISTENT, "Lumin Wake Word",
                    NotificationManager.IMPORTANCE_LOW)
            )
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ALERT, "Lumin Alert",
                    NotificationManager.IMPORTANCE_HIGH).apply {
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
            )
        }
    }

    private fun buildPersistentNotification(): Notification =
        notificationBuilder(CHANNEL_PERSISTENT)
            .setContentTitle("Lumin is listening")
            .setContentText("Say 'Lumen' to open the app")
            .setSmallIcon(R.mipmap.ic_launcher)
            .build()

    private fun notificationBuilder(channelId: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            Notification.Builder(this)
        }

    // ──────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────

    companion object {
        private const val TAG = "WakeWordService"
        private const val ACCESS_KEY = "YOUR_PICOVOICE_ACCESS_KEY"
        private const val KEYWORD_FILENAME = "lumen_en_android_v4_0_0.ppn"
        private const val FLUTTER_ASSET_PREFIX = "flutter_assets/assets/"
        private const val CHANNEL_PERSISTENT = "lumin_wakeword"
        private const val CHANNEL_ALERT = "lumin_alert"
        private const val NOTIF_PERSISTENT = 1
        private const val NOTIF_ALERT = 2
        const val ACTION_RESTART = "com.example.lumin.RESTART_WAKE_WORD"
        const val ACTION_TEST_WAKE = "com.example.lumin.TEST_WAKE_WORD"
        var isRunning = false
        var lastStatus = "Not started"
    }
}
