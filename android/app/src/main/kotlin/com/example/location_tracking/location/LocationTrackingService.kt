package com.example.location_tracking.location

import android.Manifest
import android.annotation.SuppressLint
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.*
import android.util.AtomicFile
import android.util.Log
import com.example.location_tracking.MainActivity
import com.google.android.gms.location.*
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.UUID

internal object Tracking {
    var listener: ((Map<String, Any>) -> Unit)? = null
    var starting = false
    var active = false
    var error = ""

    fun permitted(context: Context) = listOf(
        Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION
    ).any { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    fun enabled(context: Context): Boolean {
        val manager = context.getSystemService(LocationManager::class.java)
        return if (Build.VERSION.SDK_INT >= 28) manager.isLocationEnabled
        else manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
            manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }

    fun state(context: Context) = mapOf(
        "active" to (active || starting), "authorized" to permitted(context),
        "error" to error
    )

    fun publish(context: Context) = listener?.invoke(state(context))
}

internal class LocationInbox(context: Context) {
    private val directory = File(context.filesDir, "location-inbox")

    fun write(latitude: Double, longitude: Double, timestamp: Long): Map<String, Any> {
        if (!directory.mkdirs() && !directory.isDirectory) throw IOException("Cannot create location inbox")
        val id = UUID.randomUUID().toString()
        val fix = mapOf("id" to id, "latitude" to latitude, "longitude" to longitude, "timestamp" to timestamp)
        val file = AtomicFile(File(directory, "$id.json"))
        val stream = file.startWrite()
        try {
            stream.write(JSONObject(fix).toString().toByteArray())
            file.finishWrite(stream)
            if (!file.baseFile.isFile) throw IOException("Cannot commit GPS fix")
        } catch (exception: IOException) {
            file.failWrite(stream)
            throw exception
        }
        return fix
    }

    fun read() = directory.listFiles { file -> file.extension == "json" }
        ?.take(200)?.map { file ->
            val row = JSONObject(AtomicFile(file).readFully().decodeToString())
            mapOf("id" to row.getString("id"), "latitude" to row.getDouble("latitude"),
                "longitude" to row.getDouble("longitude"), "timestamp" to row.getLong("timestamp"))
        }.orEmpty()

    fun acknowledge(ids: List<String>) {
        for (id in ids) {
            if (runCatching { UUID.fromString(id).toString() }.getOrNull() != id) continue
            val file = File(directory, "$id.json")
            if (file.exists() && !file.delete()) throw IOException("Cannot acknowledge saved location")
        }
    }
}

class LocationTrackingService : Service() {
    private val client by lazy { LocationServices.getFusedLocationProviderClient(this) }
    private val inbox by lazy { LocationInbox(this) }
    private val handler = Handler(Looper.getMainLooper())
    private val monitor = object : Runnable {
        override fun run() {
            if (!Tracking.permitted(this@LocationTrackingService) ||
                !Tracking.enabled(this@LocationTrackingService)) {
                fail("Location permission or services were disabled.")
            } else {
                handler.postDelayed(this, 5000)
            }
        }
    }

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            if (!Tracking.active) return
            try {
                for (fix in result.locations) {
                    val record = inbox.write(fix.latitude, fix.longitude, fix.time)
                    Tracking.listener?.invoke(mapOf("location" to record))
                }
            } catch (error: IOException) {
                Log.e("DriverTracking", "Failed to persist location", error)
                fail("Unable to save a GPS fix. Tracking stopped.")
            }
        }
    }

    override fun onBind(intent: Intent?) = null

    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Tracking.starting = false
        if (Tracking.active) return START_NOT_STICKY
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel("tracking", "Driver tracking", NotificationManager.IMPORTANCE_LOW))
        }
        val openApp = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "tracking")
            else Notification.Builder(this)
        try {
            startForeground(1, notification.setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle("Driver Tracking").setContentText("Recording your route")
                .setContentIntent(openApp).setOngoing(true).build())
            if (!Tracking.permitted(this) || !Tracking.enabled(this)) {
                fail("Enable location services and allow location access.")
                return START_NOT_STICKY
            }
            Tracking.active = true
            Tracking.publish(this)
            val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 10_000)
                .setMinUpdateIntervalMillis(5_000).setMinUpdateDistanceMeters(10f)
                .setMaxUpdateAgeMillis(0).build()
            client.requestLocationUpdates(request, callback, Looper.getMainLooper())
                .addOnFailureListener { error ->
                    if (Tracking.active) {
                        Log.e("DriverTracking", "Location request failed", error)
                        fail("GPS updates could not start.")
                    }
                }
            handler.post(monitor)
        } catch (error: RuntimeException) {
            Log.e("DriverTracking", "Could not start foreground tracking", error)
            fail("Unable to start foreground tracking.")
        }
        return START_NOT_STICKY
    }

    private fun fail(message: String) {
        Tracking.error = message
        Tracking.active = false
        Tracking.publish(this)
        stopSelf()
    }

    override fun onDestroy() {
        handler.removeCallbacks(monitor)
        client.removeLocationUpdates(callback)
        Tracking.active = false
        Tracking.publish(this)
        super.onDestroy()
    }
}
