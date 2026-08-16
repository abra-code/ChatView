package com.abracode.chatview.demo

// The `acp-remote` demo screen: the Android twin of Examples/Shared/RemoteAgentScreen.swift. A phone attaches to
// an ACP agent running on a Mac (or anywhere) through chatview-acp-bridge, streams its turns, and answers its
// permission prompts.
//
// It is also the Android reference host for the cold-launch checkpoint contract (remote-agent plan 4.2a): the
// transcript and its resume cursor are persisted ATOMICALLY, and the plan's own risk list calls a non-atomic host
// the one failure the design cannot close in code - so the demo has to get it right visibly, not incidentally.

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.abracode.chatview.Cancellable
import com.abracode.chatview.ChatConfiguration
import com.abracode.chatview.ChatContentSource
import com.abracode.chatview.ChatHostEvent
import com.abracode.chatview.ConsoleChatLogger
import com.abracode.chatview.ui.ChatView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.io.File

// MARK: - Settings

/**
 * Where the bridge is and how to talk to it, in plain SharedPreferences.
 *
 * THAT IS WRONG FOR THE TOKEN IN A REAL APP: it authorizes tool execution on the bridge host, which is remote code
 * execution, and it belongs in an Android Keystore-backed EncryptedSharedPreferences. The demo keeps it simple and
 * says so loudly rather than implying that plaintext prefs for such a credential are fine (plan 4.6).
 */
class RemoteAgentSettings(context: Context) {

    private val prefs = context.getSharedPreferences("chatview.demo.acpRemote", Context.MODE_PRIVATE)

    // 10.0.2.2 is the emulator's route to the host machine's loopback, which is where run-bridge-demo.sh binds. A
    // real device needs the Mac's LAN address instead - run the harness with --lan.
    var url by mutableStateOf(prefs.getString("url", "ws://10.0.2.2:8737/acp")!!)
    var token by mutableStateOf(prefs.getString("token", "demo-token-please-do-not-reuse")!!)
    var sessionMode by mutableStateOf(prefs.getString("session", "latest")!!)

    fun save() {
        prefs.edit()
            .putString("url", url)
            .putString("token", token)
            .putString("session", sessionMode)
            .apply()
    }
}

// MARK: - Persistence (the 4.2a reference behavior)

/**
 * Accumulates finalized entries and the resume checkpoint, and writes BOTH under a single atomic file write.
 *
 * The timing is the whole lesson. Entries are held in memory as they arrive and committed to disk only when a
 * checkpoint arrives - which the transport emits only at turn boundaries. That makes atomicity structural rather
 * than something the host has to remember: there is no moment at which a cursor exists on disk without exactly the
 * transcript it describes.
 *
 * Entries after the last checkpoint are deliberately NOT saved. Losing them is correct: the bridge still has them,
 * and the next attach replays from the cursor and re-delivers them with identical ids. Saving them WITHOUT a
 * matching cursor is the failure that silently skips history on the next launch.
 */
class RemoteAgentPersistence(context: Context) {

    data class Restored(val content: JsonObject, val sessionId: String, val afterSeq: Int)

    private val file: File = File(File(context.filesDir, "ChatViewRemoteDemo").apply { mkdirs() }, "session.json")
    private val lock = Any()

