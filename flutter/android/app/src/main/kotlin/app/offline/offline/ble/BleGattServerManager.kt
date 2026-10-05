package app.offline.offline.ble

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.util.ArrayDeque

/**
 * BitChat-compatible GATT peripheral: advertise service UUID + peer ID in scan response,
 * accept writes, notify subscribed centrals.
 *
 * Service UUID in the primary advertise packet is required for Chrome Web Bluetooth
 * filters. A short local name in the scan response helps the picker show "Offline-…".
 *
 * Outbound notifies are queued and paced via [onNotificationSent] so photo/voice
 * fragment storms are not silently dropped by the Android BLE stack.
 */
@SuppressLint("MissingPermission")
class BleGattServerManager(
    private val context: Context,
    private val peerIdBytes: ByteArray,
    private val peerIdHex: String,
    private val onPacketFromCentral: (ByteArray) -> Unit,
    private val onConnectionChange: () -> Unit,
) {
    private val tag = "OfflineBleServer"
    private val bluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager.adapter
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private val subscribed = mutableSetOf<BluetoothDevice>()
    private var previousAdapterName: String? = null
    private val handler = Handler(Looper.getMainLooper())
    private val notifyQueue = ArrayDeque<ByteArray>()
    private var notifyInFlight = false
    private var pendingNotifyAcks = 0
    private val notifyTimeout = Runnable { completeNotifyAndContinue() }

    fun start() {
        val adapter = adapter ?: return
        if (!adapter.isEnabled) return
        // Short name so Web Bluetooth namePrefix filters can match.
        try {
            previousAdapterName = adapter.name
            val suffix = peerIdHex.take(4).ifEmpty {
                peerIdBytes.take(2).joinToString("") { "%02x".format(it) }
            }
            adapter.name = "Offline-$suffix"
        } catch (e: Exception) {
            Log.w(tag, "could not set adapter name: ${e.message}")
        }
        advertiser = adapter.bluetoothLeAdvertiser
        gattServer = bluetoothManager.openGattServer(context, serverCallback)
        val service = BluetoothGattService(BleUuids.SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val characteristic = BluetoothGattCharacteristic(
            BleUuids.CHARACTERISTIC,
            BluetoothGattCharacteristic.PROPERTY_READ or
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ or
                BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val cccd = BluetoothGattDescriptor(
            BleUuids.CCCD,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
        )
        characteristic.addDescriptor(cccd)
        service.addCharacteristic(characteristic)
        gattServer?.addService(service)
        startAdvertising()
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        notifyQueue.clear()
        notifyInFlight = false
        pendingNotifyAcks = 0
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {
        }
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
        subscribed.clear()
        try {
            val prev = previousAdapterName
            if (prev != null) {
                adapter?.name = prev
            }
        } catch (_: Exception) {
        }
        previousAdapterName = null
    }

    fun connectionCount(): Int = subscribed.size

    fun broadcast(bytes: ByteArray) {
        if (subscribed.isEmpty()) return
        // Cap queue so a stalled central cannot OOM during a large photo.
        while (notifyQueue.size >= 2_000) {
            notifyQueue.removeFirst()
        }
        notifyQueue.addLast(bytes.copyOf())
        pumpNotify()
    }

    private fun completeNotifyAndContinue() {
        handler.removeCallbacks(notifyTimeout)
        notifyInFlight = false
        pendingNotifyAcks = 0
        // Small pace between fragments (~BitChat 8–28ms relay jitter).
        handler.postDelayed({ pumpNotify() }, 12)
    }

    private fun pumpNotify() {
        if (notifyInFlight) return
        val server = gattServer ?: return
        val service = server.getService(BleUuids.SERVICE) ?: return
        val characteristic = service.getCharacteristic(BleUuids.CHARACTERISTIC) ?: return
        val payload = notifyQueue.pollFirst() ?: return
        val devices = subscribed.toList()
        if (devices.isEmpty()) return

        characteristic.value = payload
        // Fan-out to every subscriber; wait for all onNotificationSent (or timeout)
        // before the next fragment — mirrors iOS pending-notify pacing.
        var started = 0
        for (device in devices) {
            try {
                if (server.notifyCharacteristicChanged(device, characteristic, false)) {
                    started++
                }
            } catch (e: Exception) {
                Log.w(tag, "notify failed: ${e.message}")
            }
        }
        if (started == 0) {
            // Buffer full — retry shortly without dropping this payload forever.
            notifyQueue.addFirst(payload)
            handler.postDelayed({ pumpNotify() }, 20)
            return
        }
        notifyInFlight = true
        pendingNotifyAcks = started
        handler.postDelayed(notifyTimeout, 100)
    }

    private fun startAdvertising() {
        val advertiser = advertiser ?: return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()
        // Primary packet: service UUID (Web Bluetooth filter). Keep it lean.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(BleUuids.SERVICE))
            .build()
        // Scan response: local name + peer id service data for the picker / scanners.
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .addServiceData(ParcelUuid(BleUuids.SERVICE), peerIdBytes.copyOf(8))
            .build()
        try {
            advertiser.startAdvertising(settings, data, scanResponse, advertiseCallback)
        } catch (e: Exception) {
            Log.e(tag, "startAdvertising threw: ${e.message}")
            // Retry without device name if the scan response is too large.
            val leanScan = AdvertiseData.Builder()
                .addServiceData(ParcelUuid(BleUuids.SERVICE), peerIdBytes.copyOf(8))
                .build()
            advertiser.startAdvertising(settings, data, leanScan, advertiseCallback)
        }
    }

    private val advertiseCallback: AdvertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.i(tag, "advertising as ${adapter?.name}")
        }

        override fun onStartFailure(errorCode: Int) {
            Log.e(tag, "advertise failed: $errorCode")
            if (errorCode == ADVERTISE_FAILED_DATA_TOO_LARGE) {
                try {
                    val settings = AdvertiseSettings.Builder()
                        .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                        .setConnectable(true)
                        .setTimeout(0)
                        .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                        .build()
                    val data = AdvertiseData.Builder()
                        .setIncludeDeviceName(false)
                        .addServiceUuid(ParcelUuid(BleUuids.SERVICE))
                        .build()
                    advertiser?.startAdvertising(settings, data, this)
                } catch (e: Exception) {
                    Log.e(tag, "lean advertise failed: ${e.message}")
                }
            }
        }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            Log.i(tag, "connection ${device.address} status=$status state=$newState")
            if (newState != BluetoothProfile.STATE_CONNECTED) {
                subscribed.remove(device)
                onConnectionChange()
                if (notifyInFlight) {
                    pendingNotifyAcks = (pendingNotifyAcks - 1).coerceAtLeast(0)
                    if (pendingNotifyAcks == 0) {
                        completeNotifyAndContinue()
                    }
                } else {
                    pumpNotify()
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            Log.i(tag, "MTU $mtu for ${device.address}")
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(tag, "onNotificationSent status=$status for ${device.address}")
            }
            if (!notifyInFlight) return
            pendingNotifyAcks = (pendingNotifyAcks - 1).coerceAtLeast(0)
            if (pendingNotifyAcks == 0) {
                completeNotifyAndContinue()
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (descriptor.uuid == BleUuids.CCCD && value != null) {
                if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                    subscribed.add(device)
                } else {
                    subscribed.remove(device)
                }
                onConnectionChange()
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (characteristic.uuid == BleUuids.CHARACTERISTIC && value != null) {
                onPacketFromCentral(value)
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            gattServer?.sendResponse(
                device,
                requestId,
                BluetoothGatt.GATT_SUCCESS,
                offset,
                characteristic.value ?: ByteArray(0),
            )
        }
    }
}
