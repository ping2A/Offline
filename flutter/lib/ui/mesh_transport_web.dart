import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:offline/ui/mesh_transport.dart';
import 'package:web/web.dart' as web;

/// BitChat / Offline mesh GATT UUIDs (lowercase — Web Bluetooth canonical form).
const meshServiceUuid = 'f47b5e2d-4a9e-4c5a-9b3f-8e1d2c3a4b5c'; // mainnet
const meshServiceUuidTestnet = 'f47b5e2d-4a9e-4c5a-9b3f-8e1d2c3a4b5a'; // BitChat DEBUG
const meshCharacteristicUuid = 'a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d';
const _channelName = 'offline-mesh-v1';
const _meshServiceUuids = [meshServiceUuid, meshServiceUuidTestnet];

void _bleLog(String message, [Object? detail]) {
  final line = detail == null
      ? '[OfflineBLE] $message'
      : '[OfflineBLE] $message $detail';
  debugPrint(line);
  web.console.log(line.toJS);
}

/// Raw bridge installed by `web/index.html` (avoids Flutter navigator wrapping issues).
JSObject? _offlineBleBridge() {
  try {
    final v = globalContext.getProperty('__offlineBle'.toJS);
    if (v == null) return null;
    return v as JSObject;
  } catch (_) {
    return null;
  }
}