    /** Single-threaded: commits are ordered, and none of them run on the thread drawing the transcript. */
    @OptIn(ExperimentalCoroutinesApi::class)
    private val writes = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))

    // LinkedHashMap gives the two rules this needs for free: insertion order is transcript order, and re-putting an
    // existing id replaces its payload without moving it - which is exactly what a re-fired entry means (a tool
    // call's terminal status and its final output arrive as separate updates).
    private val itemsByID = LinkedHashMap<String, JsonElement>()
    private var loaded = false
    private var restorePayload: Restored? = null

    /** Records one [ChatHostEvent.Entry] envelope: `{ sequence, type, id, data, updated? }`. */
    fun record(entryJson: String) {
        val envelope = runCatching { Json.parseToJsonElement(entryJson).jsonObject }.getOrNull() ?: return
        val type = (envelope["type"] as? JsonPrimitive)?.contentOrNullIfNotString() ?: return
        if (type !in itemTypes) {
            // plan / usage / session / participants / messageIdConfirmed describe surfaces or bookkeeping, not
            // transcript rows; one of them in a restored transcript would simply fail to decode.
            return
        }
        val id = (envelope["id"] as? JsonPrimitive)?.contentOrNullIfNotString() ?: return
        val data = envelope["data"] ?: return
        synchronized(lock) { itemsByID[id] = data }
    }

    /** Records a checkpoint and commits everything. This is the ONLY write. */
    fun commit(checkpointJson: String) {
        val payload = runCatching { Json.parseToJsonElement(checkpointJson).jsonObject }.getOrNull() ?: return
        val sessionId = (payload["sessionId"] as? JsonPrimitive)?.contentOrNullIfNotString() ?: return
        val afterSeq = (payload["afterSeq"] as? JsonPrimitive)?.content?.toIntOrNull() ?: return
        val snapshot = synchronized(lock) {
            buildJsonObject {
                put("sessionId", sessionId)
                put("afterSeq", afterSeq)
                putJsonArray("items") {
                    for ((id, data) in itemsByID) {
                        add(
                            buildJsonObject {
                                put("id", id)
                                put("data", data)
                            },
                        )
                    }
                }
            }
        }
        // Encode and write OFF the main thread: the host event sink is called on the main thread, so a long
        // session would otherwise hitch the UI at every turn boundary. The snapshot above is built synchronously,
        // which is what keeps it a consistent pair; only the write is deferred, onto a single-threaded dispatcher
        // so writes cannot overtake each other.
        writes.launch {
            // Write-then-rename: a crash leaves either the previous consistent pair or the new one, never a cursor
            // from one moment beside a transcript from another. A failed rename is left alone deliberately - the
            // previous pair is still on disk and still correct, where a non-atomic rewrite could truncate it and
            // lose the whole transcript.
            runCatching {
                val temp = File(file.parentFile, file.name + ".tmp")
                temp.writeText(Json.encodeToString(JsonObject.serializer(), snapshot))
                if (!temp.renameTo(file)) {
                    temp.delete()
                }
            }
        }
    }

    /**
     * Reads the stored pair, ONCE, and seeds the in-memory accumulator from it. The once-ness is load-bearing: a
     * composable body runs constantly, and re-seeding would discard entries recorded since the last checkpoint and
     * then commit a NEW cursor beside the OLD transcript - the cursor-ahead-of-transcript failure this design calls
     * unfixable in code, manufactured by its own reference host.
     */
    fun restoreOnce(): Restored? {
        synchronized(lock) {
            if (loaded) {
                return restorePayload
            }
            loaded = true
        }
        val snapshot = runCatching { Json.parseToJsonElement(file.readText()).jsonObject }.getOrNull() ?: return null
        val sessionId = (snapshot["sessionId"] as? JsonPrimitive)?.contentOrNullIfNotString() ?: return null
        val afterSeq = (snapshot["afterSeq"] as? JsonPrimitive)?.content?.toIntOrNull() ?: return null
        val stored = runCatching { snapshot["items"]!!.jsonArray.map { it.jsonObject } }.getOrNull() ?: return null
        if (stored.isEmpty()) {
            return null
        }

        val items = mutableListOf<JsonElement>()
        synchronized(lock) {
            // MERGE, do not clobber. Anything already recorded happened AFTER the file was written and must
            // survive, or the next commit writes a cursor past rows it just dropped.
            val recorded = LinkedHashMap(itemsByID)
            itemsByID.clear()
            for (row in stored) {
                val id = (row["id"] as? JsonPrimitive)?.contentOrNullIfNotString() ?: continue
                val data = row["data"] ?: continue
                itemsByID[id] = recorded[id] ?: data
                items.add(data)
            }
            for ((id, data) in recorded) {
                if (!itemsByID.containsKey(id)) {
                    itemsByID[id] = data
                }
            }
        }
        if (items.isEmpty()) {
            return null
        }
        // "prime": "defer" - display the transcript without replaying it into the agent. The agent on the bridge
        // already has this conversation; re-priming would duplicate the context it is holding.
        val content = buildJsonObject {
            put("version", 1)
            putJsonArray("items") { for (item in items) add(item) }
            put("prime", "defer")
        }
        val payload = Restored(content, sessionId, afterSeq)
        synchronized(lock) { restorePayload = payload }
        return payload
    }

    /**
     * Forgets the stored pair AND the in-memory accumulator, for when the user deliberately starts a new
     * conversation - a cursor kept across that would point into a session they just abandoned.
     */
    fun reset() {
        synchronized(lock) {
            itemsByID.clear()
            restorePayload = null
            loaded = true          // nothing left to load; do not re-read the file we just deleted
        }
        file.delete()
    }

    private companion object {
        val itemTypes = setOf(
            "message", "thought", "toolCall", "image", "system", "error",
            "memberEvent", "callEvent", "file",
        )
    }
}

