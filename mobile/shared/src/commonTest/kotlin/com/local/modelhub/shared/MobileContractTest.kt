package com.local.modelhub.shared

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MobileContractTest {
    @Test
    fun pairingPayloadParsesAndNormalizesFingerprint() {
        val json = """
            {
              "id":"9a8cbadc-8ce8-442f-bc74-29b1e70aa1d4",
              "serviceURL":"https://192.168.1.10:11470",
              "certificateFingerprint":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
              "secret":"0123456789012345678901234567890123456789012",
              "expiresAt":"2026-09-25T12:00:00Z"
            }
        """.trimIndent()

        val payload = MobileJson.decodePairingPayload(json)

        assertEquals("https://192.168.1.10:11470", payload.serviceUrl)
        assertEquals("a".repeat(64), payload.certificateFingerprint)
        assertTrue(payload.isStructurallyValid())
    }

    @Test
    fun pairingPayloadRejectsNonHttpsAndMalformedFingerprint() {
        val payload = MobilePairingPayload(
            id = "9a8cbadc-8ce8-442f-bc74-29b1e70aa1d4",
            serviceUrl = "http://192.168.1.10:11470",
            certificateFingerprint = "not-a-fingerprint",
            secret = "short",
            expiresAt = "2026-09-25T12:00:00Z",
        )

        assertFalse(payload.isStructurallyValid())
    }

    @Test
    fun canonicalRequestMatchesDesktopContractAndKnownSha256() {
        val canonical = MobileRequestCanonicalizer.canonicalize(
            deviceId = "9A8CBADC-8CE8-442F-BC74-29B1E70AA1D4",
            timestamp = 1_790_336_000,
            nonce = "abcDEF0123_nonce-9",
            method = "GET",
            path = "/mobile/v1/bootstrap",
            body = byteArrayOf(),
        )

        assertEquals(
            listOf(
                "MODELHUB-MOBILE-V1",
                "9a8cbadc-8ce8-442f-bc74-29b1e70aa1d4",
                "1790336000",
                "abcDEF0123_nonce-9",
                "GET",
                "/mobile/v1/bootstrap",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ).joinToString("\n"),
            canonical.decodeToString(),
        )
    }

    @Test
    fun canonicalRequestFailsClosedOutsideMobileAllowlist() {
        assertFailsWith<IllegalArgumentException> {
            MobileRequestCanonicalizer.canonicalize(
                deviceId = "9a8cbadc-8ce8-442f-bc74-29b1e70aa1d4",
                timestamp = 1,
                nonce = "abcDEF0123_nonce-9",
                method = "GET",
                path = "/v1/providers",
                body = byteArrayOf(),
            )
        }
    }

    @Test
    fun overviewDecoderDoesNotModelDesktopSecrets() {
        val overview = MobileJson.decodeBootstrap(
            """
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
                "providers":[{"id":"9a8cbadc-8ce8-442f-bc74-29b1e70aa1d4","name":"Example","totalModels":3,"availableModels":2,"quarantinedModels":1}]
              },
              "granted_permissions":["viewer"]
            }
            """.trimIndent(),
        )

        assertEquals("route/smart", overview.overview.defaultModel)
        assertEquals(setOf(MobilePermission.VIEWER), overview.grantedPermissions)
        assertFalse(overview.toString().contains("apiKey", ignoreCase = true))
        assertFalse(overview.toString().contains("baseURL", ignoreCase = true))
    }
}
