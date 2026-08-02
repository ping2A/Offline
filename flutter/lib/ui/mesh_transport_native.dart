import 'dart:async';

import 'package:flutter/services.dart';
import 'package:offline/ui/mesh_transport.dart';

class NativeMeshTransport implements MeshTransport {
  static const _methods = MethodChannel('app.offline.offline/mesh');
  static const _events = EventChannel('app.offline.offline/mesh_events');

  StreamSubscription? _sub;

  @override
  void Function(Uint8List bytes)? onPacket;

  @override
  void Function(int count)? onLinkCount;

  @override
  void Function(List<String> names)? onBleDevices;

  @override
  Future<void> start({
    required String peerIdHex,
    required Uint8List peerIdBytes,
  }) async {
    await _sub?.cancel();
    _sub = _events.receiveBroadcastStream().listen(_onEvent);
    await _methods.invokeMethod('startMesh', {
      'peerIdHex': peerIdHex,
      'peerIdBytes': peerIdBytes,
    });
  }

  @override
  Future<void> stop() async {
    await _methods.invokeMethod('stopMesh');
    await _sub?.cancel();
    _sub = null;
  }

  @override
  Future<void> send(Uint8List bytes) async {
    await _methods.invokeMethod('sendPacket', {'bytes': bytes});
  }

  @override
  int linkCount() => 0;

  @override
  Future<void> connectNearbyDevice({bool showAllDevices = false}) async {}

  @override
  bool get supportsNearbyConnect => false;

  @override
  List<String> get bleDeviceNames => const [];

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'];
    if (type == 'packet') {
      final bytes = event['bytes'];
      if (bytes is Uint8List) {
        onPacket?.call(bytes);
      } else if (bytes is List) {
        onPacket?.call(Uint8List.fromList(bytes.cast<int>()));
      }
    } else if (type == 'links') {
      final count = event['count'];
      if (count is int) onLinkCount?.call(count);
    }
  }
}
