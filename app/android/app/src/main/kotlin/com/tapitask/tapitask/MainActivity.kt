package com.tapitask.tapitask

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "com.tapitask/tapitask/widget"
    private val updaterChannelName = "com.tapitask/tapitask/updater"
    private var googleTasksAuthorization: GoogleTasksAuthorization? = null
    private var pendingLaunchUri: String? = null
    private var wantIme = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLaunchUri = launchUriFrom(intent)
        // launch « + » → demander l'IME visible à la fenêtre au resume
        // (un requestFocus programmatique seul ne fait pas monter le clavier
        // sur un launch depuis un widget, windowSoftInputMode=adjustResize).
        wantIme = pendingLaunchUri?.startsWith("tapitask://quickadd") == true
    }

    override fun onResume() {
        super.onResume()
        if (wantIme) {
            wantIme = false
            window.setSoftInputMode(
                WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE or
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
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
        }
    }

    private fun launchUriFrom(intent: Intent?): String? =
        if (intent?.action == TapitaskActions.ACTION_LAUNCH)
            intent.dataString else null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        googleTasksAuthorization = GoogleTasksAuthorization(this, flutterEngine.dartExecutor)
        MethodChannel(flutterEngine.dartExecutor, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "getLaunchUri") {
                    val uri = pendingLaunchUri
                    pendingLaunchUri = null
                    result.success(uri)
                } else result.notImplemented()
            }
        // Auto-mise à jour : sert l'APK téléchargé (cache interne) au
        // package installer système.
        MethodChannel(flutterEngine.dartExecutor, updaterChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "installApk") {
                    val path = call.argument<String>("path")
                    val file = path?.let { File(it) }
                    if (file == null || !file.exists()) {
                        result.error("no_apk", "chemin APK manquant", null)
                    } else {
                        try {
                            val uri = FileProvider.getUriForFile(
                                this, "$packageName.updater", file)
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(
                                    uri,
                                    "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message, null)
                        }
                    }
                } else result.notImplemented()
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        googleTasksAuthorization?.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        googleTasksAuthorization?.dispose()
        googleTasksAuthorization = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