Map<String, Object?> _diagnose() {
  final bridge = _offlineBleBridge();
  if (bridge != null) {
    try {
      final raw = bridge.callMethod<JSAny?>('diagnose'.toJS);
      final map = raw?.dartify();
      if (map is Map) {
        return map.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
  }
  return {
    'hasBluetooth': _hasBluetooth(),
    'secure': _isSecureContext(),
    'bridge': bridge != null,
  };
}

/// Browser mesh: BroadcastChannel between tabs + [Web Bluetooth API](
/// https://developer.mozilla.org/en-US/docs/Web/API/Web_Bluetooth_API)
/// GATT client to an Offline / BitChat phone (Chrome / Edge).
class WebMeshTransport implements MeshTransport {
  web.BroadcastChannel? _bc;
  JSFunction? _bcListener;
  final List<_BleLink> _bleLinks = [];
  final Set<String> _tabPeerIds = {};
  Timer? _presenceTimer;
  String _peerIdHex = '';

  @override
  void Function(Uint8List bytes)? onPacket;

  @override
  void Function(int count)? onLinkCount;

  @override
  void Function(List<String> names)? onBleDevices;

  @override
  bool get supportsNearbyConnect => true;

  @override
  List<String> get bleDeviceNames =>
      _bleLinks.map((l) => l.name).toList(growable: false);

  @override
  Future<void> start({
    required String peerIdHex,
    required Uint8List peerIdBytes,
  }) async {
    _peerIdHex = peerIdHex;
    await stop();

    final diag = _diagnose();
    _bleLog('web mesh start (Web Bluetooth API)', 'peer=$peerIdHex diag=$diag');

    final bc = web.BroadcastChannel(_channelName);
    _bc = bc;
    _bcListener = ((web.Event event) {
      final me = event as web.MessageEvent;
      final data = me.data;
      if (data == null) return;
      if (data.isA<JSString>()) {
        _onPresence(data);
        return;
      }
      if (data.isA<JSArrayBuffer>()) {
        final bytes = (data as JSArrayBuffer).toDart.asUint8List();
        if (bytes.isNotEmpty) onPacket?.call(bytes);
        return;
      }
      if (data.isA<JSUint8Array>()) {
        onPacket?.call((data as JSUint8Array).toDart);
      }
    }).toJS;
    bc.addEventListener('message', _bcListener!);

    _broadcastPresence('join');
    _presenceTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _broadcastPresence('ping');
    });
    _emitLinks();

    if (_hasBluetooth()) {
      unawaited(_reconnectPermittedDevices());
    }
  }

  @override
  Future<void> stop() async {
    _bleLog('web mesh stop');
    _presenceTimer?.cancel();
    _presenceTimer = null;
    if (_bc != null && _bcListener != null) {
      _broadcastPresence('leave');
      _bc!.removeEventListener('message', _bcListener!);
      _bc!.close();
    }
    _bc = null;
    _bcListener = null;
    for (final link in List<_BleLink>.from(_bleLinks)) {
      await link.close();
    }
    _bleLinks.clear();
    _tabPeerIds.clear();
    _emitLinks();
    _emitBleDevices();
  }

  @override
  Future<void> send(Uint8List bytes, {bool reliable = false}) async {
    // Copy into a tight buffer so BLE/BroadcastChannel never see a larger view.
    final copy = Uint8List.fromList(bytes);
    _bc?.postMessage(copy.toJS);
    if (copy.length > 512) {
      // Native peers can notify >512; never attempt a Web Bluetooth write.
      _bleLog('skipping oversized BLE frame', '${copy.length} bytes');
      return;
    }
    if (_bleLinks.isNotEmpty) {
      _bleLog(
        'BLE → mesh',
        '${copy.length} bytes × ${_bleLinks.length} link(s)'
        '${reliable ? ' reliable' : ''}',
      );
    }
    for (final link in List<_BleLink>.from(_bleLinks)) {
      try {
        await link.write(copy, reliable: reliable);
      } catch (e) {
        _bleLog('BLE write failed', '${link.name}: $e');
        final msg = e.toString();
        if (reliable &&
            !msg.contains('512') &&
            !msg.contains('InvalidModificationError')) {
          try {
            await link.write(copy, reliable: true);
            continue;
          } catch (e2) {
            _bleLog('BLE retry failed', '${link.name}: $e2');
          }
        }
        // One bad frame must not tear down the link mid voice/photo train.
        if (msg.contains('512') || msg.contains('InvalidModificationError')) {
          continue;
        }
        await link.close();
        _bleLinks.remove(link);
        _emitLinks();
        _emitBleDevices();
      }
    }
  }

  @override
  int linkCount() => _tabPeerIds.length + _bleLinks.length;

  @override
  Future<void> connectNearbyDevice({bool showAllDevices = false}) async {
    _bleLog(
      'connectNearbyDevice: Web Bluetooth requestDevice()',
      showAllDevices ? 'showAll=true' : 'filtered',
    );
    _ensureBluetoothReady();

    final device = await _requestDevice(showAllDevices: showAllDevices);
    await _attachDevice(device, fromPicker: true);
  }

  Future<void> _reconnectPermittedDevices() async {
    try {
      final bridge = _offlineBleBridge();
      late final JSObject list;
      if (bridge != null) {
        list = (await bridge.callMethod<JSPromise>('getDevices'.toJS).toDart)!
            as JSObject;
      } else {
        final bluetooth = _bluetoothObject();
        if (bluetooth == null) return;
        if (bluetooth.getProperty('getDevices'.toJS) == null) return;
        list = (await bluetooth.callMethod<JSPromise>('getDevices'.toJS).toDart)!
            as JSObject;
      }
      final n = (list.getProperty('length'.toJS) as JSNumber?)?.toDartInt ?? 0;
      _bleLog('permitted devices', n);
      for (var i = 0; i < n; i++) {
        final device = list.getProperty('$i'.toJS);
        if (device == null) continue;
        try {
          await _attachDevice(device as JSObject, fromPicker: false);
        } catch (e) {
          _bleLog('auto-reconnect skipped', e);
        }
      }
    } catch (e) {
      _bleLog('getDevices failed', e);
    }
  }

  /// Default: mesh service UUID + Offline name filters.
  /// On Linux (and when the filtered scan is empty), use acceptAllDevices —
  /// BlueZ often misses BitChat’s service UUID in advertisements.
  Future<JSObject> _requestDevice({required bool showAllDevices}) async {
    final bridge = _offlineBleBridge();
    Future<JSObject> request(JSAny options) async {
      if (bridge != null) {
        return (await bridge
                .callMethod<JSPromise>('requestDevice'.toJS, options)
                .toDart)!
            as JSObject;
      }
      final bluetooth = _bluetoothObject()!;
      return (await bluetooth
              .callMethod<JSPromise>('requestDevice'.toJS, options)
              .toDart)!
          as JSObject;
    }

    final allOpts = {
      'acceptAllDevices': true,
      'optionalServices': _meshServiceUuids,
    }.jsify()!;

    // Linux Chrome Web Bluetooth is experimental; service filters rarely match.
    final preferAll = showAllDevices || _isLinuxDesktop;
    if (preferAll) {
      _bleLog('requestDevice(acceptAllDevices)');
      return request(allOpts);
    }

    final filtered = {
      'filters': [
        {'services': [meshServiceUuid]},
        {'services': [meshServiceUuidTestnet]},
        {'namePrefix': 'Offline'},
        {'namePrefix': 'offline'},
      ],
      'optionalServices': _meshServiceUuids,
    }.jsify()!;

    _bleLog('requestDevice(mesh service filters)');
    try {
      return await request(filtered);
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('abort') || msg.contains('cancel')) {
        rethrow;
      }
      _bleLog('filtered scan empty; falling back to acceptAllDevices', e);
      try {
        return await request(allOpts);
      } catch (e2) {
        final msg2 = e2.toString().toLowerCase();
        if (msg2.contains('abort') || msg2.contains('cancel')) {
          rethrow;
        }
        throw StateError(_linuxBleHint(e2.toString()));
      }
    }
  }

  static bool get _isLinuxDesktop {
    final ua = web.window.navigator.userAgent;
    return ua.contains('Linux') && !ua.contains('Android');
  }

  static String _linuxBleHint(String detail) {
    if (_isLinuxDesktop) {
      return 'No Bluetooth devices on Linux. In Chrome enable '
          'chrome://flags/#enable-experimental-web-platform-features, '
          'Relaunch, turn Bluetooth on (BlueZ 5.41+). BitChat is often unnamed. '
          '($detail)';
    }
    return 'No mesh device found. Keep BitChat open, then try Mesh again — '
        'or long-press Mesh to browse all devices. ($detail)';
  }

  Future<void> _attachDevice(JSObject device, {required bool fromPicker}) async {
    final name = _jsString(device, 'name') ?? '(unnamed BitChat/Offline phone)';
    final id = _jsString(device, 'id') ?? '';
    if (_bleLinks.any((l) => l.id == id && id.isNotEmpty)) {
      _bleLog('already linked', name);
      return;
    }

    _bleLog(fromPicker ? 'device selected' : 'reconnecting', 'name=$name id=$id');

    final gatt = device.getProperty('gatt'.toJS) as JSObject?;
    if (gatt == null) {
      throw StateError('No GATT server on $name');
    }

    final already = gatt.getProperty('connected'.toJS)?.dartify() == true;
    if (!already) {
      _bleLog('GATT connect…', name);
      await gatt.callMethod<JSPromise>('connect'.toJS).toDart;
    }
    _bleLog('GATT connected', name);

    // iOS BitChat sometimes needs a beat after connect before services resolve,
    // especially when it is the only peripheral the Mac has seen.
    late final JSObject service;
    JSObject? foundService;
    Object? lastErr;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
        _bleLog('getPrimaryService retry', attempt);
      }
      for (final uuid in _meshServiceUuids) {
        try {
          foundService = (await gatt
                  .callMethod<JSPromise>(
                    'getPrimaryService'.toJS,
                    uuid.toJS,
                  )
                  .toDart)!
              as JSObject;
          _bleLog('getPrimaryService ok', uuid);
          break;
        } catch (e) {
          lastErr = e;
        }
      }
      if (foundService != null) break;
    }
    if (foundService == null) {
      try {
        gatt.callMethod('disconnect'.toJS);
      } catch (_) {}
      throw StateError(
        'Mesh GATT service not found on $name '
        '(keep BitChat open in the foreground). last=$lastErr',
      );
    }
    service = foundService;

    late final JSObject characteristic;
    try {
      characteristic = (await service
              .callMethod<JSPromise>(
                'getCharacteristic'.toJS,
                meshCharacteristicUuid.toJS,
              )
              .toDart)!
          as JSObject;
    } catch (e) {
      _bleLog('getCharacteristic failed', e);
      rethrow;
    }

    final link = _BleLink(
      device: device,
      characteristic: characteristic,
      name: name,
      id: id,
      onPacket: (bytes) {
        _bleLog('BLE ← mesh', '${bytes.length} bytes from $name');
        onPacket?.call(bytes);
      },
      onClosed: () {
        _bleLog('BLE disconnected', name);
        _bleLinks.removeWhere((l) => identical(l.device, device));
        _emitLinks();
        _emitBleDevices();
      },
    );
    await link.startNotifications();
    _bleLinks.add(link);
    _bleLog('mesh peer linked', '$name (ble=${_bleLinks.length})');
    _emitLinks();
    _emitBleDevices();
  }

  void _broadcastPresence(String kind) {
    _bc?.postMessage('presence:$kind:$_peerIdHex'.toJS);
  }

  void _onPresence(JSAny? data) {
    if (data == null || !data.isA<JSString>()) return;
    final s = (data as JSString).toDart;
    if (!s.startsWith('presence:')) return;
    final parts = s.split(':');
    if (parts.length < 3) return;
    final kind = parts[1];
    final peer = parts.sublist(2).join(':');
    if (peer == _peerIdHex) return;
    if (kind == 'leave') {
      _tabPeerIds.remove(peer);
    } else {
      _tabPeerIds.add(peer);
    }
    _emitLinks();
  }

  void _emitLinks() => onLinkCount?.call(linkCount());

  void _emitBleDevices() => onBleDevices?.call(bleDeviceNames);

  void _ensureBluetoothReady() {
    final diag = _diagnose();
    _bleLog('bluetooth diagnose', diag);
    if (!_isSecureContext()) {
      throw StateError(
        'Web Bluetooth needs https:// or http://127.0.0.1 / localhost. diag=$diag',
      );
    }
    if (!_hasBluetooth()) {
      throw StateError(
        'navigator.bluetooth is missing in this browser. '
        'Need desktop Chrome/Edge with Web Bluetooth (not Safari/Firefox/iOS Chrome). '
        'Enable chrome://flags/#enable-web-bluetooth, disable privacy extensions that block Bluetooth. '
        'diag=$diag',
      );
    }
  }
}

