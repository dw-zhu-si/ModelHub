package com.local.modelhub.mobile

import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.local.modelhub.shared.MobileConnectionState
import com.local.modelhub.shared.MobileGatewayOverview

class MainActivity : ComponentActivity() {
    private lateinit var controller: MobileController

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        controller = MobileController(this)
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        val scanner = GmsBarcodeScanning.getClient(this, options)
        setContent {
            ModelHubMobileApp(
                controller = controller,
                onScan = { callback ->
                    scanner.startScan()
                        .addOnSuccessListener { barcode -> barcode.rawValue?.let(callback) }
                },
            )
        }
    }

    override fun onDestroy() {
        if (::controller.isInitialized) controller.close()
        super.onDestroy()
    }
}

private enum class Destination(val title: String) {
    OVERVIEW("概览"),
    SETTINGS("设置"),
}

@Composable
private fun DestinationIcon(destination: Destination) {
    Icon(
        imageVector = if (destination == Destination.OVERVIEW) Icons.Filled.Home else Icons.Filled.Settings,
        contentDescription = destination.title,
    )
}

@Composable
fun ModelHubMobileApp(
    controller: MobileController,
    onScan: ((String) -> Unit) -> Unit,
) {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            var destination by rememberSaveable { mutableStateOf(Destination.OVERVIEW) }
            BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding()) {
                when {
                    maxWidth < 600.dp -> CompactLayout(destination, { destination = it }) {
                        DestinationContent(destination, controller, onScan)
                    }
                    maxWidth < 840.dp -> RailLayout(destination, { destination = it }) {
                        DestinationContent(destination, controller, onScan)
                    }
                    else -> ExpandedLayout(destination, { destination = it }) {
                        DestinationContent(destination, controller, onScan)
                    }
                }
            }
        }
    }
}

@Composable
private fun CompactLayout(
    destination: Destination,
    select: (Destination) -> Unit,
    content: @Composable () -> Unit,
) {
    Scaffold(
        bottomBar = {
            NavigationBar {
                Destination.entries.forEach { item ->
                    NavigationBarItem(
                        selected = item == destination,
                        onClick = { select(item) },
                        icon = { DestinationIcon(item) },
                        label = { Text(item.title) },
                    )
                }
            }
        },
    ) { padding -> Column(Modifier.padding(padding).fillMaxSize()) { content() } }
}

@Composable
private fun RailLayout(
    destination: Destination,
    select: (Destination) -> Unit,
    content: @Composable () -> Unit,
) {
    Row(Modifier.fillMaxSize()) {
        NavigationRail {
            Destination.entries.forEach { item ->
                NavigationRailItem(
                    selected = item == destination,
                    onClick = { select(item) },
                    icon = { DestinationIcon(item) },
                    label = { Text(item.title) },
                )
            }
        }
        Column(Modifier.weight(1f).fillMaxHeight()) { content() }
    }
}

