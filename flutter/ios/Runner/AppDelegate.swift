import Flutter
import UIKit
import CoreBluetooth

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, CBCentralManagerDelegate, CBPeripheralManagerDelegate {
  private var methodChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?
  private var central: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?
  private var peerIdBytes: Data = Data(count: 8)
  private var peerIdHex: String = ""

  /// BitChat mainnet service (same as Android / web).
  private let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
  /// BitChat testnet — scan so iOS can join test builds like Chrome Web Bluetooth.
  private let testnetServiceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A")
  private let characteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")

  private var meshCharacteristic: CBMutableCharacteristic?
  private var connectedCentrals: Set<CBCentral> = []
  private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
  private var readyPeripherals: [UUID: CBPeripheral] = [:]
  private var peripheralCharacteristics: [UUID: CBCharacteristic] = [:]
  /// Outbound notify queue when CoreBluetooth returns false from updateValue.
  private var pendingNotifyPayloads: [Data] = []
  /// Per-peripheral write queues (photo/voice fragment storms).
  private var pendingWritePayloads: [UUID: [Data]] = [:]


  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    methodChannel = FlutterMethodChannel(name: "app.offline.offline/mesh", binaryMessenger: messenger)
    methodChannel?.setMethodCallHandler { [weak self] call, result in
      self?.handleMethod(call, result: result)
    }

    let events = FlutterEventChannel(name: "app.offline.offline/mesh_events", binaryMessenger: messenger)
    events.setStreamHandler(MeshStreamHandler { [weak self] sink in
      self?.eventSink = sink
    })
  }

  private func handleMethod(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startMesh":
      let args = call.arguments as? [String: Any]
      peerIdHex = args?["peerIdHex"] as? String ?? ""
      if let bytes = args?["peerIdBytes"] as? FlutterStandardTypedData {
        peerIdBytes = Data(bytes.data.prefix(8))
      }
      central = CBCentralManager(delegate: self, queue: .main)
      peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
      result(true)
    case "stopMesh":
      stopMesh()
      result(true)
    case "sendPacket":
      let args = call.arguments as? [String: Any]
      guard let typed = args?["bytes"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad_args", message: "bytes required", details: nil))
        return
      }
      broadcast(Data(typed.data))
      result(true)
    case "linkCount":
      result(connectedCentrals.count + readyPeripherals.count)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func stopMesh() {
    central?.stopScan()
    for (_, p) in discoveredPeripherals {
      central?.cancelPeripheralConnection(p)
    }
    peripheralManager?.stopAdvertising()
    peripheralManager?.removeAllServices()
    discoveredPeripherals.removeAll()
    readyPeripherals.removeAll()
    peripheralCharacteristics.removeAll()
    connectedCentrals.removeAll()
    pendingNotifyPayloads.removeAll()
    pendingWritePayloads.removeAll()
  }

  /// Send one BitChat BinaryProtocol frame on all links (matches Android BleMeshTransport.send).
  private func broadcast(_ data: Data) {
    if let characteristic = meshCharacteristic, let manager = peripheralManager {
      if !connectedCentrals.isEmpty {
        let ok = manager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
        if !ok {
          pendingNotifyPayloads.append(data)
        }
      }
    }
    for (id, peripheral) in readyPeripherals {
      guard peripheralCharacteristics[id] != nil else { continue }
      var queue = pendingWritePayloads[id] ?? []
      if queue.count >= 2_000 {
        queue.removeFirst()
      }
      queue.append(data)
      pendingWritePayloads[id] = queue
      pumpWrites(for: peripheral)
    }
  }

  private func pumpWrites(for peripheral: CBPeripheral) {
    let id = peripheral.identifier
    guard let characteristic = peripheralCharacteristics[id] else { return }
    let maxLen = peripheral.maximumWriteValueLength(for: .withoutResponse)
    while true {
      guard var queue = pendingWritePayloads[id], !queue.isEmpty else { return }
      guard peripheral.canSendWriteWithoutResponse else { return }
      let payload = queue.removeFirst()
      pendingWritePayloads[id] = queue
      if payload.count > maxLen {
        NSLog(
          "[OfflineBLE] drop write %d > max %d for %@ (raise ATT MTU)",
          payload.count, maxLen, id.uuidString
        )
        continue
      }
      peripheral.writeValue(payload, for: characteristic, type: .withoutResponse)
    }
  }

  private func emitPacket(_ data: Data) {
    eventSink?([
      "type": "packet",
      "bytes": FlutterStandardTypedData(bytes: data),
    ])
  }

  private func emitLinks() {
    eventSink?([
      "type": "links",
      "count": connectedCentrals.count + readyPeripherals.count,
    ])
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central.state == .poweredOn else { return }
    // Scan mainnet + testnet like Web Bluetooth filters.
    central.scanForPeripherals(withServices: [serviceUUID, testnetServiceUUID], options: [
      CBCentralManagerScanOptionAllowDuplicatesKey: false,
    ])
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
      for uuid in [serviceUUID, testnetServiceUUID] {
        if let raw = serviceData[uuid], raw.count >= 8 {
          let hex = raw.prefix(8).map { String(format: "%02x", $0) }.joined()
          if hex.caseInsensitiveCompare(peerIdHex) == .orderedSame { return }
        }
      }
    }
    if discoveredPeripherals[peripheral.identifier] != nil { return }
    if discoveredPeripherals.count + readyPeripherals.count >= 8 { return }
    discoveredPeripherals[peripheral.identifier] = peripheral
    peripheral.delegate = self
    central.connect(peripheral, options: nil)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([serviceUUID, testnetServiceUUID])
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    discoveredPeripherals.removeValue(forKey: peripheral.identifier)
    readyPeripherals.removeValue(forKey: peripheral.identifier)
    peripheralCharacteristics.removeValue(forKey: peripheral.identifier)
    pendingWritePayloads.removeValue(forKey: peripheral.identifier)
    emitLinks()
  }

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard peripheral.state == .poweredOn else { return }
    let characteristic = CBMutableCharacteristic(
      type: characteristicUUID,
      properties: [.read, .write, .writeWithoutResponse, .notify],
      value: nil,
      permissions: [.readable, .writeable]
    )
    meshCharacteristic = characteristic
    let service = CBMutableService(type: serviceUUID, primary: true)
    service.characteristics = [characteristic]
    peripheral.removeAllServices()
    peripheral.add(service)
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    // Local name helps Chrome Web Bluetooth namePrefix filters; service UUID is required.
    let suffix = String(peerIdHex.prefix(4))
    let localName = suffix.isEmpty ? "Offline" : "Offline-\(suffix)"
    peripheral.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
      CBAdvertisementDataLocalNameKey: localName,
    ])
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    connectedCentrals.insert(central)
    emitLinks()
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    connectedCentrals.remove(central)
    emitLinks()
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    guard let characteristic = meshCharacteristic else { return }
    while !pendingNotifyPayloads.isEmpty {
      let payload = pendingNotifyPayloads.removeFirst()
      let ok = peripheral.updateValue(payload, for: characteristic, onSubscribedCentrals: nil)
      if !ok {
        pendingNotifyPayloads.insert(payload, at: 0)
        break
      }
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveWrite requests: [CBATTRequest]
  ) {
    for request in requests {
      if let value = request.value {
        emitPacket(value)
      }
      peripheral.respond(to: request, withResult: .success)
    }
  }
}

extension AppDelegate: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    peripheral.services?.forEach { service in
      if service.uuid == serviceUUID || service.uuid == testnetServiceUUID {
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
      }
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
      return
    }
    peripheralCharacteristics[peripheral.identifier] = characteristic
    peripheral.setNotifyValue(true, for: characteristic)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if characteristic.isNotifying {
      readyPeripherals[peripheral.identifier] = peripheral
      let maxLen = peripheral.maximumWriteValueLength(for: .withoutResponse)
      NSLog(
        "[OfflineBLE] link ready %@ writeMax=%d (photo/voice need ≥512)",
        peripheral.identifier.uuidString, maxLen
      )
      emitLinks()
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let value = characteristic.value {
      emitPacket(value)
    }
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    pumpWrites(for: peripheral)
  }
}

private class MeshStreamHandler: NSObject, FlutterStreamHandler {
  private let onListen: (FlutterEventSink?) -> Void
  init(_ onListen: @escaping (FlutterEventSink?) -> Void) {
    self.onListen = onListen
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onListen(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onListen(nil)
    return nil
  }
}
