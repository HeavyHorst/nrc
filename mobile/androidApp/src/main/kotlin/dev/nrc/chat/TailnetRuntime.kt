package dev.nrc.chat

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Native boundary; the runtime owns nodes, while activities only own sessions. */
internal interface TailnetNode {
    val address: String
    val password: String
    fun status(): String
    fun authUrl(): String
    fun dialFailure(): String
    fun dialFailureCount(): Long
    fun logout()
    fun login()
    fun close()
}

internal data class TailnetProxy(val address: String, val password: String)

/** One process-wide queue serializes every use of the private node directory.
 * Releasing an activity never waits for native shutdown; replacement startup
 * still waits behind that shutdown, including overlapping activity recreation.
 */
internal class TailnetRuntime(private val start: (String) -> TailnetNode,
                              private val onFailure: (Exception) -> Unit) : AutoCloseable {
    private val executor = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "nrc-tailnet").apply { isDaemon = true }
    }
    private var activeSession: Session? = null
    private var owner: Session? = null
    private var node: TailnetNode? = null
    private var target: String? = null
    private var lastStatus: String? = null
    private var lastDialFailureCount = 0L
    private var observedRunning = false

    init { executor.scheduleWithFixedDelay({ poll() }, 0, 500, TimeUnit.MILLISECONDS) }

    fun acquire() = Session().also { session ->
        executor.execute { activeSession = session; safelyDetach() }
    }

    inner class Session internal constructor() {
        @Volatile private var released = false
        private var configuredAuthority: String? = null
        private val pendingSignIn = MutableStateFlow<String?>(null)
        val signInUrl: StateFlow<String?> = pendingSignIn
        private val dialDiagnostic = MutableStateFlow<DiagnosticEvent?>(null)
        val diagnostic: StateFlow<DiagnosticEvent?> = dialDiagnostic
        private val changingAccount = MutableStateFlow(false)
        val switching: StateFlow<Boolean> = changingAccount

        fun configure(authority: String?) {
            executor.execute {
                if (released || activeSession !== this) return@execute
                configuredAuthority = authority
                if (owner === this && target != authority) safelyDetach()
            }
        }

        fun proxyFor(authority: String): TailnetProxy {
            if (released) throw IOException("Tailnet session closed")
            if (changingAccount.value) throw IOException("Tailnet account change in progress")
            try {
                return executor.submit<TailnetProxy> {
                    val current = currentNode(authority)
                    TailnetProxy(current.address, current.password)
                }.get()
            } catch (failure: ExecutionException) {
                throw IOException("Embedded tailnet unavailable", failure.cause)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                throw IOException("Tailnet request interrupted", interrupted)
            }
        }

        // Called only on the runtime queue, including replacement after logout.
        private fun currentNode(authority: String): TailnetNode {
            if (released || activeSession !== this || configuredAuthority != authority)
                throw IOException("Obsolete tailnet request")
            if (owner !== this || target != authority) {
                detach()
                owner = this
                target = authority
            }
            return node ?: start(authority).also { node = it }
        }

        fun switchAccount(): CompletableFuture<Unit> {
            val result = CompletableFuture<Unit>()
            if (!changingAccount.compareAndSet(false, true)) {
                result.completeExceptionally(IOException("Tailnet account change already in progress"))
                return result
            }
            executor.execute {
                try {
                    val authority = configuredAuthority ?: throw IOException("No tailnet endpoint configured")
                    currentNode(authority).logout()
                    // Retire every old CONNECT tunnel before exposing a new login.
                    detach()
                    currentNode(authority).login()
                    changingAccount.value = false
                    result.complete(Unit)
                } catch (failure: Exception) {
                    changingAccount.value = false
                    result.completeExceptionally(failure)
                }
            }
            return result
        }

        fun networkChanged() {
            executor.execute { if (owner === this) safelyDetach() }
        }

        fun close() {
            released = true
            executor.execute { if (owner === this) safelyDetach() }
        }

        internal fun showSignIn(url: String?) { pendingSignIn.value = url }
        internal fun showDiagnostic(event: DiagnosticEvent?) { dialDiagnostic.value = event }
    }

    private fun poll() {
        val current = node ?: return
        try {
            val status = try { current.status() }
                catch (failure: Exception) { onFailure(failure); null }
            val failureCount = current.dialFailureCount()
            val failure = current.dialFailure()
            val detail = when (failure) {
                "" -> null
                "dns" -> "DNS lookup failed inside tsnet. Check the configured hostname and whether this node can see the server peer."
                "refused" -> "The server connection was refused. Check the server port and listening proxy."
                "timeout" -> "The server dial timed out. Check peer reachability, routing, access policy and server availability."
                "unreachable" -> "The server network or host is unreachable. Check peer visibility and routing."
                "permission" -> "The dial was denied by a local socket or OS permission. This does not establish a tailnet ACL rejection."
                "canceled" -> "The dial was canceled while the embedded node was stopping."
                else -> "The embedded dial failed with an unclassified error."
            }
            val safeStatus = if (status == null) "Unavailable" else
                status.takeIf { it in setOf("NoState", "Stopped", "Starting", "NeedsLogin", "NeedsMachineAuth", "Running", "InUseOtherUser") } ?: "Unknown"
            if (detail == null) owner?.showDiagnostic(null)
            else if (failureCount != lastDialFailureCount || status != lastStatus) {
                owner?.showDiagnostic(DiagnosticEvent(System.currentTimeMillis(), DiagnosticLevel.Error,
                    "Embedded Tailscale dial failed", "Backend: $safeStatus. $detail"))
            }
            lastDialFailureCount = failureCount
            if (status == null) { lastStatus = null; return }
            // tsnet handles initial enrollment itself. Do not force login on
            // its transient startup states when restoring a persisted identity.
            if (status == "Running") observedRunning = true
            if (status == "NeedsLogin" && observedRunning && status != lastStatus) current.login()
            lastStatus = status
            owner?.showSignIn(if (status == "Running") null else current.authUrl().takeIf { it.isNotBlank() })
        } catch (failure: Exception) { onFailure(failure) }
    }

    private fun detach() {
        val previous = node
        node = null
        owner?.showSignIn(null)
        owner?.showDiagnostic(null)
        owner = null
        target = null
        lastStatus = null
        lastDialFailureCount = 0L
        observedRunning = false
        previous?.close()
    }

    private fun safelyDetach() {
        try { detach() } catch (failure: Exception) { onFailure(failure) }
    }

    override fun close() {
        executor.execute { safelyDetach() }
        executor.shutdown()
    }
}