bool _isSecureContext() {
  try {
    return web.window.isSecureContext;
  } catch (_) {
    return false;
  }
}

bool _hasBluetooth() {
  final bridge = _offlineBleBridge();
  if (bridge != null) {
    final flagged = bridge.getProperty('hasBluetooth'.toJS)?.dartify();
    if (flagged == true) return true;
    // Fall through — flag may be stale; still try live navigator.
  }
  return _bluetoothObject() != null;
}

JSObject? _bluetoothObject() {
  try {
    final nav = globalContext.getProperty('navigator'.toJS);
    if (nav != null) {
      final navObj = nav as JSObject;
      // Prefer direct property read over `in` — some wrappers break `in`.
      final bt = navObj.getProperty('bluetooth'.toJS);
      if (bt != null) return bt as JSObject;
    }
  } catch (_) {}
  try {
    final bt = (web.window.navigator as JSObject).getProperty('bluetooth'.toJS);
    if (bt != null) return bt as JSObject;
  } catch (_) {}
  return null;
}

String? _jsString(JSObject obj, String key) {
  final v = obj.getProperty(key.toJS);
  if (v == null) return null;
  if (v.isA<JSString>()) return (v as JSString).toDart;
  return v.dartify()?.toString();
}

class _BleLink {
  _BleLink({
    required this.device,
    required this.characteristic,
    required this.name,
    required this.id,
    required this.onPacket,
    required this.onClosed,
  });

