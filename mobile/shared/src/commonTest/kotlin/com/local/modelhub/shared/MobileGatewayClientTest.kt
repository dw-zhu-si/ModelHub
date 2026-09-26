package com.local.modelhub.shared

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class MobileGatewayClientTest {
    private val deviceId = "9a8cbadc-8ce8-442f-bc74-29b1e70aa1d4"

    @Test
    fun pairingRequestUsesOnlyPairingEndpointAndExplicitPublicKey() = runTest {
        val transport = RecordingTransport(
            MobileTransportResponse(
                statusCode = 202,
                body = """
                    {
                      "request_id":"6a896b7d-8408-4f31-bba8-a14cf4b1b8d5",
                      "state":"awaiting_approval",
                      "expires_at":"2026-09-25T12:05:00Z",
                      "poll_after_seconds":2
                    }
                """.trimIndent().encodeToByteArray(),
            ),
        )
        val signer = RecordingSigner(deviceId)
        val client = MobileGatewayClient(transport, signer, { 1_790_336_000 }, { "abcDEF0123_nonce-9" })
        val payload = MobilePairingPayload(
            id = "3c7ba41c-55fd-426e-95a2-8b68c62f5098",
            serviceUrl = "https://192.168.1.10:11470",
            certificateFingerprint = "a".repeat(64),
            secret = "0123456789012345678901234567890123456789012",
            expiresAt = "2026-09-25T12:00:00Z",
        )

        val result = client.submitPairing(payload, "iPhone 17")

        assertEquals(MobilePairingState.AWAITING_APPROVAL, result.state)
        val request = transport.requests.single()
        assertEquals("POST", request.method)
        assertEquals("/mobile/v1/pairing/complete", request.path)
        assertEquals("application/json", request.headers["Content-Type"])
        val body = request.body.decodeToString()
        assertTrue(body.contains("\"public_key\":\"BASE64_X963_PUBLIC_KEY\""))
        assertTrue(body.contains("\"device_name\":\"iPhone 17\""))
        assertTrue(body.contains("\"secret\":\"${payload.secret}\""))
        assertFalse(body.contains(payload.serviceUrl))
    }

    @Test
    fun bootstrapSignsCanonicalRequestAndSendsNoPairingSecret() = runTest {
        val transport = RecordingTransport(
            MobileTransportResponse(
                statusCode = 200,
                body = """
                    {
                      "overview": {
                        "protocolVersion":"1",
                        "gatewayVersion":"1.10.0",
                        "generatedAt":"2026-09-25T12:00:00Z",
                        "isGatewayRunning":true,
                        "defaultModel":"route/smart",
                        "enabledProviderCount":2,
                        "enabledRouteCount":1,
                        "modelHealth":{"total":5,"available":4,"unavailable":1,"unknown":0,"configurationRequired":0,"unsupported":0},
                        "providers":[]
                      },
                      "granted_permissions":["viewer"]
                    }
                """.trimIndent().encodeToByteArray(),
            ),
        )
        val signer = RecordingSigner(deviceId)
        val client = MobileGatewayClient(transport, signer, { 1_790_336_000 }, { "abcDEF0123_nonce-9" })

        val bootstrap = client.bootstrap()

        assertEquals("route/smart", bootstrap.overview.defaultModel)
        val request = transport.requests.single()
        assertEquals("GET", request.method)
        assertEquals("/mobile/v1/bootstrap", request.path)
        assertTrue(request.body.isEmpty())
        assertEquals(deviceId, request.headers["X-ModelHub-Device-ID"])
        assertEquals("1790336000", request.headers["X-ModelHub-Timestamp"])
        assertEquals("abcDEF0123_nonce-9", request.headers["X-ModelHub-Nonce"])
        assertEquals("BASE64_SIGNATURE", request.headers["X-ModelHub-Signature"])
        assertEquals(
            MobileRequestCanonicalizer.canonicalize(
                deviceId = deviceId,
                timestamp = 1_790_336_000,
                nonce = "abcDEF0123_nonce-9",
                method = "GET",
                path = "/mobile/v1/bootstrap",
                body = byteArrayOf(),
            ).decodeToString(),
            signer.lastSigned?.decodeToString(),
        )
    }

    @Test
    fun pairingRejectsDeviceNameLongerThanEightyUtf8BytesBeforeNetworkCall() = runTest {
        val transport = RecordingTransport(
            MobileTransportResponse(statusCode = 500, body = byteArrayOf()),
        )
        val client = MobileGatewayClient(
            transport,
            RecordingSigner(deviceId),
            { 1_790_336_000 },
            { "abcDEF0123_nonce-9" },
        )
        val payload = MobilePairingPayload(
            id = "3c7ba41c-55fd-426e-95a2-8b68c62f5098",
            serviceUrl = "https://192.168.1.10:11470",
            certificateFingerprint = "a".repeat(64),
            secret = "0123456789012345678901234567890123456789012",
            expiresAt = "2026-09-25T12:00:00Z",
        )

        assertFailsWith<IllegalArgumentException> {
            client.submitPairing(payload, "设".repeat(27))
        }
        assertTrue(transport.requests.isEmpty())
    }

    private class RecordingTransport(
        private val response: MobileTransportResponse,
    ) : MobileGatewayTransport {
        val requests = mutableListOf<MobileTransportRequest>()

        override suspend fun execute(request: MobileTransportRequest): MobileTransportResponse {
            requests += request
            return response
        }
    }

    private class RecordingSigner(
        override val deviceId: String,
    ) : MobileDeviceSigner {
        override val publicKeyX963Base64 = "BASE64_X963_PUBLIC_KEY"
        var lastSigned: ByteArray? = null

        override fun sign(data: ByteArray): String {
            lastSigned = data.copyOf()
            return "BASE64_SIGNATURE"
        }
    }
}
