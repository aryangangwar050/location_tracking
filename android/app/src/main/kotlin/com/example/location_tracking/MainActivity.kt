package com.example.location_tracking

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.example.location_tracking.location.LocationInbox
import com.example.location_tracking.location.LocationTrackingService
import com.example.location_tracking.location.Tracking
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingStart: MethodChannel.Result? = null
    private val inbox by lazy { LocationInbox(this) }
    private val service by lazy { Intent(this, LocationTrackingService::class.java) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "driver_tracking/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                Tracking.listener = { events.success(it) }
                Tracking.publish(this@MainActivity)
            }

            override fun onCancel(arguments: Any?) { Tracking.listener = null }
        })
        MethodChannel(messenger, "driver_tracking/methods").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "state" -> result.success(Tracking.state(this))
                    "read" -> result.success(inbox.read())
                    "ack" -> { inbox.acknowledge(call.arguments as? List<String> ?: emptyList()); result.success(null) }
                    "stop" -> {
                        stopService(service)
                        Tracking.error = ""
                        Tracking.starting = false
                        Tracking.active = false
                        Tracking.publish(this)
                        result.success(null)
                    }
                    "start" -> requestStart(result)
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("tracking", error.localizedMessage, null)
            }
        }
    }

    private fun requestStart(result: MethodChannel.Result) {
        if (pendingStart != null) {
            result.error("busy", "A permission request is already open.", null)
        } else if (!Tracking.permitted(this)) {
            pendingStart = result
            requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION), 10)
        } else {
            startTracking(result)
        }
    }

    private fun startTracking(result: MethodChannel.Result) {
        if (!Tracking.enabled(this)) {
            result.error("disabled", "Turn on device location services and try again.", null)
            return
        }
        try {
            Tracking.error = ""
            Tracking.starting = true
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
            result.success(null)
        } catch (error: RuntimeException) {
            Tracking.starting = false
            result.error("start", error.localizedMessage, null)
            return
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !getPreferences(MODE_PRIVATE).getBoolean("notificationRequested", false)) {
            getPreferences(MODE_PRIVATE).edit().putBoolean("notificationRequested", true).apply()
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 11)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 10) return
        val result = pendingStart ?: return
        pendingStart = null
        if (Tracking.permitted(this)) startTracking(result)
        else result.error("denied", "Allow location access in Settings to start real GPS tracking.", null)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        Tracking.listener = null
        pendingStart?.error("interrupted", "Location permission request was interrupted.", null)
        pendingStart = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
