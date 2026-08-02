package app.offline.offline.ble

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * BitChat-compatible GATT central: scan for mesh service, connect, MTU 517, notify subscribe, write.
 */
@SuppressLint("MissingPermission")
class BleGattClientManager(
    private val context: Context,
    private val localPeerIdHex: String,
    private val onPacketFromPeripheral: (ByteArray) -> Unit,
    private val onConnectionChange: () -> Unit,
) {
    private val tag = "OfflineBleClient"
    private val bluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager.adapter
    private var scanner: BluetoothLeScanner? = null
    private val handler = Handler(Looper.getMainLooper())
    private val connections = ConcurrentHashMap<String, GattSession>()
    private val connecting = ConcurrentHashMap.newKeySet<String>()

    private data class GattSession(
        val device: BluetoothDevice,
        var gatt: BluetoothGatt?,
        var characteristic: BluetoothGattCharacteristic?,
        var ready: Boolean = false,
        val pendingWrites: ArrayDeque<ByteArray> = ArrayDeque(),
        var writeInFlight: Boolean = false,
    )

    fun start() {
        val adapter = adapter ?: return
        if (!adapter.isEnabled) return
        scanner = adapter.bluetoothLeScanner
        val filters = BleUuids.SCAN_SERVICES.map { uuid ->
            ScanFilter.Builder().setServiceUuid(ParcelUuid(uuid)).build()
        }
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
            .build()
        scanner?.startScan(filters, settings, scanCallback)
        Log.i(tag, "scanning")
    }

    fun stop() {
        try {
            scanner?.stopScan(scanCallback)
        } catch (_: Exception) {
        }
        for ((_, session) in connections) {
            try {
                session.gatt?.close()
            } catch (_: Exception) {
            }
        }
        connections.clear()
        connecting.clear()
    }

    fun connectionCount(): Int = connections.values.count { it.ready }

    fun broadcast(bytes: ByteArray) {
        for ((_, session) in connections) {
            if (!session.ready) continue
            while (session.pendingWrites.size >= 2_000) {
                session.pendingWrites.removeFirst()
            }
            session.pendingWrites.addLast(bytes.copyOf())
            pumpWrites(session)
        }
    }

    private fun pumpWrites(session: GattSession) {
        if (session.writeInFlight) return
        val gatt = session.gatt ?: return
        val characteristic = session.characteristic ?: return
        val next = session.pendingWrites.removeFirstOrNull() ?: return
        try {
            characteristic.value = next
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            session.writeInFlight = true
            val ok = gatt.writeCharacteristic(characteristic)
            if (!ok) {
                session.writeInFlight = false
                session.pendingWrites.addFirst(next)
                handler.postDelayed({ pumpWrites(session) }, 20)
            }
        } catch (e: Exception) {
            session.writeInFlight = false
            Log.w(tag, "write failed: ${e.message}")
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val address = device.address ?: return
            if (connections.containsKey(address) || connecting.contains(address)) return
            if (connections.size + connecting.size >= BleUuids.MAX_CONNECTIONS) return

            val serviceData = BleUuids.SCAN_SERVICES
                .asSequence()
                .mapNotNull { result.scanRecord?.getServiceData(ParcelUuid(it)) }
                .firstOrNull()
            if (serviceData != null && serviceData.size >= 8) {
                val peerHex = serviceData.take(8).joinToString("") { "%02x".format(it) }
                if (peerHex.equals(localPeerIdHex, ignoreCase = true)) return
            }

            connecting.add(address)
            Log.i(tag, "connecting $address")
            handler.post {
                try {
                    val gatt = device.connectGatt(
                        context,
                        false,
                        gattCallback,
                        BluetoothDevice.TRANSPORT_LE,
                    )
                    connections[address] = GattSession(device, gatt, null)
                } catch (e: Exception) {
                    connecting.remove(address)
                    Log.e(tag, "connect failed: ${e.message}")
                }
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(tag, "scan failed: $errorCode")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                handler.postDelayed({
                    gatt.requestMtu(BleUuids.TARGET_MTU)
                }, 200)
            } else {
                connecting.remove(address)
                connections.remove(address)?.gatt?.close()
                onConnectionChange()
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                gatt.discoverServices()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) return
            val service = BleUuids.SCAN_SERVICES
                .asSequence()
                .mapNotNull { gatt.getService(it) }
                .firstOrNull() ?: return
            val characteristic = service.getCharacteristic(BleUuids.CHARACTERISTIC) ?: return
            val address = gatt.device.address
            connections[address]?.characteristic = characteristic
            gatt.setCharacteristicNotification(characteristic, true)
            val cccd = characteristic.getDescriptor(BleUuids.CCCD)
            if (cccd != null) {
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                gatt.writeDescriptor(cccd)
            } else {
                markReady(address)
            }
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (descriptor.uuid == BleUuids.CCCD && status == BluetoothGatt.GATT_SUCCESS) {
                markReady(gatt.device.address)
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            val session = connections[gatt.device.address] ?: return
            session.writeInFlight = false
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(tag, "write status=$status for ${gatt.device.address}")
            }
            // Pace fragments (~BitChat 8–28ms) so the controller buffer drains.
            handler.postDelayed({ pumpWrites(session) }, 12)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid == BleUuids.CHARACTERISTIC) {
                val value = characteristic.value ?: return
                onPacketFromPeripheral(value)
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (characteristic.uuid == BleUuids.CHARACTERISTIC) {
                onPacketFromPeripheral(value)
            }
        }
    }

    private fun markReady(address: String) {
        connecting.remove(address)
        connections[address]?.ready = true
        onConnectionChange()
        Log.i(tag, "ready $address (links=${connectionCount()})")
    }
}
