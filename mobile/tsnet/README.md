# Embedded Tailscale transport

The default NRC Android APK embeds Tailscale through tsnet. There is only one
app, named **NRC**, with the existing application ID `dev.nrc.chat` and signing
identity. It updates the installed NRC app and preserves its settings/history;
there is no separate tsnet build or external VPN-app requirement. The earlier
`dev.nrc.chat.tsnet` prototype is obsolete and can be uninstalled separately.
This is still an ARM64-only alpha, not a validated production messenger.

## Build and try on a phone

Requires JDK 17, Android SDK platform 35, an Android NDK (tested with
27.2.12479018), and Go 1.27.1 or newer. The Go module pins Tailscale 1.104.1
and both gomobile generators. Native binaries are generated into ignored
`tsnet/build/`, not downloaded from a community AAR.

From `mobile/`, with the existing APK signing identity available:

```sh
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"
./sign-debug-apk.sh
```

The signing wrapper verifies the existing NRC debug certificate. Version 0.2.17
(code 19) updates the original app in place. Debug builds and ARM64 phones only
are currently supported.

1. Install the NRC APK as an update and disable the separate Tailscale app/VPN.
2. Enter the existing HTTPS NRC server address and workspace.
3. Tap **Continue Tailscale sign-in** to open the node's enrollment URL.
   Sign in and, if required, approve the new node. Return to NRC afterward.
   The button remains available if you close the browser without enrolling and
   returns when a running node needs reauthentication, including key expiry.
   Initial connection attempts can fail while enrollment is pending.
4. Verify the correct NRC identity, send/receive messages, then close/reopen the
   app. Repeat with a process restart and WLAN/mobile-data changes.

To change tailnet, open the app menu → **Switch Tailscale account** →
**Sign out / sign in**, then **Continue Tailscale sign-in**. Choose the intended
account/tailnet in the browser (switch browser account if necessary). This logs
out only the embedded node and closes its old connections; NRC settings, history
and drafts are not reset. The existing identity-isolation rule still applies:
if the NRC server authenticates a different username afterward, the old user's
local cache and drafts are cleared.

There is no embedded auth key, JWT secret, certificate-verification bypass,
VPN permission or `VpnService`. Clearing NRC's app storage removes
its node keys; remove its stale node from the control server separately.

For a reachable HTTPS Headscale installation, add
`-PnrcTailscaleControlURL=https://your-headscale.example` at build time. This
sets only the control-server address, not credentials. Never expose the local
HTTP lab configuration below to the Internet or put an auth key into the APK.

## How it works

`tailnet.Start` owns a userspace `tsnet.Server` and an authenticated loopback HTTP
CONNECT proxy limited to one destination. OkHttp retains the original HTTPS
URL, so TLS SNI, hostname checking and HTTP/WebSocket authority remain unchanged;
resolution and dialing are delegated to tsnet. Known MagicDNS peers resolve
internally; unknown names can fall back to the platform resolver. Running does
not guarantee that a particular peer is present in the current network map.
The bridge exposes only start, status, enrollment URL, logout, interactive login, proxy
credentials, fixed dial-failure categories/counts and close. Android adds those
categories and an allowlisted backend state to the sanitized system log.
It does not expose the Tailscale LocalAPI to other phone applications.

Android supplies interface addresses through Java `NetworkInterface`, following
the official Tailscale app's netmon integration approach. The getter is installed
once per process; IPv6 scope identifiers are preserved. Node keys/log directories
are app-private and excluded from backup. Closing a node also closes hijacked
WebSocket tunnels, not just the listening socket.
Interface-enumeration exceptions cross gomobile through an explicit error
result and propagate to netmon, rather than leaving a pending JNI exception
or pretending the phone has no interfaces.

Since tsnet's public API does not expose Android network-change notification,
the app closes/recreates the node when the default network changes,
reusing its stored identity. The existing chat reconnect loop recovers in the
foreground. This is intentionally not a background messaging service.
One process-wide queue serializes node shutdown/startup. Activity destruction
only enqueues native shutdown; it never waits for it on the UI thread, and a
replacement cannot open the same identity directory before shutdown completes.
Login status continues to be monitored after the node first reaches Running.

