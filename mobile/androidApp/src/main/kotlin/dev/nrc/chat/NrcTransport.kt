package dev.nrc.chat

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log
import okhttp3.Credentials
import okhttp3.OkHttpClient
import org.json.JSONArray
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.io.IOException
import java.util.Collections
import tailnet.Interfaces
import tailnet.Tailnet

/** App-local Tailscale transport. No VpnService and no bundled auth key. */
internal class NrcTransport(context: Context) {
    private val session = runtime(context.noBackupFilesDir.resolve("embedded-tailnet").absolutePath).acquire()
    val signInUrl = session.signInUrl
    val diagnostic = session.diagnostic
    val switching = session.switching
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val networkChanges = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = session.networkChanged()
        override fun onLost(network: Network) = session.networkChanged()
    }

    companion object {
        private var instance: TailnetRuntime? = null
        @Synchronized
        private fun runtime(directory: String): TailnetRuntime {
            instance?.let { return it }
            Tailnet.initialize(directory, object : Interfaces {
                override fun snapshot(): String = JSONArray().apply {
                    Collections.list(NetworkInterface.getNetworkInterfaces()).forEach { iface ->
                        put(JSONObject().apply {
                            put("Name", iface.name); put("Index", iface.index); put("MTU", iface.mtu)
                            put("Up", iface.isUp); put("Loopback", iface.isLoopback)
                            put("Addresses", JSONArray().apply {
                                iface.interfaceAddresses.forEach { address ->
                                    put("${address.address.hostAddress!!}/${address.networkPrefixLength}")
                                }
                            })
                        })
                    }
                }.toString()
            })
            return TailnetRuntime(start = { authority ->
                val native = Tailnet.start(directory, BuildConfig.TAILSCALE_CONTROL_URL, authority)
                object : TailnetNode {
                    override val address get() = native.address()
                    override val password get() = native.password()
                    override fun status() = native.status()
                    override fun authUrl() = native.authURL()
                    override fun dialFailure() = native.dialFailure()
                    override fun dialFailureCount() = native.dialFailureCount()
                    override fun logout() = native.logout()
                    override fun login() = native.login()
                    override fun close() = native.close()
                }
            }, onFailure = { failure ->
                // No URL, key or raw exception text in Android logs.
                Log.w("NrcTailnet", "Tailnet operation failed: ${failure.javaClass.simpleName}")
            }).also { instance = it }
        }
    }

    init { connectivity.registerDefaultNetworkCallback(networkChanges) }

    private fun authority(uri: URI) = "${uri.host.lowercase()}:${if (uri.port == -1) 443 else uri.port}"
    fun configureServer(profile: Profile) {
        val uri = runCatching { URI(ChatClient.connectionUrl(profile)) }.getOrNull()
        session.configure(uri?.let(::authority))
    }

    private fun proxyFor(uri: URI) = session.proxyFor(authority(uri))

    fun switchAccount() = session.switchAccount()

    fun configure(builder: OkHttpClient.Builder) {
        builder.proxySelector(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                require(uri.scheme == "https") { "Embedded tailnet requires HTTPS" }
                val address = proxyFor(uri).address.split(':')
                return listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress(address[0], address[1].toInt())))
            }
            override fun connectFailed(uri: URI, address: SocketAddress, failure: IOException) = Unit
        })
        builder.proxyAuthenticator { _, response ->
            if (response.code != 407 || response.request.header("Proxy-Authorization") != null) null
            else response.request.newBuilder().header("Proxy-Authorization",
                Credentials.basic("nrc", proxyFor(response.request.url.toUri()).password)).build()
        }
    }

    fun close() {
        connectivity.unregisterNetworkCallback(networkChanges)
        session.close() // Enqueue native shutdown; never wait from onDestroy.
    }
}