private fun JsonPrimitive.contentOrNullIfNotString(): String? = if (isString) content else null

// MARK: - The content source

/**
 * Hands ChatView its transport config and any restored transcript. Both channels are host-injected at runtime,
 * never declared in static UI data - the security boundary that keeps a bridge token out of a document (plan 4.6).
 */
private class RemoteAgentContentSource(
    private val config: JsonObject,
    private val content: JsonObject?,
) : ChatContentSource {
    override fun observeChatContent(handler: (Any?) -> Unit): Cancellable {
        content?.let(handler)
        return Cancellable { }
    }

    override fun observeChatConfig(handler: (Any?) -> Unit): Cancellable {
        handler(config)
        return Cancellable { }
    }
}

// MARK: - The screen

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun RemoteAgentScreen() {
    val context = LocalContext.current
    val settings = remember { RemoteAgentSettings(context) }
    val persistence = remember { RemoteAgentPersistence(context) }
    var showingSettings by remember { mutableStateOf(false) }
    // Bumping this rebuilds the chat with a fresh transport - how the demo applies new settings or starts over.
    var generation by remember { mutableStateOf(0) }
    // "New" is an ACTION, not a policy: it must not be written into the stored session mode. Latched here, it
    // dies with the composition, so a rotation or a tab switch after New resumes the session New started rather
    // than abandoning it and creating a third one - which, with the stored pair already deleted, would render an
    // empty transcript.
    var forceNew by remember { mutableStateOf(false) }

    val restored = remember(generation) { persistence.restoreOnce() }
    val resuming = restored != null && !forceNew && settings.sessionMode != "new"

    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Remote agent", style = MaterialTheme.typography.titleSmall)
                Text(
                    settings.url,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                )
            }
            TextButton(
                onClick = {
                    // A new conversation, and the stored pair goes with it: a cursor kept across a deliberate reset
                    // would point into a session the user just abandoned. The session MODE is left alone - see
                    // forceNew above.
                    persistence.reset()
                    forceNew = true
                    generation++
                },
                modifier = Modifier.testTag("demo.agent.new"),
            ) { Text("New") }
            TextButton(
                onClick = { showingSettings = true },
                modifier = Modifier.testTag("demo.agent.settings"),
            ) { Text("Settings") }
        }

        if (resuming && restored != null) {
            Text(
                "Resumed ${restored.sessionId} from seq ${restored.afterSeq} - only what you missed was fetched.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 12.dp).padding(bottom = 6.dp),
            )
        }

        key(generation) {
            val logger = remember { ConsoleChatLogger() }
            val config = remember(generation) {
                val props = buildJsonObject {
                    put("input", buildJsonObject { put("placeholder", "Message the remote agent") })
                    put(
                        "surfaces",
                        buildJsonObject {
                            put("thoughts", "collapsed")
                            put("toolCalls", "inline")
                            put("plan", "panel")
                        },
                    )
                }
                ChatConfiguration.fromJson(props, logger).apply {
                    // No entries out, no cursor out: the checkpoint rides the same channel the transcript does.
                    emitsEntryEvents = true
                }
            }
            val source = remember(generation) {
                val transport = buildJsonObject {
                    put("url", settings.url)
                    put("token", settings.token)
                    // Both halves or neither (plan 4.5): the transcript and the cursor it was minted with are
                    // injected together, on the same launch, or the demo starts clean.
                    if (resuming && restored != null) {
                        put("session", restored.sessionId)
                        put("resumeAfterSeq", restored.afterSeq)
                    } else if (forceNew) {
                        put("session", "new")
                    } else {
                        put("session", settings.sessionMode)
                    }
                }
                RemoteAgentContentSource(
                    config = buildJsonObject {
                        put("protocol", "acp-remote")
                        put("transport", transport)
                    },
                    content = if (resuming) restored?.content else null,
                )
            }
            ChatView(
                configuration = config,
                logger = logger,
                contentSource = source,
                hostEvents = { event ->
                    when (event) {
                        is ChatHostEvent.Entry -> persistence.record(event.json)
                        is ChatHostEvent.ResumeCheckpoint -> persistence.commit(event.json)
                        else -> Unit
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }

    if (showingSettings) {
        var draftURL by remember { mutableStateOf(settings.url) }
        var draftToken by remember { mutableStateOf(settings.token) }
        var draftSession by remember { mutableStateOf(settings.sessionMode) }
        AlertDialog(
            onDismissRequest = { showingSettings = false },
            title = { Text("Bridge settings") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    // No autocapitalization and no autocorrect on either field: a soft keyboard that capitalizes
                    // "Ws://" or "corrects" a base64url token produces an authentication failure whose cause is
                    // invisible. The token is additionally masked - it authorizes code execution on the bridge.
                    OutlinedTextField(
                        value = draftURL,
                        onValueChange = { draftURL = it },
                        label = { Text("URL") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            autoCorrectEnabled = false,
                            keyboardType = KeyboardType.Uri,
                        ),
                        modifier = Modifier.fillMaxWidth().testTag("demo.agent.url"),
                    )
                    OutlinedTextField(
                        value = draftToken,
                        onValueChange = { draftToken = it },
                        label = { Text("Token") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            autoCorrectEnabled = false,
                            keyboardType = KeyboardType.Password,
                        ),
                        modifier = Modifier.fillMaxWidth().testTag("demo.agent.token"),
                    )
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        listOf("latest" to "Resume latest", "new" to "Always new")
                            .forEachIndexed { index, (value, label) ->
                                SegmentedButton(
                                    selected = draftSession == value,
                                    onClick = { draftSession = value },
                                    shape = SegmentedButtonDefaults.itemShape(index, 2),
                                ) { Text(label) }
                            }
                    }
                    Text(
                        "Run Scripts/run-bridge-demo.sh on the Mac to start a bridge; it prints this URL and "
                            + "token. An emulator reaches the host's loopback at 10.0.2.2; a real device needs the "
                            + "Mac's LAN address (run the harness with --lan).\n\n"
                            + "The token authorizes tool execution on the bridge host, so cleartext ws:// is only "
                            + "acceptable on a network you trust.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    settings.url = draftURL
                    settings.token = draftToken
                    settings.sessionMode = draftSession
                    settings.save()
                    // Switching to "Always new" must drop the stored pair too. Leaving it would reseed the
                    // accumulator from the abandoned session, and the new session's first checkpoint would then
                    // write those old rows under the new id.
                    if (draftSession == "new") {
                        persistence.reset()
                    }
                    // The sheet sets the policy explicitly, so a latched one-shot must not outlive it.
                    forceNew = false
                    showingSettings = false
                    generation++
                }) { Text("Apply") }
            },
            dismissButton = {
                TextButton(onClick = { showingSettings = false }) { Text("Cancel") }
            },
        )
    }
}
