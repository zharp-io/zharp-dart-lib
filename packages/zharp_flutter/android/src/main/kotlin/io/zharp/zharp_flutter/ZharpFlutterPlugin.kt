package io.zharp.zharp_flutter

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * What the Dart side can't learn by itself: the device model, the Android version, the app's
 * version, and an install ID kept in the app's own preferences.
 *
 * The install ID is random and scoped to this install — not a hardware ID — so it resets when the
 * app is reinstalled or its data cleared, and needs no permission.
 */
class ZharpFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "io.zharp/flutter").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "deviceInfo") return result.notImplemented()
        try {
            result.success(deviceInfo(context))
        } catch (e: Exception) {
            result.error("zharp", e.message, null)
        }
    }

    private fun deviceInfo(context: Context?): Map<String, Any?> {
        val info = mutableMapOf<String, Any?>(
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "osName" to "Android",
            "osVersion" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
        )
        if (context != null) {
            info["installId"] = installId(context)
            try {
                val pm = context.packageManager
                val pkg = if (Build.VERSION.SDK_INT >= 33) {
                    pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
                } else {
                    @Suppress("DEPRECATION") pm.getPackageInfo(context.packageName, 0)
                }
                info["appId"] = context.packageName
                info["appVersion"] = pkg.versionName
                info["appBuild"] = if (Build.VERSION.SDK_INT >= 28) pkg.longVersionCode.toString()
                    else @Suppress("DEPRECATION") pkg.versionCode.toString()
            } catch (_: Exception) {
                // No package info: the release stays unset unless the app passes one.
            }
        }
        return info
    }

    private fun installId(context: Context): String {
        val prefs = context.getSharedPreferences("io.zharp.flutter", Context.MODE_PRIVATE)
        prefs.getString("install_id", null)?.let { return it }
        val id = UUID.randomUUID().toString()
        prefs.edit().putString("install_id", id).apply()
        return id
    }
}
