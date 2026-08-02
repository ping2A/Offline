import 'package:offline/ui/mesh_transport.dart';

/// Fallback when neither dart:io nor web JS interop is available.
MeshTransport createMeshTransport() {
  throw UnsupportedError('No mesh transport for this platform');
}
