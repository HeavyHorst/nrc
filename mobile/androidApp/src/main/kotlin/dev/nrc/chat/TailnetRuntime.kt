package dev.nrc.chat

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.IOException
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Native boundary; the runtime owns nodes, while activities only own sessions. */
internal interface TailnetNode {
    val address: String
    val password: String
    fun status(): String
    fun authUrl(): String
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

        fun configure(authority: String?) {
            executor.execute {
                if (released || activeSession !== this) return@execute
                configuredAuthority = authority
                if (owner === this && target != authority) safelyDetach()
            }
        }

        fun proxyFor(authority: String): TailnetProxy {
            if (released) throw IOException("Tailnet session closed")
            try {
                return executor.submit<TailnetProxy> {
                    if (released || activeSession !== this || configuredAuthority != authority)
                        throw IOException("Obsolete tailnet request")
                    if (owner !== this || target != authority) {
                        detach()
                        owner = this
                        target = authority
                    }
                    val current = node ?: start(authority).also { node = it }
                    TailnetProxy(current.address, current.password)
                }.get()
            } catch (failure: ExecutionException) {
                throw IOException("Embedded tailnet unavailable", failure.cause)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                throw IOException("Tailnet request interrupted", interrupted)
            }
        }

        fun networkChanged() {
            executor.execute { if (owner === this) safelyDetach() }
        }

        fun close() {
            released = true
            executor.execute { if (owner === this) safelyDetach() }
        }

        internal fun showSignIn(url: String?) { pendingSignIn.value = url }
    }

    private fun poll() {
        val current = node ?: return
        try {
            val status = current.status()
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
        owner = null
        target = null
        lastStatus = null
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
