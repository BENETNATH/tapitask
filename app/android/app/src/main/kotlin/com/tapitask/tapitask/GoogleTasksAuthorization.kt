package com.tapitask.tapitask

import android.app.Activity
import android.content.Intent
import android.content.IntentSender
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class GoogleTasksAuthorization(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val client by lazy { Identity.getAuthorizationClient(activity) }
    private val channel = MethodChannel(messenger, "com.tapitask/tapitask/google_tasks")
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when {
                call.method != "authorize" -> result.notImplemented()
                pending != null -> result.error("authorization_in_progress", null, null)
                else -> authorize(result)
            }
        }
    }

    private fun authorize(result: MethodChannel.Result) {
        val request = AuthorizationRequest.builder()
            .setRequestedScopes(listOf(Scope(TASKS_SCOPE)))
            .build()
        val authorizationTask = client.authorize(request)
        pending = result
        authorizationTask
            .addOnSuccessListener { authorization ->
                if (pending !== result) return@addOnSuccessListener
                val resolution = authorization.pendingIntent
                if (resolution == null) {
                    complete(authorization)
                } else {
                    try {
                        activity.startIntentSenderForResult(
                            resolution.intentSender, REQUEST_CODE, null, 0, 0, 0)
                    } catch (_: IntentSender.SendIntentException) {
                        fail()
                    }
                }
            }
            .addOnFailureListener { if (pending === result) fail() }
            .addOnCanceledListener { if (pending === result) complete(null) }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CODE || pending == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            complete(null)
            return
        }
        try {
            complete(client.getAuthorizationResultFromIntent(data))
        } catch (_: ApiException) {
            fail()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        complete(null)
    }

    private fun complete(authorization: AuthorizationResult?) {
        val result = pending
        pending = null
        val token = authorization?.takeIf { TASKS_SCOPE in it.grantedScopes }?.accessToken
        result?.success(token)
    }

    private fun fail() {
        val result = pending
        pending = null
        result?.error("authorization_failed", null, null)
    }

    private companion object {
        const val REQUEST_CODE = 0x7450
        const val TASKS_SCOPE = "https://www.googleapis.com/auth/tasks"
    }
}
