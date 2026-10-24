export 'open_external_url_stub.dart'
    if (dart.library.html) 'open_external_url_web.dart'
    if (dart.library.io) 'open_external_url_io.dart';
