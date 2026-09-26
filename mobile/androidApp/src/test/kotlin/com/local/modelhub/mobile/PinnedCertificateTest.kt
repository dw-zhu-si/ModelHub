package com.local.modelhub.mobile

import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import org.junit.Test

class PinnedCertificateTest {
    @Test
    fun fingerprintNormalizesUppercaseAndColons() {
        val raw = "AA:".repeat(31) + "AA"
        assertEquals("aa".repeat(32), PinnedCertificate.normalizeFingerprint(raw))
    }

    @Test
    fun malformedFingerprintFailsClosed() {
        assertFailsWith<IllegalArgumentException> {
            PinnedCertificate.normalizeFingerprint("abc")
        }
    }
}
