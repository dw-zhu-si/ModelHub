package com.local.modelhub.mobile

import android.content.Context
import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.local.modelhub.shared.MobileConnectionState
import com.local.modelhub.shared.MobileGatewayClient
import com.local.modelhub.shared.MobileJson
import com.local.modelhub.shared.MobilePairingPayload
import com.local.modelhub.shared.MobilePairingState
import com.local.modelhub.shared.MobilePermission
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.security.SecureRandom

class MobileController(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences("mobile_gateway_binding", Context.MODE_PRIVATE)
    private val identity = AndroidDeviceIdentity(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var activeJob: Job? = null
    private var pendingSecret: String? = null

    var state: MobileConnectionState by mutableStateOf(loadInitialState())
        private set

    val savedServiceUrl: String?
        get() = preferences.getString(KEY_SERVICE_URL, null)

    init {
        if (identity.isPaired && savedServiceUrl != null) refresh()
    }

    fun pair(rawPayload: String, deviceName: String) {
        activeJob?.cancel()
        activeJob = scope.launch {
            try {
                val payload = MobileJson.decodePairingPayload(rawPayload.trim())
                require(deviceName.trim().encodeToByteArray().size in 1..80) { "设备名称需要 1–80 个 UTF-8 字节" }
                pendingSecret = payload.secret
                val client = client(payload.serviceUrl, payload.certificateFingerprint)
                val submission = withContext(Dispatchers.IO) {
                    client.submitPairing(payload, deviceName.trim())
                }
                require(submission.state == MobilePairingState.AWAITING_APPROVAL)
                state = MobileConnectionState.AwaitingDesktopApproval(
                    submission.requestId,
                    submission.pollAfterSeconds.coerceIn(1, 10),
                )
                pollApproval(client, payload, submission.requestId, submission.pollAfterSeconds)
            } catch (error: Throwable) {
                pendingSecret = null
                state = MobileConnectionState.Failed(
                    message = error.message ?: "无法完成安全配对",
                    canRetry = true,
                )
            }
        }
    }

    fun refresh() {
        val serviceUrl = preferences.getString(KEY_SERVICE_URL, null) ?: return
        val fingerprint = preferences.getString(KEY_CERTIFICATE_FINGERPRINT, null) ?: return
        activeJob?.cancel()
        activeJob = scope.launch {
            try {
                val bootstrap = withContext(Dispatchers.IO) { client(serviceUrl, fingerprint).bootstrap() }
                preferences.edit().putString(KEY_LAST_BOOTSTRAP, MobileJson.encodeBootstrap(bootstrap)).apply()
                state = MobileConnectionState.Connected(bootstrap)
            } catch (error: Throwable) {
                val lastKnown = preferences.getString(KEY_LAST_BOOTSTRAP, null)
                    ?.let { runCatching { MobileJson.decodeBootstrap(it) }.getOrNull() }
                state = if (error.message?.contains("HTTP 401") == true) {
                    MobileConnectionState.Revoked
                } else {
                    MobileConnectionState.Offline(lastKnown)
                }
            }
        }
    }

    fun forgetBinding() {
        activeJob?.cancel()
        pendingSecret = null
        try {
            identity.forgetDevice()
        } catch (error: Throwable) {
            state = MobileConnectionState.Failed(
                message = error.message ?: "无法删除 Android Keystore 中的设备密钥",
                canRetry = true,
            )
            return
        }
        preferences.edit().clear().apply()
        state = MobileConnectionState.Unpaired
    }

    fun close() {
        activeJob?.cancel()
        pendingSecret = null
        scope.cancel()
    }

    private suspend fun pollApproval(
        client: MobileGatewayClient,
        payload: MobilePairingPayload,
        requestId: String,
        pollAfterSeconds: Int,
    ) {
        repeat(MAX_POLL_ATTEMPTS) {
            delay(pollAfterSeconds.coerceIn(1, 10) * 1_000L)
            val secret = pendingSecret ?: error("配对会话已结束")
            val status = withContext(Dispatchers.IO) { client.pairingStatus(requestId, secret) }
            when (status.state) {
                MobilePairingState.AWAITING_APPROVAL -> Unit
                MobilePairingState.REJECTED -> {
                    pendingSecret = null
                    state = MobileConnectionState.Failed("桌面端已拒绝该设备", true)
                    return
                }
                MobilePairingState.APPROVED -> {
                    val credential = requireNotNull(status.credential)
                    require(MobilePermission.VIEWER in credential.permissions)
                    identity.storeApprovedDevice(credential.deviceId)
                    preferences.edit()
                        .putString(KEY_SERVICE_URL, payload.serviceUrl)
                        .putString(KEY_CERTIFICATE_FINGERPRINT, payload.certificateFingerprint)
                        .apply()
                    pendingSecret = null
                    val bootstrap = withContext(Dispatchers.IO) { client.bootstrap() }
                    preferences.edit().putString(KEY_LAST_BOOTSTRAP, MobileJson.encodeBootstrap(bootstrap)).apply()
                    state = MobileConnectionState.Connected(bootstrap)
                    return
                }
            }
        }
        pendingSecret = null
        state = MobileConnectionState.Failed("桌面审批等待超时，请重新生成二维码", true)
    }

    private fun client(serviceUrl: String, fingerprint: String) = MobileGatewayClient(
        transport = AndroidGatewayTransport(serviceUrl, fingerprint),
        signer = identity,
        timestampSeconds = { System.currentTimeMillis() / 1_000L },
        nonce = ::randomNonce,
    )

    private fun loadInitialState(): MobileConnectionState {
        val lastKnown = preferences.getString(KEY_LAST_BOOTSTRAP, null)
            ?.let { runCatching { MobileJson.decodeBootstrap(it) }.getOrNull() }
        return if (identity.isPaired && savedServiceUrl != null) {
            MobileConnectionState.Offline(lastKnown)
        } else {
            MobileConnectionState.Unpaired
        }
    }

    private fun randomNonce(): String = ByteArray(24).also(SecureRandom()::nextBytes).let {
        Base64.encodeToString(it, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private companion object {
        const val KEY_SERVICE_URL = "service_url"
        const val KEY_CERTIFICATE_FINGERPRINT = "certificate_fingerprint"
        const val KEY_LAST_BOOTSTRAP = "last_bootstrap"
        const val MAX_POLL_ATTEMPTS = 150
    }
}