@Composable
private fun ExpandedLayout(
    destination: Destination,
    select: (Destination) -> Unit,
    content: @Composable () -> Unit,
) {
    Row(Modifier.fillMaxSize()) {
        Column(
            Modifier.width(240.dp).fillMaxHeight().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("ModelHub", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            Text("安全伴侣端", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(20.dp))
            Destination.entries.forEach { item ->
                if (item == destination) Button(onClick = { select(item) }, modifier = Modifier.fillMaxWidth()) {
                    Text(item.title)
                } else OutlinedButton(onClick = { select(item) }, modifier = Modifier.fillMaxWidth()) {
                    Text(item.title)
                }
            }
        }
        Column(Modifier.weight(1f).fillMaxHeight()) { content() }
    }
}

@Composable
private fun DestinationContent(
    destination: Destination,
    controller: MobileController,
    onScan: ((String) -> Unit) -> Unit,
) {
    when (destination) {
        Destination.OVERVIEW -> OverviewDestination(controller, onScan)
        Destination.SETTINGS -> SettingsDestination(controller)
    }
}

@Composable
private fun OverviewDestination(
    controller: MobileController,
    onScan: ((String) -> Unit) -> Unit,
) {
    when (val state = controller.state) {
        MobileConnectionState.Unpaired -> PairingView(controller, onScan)
        is MobileConnectionState.AwaitingDesktopApproval -> CenterMessage(
            title = "等待 Mac 批准",
            message = "配对申请已安全送达。请在 ModelHub 桌面端核对设备名称和公钥指纹后批准。",
            progress = true,
        )
        is MobileConnectionState.Connected -> OverviewView(state.bootstrap.overview, isOffline = false, onRefresh = controller::refresh)
        is MobileConnectionState.Offline -> state.lastKnown?.let {
            OverviewView(it.overview, isOffline = true, onRefresh = controller::refresh)
        } ?: CenterMessage("无法连接网关", "确认 Mac 上的移动访问已开启，且两台设备在同一局域网或 VPN。", false, controller::refresh)
        MobileConnectionState.Revoked -> CenterMessage("设备授权已撤销", "请在桌面端重新生成配对二维码。", false, controller::forgetBinding)
        is MobileConnectionState.Failed -> CenterMessage("配对未完成", state.message, false, controller::forgetBinding)
    }
}

@Composable
private fun PairingView(
    controller: MobileController,
    onScan: ((String) -> Unit) -> Unit,
) {
    var payload by rememberSaveable { mutableStateOf("") }
    var deviceName by rememberSaveable { mutableStateOf(Build.MODEL.take(80)) }
    LazyColumn(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Text("连接 ModelHub", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
            Text("扫描 Mac 端的 2 分钟配对码。扫码后仍需在 Mac 上显式批准。")
        }
        item {
            Button(onClick = { onScan { payload = it } }, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                Text("扫描配对二维码")
            }
        }
        item {
            OutlinedTextField(
                value = payload,
                onValueChange = { payload = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("或粘贴二维码内容") },
                minLines = 4,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None),
            )
        }
        item {
            OutlinedTextField(
                value = deviceName,
                onValueChange = { if (it.encodeToByteArray().size <= 80) deviceName = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("设备名称") },
                singleLine = true,
            )
        }
        item {
            Button(
                onClick = { controller.pair(payload, deviceName) },
                enabled = payload.isNotBlank() && deviceName.isNotBlank(),
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) { Text("提交安全配对") }
        }
        item { Text("供应商密钥、OAuth 令牌和桌面网关令牌始终留在 Mac。", color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun OverviewView(overview: MobileGatewayOverview, isOffline: Boolean, onRefresh: () -> Unit) {
    LazyColumn(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Column {
                    Text("概览", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                    Text(if (isOffline) "离线快照 · ${overview.generatedAt}" else "已安全连接 · ${overview.gatewayVersion}")
                }
                OutlinedButton(onClick = onRefresh) { Text("刷新") }
            }
        }
        item { SummaryCard("默认模型", overview.defaultModel ?: "暂无健康默认模型") }
        item { SummaryCard("可用模型", "${overview.modelHealth.available} / ${overview.modelHealth.total}") }
        item { SummaryCard("已启用供应商", overview.enabledProviderCount.toString()) }
        item { Text("供应商健康", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold) }
        items(overview.providers, key = { it.id }) { provider ->
            Card(Modifier.fillMaxWidth()) {
                Row(Modifier.padding(18.dp).fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column {
                        Text(provider.name, fontWeight = FontWeight.SemiBold)
                        Text("可用 ${provider.availableModels} · 隔离 ${provider.quarantinedModels}")
                    }
                    Text("${provider.availableModels}/${provider.totalModels}")
                }
            }
        }
    }
}

@Composable
private fun SummaryCard(title: String, value: String) {
    Card(
        Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun SettingsDestination(controller: MobileController) {
    var showsForgetConfirmation by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("设置", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Text("当前网关：${controller.savedServiceUrl ?: "未配对"}")
        Text("设备签名私钥保存在 Android Keystore；不保存供应商密钥或桌面全局令牌。")
        OutlinedButton(onClick = { showsForgetConfirmation = true }, modifier = Modifier.fillMaxWidth().height(52.dp)) {
            Text("忘记本机配对")
        }
    }
    if (showsForgetConfirmation) {
        AlertDialog(
            onDismissRequest = { showsForgetConfirmation = false },
            title = { Text("忘记本机配对？") },
            text = { Text("这会删除本机的设备签名密钥和网关绑定。下次连接需要重新扫码并在 Mac 上批准。") },
            confirmButton = {
                TextButton(onClick = {
                    showsForgetConfirmation = false
                    controller.forgetBinding()
                }) { Text("忘记配对", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { showsForgetConfirmation = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun CenterMessage(
    title: String,
    message: String,
    progress: Boolean,
    action: (() -> Unit)? = null,
) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (progress) CircularProgressIndicator()
        Spacer(Modifier.height(20.dp))
        Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        Text(message)
        if (action != null) {
            Spacer(Modifier.height(20.dp))
            Button(onClick = action, modifier = Modifier.height(52.dp)) { Text("继续") }
        }
    }
}
