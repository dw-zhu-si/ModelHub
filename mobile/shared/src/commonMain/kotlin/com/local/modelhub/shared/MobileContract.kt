package com.local.modelhub.shared

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class MobilePairingPayload(
    val id: String,
    @SerialName("serviceURL") val serviceUrl: String,
    val certificateFingerprint: String,
    val secret: String,
    val expiresAt: String,
) {
    fun normalized(): MobilePairingPayload = copy(
        certificateFingerprint = certificateFingerprint.lowercase(),
    )

    fun isStructurallyValid(): Boolean {
        val normalized = normalized()
        return UUID_PATTERN.matches(id) &&
            HTTPS_ENDPOINT.matches(serviceUrl) &&
            HEX_SHA256.matches(normalized.certificateFingerprint) &&
            secret.length in 40..128 &&
            expiresAt.length in 20..40
    }

    internal companion object {
        val UUID_PATTERN = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
        val HTTPS_ENDPOINT = Regex("^https://(?:\\[[0-9a-fA-F:]+]|[A-Za-z0-9.-]+)(?::(?:[1-9][0-9]{0,4}))?/?$")
        val HEX_SHA256 = Regex("^[0-9a-f]{64}$")
    }
}

@Serializable
data class MobilePairingCompletion(
    @SerialName("session_id") val sessionId: String,
    val secret: String,
    @SerialName("device_name") val deviceName: String,
    @SerialName("public_key") val publicKey: String,
)

@Serializable
data class MobilePairingSubmission(
    @SerialName("request_id") val requestId: String,
    val state: MobilePairingState,
    @SerialName("expires_at") val expiresAt: String,
    @SerialName("poll_after_seconds") val pollAfterSeconds: Int,
)

@Serializable
data class MobilePairingStatusRequest(
    @SerialName("request_id") val requestId: String,
    val secret: String,
)

@Serializable
data class MobilePairingStatus(
    val state: MobilePairingState,
    val credential: MobileDeviceCredential? = null,
)

@Serializable
enum class MobilePairingState {
    @SerialName("awaiting_approval") AWAITING_APPROVAL,
    @SerialName("approved") APPROVED,
    @SerialName("rejected") REJECTED,
}

@Serializable
enum class MobilePermission {
    @SerialName("viewer") VIEWER,
    @SerialName("chat") CHAT,
    @SerialName("operator") OPERATOR,
}

@Serializable
data class MobileDeviceCredential(
    @SerialName("device_id") val deviceId: String,
    @SerialName("device_name") val deviceName: String,
    val permissions: Set<MobilePermission>,
    @SerialName("paired_at") val pairedAt: String,
)

@Serializable
data class MobileBootstrap(
    val overview: MobileGatewayOverview,
    @SerialName("granted_permissions") val grantedPermissions: Set<MobilePermission>,
)

@Serializable
data class MobileGatewayOverview(
    val protocolVersion: String,
    val gatewayVersion: String,
    val generatedAt: String,
    val isGatewayRunning: Boolean,
    val defaultModel: String? = null,
    val enabledProviderCount: Int,
    val enabledRouteCount: Int,
    val modelHealth: MobileModelHealth,
    val providers: List<MobileProviderHealth>,
)

@Serializable
data class MobileModelHealth(
    val total: Int,
    val available: Int,
    val unavailable: Int,
    val unknown: Int,
    val configurationRequired: Int,
    val unsupported: Int,
)

@Serializable
data class MobileProviderHealth(
    val id: String,
    val name: String,
    val totalModels: Int,
    val availableModels: Int,
    val quarantinedModels: Int,
)

object MobileJson {
    val codec = Json {
        ignoreUnknownKeys = false
        explicitNulls = false
        encodeDefaults = true
    }

    @Throws(Exception::class)
    fun decodePairingPayload(value: String): MobilePairingPayload {
        val payload = codec.decodeFromString<MobilePairingPayload>(value).normalized()
        require(payload.isStructurallyValid()) { "Invalid ModelHub pairing payload" }
        return payload
    }

    fun encodePairingCompletion(value: MobilePairingCompletion): String = codec.encodeToString(value)
    fun encodePairingStatus(value: MobilePairingStatusRequest): String = codec.encodeToString(value)
    @Throws(Exception::class)
    fun decodePairingSubmission(value: String): MobilePairingSubmission = codec.decodeFromString(value)
    @Throws(Exception::class)
    fun decodePairingStatus(value: String): MobilePairingStatus = codec.decodeFromString(value)
    @Throws(Exception::class)
    fun decodeBootstrap(value: String): MobileBootstrap = codec.decodeFromString(value)
    fun encodeBootstrap(value: MobileBootstrap): String = codec.encodeToString(value)
}

object MobileRequestCanonicalizer {
    private val UUID_PATTERN = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
    private val ALLOWED_METHODS = setOf("GET", "POST", "PATCH", "DELETE")

