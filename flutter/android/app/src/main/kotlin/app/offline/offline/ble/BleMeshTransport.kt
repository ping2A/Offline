package app.offline.offline.ble

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Dual-role BLE mesh transport: GATT server + client sharing one packet callback.
 */
class BleMeshTransport(
    context: Context,
    peerIdBytes: ByteArray,
    peerIdHex: String,
) {
    private val tag = "OfflineBleMesh"
    private val main = Handler(Looper.getMainLooper())
    @Volatile
    var packetListener: ((ByteArray) -> Unit)? = null
    @Volatile
    var linkCountListener: ((Int) -> Unit)? = null

    private val server = BleGattServerManager(
        context = context,
        peerIdBytes = peerIdBytes,
        peerIdHex = peerIdHex,
        onPacketFromCentral = { bytes -> dispatchPacket(bytes) },
        onConnectionChange = { emitLinks() },
    )
    private val client = BleGattClientManager(
        context = context,
        localPeerIdHex = peerIdHex,
        onPacketFromPeripheral = { bytes -> dispatchPacket(bytes) },
        onConnectionChange = { emitLinks() },
    )

    fun start() {
        server.start()
        client.start()
        Log.i(tag, "mesh transport started")
    }

    fun stop() {
        client.stop()
        server.stop()
        Log.i(tag, "mesh transport stopped")
    }

    fun send(bytes: ByteArray) {
        server.broadcast(bytes)
        client.broadcast(bytes)
    }

    fun linkCount(): Int = server.connectionCount() + client.connectionCount()

    private fun dispatchPacket(bytes: ByteArray) {
        main.post { packetListener?.invoke(bytes) }
    }

    private fun emitLinks() {
        val n = linkCount()
        main.post { linkCountListener?.invoke(n) }
    }
}
