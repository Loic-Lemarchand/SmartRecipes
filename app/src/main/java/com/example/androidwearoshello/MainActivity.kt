package com.example.androidwearoshello

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { PhoneApp() }
    }
}

@Composable
private fun PhoneApp() {
    MaterialTheme {
        Scaffold(topBar = { TopAppBar(title = { Text("Hello Android") }) }) { padding ->
            Text(
                text = "Hello from the phone app!",
                modifier = Modifier.fillMaxSize().padding(padding),
                style = MaterialTheme.typography.headlineSmall
            )
        }
    }
}
