package com.abracode.chatview.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.abracode.chatview.ChatConfiguration

/**
 * Stage A2/A3 demo shell. It exercises the Compose toolchain end to end and depends on :chatview so the composite
 * build (ChatView includeBuild RichText + AsyncImageCache) is proven to resolve. A8 replaces this with the real
 * People / Group / ReadOnly screens wiring the ChatView composable.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { DemoShell() }
    }
}

@Composable
private fun DemoShell() {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier.fillMaxSize().padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(text = "ChatView Demo", style = MaterialTheme.typography.titleLarge)
                Text(text = "Stage A3 pure-logic port - screens land in A8.", style = MaterialTheme.typography.bodyMedium)
                // Touch a real :chatview type so the composite dependency is a compile-time fact, not just config.
                Text(text = "placeholder: ${ChatConfiguration().placeholder}", style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}
