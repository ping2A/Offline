package app.offline.offline.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import app.offline.offline.MainActivity
import app.offline.offline.ble.BleMeshTransport

/**
 * Keeps BitChat-compatible BLE mesh advertise/scan/connections alive in background.
 */
class MeshForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "offline_mesh_service"
        const val NOTIFICATION_ID = 42
        const val ACTION_START = "app.offline.offline.MESH_START"
        const val ACTION_STOP = "app.offline.offline.MESH_STOP"
        const val EXTRA_PEER_ID_BYTES = "peer_id_bytes"
        const val EXTRA_PEER_ID_HEX = "peer_id_hex"

        @Volatile
        var transport: BleMeshTransport? = null
            private set
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopMesh()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val peerBytes = intent?.getByteArrayExtra(EXTRA_PEER_ID_BYTES) ?: ByteArray(8)
                val peerHex = intent?.getStringExtra(EXTRA_PEER_ID_HEX) ?: ""
                startForeground(NOTIFICATION_ID, buildNotification())
                startMesh(peerBytes, peerHex)
            }
        }
        return START_STICKY
    }

    private fun startMesh(peerBytes: ByteArray, peerHex: String) {
        if (transport != null) return
        val t = BleMeshTransport(applicationContext, peerBytes, peerHex)
        transport = t
        t.start()
    }

    private fun stopMesh() {
        transport?.stop()
        transport = null
    }

    override fun onDestroy() {
        stopMesh()
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        ensureChannel()
        val launch = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Offline mesh")
            .setContentText("Bluetooth mesh is active")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(launch)
            .setOngoing(true)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Offline mesh",
            NotificationManager.IMPORTANCE_LOW,
        )
        mgr.createNotificationChannel(channel)
    }
}
