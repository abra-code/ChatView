package com.abracode.chatview.acp

// Port of Sources/ACP/ACPRemoteTransport.swift - the `acp-remote` transport: ChatView driving an ACP agent that runs
// somewhere else, over the bridge protocol (Private/ChatView_Remote_Agent_Plan.md section 7).
//
// The shape differs from a local transport in exactly one way, and everything else follows from it: the connection
// is not the session. A socket can drop and come back many times inside one conversation, and the agent keeps
// working the whole time. So:
//
//  - A turn is NEVER ended because the socket died (invariant I9). A dropped socket says nothing about a turn that
//    is still running bridge-side; the truth arrives with the replay. The composer is gated by connection state.
//  - Every transcript id is derived from the bridge's sequence number (plan 4.5), so two devices - and the same
//    device after a restart - render byte-identical ids without any reconciliation protocol.
//  - `lastSeq` advances only AFTER an entry is fully processed (invariant I7), so a reattach asks for exactly what
//    was missed. At-least-once delivery plus idempotent processing.
//
// The reconnect loop lives here rather than in AcpRemoteConnection: a connection object is single-use (I2), and
// this owns the policy for making new ones. The Swift file is normative for anything left unstated here.

import com.abracode.chatview.AgentSessionInfo
import com.abracode.chatview.ChatCommand
import com.abracode.chatview.ChatConnectionState
import com.abracode.chatview.ChatEvent
import com.abracode.chatview.ChatLogLevel
import com.abracode.chatview.ChatLogger
import com.abracode.chatview.ChatRole
import com.abracode.chatview.ChatTransport
import com.abracode.chatview.ChatTransportCapabilities
import com.abracode.chatview.ChatTransportConfig
import com.abracode.chatview.PermissionRequest
import com.abracode.chatview.SessionConfigOption
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.WebSocket
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.coroutines.cancellation.CancellationException
import kotlin.random.Random

