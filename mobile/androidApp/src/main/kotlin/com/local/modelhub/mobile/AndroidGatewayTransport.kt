package com.local.modelhub.mobile

import com.local.modelhub.shared.MobileGatewayTransport
import com.local.modelhub.shared.MobileTransportRequest
import com.local.modelhub.shared.MobileTransportResponse
import java.io.ByteArrayOutputStream
import java.net.URL
import java.security.SecureRandom
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext

class AndroidGatewayTransport(
    serviceUrl: String,
    certificateFingerprint: String,
) : MobileGatewayTransport {
    private val baseUrl = serviceUrl.removeSuffix("/")
    private val expectedFingerprint = PinnedCertificate.normalizeFingerprint(certificateFingerprint)
    private val socketFactory = SSLContext.getInstance("TLSv1.3").apply {
        init(null, arrayOf(PinnedCertificateTrustManager(expectedFingerprint)), SecureRandom())
    }.socketFactory

    init {
        val parsed = URL(baseUrl)
        require(parsed.protocol == "https" && parsed.userInfo == null && parsed.query == null && parsed.ref == null)
        require(parsed.path.isEmpty() || parsed.path == "/")
    }

    override suspend fun execute(request: MobileTransportRequest): MobileTransportResponse {
        require(request.path.startsWith("/mobile/v1/") && '?' !in request.path && '#' !in request.path)
        require(request.body.size <= MAX_REQUEST_BYTES)
        val connection = URL(baseUrl + request.path).openConnection() as HttpsURLConnection
        try {
            connection.sslSocketFactory = socketFactory
            connection.hostnameVerifier = javax.net.ssl.HostnameVerifier { _, session ->
                val certificate = session.peerCertificates.firstOrNull() as? java.security.cert.X509Certificate
                certificate != null && PinnedCertificate.sha256(certificate) == expectedFingerprint
            }
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 8_000
            connection.readTimeout = 12_000
            connection.requestMethod = request.method
            connection.setRequestProperty("Accept", "application/json")
            request.headers.forEach { (name, value) ->
                require('\r' !in name && '\n' !in name && '\r' !in value && '\n' !in value)
                connection.setRequestProperty(name, value)
            }
            if (request.body.isNotEmpty()) {
                connection.doOutput = true
                connection.outputStream.use { it.write(request.body) }
            }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            return MobileTransportResponse(status, stream?.use(::readBounded) ?: byteArrayOf())
        } finally {
            connection.disconnect()
        }
    }

    private fun readBounded(stream: java.io.InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8_192)
        var total = 0
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            total += count
            require(total <= MAX_RESPONSE_BYTES) { "ModelHub response exceeded 1 MiB" }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private companion object {
        const val MAX_REQUEST_BYTES = 16 * 1_024
        const val MAX_RESPONSE_BYTES = 1_024 * 1_024
    }
}
