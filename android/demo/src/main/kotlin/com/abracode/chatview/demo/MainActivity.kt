package com.abracode.chatview.demo

// Stage A8 demo app. Three standalone screens - People (1:1), Group (four participants, member / call events), and
// ReadOnly (a restored group transcript) - each wiring the ChatView composable directly, no ActionUI. People and
// Group inject a live `local-p2p` transport config (the scripted person-to-person / group backend); ReadOnly loads
// transcript-v2-group.json from assets into a readOnly (no-composer) history view. Mirrors the Apple ChatViewDemo.

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.abracode.chatview.Cancellable
import com.abracode.chatview.ChatConfiguration
import com.abracode.chatview.ChatContentSource
import com.abracode.chatview.ConsoleChatLogger
import com.abracode.chatview.ui.ChatView
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme { Surface(Modifier.fillMaxSize()) { DemoRoot() } } }
    }
}

private enum class DemoScreen(val label: String) { PEOPLE("People"), GROUP("Group"), READ_ONLY("ReadOnly") }

/** A ChatContentSource that hands the store one fixed operational config on subscription (the host-injection seam). */
private class FixedConfigSource(private val config: JsonObject) : ChatContentSource {
    override fun observeChatContent(handler: (Any?) -> Unit): Cancellable = Cancellable { }
    override fun observeChatConfig(handler: (Any?) -> Unit): Cancellable {
        handler(config)
        return Cancellable { }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun DemoRoot() {
    var screen by remember { mutableStateOf(DemoScreen.PEOPLE) }
    Column(Modifier.fillMaxSize()) {
        SingleChoiceSegmentedButtonRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(8.dp)
                .testTag("demo.screenPicker"),
        ) {
            DemoScreen.entries.forEachIndexed { index, entry ->
                SegmentedButton(
                    selected = screen == entry,
                    onClick = { screen = entry },
                    shape = SegmentedButtonDefaults.itemShape(index, DemoScreen.entries.size),
                    modifier = Modifier.testTag("demo.tab.${entry.label}"),
                ) { Text(entry.label) }
            }
        }
        // Rebuild the ChatView (and its store) when the screen changes, so each demo starts a fresh session.
        key(screen) {
            when (screen) {
                DemoScreen.PEOPLE -> LiveScreen(scenario = "people")
                DemoScreen.GROUP -> LiveScreen(scenario = "group")
                DemoScreen.READ_ONLY -> ReadOnlyScreen()
            }
        }
    }
}

/** People / Group: a live local-p2p session. The document opts into every v2 feature; local-p2p backs them all. */
@Composable
private fun LiveScreen(scenario: String) {
    val logger = remember { ConsoleChatLogger() }
    val config = remember {
        val props = buildJsonObject {
            putJsonObject("appearance") {
                put("alignment", "dual")
                put("showAvatars", true)
            }
            putJsonObject("features") {
                put("reactions", true)
                put("editing", true)
                put("deletion", true)
                put("replies", true)
            }
            putJsonObject("input") { put("placeholder", "Message") }
        }
        ChatConfiguration.fromJson(props, logger)
    }
    val source = remember(scenario) {
        FixedConfigSource(
            buildJsonObject {
                put("protocol", "local-p2p")
                putJsonObject("transport") { put("scenario", scenario) }
            },
        )
    }
    ChatView(configuration = config, logger = logger, contentSource = source, modifier = Modifier.fillMaxSize())
}

/** ReadOnly: a restored group transcript from assets, shown in history-viewer mode (no transport, no composer). */
@Composable
private fun ReadOnlyScreen() {
    val context = LocalContext.current
    val logger = remember { ConsoleChatLogger() }
    val config = remember {
        val transcript = context.assets.open("transcript-v2-group.json").use { stream ->
            Json.parseToJsonElement(stream.readBytes().toString(Charsets.UTF_8))
        }
        val props = buildJsonObject {
            putJsonObject("appearance") {
                put("alignment", "dual")
                put("showAvatars", true)
            }
            put("readOnly", true)
            put("content", transcript)
        }
        ChatConfiguration.fromJson(props, logger)
    }
    ChatView(configuration = config, logger = logger, modifier = Modifier.fillMaxSize())
}
