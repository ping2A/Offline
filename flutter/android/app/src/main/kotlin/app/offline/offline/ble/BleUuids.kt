package app.offline.offline.ble

import java.util.UUID

object BleUuids {
    /** BitChat mainnet mesh service. */
    val SERVICE: UUID = UUID.fromString("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    /** BitChat testnet — scanned alongside mainnet (same as iOS / Web Bluetooth). */
    val SERVICE_TESTNET: UUID = UUID.fromString("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A")
    val CHARACTERISTIC: UUID = UUID.fromString("A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
    const val TARGET_MTU = 517
    const val MAX_CONNECTIONS = 8

    val SCAN_SERVICES: List<UUID> = listOf(SERVICE, SERVICE_TESTNET)
}
