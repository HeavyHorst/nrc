package dev.nrc.chat

import io.ktor.client.plugins.ResponseException
import kotlinx.serialization.Serializable

const val MAX_DIAGNOSTIC_EVENTS = 200

@Serializable
enum class DiagnosticLevel { Info, Warning, Error }

@Serializable
data class DiagnosticEvent(val timestampMillis: Long, val level: DiagnosticLevel,
                           val summary: String, val detail: String = "")

/** Never serialize exception messages, stack traces, URLs, headers or server payloads. */
internal fun connectionFailure(error: Throwable, phase: String, reason: String?): Pair<String, String> {
    val causes = generateSequence(error) { it.cause }.take(8).toList()
    val names = causes.map { it::class.simpleName.orEmpty().take(80).ifEmpty { "Exception" } }
    val status = causes.filterIsInstance<ResponseException>().firstOrNull()?.response?.status?.value
        // Ktor 3/OkHttp discard the typed response for rejected WebSocket upgrades.
        // Read only the numeric status from their exact error prefixes, never the reason phrase.
        ?: causes.firstNotNullOfOrNull { cause ->
            val pattern = when (cause::class.simpleName) {
                "ProtocolException" -> "^Expected HTTP 101 response but was '([1-5][0-9]{2})(?: |')"
                "WebSocketException" -> "^Handshake exception, expected status code 101 but was ([1-5][0-9]{2})$"
                else -> return@firstNotNullOfOrNull null
            }
            Regex(pattern).find(cause.message.orEmpty())?.groupValues?.get(1)?.toIntOrNull()
        }
    // Extract only known constant OS codes, never surrounding exception text.
    val errno = listOf("ECONNREFUSED", "ENETUNREACH", "EHOSTUNREACH", "ETIMEDOUT", "EACCES", "EPERM")
        .firstOrNull { code -> causes.any { it.message?.contains(code) == true } }
    val hint = when {
        reason != null -> reason
        status == 401 || status == 403 -> "HTTP $status: access rejected. Check proxy authentication and Tailscale access policy."
        status != null -> "HTTP $status: WebSocket upgrade failed. Check the HTTPS proxy and NRC route."
        names.any { it == "UnknownHostException" || it == "UnresolvedAddressException" } ->
            "DNS resolution failed. Check the server hostname and Tailscale DNS connection."
        names.any { it.contains("SSL") || it.contains("TLS") || it.contains("CertPath") || it.contains("Certificate") } ->
            "TLS verification or negotiation failed. Check certificate trust, HTTPS hostname and device time."
        names.any { it.contains("Timeout") } -> "Network operation timed out. Check connectivity, proxy and server availability."
        names.any { it == "ConnectException" || it == "NoRouteToHostException" } ->
            "TCP connection failed. Check Tailscale routing, server port and proxy availability."
        else -> "Connection failed. The technical cause chain is shown below; no raw server or exception text is stored."
    }
    return "$phase failed" to "$hint\n${names.joinToString(" → ")}${errno?.let { " [$it]" }.orEmpty()}"
}

fun diagnosticReport(events: List<DiagnosticEvent>): String = buildString {
    appendLine("NRC chat · system log · timestamps UTC")
    appendLine("Sanitized operational events only; no message contents, addresses or credentials.")
    events.forEach { event ->
        appendLine("${kotlinx.datetime.Instant.fromEpochMilliseconds(event.timestampMillis)} ${event.level.name.uppercase()} ${event.summary}")
        if (event.detail.isNotEmpty()) appendLine(event.detail)
    }
}
