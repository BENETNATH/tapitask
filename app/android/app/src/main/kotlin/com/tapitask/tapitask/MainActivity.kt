package com.tapitask.tapitask

import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.tapitask/tapitask/widget"
    private var pendingLaunchUri: String? = null
    private var wantIme = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d("TAPITASK-FLOW",
            "onCreate action=${intent?.action} data=${intent?.dataString} " +
                "restored=${savedInstanceState != null}")
        pendingLaunchUri = launchUriFrom(intent)
        // launch « + » → demander l'IME visible à la fenêtre au resume
        // (un requestFocus programmatique seul ne fait pas monter le clavier
        // sur un launch depuis un widget, windowSoftInputMode=adjustResize).
        wantIme = pendingLaunchUri?.startsWith("tapitask://quickadd") == true
    }

    override fun onResume() {
        super.onResume()
        Log.d("TAPITASK-FLOW", "onResume wantIme=$wantIme")
        if (wantIme) {
            wantIme = false
            window.setSoftInputMode(
                WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE or
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            Log.d("TAPITASK-FLOW", "onResume IME requested")
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d("TAPITASK-FLOW", "onNewIntent data=${intent.dataString}")
        val uri = launchUriFrom(intent) ?: return
        pendingLaunchUri = null
        try {
            MethodChannel(flutterEngine!!.dartExecutor, channelName)
                .invokeMethod("widgetLaunch", uri)
            Log.d("TAPITASK-FLOW", "widgetLaunch pushed")
        } catch (_: Exception) {
            // Channel pas prêt → repli sur getLaunchUri.
            pendingLaunchUri = uri
            Log.d("TAPITASK-FLOW", "widgetLaunch push failed → pendingLaunchUri")
        }
        intent.data = null
        // relance « + » alors que l'app est ouverte → fenêtre déjà
        // visible, on demande l'IME directement.
        if (uri.startsWith("tapitask://quickadd")) {
            window.setSoftInputMode(
                WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE or
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        // getIntent() peut être null sur recreation système (return recents
        // après kill process) : super.onSaveInstanceState →
        // shouldRestoreAndSaveState() → NPE fatal (FlutterActivity.java:1499,
        // sans test de nullité côté engine). Sans intent, l'état à restaurer
        // n'existe pas : sauter le save (recreate = démarrage frais).
        if (getIntent() != null) {
            super.onSaveInstanceState(outState)
        } else {
            Log.d("TAPITASK-FLOW", "onSaveInstanceState skipped (intent null)")
        }
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
                    Log.d("TAPITASK-FLOW", "getLaunchUri → $uri")
                    result.success(uri)
                } else result.notImplemented()
            }
    }
}