  final JSObject device;
  final JSObject characteristic;
  final String name;
  final String id;
  final void Function(Uint8List bytes) onPacket;
  final void Function() onClosed;
  JSFunction? _notifyHandler;
  JSFunction? _disconnectHandler;

  Future<void> startNotifications() async {
    _notifyHandler = ((web.Event event) {
      final target = event.target;
      if (target == null) return;
      final value = (target as JSObject).getProperty('value'.toJS);
      if (value == null) return;
      final bytes = _dataViewToBytes(value as JSObject);
      if (bytes.isNotEmpty) onPacket(bytes);
    }).toJS;
    characteristic.callMethod(
      'addEventListener'.toJS,
      'characteristicvaluechanged'.toJS,
      _notifyHandler!,
    );
    await characteristic
        .callMethod<JSPromise>('startNotifications'.toJS)
        .toDart;
    _bleLog('notifications on', name);

    _disconnectHandler = ((web.Event _) {
      onClosed();
    }).toJS;
    device.callMethod(
      'addEventListener'.toJS,
      'gattserverdisconnected'.toJS,
      _disconnectHandler!,
    );
  }

  Future<void> write(Uint8List bytes, {bool reliable = false}) async {
    // Web Bluetooth hard-caps attribute values at 512 bytes.
    if (bytes.length > 512) {
      throw StateError(
        'BLE frame ${bytes.length} bytes exceeds Web Bluetooth 512-byte write limit',
      );
    }
    final payload = Uint8List.fromList(bytes);
    final props = characteristic.getProperty('properties'.toJS) as JSObject?;
    final withoutResponse =
        props?.getProperty('writeWithoutResponse'.toJS)?.dartify() == true;
    final withResponse =
        props?.getProperty('write'.toJS)?.dartify() == true;

    Future<void> attempt(String method) async {
      await characteristic
          .callMethod<JSPromise>(method.toJS, payload.toJS)
          .toDart;
    }

    if (reliable && withResponse) {
      await attempt('writeValueWithResponse');
      return;
    }
    if (withoutResponse) {
      try {
        await attempt('writeValueWithoutResponse');
        // Fragment trains need more airtime than tiny control packets.
        await Future<void>.delayed(
          Duration(milliseconds: reliable ? 28 : 12),
        );
        return;
      } catch (e) {
        _bleLog('writeWithoutResponse failed, trying withResponse', e);
      }
    }
    if (withResponse) {
      await attempt('writeValueWithResponse');
      return;
    }
    await attempt('writeValue');
  }

  Future<void> close() async {
    try {
      if (_notifyHandler != null) {
        characteristic.callMethod(
          'removeEventListener'.toJS,
          'characteristicvaluechanged'.toJS,
          _notifyHandler!,
        );
      }
      await characteristic
          .callMethod<JSPromise>('stopNotifications'.toJS)
          .toDart;
    } catch (_) {}
    try {
      final gatt = device.getProperty('gatt'.toJS) as JSObject?;
      gatt?.callMethod('disconnect'.toJS);
    } catch (_) {}
  }

  static Uint8List _dataViewToBytes(JSObject view) {
    final byteLength =
        (view.getProperty('byteLength'.toJS) as JSNumber).toDartInt;
    final byteOffset =
        (view.getProperty('byteOffset'.toJS) as JSNumber).toDartInt;
    final buffer = view.getProperty('buffer'.toJS) as JSArrayBuffer;
    return buffer.toDart.asUint8List(byteOffset, byteLength);
  }
}
