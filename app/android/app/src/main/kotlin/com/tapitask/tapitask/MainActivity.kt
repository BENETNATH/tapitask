package com.tapitask.tapitask

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.tapitask/tapitask/widget"
    private var pendingLaunchUri: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLaunchUri = launchUriFrom(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = launchUriFrom(intent) ?: return
        pendingLaunchUri = null
        try {
            MethodChannel(flutterEngine!!.dartExecutor, channelName)
                .invokeMethod("widgetLaunch", uri)
        } catch (_: Exception) {
            // Channel pas prêt → repli sur getLaunchUri.
            pendingLaunchUri = uri
        }
        setIntent(null)
    }

    private fun launchUriFrom(intent: Intent?): String? =
        if (intent?.action == TapitaskActions.ACTION_LAUNCH)
            intent.dataString else null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "getLaunchUri") {
                    val uri = pendingLaunchUri
                    pendingLaunchUri = null
                    result.success(uri)
                } else result.notImplemented()
            }
    }
}