NRC inline attachments share the chat's configured tsnet HTTP transport, with
separate per-profile/identity image caches. Disposing those caches does not
close the shared chat client. External Markdown images retain their separate,
unauthenticated ordinary-network client; external links open in the browser.
Embedding tsnet gives neither the browser nor other phone apps tailnet access.

The bridge's callback-error/recovery contract also runs on the host (explicit
file arguments include the Android source without an Android runtime):

```sh
cd mobile/tsnet
go test -race platform_android.go platform_android_test.go
```

This checks error propagation and address parsing, not actual JNI execution.

## Reproduce the isolated Headscale test

Use a **disposable** Headscale 0.29.5 installation. The test approves its own
nodes through the local admin socket and deletes them afterward. It must not
target a shared or production database. No installed Tailscale daemon is needed.
In an Amp orb, start the lab as a supervised service:

```sh
lab=$(mktemp -d /tmp/nrc-headscale.XXXXXX)
cp mobile/tsnet/testdata/headscale.yaml "$lab/config.yaml"
# Put the Headscale 0.29.5 Linux binary at "$lab/headscale" and make it executable.
amp orb service start nrc-headscale --command "cd '$lab' && ./headscale serve -c config.yaml"
(cd "$lab" && ./headscale -c config.yaml users create nrc-lab --email nrc-lab@example.test)
(cd "$lab" && ./headscale -c config.yaml users create nrc-lab-switch --email nrc-lab-switch@example.test)
cd mobile/tsnet
NRC_HEADSCALE_BINARY="$lab/headscale" NRC_HEADSCALE_CONFIG="$lab/config.yaml" \
  GOMAXPROCS=2 go test -p 2 -run TestHeadscale -v -count=3 -timeout=4m .
amp orb service stop nrc-headscale
rm -rf "$lab"
```

The fixture uses loopback ports 18080, 19090 and 15043, private MagicDNS under
`nrc-lab.test`, and the public DERP map for encrypted relay fallback. It is a
separate control plane, not an enrollment into the organization's tailnet.
The test follows the actual interactive enrollment state and approves the URL's
auth ID with Headscale CLI; it does **not** automate a phone's browser login.

For the optional real OkHttp 4.12 JVM probe, compile `testdata/OkHttpProbe.java`
with JDK 17 and these Maven jars on its classpath:

- `com.squareup.okhttp3:okhttp:4.12.0`
- `com.squareup.okhttp3:okhttp-tls:4.12.0`
- `com.squareup.okio:okio-jvm:3.6.0`
- `org.jetbrains.kotlin:kotlin-stdlib:1.9.10`

For example, with the jars in a scratch `$probe` directory:

```sh
javac -cp "$probe/*" -d "$probe" testdata/OkHttpProbe.java
NRC_HEADSCALE_BINARY="$lab/headscale" NRC_HEADSCALE_CONFIG="$lab/config.yaml" \
  NRC_OKHTTP_CLASSPATH="$probe:$probe/*" \
  GOMAXPROCS=2 go test -p 2 -run TestHeadscale -v -count=3 -timeout=4m .
```

## What this verifies — and what it does not

The real two-node Headscale test verifies private DNS, HTTPS with verified
WhoIs identity, exact binary WSS roundtrips, proxy authentication/destination
restrictions, TLS rejection of unknown certificates and wrong hostnames,
closure of active tunnels, and reconnect with the same identity after restart.
It also logs out and re-enrolls the same private directory as a different user,
checking the resulting identity through the server's WhoIs response.
The JVM probe exercises real OkHttp against that same tailnet endpoint.
The lab explicitly trusts its generated test certificate; the APK does not.

The endpoint is a TLS/identity/WebSocket **fixture, not the NRC server**. These
tests establish the transport, not full chat delivery. Linux/JVM tests and an
Android build cannot establish Android runtime behavior. Browser return,
interface permissions on current Android releases, WLAN/mobile handoff, battery
cost, key-expiry reauthentication, linked images and external browser links
still need device testing. The UI/transport ownership regression tests are not
a substitute for those checks on a real phone.
