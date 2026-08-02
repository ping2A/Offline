import 'dart:typed_data';

/// Platform mesh pipe: start/stop links and move BitChat frames.
abstract class MeshTransport {
  void Function(Uint8List bytes)? onPacket;
  void Function(int count)? onLinkCount;

  /// Names of phones currently linked over Web Bluetooth (web only).
  void Function(List<String> names)? onBleDevices;

  Future<void> start({
    required String peerIdHex,
    required Uint8List peerIdBytes,
  });

  Future<void> stop();

  Future<void> send(Uint8List bytes);

  int linkCount();

  /// Web: prompt user to pick a nearby Offline/BitChat phone via Web Bluetooth.
  /// When [showAllDevices] is true, Chrome lists every Bluetooth peripheral
  /// (escape hatch if filtered discovery misses a nameless BitChat iPhone).
  Future<void> connectNearbyDevice({bool showAllDevices = false}) async {}

  /// Whether this browser exposes Web Bluetooth (Chrome/Edge).
  bool get supportsNearbyConnect => false;

  List<String> get bleDeviceNames => const [];
}