class AcpRemoteTransport(
    config: ChatTransportConfig,
    private val logger: ChatLogger,
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
    webSocketFactory: WebSocket.Factory? = null,
) : ChatTransport {

    private val channel = Channel<ChatEvent>(Channel.UNLIMITED)
    override val events: ReceiveChannel<ChatEvent> get() = channel
    override val capabilities = ChatTransportCapabilities(reportsConnectionState = true)

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    /**
     * The parsed endpoint, kept as the HttpUrl the socket is actually opened with rather than as the raw string.
     * Validating one URL and connecting with another is how a scheme check gets bypassed: OkHttp resolves hosts
     * java.net.URI does not (`ws://127.0.0.1%2eevil.com/` is one), so the private-host gate must run on the value
     * that decides where the token is sent. Parsing here also means a port or literal OkHttp rejects fails at
     * construction - the deferred-config seam - instead of throwing out of start().
     */
    private val url: HttpUrl
    private val token: String
    /** OkHttp rejects any header byte outside 0x20...0x7e; see the request builder in connectOnce. */
    private val tokenFitsAHeader: Boolean
    private val sessionSelector: String           // "new" | "latest" | an explicit session id
    private val requestedCwd: String?
    internal val handshakeTimeout: Double         // internal so tests can pin the default
    private val configuredResumeAfterSeq: Int?

    /**
     * Built on first use so a transport that never connects (a deferred config, a test that only checks
     * validation) never spins up a client. OkHttp's own pingInterval is the keepalive: a silently reaped flow
     * (NAT timeout, a phone changing networks) never delivers a read error, and without a ping a client sits
     * "connected" on a dead socket - on a phone the common case rather than the exotic one.
     *
     * Held as a `Lazy` rather than a `by lazy` property so stop() can tell whether one was ever created, and an
     * injected factory from whichever this one built: the store rebuilds its transport on every config change, and
     * a client left with a live dispatcher thread pool and connection pool per rebuild adds up.
     */
    private val ownsClient = webSocketFactory == null
    private val socketsLazy: Lazy<WebSocket.Factory> = lazy {
        webSocketFactory ?: OkHttpClient.Builder()
            .pingInterval(30, TimeUnit.SECONDS)
            // A WebSocket upgrade has no legitimate reason to be redirected, and following one
            // would undo the private-host gate: OkHttp strips the Authorization header across
            // hosts, but the token the bridge actually validates rides in the `initialize` params,
            // so a 3xx would hand a code-execution credential to wherever it points - in cleartext
            // if the new location says ws://. followSslRedirects would likewise let a wss://
            // endpoint be downgraded to plain ws://.
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
    }
    private val sockets: WebSocket.Factory get() = socketsLazy.value

    private val lock = Any()
    private var connection: AcpRemoteConnection? = null
    private var sessionID: String? = null
    private var sessionOptions: List<SessionConfigOption> = emptyList()
    private var lastSeq = 0
    private var activeTurn: Int? = null
    private var stopped = false
    private var reconnectJob: Job? = null
    private var handshakeGeneration = 0

    /**
     * The bridge's `initialize` result, which carries the AGENT's identity verbatim. Kept so every sessionInfo
     * reports the real agent rather than a placeholder - a phone has no other way to learn what it is talking to.
     */
    private var agentIdentity: JsonObject = JsonObject(emptyMap())

    // Segmentation state, the same shape the stdio transport keeps, but keyed off seqs.
    private var openMessageID: String? = null
    private var openMessageRole: ChatRole = ChatRole.AGENT
    private var openThoughtID: String? = null

    /**
     * echoKeys this device minted. The store already appended the user's message optimistically on send, so our own
     * `bridge/user_message` must not be rendered twice. Bounded: a set that grew forever would be a leak in a long
     * session, and an echoKey is only interesting between sending and seeing it come back.
     */
    private val mintedEchoKeys = mutableListOf<String>()

    /**
     * Stop pressed while the socket was down. There is no turn to cancel locally - it is running bridge-side - so
     * the intent is latched and sent after the next attach, but only if that same turn is still live (I3).
     */
    private var pendingCancel: Int? = null

    /**
     * The highest turn the bridge has told us ended. `session/prompt` learns its turn number only from the reply,
     * so a turn that ends before that reply lands would otherwise be written back into `activeTurn` as though it
     * were live - and a later Stop would target a turn that is already over.
     */
    private var lastEndedTurn = 0

    /**
     * Set when the bridge refuses us for a reason retrying cannot fix (bad token, unknown session, ended session).
     * Without it the failure path closes the socket, which looks like a network drop, which restarts the reconnect
     * loop - retrying a bad token forever.
     */
    private var abandoned = false

    /** After an attach, the replay is complete once `lastSeq` reaches this. Drives the quiet-attach checkpoint. */
    private var quietCheckpointTarget: Int? = null

    /**
     * Answers the user has given, keyed by requestKey, kept until the bridge confirms the resolution. This is what
     * survives a socket that dropped between the tap and the send: the bridge re-issues unanswered requests after a
     * reattach, and the held answer settles them without asking the user twice. A LinkedHashMap so the eviction
     * below drops the oldest answer rather than an arbitrary one.
     */
    private val permissionAnswers = LinkedHashMap<String, String?>()

    /**
     * Coroutines parked on the UI, keyed by requestKey. A LIST because the bridge re-issues the same requestKey to
     * every connection that attaches while it is unanswered, and each re-issue is its own JSON-RPC request needing
     * its own response.
     */
    private val permissionWaiters = mutableMapOf<String, MutableList<CancellableContinuation<String?>>>()

    /**
     * requestKeys whose gate the store is already showing. The store appends gates without deduping, so a re-issue
     * after a reconnect must not stack a second prompt on a question the user is already looking at.
     */
    private val shownPermissionKeys = mutableSetOf<String>()

    // MARK: - Init and config validation

    init {
        val raw = config.string("url").orEmpty()
        if (raw.isEmpty()) {
            throw AcpRemoteError(null, "the acp-remote transport requires a 'url' setting")
        }
        val scheme = raw.substringBefore("://", missingDelimiterValue = "").lowercase()
        if (scheme.isEmpty()) {
            throw AcpRemoteError(null, "'$raw' is not a usable URL")
        }
        if (scheme != "ws" && scheme != "wss") {
            throw AcpRemoteError(null, "the acp-remote url must be ws:// or wss://, got '$scheme://'")
        }
        // The same rewrite OkHttp's own Request.Builder.url(String) performs: HttpUrl models ws/wss as their
        // http/https twins. Doing it here means the endpoint is parsed once, by the parser that will connect it.
        val parsed = ("http" + raw.substring(2)).toHttpUrlOrNull()
            ?: throw AcpRemoteError(null, "'$raw' is not a usable URL")
        val allowInsecure = config.bool("allowInsecure") ?: false
        if (scheme == "ws" && !allowInsecure && !isPrivateHost(parsed.host)) {
            // Cleartext to a public host would put a token that is remote code execution on the wire. Refuse at
            // construction, the way `acp` refuses a missing command: the registry treats a throwing factory as
            // "not viable yet" and the element waits for a complete config.
            throw AcpRemoteError(
                null,
                "refusing ws:// to the non-private host '${parsed.host}'; use wss:// or set allowInsecure",
            )
        }
        url = parsed
        token = config.string("token") ?: ""
        tokenFitsAHeader = token.all { it.code in 0x20..0x7e }
        if (token.isNotEmpty() && !tokenFitsAHeader) {
            // Not fatal: the bridge authenticates the copy inside `initialize` (plan 4.6), and the header exists
            // for proxies. Building it would throw, and a throw here would take the whole connect down.
            logger.log(
                "acp-remote: the token has characters an HTTP header cannot carry (a stray newline?); sending it "
                    + "in the initialize params only",
                ChatLogLevel.WARNING,
            )
        }
        sessionSelector = config.string("session") ?: "new"
        requestedCwd = config.string("cwd")
        handshakeTimeout = clampedTimeout(config.double("handshakeTimeoutSeconds"), 15.0)

        // The cold-launch cursor (plan 4.2a). Only meaningful against the session id it was minted for: with "new"
        // or "latest" there is nothing for it to line up with, and a cursor applied to the wrong session silently
        // skips that session's history.
        configuredResumeAfterSeq = if (!config.settings.containsKey("resumeAfterSeq")) {
            null
        } else if (sessionSelector == "new" || sessionSelector == "latest") {
            logger.log(
                "acp-remote: ignoring resumeAfterSeq with session '$sessionSelector'; a checkpoint only means "
                    + "something against an explicit session id",
                ChatLogLevel.WARNING,
            )
            null
        } else {
            val value = config.int("resumeAfterSeq")
            if (value != null && value >= 0) {
                value
            } else {
                logger.log("acp-remote: ignoring a non-numeric or negative resumeAfterSeq", ChatLogLevel.WARNING)
                null
            }
        }
        if (configuredResumeAfterSeq != null) {
            lastSeq = configuredResumeAfterSeq
        }
    }

    // MARK: - Lifecycle

    override suspend fun start() {
        emit(ChatEvent.ConnectionStateChanged(ChatConnectionState.CONNECTING))
        connectOnce(isReconnect = false)
    }

    override suspend fun stop() {
        val (job, existing) = synchronized(lock) {
            stopped = true
            val job = reconnectJob
            reconnectJob = null
            val existing = connection
            connection = null
            job to existing
        }
        job?.cancel()
        existing?.close()
        drainPermissionWaiters()
        channel.close()
        scope.cancel()
        // Only a client this transport built: an injected factory belongs to whoever injected it, and the store
        // rebuilds transports often enough that a per-instance dispatcher thread pool and connection pool left
        // running would accumulate.
        if (ownsClient && socketsLazy.isInitialized()) {
            (socketsLazy.value as? OkHttpClient)?.let { client ->
                client.dispatcher.executorService.shutdown()
                client.connectionPool.evictAll()
            }
        }
    }

    /**
     * No-ops with the same justification the Swift transport records: this transport's history lives server-side,
     * so a restored transcript is never replayed onto the wire, and ids are pure functions of an append-only log,
     * so no id a restore could re-alias is ever minted twice.
     */
    override fun primeHistory(messages: List<com.abracode.chatview.ChatMessage>) {}

    override fun reserveIDs(seen: List<String>) {}

    // MARK: - Connect / reconnect

    private suspend fun connectOnce(isReconnect: Boolean) {
        if (synchronized(lock) { stopped }) {
            return
        }
        val connection = AcpRemoteConnection(
            logger = logger,
            scope = scope,
            onOpen = {},
            onNotification = { method, params -> handleNotification(method, params) },
            onRequest = { method, params -> handleBridgeRequest(method, params) },
            onClose = { error -> handleSocketClosed(error) },
        )
        // Publish and re-check stopped under ONE acquisition: a stop() that lands between the check above and this
        // assignment would otherwise be overwritten, and the socket opened below would have nothing left alive to
        // close it - a stopped transport holding an authenticated connection.
        val accepted = synchronized(lock) {
            if (stopped) {
                false
            } else {
                this.connection = connection
                true
            }
        }
        if (!accepted) {
            connection.close()
            return
        }

        val request = Request.Builder().url(url).apply {
            if (token.isNotEmpty() && tokenFitsAHeader) {
                // Sent for proxies and for a future bridge that reads upgrade headers; the bridge itself validates
                // the in-band copy in initialize, because Network.framework does not reliably expose them.
                header("Authorization", "Bearer $token")
            }
        }.build()
        connection.adopt(sockets.newWebSocket(request, connection.listener()))

        // I1: the watchdog closes the CONNECTION, it does not race the request. Racing an await against a timeout
        // deadlocked the stdio transport, and the same reasoning applies verbatim to a socket.
        val generation = synchronized(lock) { ++handshakeGeneration }
        val watchdog = if (handshakeTimeout > 0) {
            scope.launch {
                delay((handshakeTimeout * 1000).toLong())
                if (synchronized(lock) { handshakeGeneration == generation }) {
                    logger.log(
                        "acp-remote: no handshake within ${secondsText(handshakeTimeout)}; closing the socket",
                        ChatLogLevel.WARNING,
                    )
                    connection.close(
                        AcpRemoteError(
                            null,
                            "The agent bridge did not respond within ${secondsText(handshakeTimeout)}",
                        ),
                    )
                }
            }
        } else {
            null
        }

        try {
            val handshake = connection.request(
                "initialize",
                buildJsonObject {
                    put("protocolVersion", 1)
                    put("bridgeToken", token)
                    putJsonObject("clientInfo") {
                        put("name", "ChatView")
                        put("title", "ChatView")
                        put("version", "0.3.0")
                    }
                },
            )
            synchronized(lock) { agentIdentity = handshake }
            establishSession(connection, isReconnect)
            // Only now is the handshake done; retire the watchdog so a later slow turn is not mistaken for a
            // failed connect. Cancelling it as well as bumping the generation matters when the timeout is long:
            // a sleeping coroutine pins its connection object for the whole duration otherwise.
            synchronized(lock) { handshakeGeneration++ }
            watchdog?.cancel()
            emit(ChatEvent.ConnectionStateChanged(ChatConnectionState.CONNECTED))
        } catch (cancellation: CancellationException) {
            // A cancelled caller is not a failed connect: reporting it as one would tell the user the bridge
            // refused them, and would swallow the cancellation the coroutine machinery is entitled to see.
            synchronized(lock) { handshakeGeneration++ }
            watchdog?.cancel()
            connection.close()
            throw cancellation
        } catch (error: Throwable) {
            synchronized(lock) { handshakeGeneration++ }
            watchdog?.cancel()
            val message = (error as? AcpRemoteError)?.message ?: error.toString()
            if (isReconnect) {
                // A failed reconnect is not terminal: the loop keeps trying, and the composer stays gated by the
                // connection state in the meantime.
                logger.log("acp-remote: reconnect attempt failed: $message", ChatLogLevel.WARNING)
                connection.close()
                return
            }
            // Codes the bridge uses for "this will never work": a bad token, a session that does not exist, a
            // session that has ended. Latch so the close below is not mistaken for a network drop and answered
            // with a reconnect loop.
            val code = (error as? AcpRemoteError)?.code
            if (code != null && code in setOf(-32000, -32001, -32002)) {
                synchronized(lock) { abandoned = true }
            }
            emit(ChatEvent.Error(message, recoverable = false))
            emit(ChatEvent.ConnectionStateChanged(ChatConnectionState.OFFLINE))
            connection.close()
        }
    }

    /**
     * Creates or attaches to the session, in the order invariant I6 requires: the session is announced BEFORE any
     * replayed event, so the store leaves its unconfigured state first.
     */
    private suspend fun establishSession(connection: AcpRemoteConnection, isReconnect: Boolean) {
        val known = synchronized(lock) { sessionID }
        if (known != null) {
            attach(known, connection, resumed = true)
            return
        }

        when (sessionSelector) {
            "new" -> createSession(connection)

            "latest" -> {
                val listing = connection.request("bridge/sessions", JsonObject(emptyMap()))
                val rows = listing.objectArray("sessions") ?: emptyList()
                val preferred = rows.firstOrNull { it.text("state") == "live" } ?: rows.firstOrNull()
                val target = preferred?.text("sessionId")
                if (target == null) {
                    // No session to resume is not an error; it means this is a first run.
                    logger.log("acp-remote: no existing session to resume; creating one", ChatLogLevel.INFO)
                    synchronized(lock) { sessionID = null }
                    createSession(connection)
                } else {
                    attach(target, connection, resumed = isReconnect)
                }
            }

            else -> attach(sessionSelector, connection, resumed = isReconnect)
        }
    }

    private suspend fun createSession(connection: AcpRemoteConnection) {
        val params = buildJsonObject {
            if (requestedCwd != null) {
                put("cwd", requestedCwd)
            }
        }
        val result = connection.request("session/new", params)
        val newID = result.text("sessionId")
            ?: throw AcpRemoteError(null, "the agent bridge returned no sessionId")
        val options = AcpWireParsing.parseConfigOptions(result)
        synchronized(lock) {
            sessionID = newID
            sessionOptions = options
        }
        emit(ChatEvent.SessionReady(newID, options))
        emit(ChatEvent.SessionInfo(makeSessionInfo(newID, resumed = false)))
    }

    private suspend fun attach(target: String, connection: AcpRemoteConnection, resumed: Boolean) {
        val cursor = synchronized(lock) { lastSeq }
        var result = connection.request(
            "bridge/attach",
            buildJsonObject {
                put("sessionId", target)
                put("afterSeq", cursor)
            },
        )

        // A cursor minted against a DIFFERENT session would silently skip this session's history up to that
        // number. Zeroing lastSeq is not enough - the attach that used the bad cursor has already gone out - so
        // ATTACH AGAIN from the beginning and use that result.
        val echoed = result.text("sessionId")
        if (echoed != null && echoed != target && cursor > 0) {
            logger.log(
                "acp-remote: the bridge attached '$echoed' but '$target' was requested; re-attaching and "
                    + "replaying from the beginning",
                ChatLogLevel.WARNING,
            )
            synchronized(lock) { lastSeq = 0 }
            result = connection.request(
                "bridge/attach",
                buildJsonObject {
                    put("sessionId", target)
                    put("afterSeq", 0)
                },
            )
        }

        val rawOptions = result["configOptions"] as? JsonArray
        val options = if (rawOptions == null) {
            emptyList()
        } else {
            AcpWireParsing.parseConfigOptions(buildJsonObject { put("configOptions", rawOptions) })
        }
        val turn = result.number("activeTurn")
        synchronized(lock) {
            sessionID = target
            if (options.isNotEmpty()) {
                sessionOptions = options
            }
            activeTurn = turn
        }

        emit(ChatEvent.SessionReady(target, options))
        emit(ChatEvent.SessionInfo(makeSessionInfo(target, resumed = resumed)))

        if (result.text("state") == "ended") {
            val reason = result.text("endedReason") ?: "the session ended"
            // The transcript still replays after this; the error only says it cannot be continued. Emitted after
            // sessionReady so the store is configured first.
            emit(ChatEvent.Error("The remote agent session has ended ($reason)", recoverable = false))
        }

        // Stop pressed while disconnected: send it now, but only if that same turn is still the live one -
        // otherwise we would cancel somebody else's turn.
        val latched = synchronized(lock) {
            val value = pendingCancel
            pendingCancel = null
            value
        }
        if (latched != null && latched == turn) {
            connection.notify("session/cancel", buildJsonObject { put("sessionId", target) })
        }

        // A quiet attach is a checkpoint moment - but only ONCE THE REPLAY HAS ARRIVED. The attach result returns
        // before its replayed notifications, so checkpointing here would hand the host a cursor describing the
        // state before the catch-up it is about to render. Arm a target instead, and fire when lastSeq reaches the
        // tail the bridge just told us about.
        val latest = result.number("latestSeq") ?: 0
        if (turn == null) {
            val reached = synchronized(lock) {
                if (lastSeq >= latest) {
                    quietCheckpointTarget = null
                    true
                } else {
                    quietCheckpointTarget = latest
                    false
                }
            }
            if (reached) {
                emitCheckpointIfPossible()
            }
        } else {
            synchronized(lock) { quietCheckpointTarget = null }
        }
    }

    private fun handleSocketClosed(error: Throwable?) {
        val shouldReconnect = synchronized(lock) {
            connection = null
            !stopped && !abandoned
        }
        if (!shouldReconnect) {
            return
        }
        // I9: the socket dying says NOTHING about the turn, which is still running bridge-side. Never synthesize a
        // turn end here - the composer is gated by connection state and the truth arrives with the replay.
        emit(ChatEvent.ConnectionStateChanged(ChatConnectionState.RECONNECTING))
        scheduleReconnect()
    }

    private fun scheduleReconnect() {
        // LAZY so the job is latched BEFORE it can run. Started eagerly, a body that reached its own
        // `reconnectJob = null` before the launcher's assignment would leave a finished job in the field, and
        // every later socket drop would then find the loop "already running" and never reconnect again.
        val job = scope.launch(start = CoroutineStart.LAZY) {
            var attempt = 0
            while (isActive && !synchronized(lock) { stopped }) {
                val base = min(2.0.pow(attempt) * 0.5, 30.0)
                val jitter = Random.nextDouble(0.8, 1.2)
                delay((base * jitter * 1000).toLong())
                if (!isActive || synchronized(lock) { stopped }) {
                    return@launch
                }
                connectOnce(isReconnect = true)
                // ONE acquisition for the check and the retirement. Split in two, a socket that
                // drops in the gap sees this job still latched, declines to schedule a new loop,
                // and is then followed by the clear below - leaving the transport reconnecting
                // forever with nothing running to reconnect it.
                val settled = synchronized(lock) {
                    if (connection != null) {
                        reconnectJob = null
                        true
                    } else {
                        false
                    }
                }
                if (settled) {
                    return@launch
                }
                attempt++
            }
        }
        val accepted = synchronized(lock) {
            if (stopped || reconnectJob != null) {
                false
            } else {
                reconnectJob = job
                true
            }
        }
        if (!accepted) {
            job.cancel()
            return
        }
        job.start()
    }

    // MARK: - Commands

    override suspend fun send(command: ChatCommand) {
        when (command) {
            is ChatCommand.Prompt -> sendPrompt(command.text)
            is ChatCommand.Cancel -> sendCancel()
            is ChatCommand.PermissionResponse -> answerPermission(command.requestID, command.optionID)
            is ChatCommand.SetConfigOption -> setConfigOption(command.optionID, command.value)
            else -> Unit
        }
    }

    private suspend fun sendPrompt(text: String) {
        val (connection, session) = synchronized(lock) { this.connection to this.sessionID }
        if (connection == null || session == null || connection.isClosed) {
            // Never queue a prompt: one firing after minutes of reconnect surprises the user, and the composer is
            // connection-gated anyway.
            emit(ChatEvent.Error("Not connected to the agent bridge; message not sent", recoverable = true))
            return
        }
        val echoKey = UUID.randomUUID().toString()
        synchronized(lock) {
            mintedEchoKeys.add(echoKey)
            while (mintedEchoKeys.size > ECHO_KEY_MEMORY) {
                mintedEchoKeys.removeAt(0)
            }
        }
        try {
            val result = connection.request(
                "session/prompt",
                buildJsonObject {
                    put("sessionId", session)
                    putJsonArray("prompt") {
                        add(
                            buildJsonObject {
                                put("type", "text")
                                put("text", text)
                            },
                        )
                    }
                    put("echoKey", echoKey)
                },
            )
            synchronized(lock) {
                val turn = result.number("turn")
                if (turn != null && turn > lastEndedTurn) {
                    activeTurn = turn
                }
            }
        } catch (error: Throwable) {
            emit(ChatEvent.Error((error as? AcpRemoteError)?.message ?: error.toString(), recoverable = true))
        }
    }

    private fun sendCancel() {
        val (connection, session, turn) = synchronized(lock) {
            Triple(this.connection, this.sessionID, this.activeTurn)
        }
        if (session == null) {
            return
        }
        if (connection == null || connection.isClosed) {
            // Latch it: the turn is still running bridge-side and Stop must still stop it.
            synchronized(lock) { pendingCancel = turn }
            return
        }
        connection.notify("session/cancel", buildJsonObject { put("sessionId", session) })
    }

    private suspend fun setConfigOption(optionID: String, value: String) {
        val (connection, session) = synchronized(lock) { this.connection to this.sessionID }
        if (connection == null || session == null || connection.isClosed) {
            return
        }
        try {
            val result = connection.request(
                "session/set_config_option",
                buildJsonObject {
                    put("sessionId", session)
                    put("configId", optionID)
                    put("type", "select")
                    put("value", value)
                },
            )
            val refreshed = AcpWireParsing.parseConfigOptions(result)
            if (refreshed.isNotEmpty()) {
                synchronized(lock) { sessionOptions = refreshed }
                emit(ChatEvent.ConfigOptionsChanged(refreshed))
            }
        } catch (error: Throwable) {
            logger.log("acp-remote: set_config_option failed: $error", ChatLogLevel.WARNING)
        }
    }

    private fun answerPermission(requestKey: String, optionID: String?) {
        // ALWAYS record the answer, even when a waiter exists. The bad case is precisely the one where it exists:
        // the request arrived, the socket then dropped, and the user taps Allow. Resuming the waiter writes the
        // result into a dead connection, which the send path silently discards - so without the record the answer
        // is lost and the user is asked again after reattach. The record is cleared when the bridge confirms the
        // resolution, which is the only authoritative "this is settled" signal there is.
        val waiters = synchronized(lock) {
            permissionAnswers[requestKey] = optionID
            while (permissionAnswers.size > PERMISSION_ANSWER_MEMORY) {
                val oldest = permissionAnswers.keys.first()
                permissionAnswers.remove(oldest)
            }
            permissionWaiters.remove(requestKey) ?: mutableListOf()
        }
        for (waiter in waiters) {
            waiter.resume(optionID)
        }
    }

    /** Unparks every waiting permission request handler so teardown never leaves a coroutine parked forever. */
    private fun drainPermissionWaiters() {
        val waiters = synchronized(lock) {
            val all = permissionWaiters.values.flatten()
            permissionWaiters.clear()
            all
        }
        for (waiter in waiters) {
            waiter.resume(null)
        }
    }

    // MARK: - Inbound

    private suspend fun handleBridgeRequest(method: String, params: JsonObject): JsonObject? {
        if (method != "session/request_permission") {
            return null
        }
        val requestKey = params.text("requestKey") ?: return null

        // Already answered - either while the socket was down, or by this same user before a re-issue reached us.
        // Settle it without asking again. The record is NOT consumed here: only the bridge's permission_resolved
        // clears it, so a second re-issue is also settled.
        val held = synchronized(lock) {
            if (permissionAnswers.containsKey(requestKey)) true to permissionAnswers[requestKey] else false to null
        }
        if (held.first) {
            return permissionOutcome(held.second)
        }

        // Show the gate only the first time this key is seen. The bridge re-issues the same key to every
        // connection that attaches while it is unanswered, and the store appends gates without deduping.
        val alreadyShowing = synchronized(lock) {
            val seen = shownPermissionKeys.contains(requestKey)
            shownPermissionKeys.add(requestKey)
            seen
        }
        if (!alreadyShowing) {
            emit(ChatEvent.PermissionRequestEvent(parsePermissionRequest(params, requestKey)))
        }

        val choice = suspendCancellableCoroutine { continuation ->
            val answered = synchronized(lock) {
                if (permissionAnswers.containsKey(requestKey)) {
                    true to permissionAnswers[requestKey]
                } else {
                    permissionWaiters.getOrPut(requestKey) { mutableListOf() }.add(continuation)
                    false to null
                }
            }
            continuation.invokeOnCancellation {
                synchronized(lock) {
                    val waiting = permissionWaiters[requestKey] ?: return@synchronized
                    waiting.remove(continuation)
                    // Drop the key with its last waiter: a request that is cancelled and never resolved would
                    // otherwise leave an empty list behind for the transport's life.
                    if (waiting.isEmpty()) {
                        permissionWaiters.remove(requestKey)
                    }
                }
            }
            if (answered.first) {
                // Raced us between the read above and here.
                continuation.resume(answered.second)
            }
        }
        return permissionOutcome(choice)
    }

    /**
     * Builds the identity event from the bridge's cached `initialize` result. `agentPid` is deliberately null: the
     * agent's pid is a fact about the BRIDGE host, and a remote client has no business acting on it.
     */
    private fun makeSessionInfo(sessionID: String, resumed: Boolean): AgentSessionInfo {
        val identity = synchronized(lock) { agentIdentity }
        val info = identity.obj("agentInfo")
        val capabilities = identity.obj("agentCapabilities")
        return AgentSessionInfo(
            sessionId = sessionID,
            agentName = info?.text("name"),
            agentVersion = info?.text("version"),
            protocolVersion = identity.number("protocolVersion"),
            agentPid = null,
            canLoadSession = capabilities?.flag("loadSession") ?: false,
            canPrime = capabilities?.flag("sessionPrime") ?: false,
            resumed = resumed,
        )
    }

    private fun handleNotification(method: String, params: JsonObject) {
        val seq = params.number("seq")
        if (seq == null) {
            logger.log("acp-remote: dropping '$method' with no seq", ChatLogLevel.WARNING)
            return
        }
        // I7: process first, advance lastSeq after. A cursor ahead of what was processed loses content on the next
        // attach.
        if (synchronized(lock) { seq <= lastSeq }) {
            return
        }

        when (method) {
            "session/update" -> routeSessionUpdate(params.obj("update") ?: JsonObject(emptyMap()), seq)
            "bridge/user_message" -> routeUserMessage(params, seq)
            "bridge/turn_ended" -> routeTurnEnded(params, seq)
            "bridge/permission_resolved" -> routePermissionResolved(params)
            "bridge/session_ended" -> routeSessionEnded(params)
            else -> logger.log("acp-remote: ignoring unknown notification '$method'", ChatLogLevel.INFO)
        }

        val quietTargetReached = synchronized(lock) {
            lastSeq = max(lastSeq, seq)
            val target = quietCheckpointTarget
            if (target != null && lastSeq >= target && activeTurn == null) {
                quietCheckpointTarget = null
                true
            } else {
                false
            }
        }
        if (quietTargetReached) {
            emitCheckpointIfPossible()
        }

        if (method == "bridge/turn_ended") {
            // A turn boundary is the only moment the transcript is quiescent, which is what makes the cursor and
            // the host's stored entries describe the same instant.
            emitCheckpointIfPossible()
        }
    }

    private fun routeSessionUpdate(update: JsonObject, seq: Int) {
        when (update.text("sessionUpdate")) {
            "agent_message_chunk" ->
                appendMessageChunk(AcpWireParsing.contentText(update["content"]), ChatRole.AGENT, seq)
            "user_message_chunk" ->
                appendMessageChunk(AcpWireParsing.contentText(update["content"]), ChatRole.LOCAL, seq)
            "agent_thought_chunk" ->
                appendThoughtChunk(AcpWireParsing.contentText(update["content"]), seq)
            "tool_call" -> {
                finalizeOpenItems()
                emit(ChatEvent.ToolCall(AcpWireParsing.parseToolCall(update)))
            }
            "tool_call_update" -> emit(ChatEvent.ToolCallUpdateEvent(AcpWireParsing.parseToolCallUpdate(update)))
            "plan" -> emit(ChatEvent.Plan(AcpWireParsing.parsePlan(update)))
            "usage_update" -> AcpWireParsing.parseUsage(update)?.let { emit(ChatEvent.Usage(it)) }
            "current_mode_update" -> update.text("currentModeId")?.let { emit(ChatEvent.CurrentModeChanged(it)) }
            "available_commands_update" -> emit(ChatEvent.CommandsAvailable(AcpWireParsing.parseCommands(update)))
            else -> logger.log("acp-remote: ignoring unknown session/update kind", ChatLogLevel.INFO)
        }
    }

    private fun routeUserMessage(params: JsonObject, seq: Int) {
        val echoKey = params.text("echoKey") ?: ""
        val isOurs = synchronized(lock) { mintedEchoKeys.remove(echoKey) }
        if (isOurs) {
            // Our own send; the store already appended it optimistically.
            return
        }
        val text = (params.objectArray("content") ?: emptyList())
            .mapNotNull { it.text("text") }
            .joinToString("\n\n")
        if (text.isEmpty()) {
            return
        }
        finalizeOpenItems()
        val id = "acpr-m-$seq"
        emit(ChatEvent.MessageStart(id, ChatRole.LOCAL))
        emit(ChatEvent.MessageDelta(id, text))
        emit(ChatEvent.MessageEnd(id, null))
    }

    private fun routeTurnEnded(params: JsonObject, seq: Int) {
        val stopReason = params.text("stopReason") ?: "end_turn"
        val open = synchronized(lock) {
            params.number("turn")?.let { lastEndedTurn = max(lastEndedTurn, it) }
            activeTurn = null
            val id = openMessageID
            openMessageID = null
            openThoughtID = null
            id
        }
        // The terminal messageEnd is what clears the store's streaming flag and its pending permissions, so it must
        // be emitted for every turn - with an open bubble if there is one, and against a synthetic id if the turn
        // produced nothing.
        emit(ChatEvent.MessageEnd(open ?: "acpr-turn-$seq", stopReason))
    }

    private fun routePermissionResolved(params: JsonObject) {
        val requestKey = params.text("requestKey") ?: return
        val waiters = synchronized(lock) {
            permissionAnswers.remove(requestKey)
            shownPermissionKeys.remove(requestKey)
            permissionWaiters.remove(requestKey) ?: mutableListOf()
        }
        // Somebody else settled it (another device, or the bridge's timeout). Unpark every request handler still
        // waiting on this key, and clear the gate in the store.
        for (waiter in waiters) {
            waiter.resume(null)
        }
        emit(ChatEvent.PermissionResolved(requestKey))
        if (params.text("outcome") == "timeout") {
            emit(ChatEvent.System("The permission request timed out and was declined"))
        }
    }

    private fun routeSessionEnded(params: JsonObject) {
        finalizeOpenItems()
        val reason = params.text("reason") ?: "unknown"
        emit(ChatEvent.Error("The remote agent session has ended ($reason)", recoverable = false))
    }

    // MARK: - Segmentation (ids derived from seq, per plan 4.5)

    private fun appendMessageChunk(text: String, role: ChatRole, seq: Int) {
        if (text.isEmpty()) {
            return
        }
        // A whitespace-only chunk never OPENS a bubble (it may extend one) - carried over from the stdio transport,
        // where agents emit leading whitespace before real content.
        val existing = synchronized(lock) { openMessageID }
        if (existing == null && text.isBlank()) {
            return
        }
        synchronized(lock) { openThoughtID = null }
        val (id, replaced) = synchronized(lock) {
            val open = openMessageID
            if (open != null && openMessageRole == role) {
                open to null
            } else {
                val minted = "acpr-m-$seq"
                openMessageID = minted
                openMessageRole = role
                minted to open
            }
        }
        // A role switch mid-turn (agent chunk then user chunk) must CLOSE the bubble it replaces. Leaving it open
        // keeps the store streaming that item until the turn ends, and the turn-end only closes the newest id.
        if (replaced != null) {
            emit(ChatEvent.MessageEnd(replaced, null))
        }
        if (replaced != null || id == "acpr-m-$seq") {
            emit(ChatEvent.MessageStart(id, role))
        }
        emit(ChatEvent.MessageDelta(id, text))
    }

    private fun appendThoughtChunk(text: String, seq: Int) {
        if (text.isEmpty()) {
            return
        }
        val openMessage = synchronized(lock) {
            val id = openMessageID
            openMessageID = null
            id
        }
        if (openMessage != null) {
            emit(ChatEvent.MessageEnd(openMessage, null))
        }
        val id = synchronized(lock) {
            openThoughtID ?: "acpr-t-$seq".also { openThoughtID = it }
        }
        emit(ChatEvent.ThoughtDelta(id, text))
    }

    private fun finalizeOpenItems() {
        val open = synchronized(lock) {
            val id = openMessageID
            openMessageID = null
            openThoughtID = null
            id
        }
        if (open != null) {
            emit(ChatEvent.MessageEnd(open, null))
        }
    }

    // MARK: - Cold-launch checkpoint (plan 4.2a)

    private fun emitCheckpointIfPossible() {
        val (session, seq) = synchronized(lock) { this.sessionID to this.lastSeq }
        if (session == null || seq <= 0) {
            return
        }
        emit(ChatEvent.ResumeCheckpoint(session, seq))
    }

    private fun emit(event: ChatEvent) {
        channel.trySend(event)
    }

    companion object {
        private const val ECHO_KEY_MEMORY = 64
        private const val PERMISSION_ANSWER_MEMORY = 64

        /**
         * Loopback, `.local`, RFC 1918, link-local, CGNAT (Tailscale), and their IPv6 twins. Internal for tests.
         *
         * This gate decides whether a token that is remote code execution on the bridge host may travel in
         * cleartext, so it fails CLOSED and parses strictly. Splitting on "." and keeping only the numeric labels
         * would make `127.0.0.1.evil.com` look like 127.0.0.1 - an attacker who registers that name gets the token
         * over plain ws://. Every label must parse, or the host is public.
         */
        internal fun isPrivateHost(host: String): Boolean {
            var name = host.lowercase()
            // Strip one trailing root dot ("mac.local." is the same name as "mac.local").
            if (name.endsWith(".")) {
                name = name.dropLast(1)
            }
            if (name.isEmpty()) {
                return false
            }
            if (name == "localhost" || name.endsWith(".local") || name.endsWith(".localhost")) {
                return true
            }
            if (name.contains(":")) {
                return isPrivateIPv6(name)
            }

            // Exactly four labels, every one a plain decimal 0...255. No octal, no hex, no shorthand forms, and
            // crucially no non-numeric labels sneaking through.
            val labels = name.split(".")
            if (labels.size != 4) {
                return false
            }
            val parts = mutableListOf<Int>()
            for (label in labels) {
                if (label.length !in 1..3 || !label.all { it.isDigit() && it.code < 128 }) {
                    return false
                }
                if (label.length > 1 && label.first() == '0') {   // 0177 must not read as 127
                    return false
                }
                val value = label.toIntOrNull() ?: return false
                if (value > 255) {
                    return false
                }
                parts.add(value)
            }

            return when {
                parts[0] == 127 || parts[0] == 10 -> true
                parts[0] == 192 && parts[1] == 168 -> true
                parts[0] == 169 && parts[1] == 254 -> true
                parts[0] == 172 && parts[1] in 16..31 -> true
                parts[0] == 100 && parts[1] in 64..127 -> true    // CGNAT / Tailscale
                else -> false
            }
        }

        /**
         * IPv6 loopback, unique-local (fc00::/7), and link-local (fe80::/10). The address arrives without its
         * brackets, and a zone id ("fe80::1%en0") is stripped first.
         */
        private fun isPrivateIPv6(name: String): Boolean {
            val address = name.substringBefore("%")
            if (!address.all { it == ':' || (it.code < 128 && (it.isDigit() || it in 'a'..'f')) }) {
                return false
            }
            if (address == "::1") {
                return true
            }
            val head = address.substringBefore(":")
            val leading = head.toIntOrNull(16)?.takeIf { it in 0..0xFFFF } ?: return false
            if (leading and 0xFE00 == 0xFC00) {      // fc00::/7, unique local
                return true
            }
            if (leading and 0xFFC0 == 0xFE80) {      // fe80::/10, link local
                return true
            }
            return false
        }

        internal fun clampedTimeout(raw: Double?, fallback: Double): Double {
            if (raw == null) {
                return fallback
            }
            if (!raw.isFinite() || raw <= 0) {
                return 0.0     // 0 or a nonsense value means "no watchdog", matching acp's startupTimeout
            }
            return min(raw, 86_400.0)
        }

        private fun secondsText(seconds: Double): String =
            if (seconds == Math.floor(seconds)) "${seconds.toInt()}s" else String.format(Locale.US, "%.1fs", seconds)

        private fun permissionOutcome(optionID: String?): JsonObject = buildJsonObject {
            putJsonObject("outcome") {
                if (optionID != null) {
                    put("outcome", "selected")
                    put("optionId", optionID)
                } else {
                    put("outcome", "cancelled")
                }
            }
        }

        private fun parsePermissionRequest(params: JsonObject, requestKey: String): PermissionRequest {
            val toolCall = params.obj("toolCall")
            val options = (params.objectArray("options") ?: emptyList())
                .mapNotNull { option ->
                    val id = option.text("optionId") ?: return@mapNotNull null
                    PermissionRequest.Option(
                        id = id,
                        name = option.text("name") ?: id,
                        kind = PermissionRequest.Option.Kind.entries
                            .firstOrNull { it.wire == option.text("kind") }
                            ?: PermissionRequest.Option.Kind.ALLOW_ONCE,
                    )
                }
            // The id IS the requestKey, so the gate keeps its identity across reconnects and across devices - that
            // is what lets the bridge re-issue the same request after a reattach.
            return PermissionRequest(
                id = requestKey,
                toolCallID = toolCall?.text("toolCallId"),
                title = toolCall?.text("title") ?: "Allow this action?",
                options = options,
            )
        }
    }
}

// Terse readers for the wire payloads. File-private so they never collide with the ones the test source set
// defines for its own assertions.
private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

private fun JsonObject.number(key: String): Int? = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull

private fun JsonObject.flag(key: String): Boolean? =
    (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.content?.toBooleanStrictOrNull()

private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

/**
 * An array of objects, ALL of them or none: one malformed element voids the list. That is Swift's
 * `as? [[String: Any]]` cast semantics, which AcpWireParsing already follows, and the safer reading of a payload
 * whose shape we do not recognize - half a list of permission options is worse than no list at all.
 */
private fun JsonObject.objectArray(key: String): List<JsonObject>? {
    val array = this[key] as? JsonArray ?: return null
    return array.map { it as? JsonObject ?: return null }
}
