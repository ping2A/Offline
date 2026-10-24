import 'dart:typed_data';

/// Platform mesh pipe: start/stop links and move BitChat frames.
abstract class MeshTransport {
  void Function(Uint8List bytes)? onPacket;
  void Function(int count)? onLinkCount;

  /// Names of mesh peers linked over Web Bluetooth (web only).
  void Function(List<String> names)? onBleDevices;

  Future<void> start({
    required String peerIdHex,
    required Uint8List peerIdBytes,
  });

  Future<void> stop();

  /// Send one BitChat frame. When [reliable] is true (fragment trains), prefer
  /// acknowledged GATT writes so private images reassemble on BitChat.
  Future<void> send(Uint8List bytes, {bool reliable = false});

  int linkCount();

  /// Web: pick a nearby Offline/BitChat peer via this desktop’s Bluetooth.
  /// When [showAllDevices] is true, Chrome lists every Bluetooth peripheral
  /// (escape hatch if filtered discovery misses a nameless BitChat device).
  Future<void> connectNearbyDevice({bool showAllDevices = false}) async {}

  /// Whether this browser exposes Web Bluetooth (Chrome/Edge).
  bool get supportsNearbyConnect => false;

  List<String> get bleDeviceNames => const [];
}
