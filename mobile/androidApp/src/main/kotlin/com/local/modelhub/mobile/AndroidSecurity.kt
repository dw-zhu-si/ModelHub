package com.local.modelhub.mobile

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.local.modelhub.shared.MobileDeviceSigner
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import javax.net.ssl.X509TrustManager

object PinnedCertificate {
    fun normalizeFingerprint(value: String): String {
        val normalized = value.lowercase().replace(":", "")
        require(normalized.length == 64 && normalized.all { it in '0'..'9' || it in 'a'..'f' }) {
            "Invalid SHA-256 certificate fingerprint"
        }
        return normalized
    }

    fun sha256(certificate: X509Certificate): String =
        MessageDigest.getInstance("SHA-256")
            .digest(certificate.encoded)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

class PinnedCertificateTrustManager(fingerprint: String) : X509TrustManager {
    private val expectedFingerprint = PinnedCertificate.normalizeFingerprint(fingerprint)

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        throw CertificateException("Client certificates are not accepted")
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("Missing server certificate")
        leaf.checkValidity()
        if (!MessageDigest.isEqual(
                PinnedCertificate.sha256(leaf).encodeToByteArray(),
                expectedFingerprint.encodeToByteArray(),
            )
        ) {
            throw CertificateException("ModelHub certificate fingerprint mismatch")
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

class AndroidDeviceIdentity(context: Context) : MobileDeviceSigner {
    private val preferences = context.getSharedPreferences("mobile_device_identity", Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    override val deviceId: String
        get() = preferences.getString(KEY_DEVICE_ID, null) ?: UNPAIRED_DEVICE_ID

    val isPaired: Boolean
        get() = preferences.contains(KEY_DEVICE_ID)

    override val publicKeyX963Base64: String
        get() {
            val publicKey = certificate().publicKey as? ECPublicKey
                ?: error("ModelHub device key is not P-256")
            val coordinateSize = 32
            val x = publicKey.w.affineX.toUnsignedFixed(coordinateSize)
            val y = publicKey.w.affineY.toUnsignedFixed(coordinateSize)
            return Base64.encodeToString(byteArrayOf(0x04) + x + y, Base64.NO_WRAP)
        }

    override fun sign(data: ByteArray): String {
        val privateKey = keyStore.getKey(KEY_ALIAS, null)
            ?: error("ModelHub device key is unavailable")
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(privateKey as java.security.PrivateKey)
        signature.update(data)
        return Base64.encodeToString(signature.sign(), Base64.NO_WRAP)
    }

    fun storeApprovedDevice(deviceId: String) {
        require(UUID_PATTERN.matches(deviceId))
        preferences.edit().putString(KEY_DEVICE_ID, deviceId.lowercase()).apply()
    }

    fun forgetDevice() {
        if (keyStore.containsAlias(KEY_ALIAS)) keyStore.deleteEntry(KEY_ALIAS)
        preferences.edit().remove(KEY_DEVICE_ID).apply()
    }

    private fun certificate(): X509Certificate {
        if (!keyStore.containsAlias(KEY_ALIAS)) {
            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC,
                "AndroidKeyStore",
            )
            generator.initialize(
                KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setUserAuthenticationRequired(false)
                    .build(),
            )
            generator.generateKeyPair()
        }
        return keyStore.getCertificate(KEY_ALIAS) as X509Certificate
    }

    private fun BigInteger.toUnsignedFixed(size: Int): ByteArray {
        val raw = toByteArray()
        val unsigned = if (raw.size > size && raw.first() == 0.toByte()) raw.copyOfRange(1, raw.size) else raw
        require(unsigned.size <= size)
        return ByteArray(size - unsigned.size) + unsigned
    }

    private companion object {
        const val KEY_ALIAS = "modelhub.mobile.device-signing.v1"
        const val KEY_DEVICE_ID = "approved_device_id"
        const val UNPAIRED_DEVICE_ID = "00000000-0000-4000-8000-000000000000"
        val UUID_PATTERN = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
    }
}
