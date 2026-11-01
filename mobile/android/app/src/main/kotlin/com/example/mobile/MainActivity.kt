package com.example.mobile

import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Camera Mode's health reports read how hot the phone is running
        // from here (lib/health/health_monitor.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "keepwatch/thermal").setMethodCallHandler { call, result ->
            if (call.method == "thermalState") result.success(thermalState()) else result.notImplemented()
        }
    }

    /// Android's thermal status, mapped onto iOS's four levels (the names
    /// the server stores). Null before Android 10, which has no thermal API.
    private fun thermalState(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        return when (powerManager.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "nominal"
            PowerManager.THERMAL_STATUS_LIGHT -> "fair"
            PowerManager.THERMAL_STATUS_MODERATE, PowerManager.THERMAL_STATUS_SEVERE -> "serious"
            else -> "critical"
        }
    }
}
