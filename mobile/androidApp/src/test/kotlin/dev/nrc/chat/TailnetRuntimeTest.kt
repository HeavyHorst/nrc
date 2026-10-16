package dev.nrc.chat

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class TailnetRuntimeTest {
    private class Node(private val closeAction: () -> Unit = {}) : TailnetNode {
        override val address = "127.0.0.1:12345"
        override val password = "test-only"
        @Volatile var state = "NeedsLogin"
        @Volatile var url = "https://login.example/initial"
        override fun status() = state
        override fun authUrl() = url
        override fun login() { url = "https://login.example/renewed" }
        override fun close() = closeAction()
    }

    @Test fun pendingEnrollmentSurvivesBrowserCancellationAndReturnsAfterExpiry() = runBlocking {
        val node = Node()
        val failures = mutableListOf<Exception>()
        val runtime = TailnetRuntime({ node }, { synchronized(failures) { failures.add(it) } })
        try {
            val session = runtime.acquire()
            session.configure("nrc.example:443")
            session.proxyFor("nrc.example:443")
            withTimeout(5_000) { session.signInUrl.first { it == "https://login.example/initial" } }
            // A browser roundtrip/reconnect does not consume the same pending URL.
            session.proxyFor("nrc.example:443")
            assertEquals("https://login.example/initial", session.signInUrl.value)
            node.state = "Running"
            withTimeout(5_000) { session.signInUrl.first { it == null } }
            node.url = ""; node.state = "NeedsLogin"
            withTimeout(5_000) { session.signInUrl.first { it == "https://login.example/renewed" } }
            node.state = "Running"
            withTimeout(5_000) { session.signInUrl.first { it == null } }
            synchronized(failures) { assertTrue(failures.isEmpty()) }
        } finally { runtime.close() }
    }

    @Test fun activityReleaseReturnsWhileNativeCloseWaitsAndReplacementNeverOverlaps() {
        val closing = CountDownLatch(1)
        val allowClose = CountDownLatch(1)
        val active = AtomicInteger()
        val starts = AtomicInteger()
        val runtime = TailnetRuntime(start = {
            assertEquals("Only one native identity-directory owner", 1, active.incrementAndGet())
            val first = starts.incrementAndGet() == 1
            Node {
                if (first) { closing.countDown(); check(allowClose.await(5, TimeUnit.SECONDS)) }
                active.decrementAndGet()
            }
        }, onFailure = { throw AssertionError(it) })
        try {
            val activity = runtime.acquire()
            activity.configure("nrc.example:443")
            activity.proxyFor("nrc.example:443")
            // If close becomes synchronous, this call hangs until the fake's timeout.
            activity.close()
            assertTrue(closing.await(2, TimeUnit.SECONDS))
            assertEquals(1L, allowClose.count)
            val nextActivity = runtime.acquire()
            nextActivity.configure("nrc.example:443")
            val nextProxy = CompletableFuture.supplyAsync { nextActivity.proxyFor("nrc.example:443") }
            assertFalse(nextProxy.isDone)
            assertEquals(1, starts.get())
            allowClose.countDown()
            assertEquals("127.0.0.1:12345", nextProxy.get(5, TimeUnit.SECONDS).address)
            activity.close() // Late cleanup of the old activity cannot close its replacement.
            assertEquals(Node().password, nextActivity.proxyFor("nrc.example:443").password)
            assertEquals(2, starts.get())
            assertThrows(IOException::class.java) { activity.proxyFor("nrc.example:443") }
            nextActivity.networkChanged()
            nextActivity.proxyFor("nrc.example:443")
            assertEquals(3, starts.get())
        } finally { allowClose.countDown(); runtime.close() }
    }

    @Test fun obsoleteServerAndActivityRequestsCannotReplaceCurrentTunnel() {
        val started = mutableListOf<String>()
        val closed = mutableListOf<String>()
        val runtime = TailnetRuntime({ authority ->
            started.add(authority)
            Node { closed.add(authority) }
        }, { throw AssertionError(it) })
        try {
            val session = runtime.acquire()
            session.configure("old.example:443"); session.proxyFor("old.example:443")
            session.configure("new.example:443"); session.proxyFor("new.example:443")
            assertThrows(IOException::class.java) { session.proxyFor("old.example:443") }
            session.proxyFor("new.example:443")
            assertEquals(listOf("old.example:443", "new.example:443"), started)
            assertEquals(listOf("old.example:443"), closed)
            val replacement = runtime.acquire()
            replacement.configure("new.example:443"); replacement.proxyFor("new.example:443")
            assertThrows(IOException::class.java) { session.proxyFor("new.example:443") }
            session.networkChanged(); session.close()
            replacement.proxyFor("new.example:443")
            assertEquals(3, started.size)
            assertEquals(2, closed.size)
        } finally { runtime.close() }
    }
}
