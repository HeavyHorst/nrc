package dev.nrc.chat

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import org.webrtc.*
import org.webrtc.audio.JavaAudioDeviceModule
import java.nio.ByteBuffer

/** One foreground-only audio peer. No video, WebView, provider key or transcript storage. */
internal class AndroidVoiceAudio(private val context: Context) : VoiceAudio {
    private val handler = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(AudioManager::class.java)
    private var previousMode = manager.mode
    private var focus: AudioFocusRequest? = null
    private var factory: PeerConnectionFactory? = null
    private var module: JavaAudioDeviceModule? = null
    private var peer: PeerConnection? = null
    private var source: AudioSource? = null
    private var track: AudioTrack? = null
    private var channel: DataChannel? = null
    private var ended = false
    private var started = false
    private val ice = CompletableDeferred<Unit>()

    override suspend fun offer(onEvent: (String) -> Unit): String {
        fun emit(value: String) { handler.post { if (!ended) onEvent(value) } }
        focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setOnAudioFocusChangeListener { change ->
                if (change < 0) emit("""{"type":"transport.closed"}""")
            }.build()
        check(manager.requestAudioFocus(focus!!) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        previousMode = manager.mode
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context).createInitializationOptions())
        module = JavaAudioDeviceModule.builder(context)
            .setAudioRecordErrorCallback(object : JavaAudioDeviceModule.AudioRecordErrorCallback {
                override fun onWebRtcAudioRecordInitError(message: String) = emit("""{"type":"transport.closed"}""")
                override fun onWebRtcAudioRecordStartError(code: JavaAudioDeviceModule.AudioRecordStartErrorCode, message: String) = emit("""{"type":"transport.closed"}""")
                override fun onWebRtcAudioRecordError(message: String) = emit("""{"type":"transport.closed"}""")
            })
            .setAudioTrackErrorCallback(object : JavaAudioDeviceModule.AudioTrackErrorCallback {
                override fun onWebRtcAudioTrackInitError(message: String) = emit("""{"type":"transport.closed"}""")
                override fun onWebRtcAudioTrackStartError(code: JavaAudioDeviceModule.AudioTrackStartErrorCode, message: String) = emit("""{"type":"transport.closed"}""")
                override fun onWebRtcAudioTrackError(message: String) = emit("""{"type":"transport.closed"}""")
            }).createAudioDeviceModule()
        factory = PeerConnectionFactory.builder().setAudioDeviceModule(module).createPeerConnectionFactory()
        val config = PeerConnection.RTCConfiguration(emptyList()).apply { sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN }
        peer = checkNotNull(factory!!.createPeerConnection(config, object : PeerConnection.Observer {
            override fun onSignalingChange(state: PeerConnection.SignalingState) = Unit
            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {
                if (state == PeerConnection.IceConnectionState.FAILED || state == PeerConnection.IceConnectionState.DISCONNECTED)
                    emit("""{"type":"transport.closed"}""")
            }
            override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {
                if (state == PeerConnection.IceGatheringState.COMPLETE) ice.complete(Unit)
            }
            override fun onIceCandidate(candidate: IceCandidate) = Unit
            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) = Unit
            override fun onAddStream(stream: MediaStream) = Unit
            override fun onRemoveStream(stream: MediaStream) = Unit
            override fun onDataChannel(channel: DataChannel) = Unit
            override fun onRenegotiationNeeded() = Unit
        }))
        source = factory!!.createAudioSource(MediaConstraints())
        track = factory!!.createAudioTrack("nrc-microphone", source)
        peer!!.addTrack(track, listOf("nrc-voice"))
        channel = peer!!.createDataChannel("oai-events", DataChannel.Init()).also { events ->
            events.registerObserver(object : DataChannel.Observer {
                override fun onBufferedAmountChange(previous: Long) = Unit
                override fun onStateChange() {
                    if (events.state() == DataChannel.State.CLOSED) emit("""{"type":"transport.closed"}""")
                }
                override fun onMessage(buffer: DataChannel.Buffer) {
                    if (buffer.binary || buffer.data.remaining() > 128 * 1024) return
                    val bytes = ByteArray(buffer.data.remaining())
                    buffer.data.get(bytes)
                    // Do not keep a transcript; forward only control event types.
                    val type = runCatching { org.json.JSONObject(String(bytes, Charsets.UTF_8)).optString("type") }.getOrNull()
                    if (type == "session.started" || type == "session.closed") handler.post {
                        if (type == "session.started") {
                            started = true
                            if (ended) sendClose()
                        } else if (ended) release()
                    }
                    if (type in setOf("session.started", "session.closed", "session.input_transcript.delta", "error"))
                        emit("""{"type":"$type"}""")
                }
            })
        }
        val offer = CompletableDeferred<SessionDescription>()
        peer!!.createOffer(observer(offer), MediaConstraints())
        val description = withTimeout(10_000) { offer.await() }
        val set = CompletableDeferred<SessionDescription>()
        peer!!.setLocalDescription(observer(set), description)
        withTimeout(10_000) { set.await(); ice.await() }
        check(!ended)
        return checkNotNull(peer!!.localDescription).description
    }

    override suspend fun answer(sdp: String) {
        check(!ended)
        val result = CompletableDeferred<SessionDescription>()
        peer!!.setRemoteDescription(observer(result), SessionDescription(SessionDescription.Type.ANSWER, sdp))
        withTimeout(10_000) { result.await() }
    }

    private fun observer(result: CompletableDeferred<SessionDescription>) = object : SdpObserver {
        override fun onCreateSuccess(description: SessionDescription) { result.complete(description) }
        override fun onSetSuccess() { result.complete(SessionDescription(SessionDescription.Type.OFFER, "")) }
        override fun onCreateFailure(error: String) { result.completeExceptionally(IllegalStateException("SDP creation failed")) }
        override fun onSetFailure(error: String) { result.completeExceptionally(IllegalStateException("SDP negotiation failed")) }
    }

    override fun mute(muted: Boolean) {
        if (!ended) {
            track?.setEnabled(!muted)
            peer?.setAudioRecording(!muted)
        }
    }

    override fun close() {
        if (ended) return
        ended = true
        track?.setEnabled(false)
        peer?.setAudioRecording(false)
        peer?.setAudioPlayout(false)
        focus?.let { manager.abandonAudioFocusRequest(it) }; focus = null
        manager.mode = previousMode
        // A close-only SDP can arrive before session.started. Keep only the
        // control transport briefly so the primary channel can end billing.
        if (peer?.remoteDescription != null) {
            if (started) sendClose()
            handler.postDelayed({ release() }, 15_000)
        } else release()
    }

    private fun sendClose() {
        channel?.let { events ->
            if (events.state() == DataChannel.State.OPEN)
                events.send(DataChannel.Buffer(ByteBuffer.wrap("""{"type":"session.close"}""".toByteArray()), false))
        }
    }

    private fun release() {
        channel?.unregisterObserver()
        peer?.close()
        channel?.dispose(); channel = null
        peer?.dispose(); peer = null
        track?.dispose(); track = null
        source?.dispose(); source = null
        factory?.dispose(); factory = null
        module?.release(); module = null
        ice.completeExceptionally(IllegalStateException("Voice stopped"))
    }
}