    fun canonicalize(
        deviceId: String,
        timestamp: Long,
        nonce: String,
        method: String,
        path: String,
        body: ByteArray,
    ): ByteArray {
        val normalizedMethod = method.uppercase()
        require(method == normalizedMethod && normalizedMethod in ALLOWED_METHODS)
        require(UUID_PATTERN.matches(deviceId))
        require(timestamp > 0)
        require(nonce.length in 16..128 && nonce.all(::isNonceCharacter))
        require(path.startsWith("/mobile/v1/") && path.length <= 2_048)
        require('?' !in path && '#' !in path && '\u0000' !in path)
        require(body.size <= 1_048_576)

        return listOf(
            "MODELHUB-MOBILE-V1",
            deviceId.lowercase(),
            timestamp.toString(),
            nonce,
            normalizedMethod,
            path,
            Sha256.digest(body).toHex(),
        ).joinToString("\n").encodeToByteArray()
    }

    private fun isNonceCharacter(character: Char): Boolean =
        character in '0'..'9' || character in 'A'..'Z' || character in 'a'..'z' || character == '-' || character == '_'

    private fun ByteArray.toHex(): String = joinToString(separator = "") { byte ->
        (byte.toInt() and 0xff).toString(16).padStart(2, '0')
    }
}

sealed interface MobileConnectionState {
    data object Unpaired : MobileConnectionState
    data class AwaitingDesktopApproval(val requestId: String, val pollAfterSeconds: Int) : MobileConnectionState
    data class Connected(val bootstrap: MobileBootstrap) : MobileConnectionState
    data class Offline(val lastKnown: MobileBootstrap?) : MobileConnectionState
    data object Revoked : MobileConnectionState
    data class Failed(val message: String, val canRetry: Boolean) : MobileConnectionState
}

data class MobileTransportRequest(
    val method: String,
    val path: String,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray = byteArrayOf(),
)

data class MobileTransportResponse(
    val statusCode: Int,
    val body: ByteArray,
)

interface MobileGatewayTransport {
    suspend fun execute(request: MobileTransportRequest): MobileTransportResponse
}

interface MobileDeviceSigner {
    val deviceId: String
    val publicKeyX963Base64: String
    fun sign(data: ByteArray): String
}

class MobileGatewayClient(
    private val transport: MobileGatewayTransport,
    private val signer: MobileDeviceSigner,
    private val timestampSeconds: () -> Long,
    private val nonce: () -> String,
) {
    @Throws(Exception::class)
    suspend fun submitPairing(payload: MobilePairingPayload, deviceName: String): MobilePairingSubmission {
        require(payload.isStructurallyValid())
        val normalizedName = deviceName.trim()
        require(normalizedName.encodeToByteArray().size in 1..80) { "Device name must be 1–80 UTF-8 bytes" }
        val requestBody = MobileJson.encodePairingCompletion(
            MobilePairingCompletion(
                sessionId = payload.id,
                secret = payload.secret,
                deviceName = normalizedName,
                publicKey = signer.publicKeyX963Base64,
            ),
        ).encodeToByteArray()
        val response = transport.execute(
            MobileTransportRequest(
                method = "POST",
                path = "/mobile/v1/pairing/complete",
                headers = mapOf("Content-Type" to "application/json"),
                body = requestBody,
            ),
        )
        require(response.statusCode == 202) { "Pairing submission failed: HTTP ${response.statusCode}" }
        return MobileJson.decodePairingSubmission(response.body.decodeToString())
    }

    @Throws(Exception::class)
    suspend fun pairingStatus(requestId: String, secret: String): MobilePairingStatus {
        val body = MobileJson.encodePairingStatus(MobilePairingStatusRequest(requestId, secret)).encodeToByteArray()
        val response = transport.execute(
            MobileTransportRequest(
                method = "POST",
                path = "/mobile/v1/pairing/status",
                headers = mapOf("Content-Type" to "application/json"),
                body = body,
            ),
        )
        require(response.statusCode == 200) { "Pairing status failed: HTTP ${response.statusCode}" }
        return MobileJson.decodePairingStatus(response.body.decodeToString())
    }

    @Throws(Exception::class)
    suspend fun bootstrap(): MobileBootstrap {
        val timestamp = timestampSeconds()
        val requestNonce = nonce()
        val path = "/mobile/v1/bootstrap"
        val signature = signer.sign(
            MobileRequestCanonicalizer.canonicalize(
                deviceId = signer.deviceId,
                timestamp = timestamp,
                nonce = requestNonce,
                method = "GET",
                path = path,
                body = byteArrayOf(),
            ),
        )
        val response = transport.execute(
            MobileTransportRequest(
                method = "GET",
                path = path,
                headers = mapOf(
                    "X-ModelHub-Device-ID" to signer.deviceId,
                    "X-ModelHub-Timestamp" to timestamp.toString(),
                    "X-ModelHub-Nonce" to requestNonce,
                    "X-ModelHub-Signature" to signature,
                ),
            ),
        )
        require(response.statusCode == 200) { "Bootstrap failed: HTTP ${response.statusCode}" }
        return MobileJson.decodeBootstrap(response.body.decodeToString())
    }
}
