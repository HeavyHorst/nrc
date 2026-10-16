import java.io.FileInputStream;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.security.cert.CertificateFactory;
import java.io.ByteArrayInputStream;
import java.util.Base64;
import java.util.Properties;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import okhttp3.*;
import okhttp3.tls.HandshakeCertificates;
import okio.ByteString;

// Uses the same OkHttp transport as Android, without mocking the tailnet. The
// lab-only certificate is explicitly trusted; production certificate checks
// are not disabled. Credentials arrive via a mode-0600 temporary file.
public final class OkHttpProbe {
    public static void main(String[] args) throws Exception {
        Properties p = new Properties();
        try (FileInputStream input = new FileInputStream(args[0])) { p.load(input); }
        String[] address = p.getProperty("proxy").split(":");
        Proxy proxy = new Proxy(Proxy.Type.HTTP, new InetSocketAddress(address[0], Integer.parseInt(address[1])));
        var certificate = (java.security.cert.X509Certificate) CertificateFactory.getInstance("X.509")
            .generateCertificate(new ByteArrayInputStream(Base64.getDecoder().decode(p.getProperty("certificate"))));
        var trust = new HandshakeCertificates.Builder().addTrustedCertificate(certificate).build();
        OkHttpClient client = new OkHttpClient.Builder().proxy(proxy)
            .proxyAuthenticator((route, response) -> {
                if (response.request().header("Proxy-Authorization") != null) return null;
                return response.request().newBuilder().header("Proxy-Authorization",
                    Credentials.basic("nrc", p.getProperty("password"))).build();
            })
            .sslSocketFactory(trust.sslSocketFactory(), trust.trustManager())
            .callTimeout(15, TimeUnit.SECONDS).build();
        String url = "https://" + p.getProperty("target");
        try {
            try (Response response = client.newCall(new Request.Builder().url(url).build()).execute()) {
                if (response.code() != 200 || !response.body().string().startsWith("nrc-lab@example.test/"))
                    throw new AssertionError("HTTPS verified identity mismatch");
            }
            CountDownLatch done = new CountDownLatch(1);
            AtomicReference<Throwable> failure = new AtomicReference<>();
            ByteString payload = ByteString.of(new byte[]{0, (byte)128, (byte)255, 1, 42});
            WebSocket socket = client.newWebSocket(new Request.Builder().url(url+"/socket").build(), new WebSocketListener() {
                @Override public void onOpen(WebSocket ws, Response response) { ws.send(payload); }
                @Override public void onMessage(WebSocket ws, ByteString data) {
                    if (!data.equals(payload)) failure.set(new AssertionError("binary echo mismatch"));
                    done.countDown();
                }
                @Override public void onFailure(WebSocket ws, Throwable error, Response response) {
                    failure.set(error); done.countDown();
                }
            });
            if (!done.await(15, TimeUnit.SECONDS)) throw new AssertionError("WSS timed out");
            socket.cancel();
            if (failure.get() != null) throw new AssertionError("WSS failed", failure.get());
            OkHttpClient untrusted = client.newBuilder().sslSocketFactory(
                new HandshakeCertificates.Builder().addPlatformTrustedCertificates().build().sslSocketFactory(),
                new HandshakeCertificates.Builder().addPlatformTrustedCertificates().build().trustManager()).build();
            try (Response unexpected = untrusted.newCall(new Request.Builder().url(url).build()).execute()) {
                throw new AssertionError("untrusted certificate accepted");
            } catch (javax.net.ssl.SSLHandshakeException expected) { }
            System.out.println("OkHttp JVM: HTTPS identity, binary WSS, authenticated CONNECT and untrusted-certificate rejection passed");
        } finally {
            client.connectionPool().evictAll();
            client.dispatcher().executorService().shutdownNow();
        }
    }
}
