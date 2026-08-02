package app.offline.offline

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import app.offline.offline.service.MeshForegroundService

class MainActivity : FlutterActivity() {
    private val methodChannelName = "app.offline.offline/mesh"
    private val eventChannelName = "app.offline.offline/mesh_events"

    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    attachTransportListeners()
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    MeshForegroundService.transport?.packetListener = null
                    MeshForegroundService.transport?.linkCountListener = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startMesh" -> {
                        val peerHex = call.argument<String>("peerIdHex") ?: ""
                        val peerBytes = call.argument<ByteArray>("peerIdBytes")
                            ?: ByteArray(8)
                        val intent = Intent(this, MeshForegroundService::class.java).apply {
                            action = MeshForegroundService.ACTION_START
                            putExtra(MeshForegroundService.EXTRA_PEER_ID_HEX, peerHex)
                            putExtra(MeshForegroundService.EXTRA_PEER_ID_BYTES, peerBytes)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        // Attach listeners after a short delay once service creates transport
                        window.decorView.postDelayed({ attachTransportListeners() }, 400)
                        result.success(true)
                    }
                    "stopMesh" -> {
                        val intent = Intent(this, MeshForegroundService::class.java).apply {
                            action = MeshForegroundService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(true)
                    }
                    "sendPacket" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null) {
                            result.error("bad_args", "bytes required", null)
                            return@setMethodCallHandler
                        }
                        val transport = MeshForegroundService.transport
                        if (transport == null) {
                            result.error("not_started", "mesh transport not running", null)
                            return@setMethodCallHandler
                        }
                        transport.send(bytes)
                        result.success(true)
                    }
                    "linkCount" -> {
                        result.success(MeshForegroundService.transport?.linkCount() ?: 0)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun attachTransportListeners() {
        val transport = MeshForegroundService.transport ?: return
        transport.packetListener = { bytes ->
            eventSink?.success(
                mapOf(
                    "type" to "packet",
                    "bytes" to bytes,
                ),
            )
        }
        transport.linkCountListener = { count ->
            eventSink?.success(
                mapOf(
                    "type" to "links",
                    "count" to count,
                ),
            )
        }
    }
}
