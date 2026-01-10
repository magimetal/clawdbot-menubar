import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var launchAtLogin: Bool = LaunchAtLoginManager.isEnabled
    @State private var clawdbotPathInput: String = ""
    @State private var showPathEditor: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.circle.fill")
                    .font(.title2)
                    .foregroundColor(headerColor)
                Text("Clawdbot")
                    .font(.headline)
                Spacer()
                ProgressView()
                    .scaleEffect(0.5)
                    .opacity(appState.isRefreshing ? 1 : 0)
                if let appIconImage = NSImage(named: "AppIcon") {
                    Image(nsImage: appIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                          let iconImage = NSImage(contentsOf: iconURL) {
                    Image(nsImage: iconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                }
            }
            .padding(.bottom, 4)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(
                    icon: "power",
                    label: "Gateway",
                    value: appState.gatewayStatus.rawValue,
                    valueColor: gatewayStatusColor
                )
                
                if let pid = appState.gatewayPID {
                    StatusRow(
                        icon: "number",
                        label: "PID",
                        value: "\(pid)",
                        valueColor: .secondary
                    )
                }
                
                StatusRow(
                    icon: "bubble.left.and.bubble.right",
                    label: "Discord",
                    value: appState.discordConnected ? "Connected" : "Disconnected",
                    valueColor: appState.discordConnected ? .green : .red
                )
                
                StatusRow(
                    icon: "person.2",
                    label: "Sessions",
                    value: "\(appState.activeSessionsCount)",
                    valueColor: .secondary
                )
                
                if let lastActivity = appState.lastActivity {
                    StatusRow(
                        icon: "clock",
                        label: "Last Check",
                        value: lastActivity.formatted(date: .omitted, time: .shortened),
                        valueColor: .secondary
                    )
                }
                
                StatusRow(
                    icon: "gearshape",
                    label: "Mode",
                    value: appState.launchMode == .launchd ? "launchd" : "Direct",
                    valueColor: .secondary
                )
                
                if appState.launchMode == .launchd {
                    StatusRow(
                        icon: "checkmark.circle",
                        label: "Service",
                        value: appState.launchdInstalled ? "Installed" : "Not Installed",
                        valueColor: appState.launchdInstalled ? .green : .orange
                    )
                }
            }
            
            Divider()
            
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    if appState.gatewayStatus == .running {
                        Button(action: { appState.stopGateway() }) {
                            Label("Stop", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        
                        Button(action: { appState.restartGateway() }) {
                            Label("Restart", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    } else {
                        Button(action: { appState.startGateway() }) {
                            Label("Start Gateway", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
                
                HStack(spacing: 8) {
                    Button(action: { appState.openLogs() }) {
                        Label("Logs", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: { appState.openWebUI() }) {
                        Label("Web UI", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.gatewayStatus != .running)
                }
                
                Button(action: { appState.refresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Update & Rebuild
                if appState.isUpdating {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text(appState.updateStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button(action: { appState.updateAndRebuild() }) {
                        Label("Update & Rebuild", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.getClawdbotDirectory() == nil)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $launchAtLogin) {
                    Label("Launch at Login", systemImage: "power")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLoginManager.isEnabled = newValue
                }
                
                Toggle(isOn: $appState.notificationsEnabled) {
                    Label("Notify on Status Change", systemImage: "bell")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                
                Picker("Launch Mode", selection: Binding(
                    get: { appState.launchMode },
                    set: { appState.launchMode = $0 }
                )) {
                    Text("Direct Process").tag(LaunchMode.direct)
                    Text("launchd Service").tag(LaunchMode.launchd)
                }
                .pickerStyle(.menu)
                .controlSize(.small)

                // Clawdbot Path Configuration
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Clawdbot Path")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if !appState.clawdbotPath.isEmpty {
                            Image(systemName: appState.validateClawdbotPath(appState.clawdbotPath) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(appState.validateClawdbotPath(appState.clawdbotPath) ? .green : .red)
                                .font(.caption)
                        }
                    }

                    if showPathEditor {
                        HStack(spacing: 4) {
                            TextField("~/Dev/clawdbot", text: $clawdbotPathInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    appState.setClawdbotPath(clawdbotPathInput)
                                    showPathEditor = false
                                }

                            Button(action: browseForPath) {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(action: {
                                appState.setClawdbotPath(clawdbotPathInput)
                                showPathEditor = false
                            }) {
                                Image(systemName: "checkmark")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    } else {
                        Button(action: {
                            clawdbotPathInput = appState.clawdbotPath
                            showPathEditor = true
                        }) {
                            HStack {
                                Text(appState.clawdbotPath.isEmpty ? "Auto-detect" : appState.clawdbotPath)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Image(systemName: "pencil")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if appState.launchMode == .launchd {
                    HStack(spacing: 8) {
                        if appState.launchdInstalled {
                            Button("Uninstall Service") {
                                appState.uninstallLaunchdService()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.small)
                        } else {
                            Button("Install Service") {
                                appState.installLaunchdService()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
            
            if appState.detectedNodePath == nil || appState.detectedScriptPath == nil {
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    if appState.detectedNodePath == nil {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Node.js not found")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    if appState.detectedScriptPath == nil {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("clawdbot not found")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            
            Divider()
            
            HStack {
                Text("METAL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            appState.refresh()
        }
    }
    
    private var headerColor: Color {
        switch appState.gatewayStatus {
        case .running:
            return appState.discordConnected ? .green : .yellow
        case .stopped:
            return .red
        case .unknown:
            return .gray
        }
    }
    
    private var gatewayStatusColor: Color {
        switch appState.gatewayStatus {
        case .running:
            return .green
        case .stopped:
            return .red
        case .unknown:
            return .gray
        }
    }

    private func browseForPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your clawdbot installation directory"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            clawdbotPathInput = url.path
            appState.setClawdbotPath(url.path)
            showPathEditor = false
        }
    }
}

struct StatusRow: View {
    let icon: String
    let label: String
    let value: String
    let valueColor: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(valueColor)
                .fontWeight(.medium)
        }
        .font(.callout)
    }
}
