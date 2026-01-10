import SwiftUI
import AppKit
import UserNotifications

@main
struct ClawdbotMenuApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(iconColor, .primary)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        switch appState.gatewayStatus {
        case .running:
            return appState.discordConnected ? "bolt.fill" : "bolt"
        case .stopped:
            return "bolt.slash"
        case .unknown:
            return "bolt.badge.clock"
        }
    }

    private var iconColor: Color {
        switch appState.gatewayStatus {
        case .running:
            return appState.discordConnected ? .green : .yellow
        case .stopped:
            return .red
        case .unknown:
            return .gray
        }
    }
}

enum GatewayStatus: String {
    case running = "Running"
    case stopped = "Stopped"
    case unknown = "Unknown"
}

enum LaunchMode: String, CaseIterable {
    case direct = "Direct Process"
    case launchd = "launchd Service"
}

final class AppState: ObservableObject {
    static let shared = AppState()
    
    static let gatewayPort = 18789
    static let launchdLabel = "com.clawdbot.gateway"
    static let logDirectory = NSString(string: "~/.clawdbot/logs").expandingTildeInPath
    static let logPath = NSString(string: "~/.clawdbot/logs/gateway.log").expandingTildeInPath
    static let launchAgentsDir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
    #if DEBUG
    static let debugLogPath = NSString(string: "~/.clawdbot/logs/menubar-debug.log").expandingTildeInPath
    #endif
    
    private func debugLog(_ message: String) {
        #if DEBUG
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.debugLogPath) {
                if let handle = FileHandle(forWritingAtPath: Self.debugLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: Self.debugLogPath, contents: data)
            }
        }
        #endif
    }
    
    @Published var gatewayStatus: GatewayStatus = .unknown
    @Published var gatewayPID: Int?
    @Published var discordConnected: Bool = false
    @Published var activeSessionsCount: Int = 0
    @Published var lastActivity: Date?
    @Published var isRefreshing: Bool = false
    @Published var detectedNodePath: String?
    @Published var detectedScriptPath: String?
    @Published var launchdInstalled: Bool = false
    @Published var isUpdating: Bool = false
    @Published var updateStatus: String = ""
    
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true
    @AppStorage("launchMode") var launchModeRaw: String = LaunchMode.direct.rawValue
    @AppStorage("clawdbotPath") var clawdbotPath: String = ""
    
    var launchMode: LaunchMode {
        get { LaunchMode(rawValue: launchModeRaw) ?? .direct }
        set { launchModeRaw = newValue.rawValue }
    }
    
    private var previousGatewayStatus: GatewayStatus = .unknown
    private var gatewayProcess: Process?
    private var processTerminationObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var fastPollTimer: Timer?
    private var expectedStatus: GatewayStatus?
    
    private init() {
        requestNotificationPermission()
        ensureLogDirectory()
        detectPaths()
        checkLaunchdStatus()
        startPolling()
        refresh()
    }
    
    // MARK: - Path Detection
    
    private func detectPaths() {
        detectedNodePath = detectNodePath()
        detectedScriptPath = detectScriptPath()
        debugLog("Detected Node path: \(detectedNodePath ?? "nil")")
        debugLog("Detected script path: \(detectedScriptPath ?? "nil")")
    }
    
    private func detectNodePath() -> String? {
        // Try 'which node' first
        if let path = runCommand("/usr/bin/which", arguments: ["node"]) {
            return path
        }
        
        // Common node locations
        let commonPaths = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            NSString(string: "~/.nvm/versions/node").expandingTildeInPath,
            "/usr/bin/node"
        ]
        
        // Check NVM directory for latest version
        let nvmVersionsDir = NSString(string: "~/.nvm/versions/node").expandingTildeInPath
        if FileManager.default.fileExists(atPath: nvmVersionsDir) {
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsDir) {
                // Sort versions and get the latest
                let sortedVersions = versions.sorted { v1, v2 in
                    v1.compare(v2, options: .numeric) == .orderedDescending
                }
                if let latestVersion = sortedVersions.first {
                    let nodePath = "\(nvmVersionsDir)/\(latestVersion)/bin/node"
                    if FileManager.default.fileExists(atPath: nodePath) {
                        return nodePath
                    }
                }
            }
        }
        
        // Check common paths
        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    private func detectScriptPath() -> String? {
        // Check user-configured path first
        if !clawdbotPath.isEmpty {
            let expandedPath = NSString(string: clawdbotPath).expandingTildeInPath
            let scriptPath = "\(expandedPath)/dist/index.js"
            if FileManager.default.fileExists(atPath: scriptPath) {
                return scriptPath
            }
        }

        // Try 'which clawdbot' first
        if let whichPath = runCommand("/usr/bin/which", arguments: ["clawdbot"]) {
            return whichPath
        }

        // Common locations for clawdbot
        let homeDir = NSString(string: "~").expandingTildeInPath
        let commonPaths = [
            "\(homeDir)/Dev/clawdbot/dist/index.js",
            "\(homeDir)/clawdbot/dist/index.js",
            "/usr/local/lib/node_modules/clawdbot/dist/index.js",
            "\(homeDir)/.npm-global/lib/node_modules/clawdbot/dist/index.js"
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try npm/pnpm global
        if let npmGlobal = runCommand("/usr/bin/which", arguments: ["npm"]) {
            let npmRoot = runCommand(npmGlobal, arguments: ["root", "-g"])
            if let root = npmRoot {
                let clawdbotScript = "\(root)/clawdbot/dist/index.js"
                if FileManager.default.fileExists(atPath: clawdbotScript) {
                    return clawdbotScript
                }
            }
        }

        return nil
    }

    func validateClawdbotPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let expandedPath = NSString(string: path).expandingTildeInPath
        let scriptPath = "\(expandedPath)/dist/index.js"
        return FileManager.default.fileExists(atPath: scriptPath)
    }

    func setClawdbotPath(_ path: String) {
        clawdbotPath = path
        detectedScriptPath = detectScriptPath()
    }
    
    private func runCommand(_ command: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        // Set PATH to include common locations
        var env = ProcessInfo.processInfo.environment
        let additionalPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            NSString(string: "~/.nvm/versions/node").expandingTildeInPath,
            "/usr/bin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = additionalPaths.joined(separator: ":") + ":" + currentPath
        process.environment = env
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            // Silently fail
        }
        
        return nil
    }
    
    // MARK: - Launchd Management
    
    private var plistPath: String {
        return "\(Self.launchAgentsDir)/\(Self.launchdLabel).plist"
    }
    
    func checkLaunchdStatus() {
        launchdInstalled = FileManager.default.fileExists(atPath: plistPath)
        
        // Also check if it's loaded
        if launchdInstalled {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "gui/\(getuid())/\(Self.launchdLabel)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            
            do {
                try process.run()
                process.waitUntilExit()
                // If exit code is 0, service is loaded
            } catch {
                // Ignore errors
            }
        }
    }
    
    func installLaunchdService() {
        guard let nodePath = detectedNodePath else {
            sendNotification(title: "Installation Failed", body: "Could not detect Node.js path")
            return
        }
        
        guard let scriptPath = detectedScriptPath else {
            sendNotification(title: "Installation Failed", body: "Could not detect clawdbot script path")
            return
        }
        
        // Ensure LaunchAgents directory exists
        try? FileManager.default.createDirectory(atPath: Self.launchAgentsDir, withIntermediateDirectories: true)
        
        // Ensure log directory exists
        ensureLogDirectory()
        
        // Determine working directory (parent of dist folder or script folder)
        let scriptURL = URL(fileURLWithPath: scriptPath)
        let workingDir: String
        if scriptPath.contains("/dist/") {
            workingDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent().path
        } else {
            workingDir = scriptURL.deletingLastPathComponent().path
        }
        
        // Build plist content
        let plistContent = buildPlist(
            nodePath: nodePath,
            scriptPath: scriptPath,
            workingDir: workingDir
        )
        
        do {
            // Write plist
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
            
            // Load the service
            let loadProcess = Process()
            loadProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            loadProcess.arguments = ["bootstrap", "gui/\(getuid())", plistPath]
            loadProcess.standardOutput = FileHandle.nullDevice
            loadProcess.standardError = FileHandle.nullDevice
            
            try loadProcess.run()
            loadProcess.waitUntilExit()
            
            if loadProcess.terminationStatus == 0 {
                launchdInstalled = true
                sendNotification(title: "Service Installed", body: "Gateway launchd service is now installed and running")
                
                // Kickstart to ensure it's running
                let kickProcess = Process()
                kickProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                kickProcess.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.launchdLabel)"]
                kickProcess.standardOutput = FileHandle.nullDevice
                kickProcess.standardError = FileHandle.nullDevice
                try? kickProcess.run()
                kickProcess.waitUntilExit()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.refresh()
                }
            } else {
                sendNotification(title: "Installation Failed", body: "Could not load launchd service")
            }
        } catch {
            sendNotification(title: "Installation Failed", body: error.localizedDescription)
        }
    }
    
    func uninstallLaunchdService() {
        // Stop and unload the service
        let bootoutProcess = Process()
        bootoutProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootoutProcess.arguments = ["bootout", "gui/\(getuid())/\(Self.launchdLabel)"]
        bootoutProcess.standardOutput = FileHandle.nullDevice
        bootoutProcess.standardError = FileHandle.nullDevice
        
        do {
            try bootoutProcess.run()
            bootoutProcess.waitUntilExit()
        } catch {
            // Continue even if bootout fails
        }
        
        // Remove the plist file
        try? FileManager.default.removeItem(atPath: plistPath)
        
        launchdInstalled = false
        sendNotification(title: "Service Uninstalled", body: "Gateway launchd service has been removed")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
    }
    
    private func buildPlist(nodePath: String, scriptPath: String, workingDir: String) -> String {
        // Determine if we're using a global clawdbot binary or node + script
        let isGlobalBinary = !scriptPath.hasSuffix(".js")
        
        let programArgs: String
        if isGlobalBinary {
            programArgs = """
                  <string>\(escapeXML(scriptPath))</string>
                  <string>gateway</string>
                  <string>--port</string>
                  <string>\(Self.gatewayPort)</string>
                  <string>--force</string>
            """
        } else {
            programArgs = """
                  <string>\(escapeXML(nodePath))</string>
                  <string>\(escapeXML(scriptPath))</string>
                  <string>gateway</string>
                  <string>--port</string>
                  <string>\(Self.gatewayPort)</string>
                  <string>--force</string>
            """
        }
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
          <dict>
            <key>Label</key>
            <string>\(Self.launchdLabel)</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProgramArguments</key>
            <array>
        \(programArgs)
            </array>
            <key>WorkingDirectory</key>
            <string>\(escapeXML(workingDir))</string>
            <key>StandardOutPath</key>
            <string>\(escapeXML(Self.logPath))</string>
            <key>StandardErrorPath</key>
            <string>\(escapeXML(Self.logPath))</string>
          </dict>
        </plist>
        """
    }
    
    private func escapeXML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    
    // MARK: - Directory Setup
    
    private func ensureLogDirectory() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: Self.logDirectory) {
            try? fileManager.createDirectory(atPath: Self.logDirectory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Notifications
    
    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    private func sendNotification(title: String, body: String) {
        guard notificationsEnabled else { return }
        guard Bundle.main.bundleIdentifier != nil else {
            print("\u{1F514} \(title): \(body)")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    private func checkForStatusChange() {
        if previousGatewayStatus == .running && gatewayStatus == .stopped {
            sendNotification(title: "Gateway Stopped", body: "Clawdbot gateway has stopped running.")
        } else if previousGatewayStatus == .stopped && gatewayStatus == .running {
            sendNotification(title: "Gateway Started", body: "Clawdbot gateway is now running.")
        }
        
        previousGatewayStatus = gatewayStatus
    }
    
    deinit {
        pollTimer?.invalidate()
        fastPollTimer?.invalidate()
        if let observer = processTerminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func startFastPolling(expecting status: GatewayStatus) {
        expectedStatus = status
        fastPollTimer?.invalidate()
        fastPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
            if self?.gatewayStatus == self?.expectedStatus {
                self?.stopFastPolling()
            }
        }
        // Auto-stop after 30 seconds max
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.stopFastPolling()
        }
    }

    private func stopFastPolling() {
        fastPollTimer?.invalidate()
        fastPollTimer = nil
        expectedStatus = nil
    }

    func refresh() {
        isRefreshing = true
        
        checkPortStatus()
        checkLaunchdStatus()
        checkForStatusChange()
        
        if gatewayStatus == .running {
            fetchGatewayDetails()
        } else {
            discordConnected = false
            activeSessionsCount = 0
        }
        
        isRefreshing = false
    }
    
    // MARK: - Port Status Check
    
    private func checkPortStatus() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", ":\(Self.gatewayPort)", "-t"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if process.terminationStatus == 0, !output.isEmpty {
                let pids = output.components(separatedBy: .newlines)
                if let firstPid = pids.first, let pid = Int(firstPid) {
                    gatewayPID = pid
                    gatewayStatus = .running
                } else {
                    gatewayPID = nil
                    gatewayStatus = .stopped
                }
            } else {
                gatewayPID = nil
                gatewayStatus = .stopped
            }
        } catch {
            gatewayStatus = .unknown
            gatewayPID = nil
        }
    }
    
    private func isPortAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", ":\(Self.gatewayPort)", "-t"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            // Port is available if no PIDs are returned
            return output.isEmpty || process.terminationStatus != 0
        } catch {
            return true // Assume available if check fails
        }
    }
    
    private func waitForPortAvailable(timeout: TimeInterval = 10, completion: @escaping (Bool) -> Void) {
        debugLog("waitForPortAvailable starting, timeout: \(timeout)")
        let startTime = Date()
        
        func check() {
            let available = isPortAvailable()
            debugLog("Port check: available=\(available), elapsed=\(Date().timeIntervalSince(startTime))s")
            
            if available {
                debugLog("Port is available, calling completion(true)")
                completion(true)
                return
            }
            
            if Date().timeIntervalSince(startTime) > timeout {
                debugLog("Timeout reached, calling completion(false)")
                completion(false)
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.debugLog("Rechecking port...")
                check()
            }
        }
        
        check()
    }
    
    // MARK: - Gateway Details
    
    private func fetchGatewayDetails() {
        // Read sessions count from file
        let sessionsPath = NSString(string: "~/.clawdbot/agents/main/sessions/sessions.json").expandingTildeInPath
        if let data = FileManager.default.contents(atPath: sessionsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            activeSessionsCount = json.count
        } else {
            activeSessionsCount = 0
        }

        let task = Task {
            do {
                let url = URL(string: "http://127.0.0.1:\(Self.gatewayPort)/")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 2.0
                request.httpMethod = "HEAD"

                let (_, response) = try await URLSession.shared.data(for: request)

                await MainActor.run {
                    if let httpResponse = response as? HTTPURLResponse {
                        self.discordConnected = httpResponse.statusCode == 200
                        self.lastActivity = Date()
                    }
                }
            } catch {
                await MainActor.run {
                    self.discordConnected = false
                }
            }
        }
        _ = task
    }
    
    // MARK: - Gateway Control
    
    func startGateway() {
        guard gatewayStatus != .running else { return }

        startFastPolling(expecting: .running)

        if launchMode == .launchd {
            startViaLaunchd()
        } else {
            startDirectProcess()
        }
    }
    
    private func startViaLaunchd() {
        // If service not installed, install it first
        if !launchdInstalled {
            installLaunchdService()
            return
        }
        
        // Kickstart the service
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.launchdLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refresh()
            }
        } catch {
            sendNotification(title: "Gateway Start Failed", body: error.localizedDescription)
        }
    }
    
    private func startDirectProcess() {
        debugLog("startDirectProcess called")
        debugLog("detectedNodePath: \(detectedNodePath ?? "nil")")
        debugLog("detectedScriptPath: \(detectedScriptPath ?? "nil")")
        
        guard let nodePath = detectedNodePath else {
            debugLog("ERROR: No Node.js path detected")
            sendNotification(title: "Gateway Start Failed", body: "Could not detect Node.js path. Please install Node.js.")
            return
        }
        
        guard let scriptPath = detectedScriptPath else {
            debugLog("ERROR: No clawdbot script path detected")
            sendNotification(title: "Gateway Start Failed", body: "Could not detect clawdbot. Please install clawdbot globally.")
            return
        }
        
        let process = Process()
        var workingDir: URL?
        
        if scriptPath.hasSuffix(".js") {
            process.executableURL = URL(fileURLWithPath: nodePath)
            process.arguments = [scriptPath, "gateway", "--port", "\(Self.gatewayPort)", "--force"]
            let scriptURL = URL(fileURLWithPath: scriptPath)
            workingDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
            process.currentDirectoryURL = workingDir
        } else {
            process.executableURL = URL(fileURLWithPath: scriptPath)
            process.arguments = ["gateway", "--port", "\(Self.gatewayPort)", "--force"]
        }
        
        debugLog("Executable: \(process.executableURL?.path ?? "nil")")
        debugLog("Arguments: \(process.arguments ?? [])")
        debugLog("Working directory: \(workingDir?.path ?? "default")")
        
        ensureLogDirectory()
        let logURL = URL(fileURLWithPath: Self.logPath)
        FileManager.default.createFile(atPath: Self.logPath, contents: nil)
        debugLog("Log path: \(Self.logPath)")
        
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            debugLog("WARNING: Could not open log file for writing")
        }
        
        if let observer = processTerminationObserver {
            NotificationCenter.default.removeObserver(observer)
            processTerminationObserver = nil
        }
        
        processTerminationObserver = NotificationCenter.default.addObserver(
            forName: Process.didTerminateNotification,
            object: process,
            queue: .main
        ) { [weak self] notification in
            if let proc = notification.object as? Process {
                self?.debugLog("Process terminated with status: \(proc.terminationStatus)")
                self?.debugLog("Termination reason: \(proc.terminationReason.rawValue)")
            }
            self?.gatewayProcess = nil
            self?.refresh()
        }
        
        do {
            try process.run()
            gatewayProcess = process
            debugLog("Process started with PID: \(process.processIdentifier)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.refresh()
            }
        } catch {
            debugLog("Failed to start gateway: \(error)")
            sendNotification(title: "Gateway Start Failed", body: "Could not start gateway: \(error.localizedDescription)")
        }
    }
    
    func stopGateway() {
        debugLog("stopGateway called, launchMode: \(launchMode), launchdInstalled: \(launchdInstalled)")

        startFastPolling(expecting: .stopped)

        if launchMode == .launchd && launchdInstalled {
            stopViaLaunchd()
        } else {
            stopDirectProcess()
        }
    }
    
    private func stopViaLaunchd() {
        debugLog("stopViaLaunchd called")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(Self.launchdLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            debugLog("launchctl bootout completed")
        } catch {
            debugLog("launchctl bootout error: \(error)")
        }
        
        killProcessOnPort()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
    }
    
    private func stopDirectProcess() {
        debugLog("stopDirectProcess called")
        debugLog("gatewayProcess is nil: \(gatewayProcess == nil)")
        debugLog("gatewayPID: \(gatewayPID ?? -1)")
        
        let managedProcess = gatewayProcess
        let pidToKill = gatewayPID
        gatewayProcess = nil
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let process = managedProcess {
                self?.debugLog("Process isRunning: \(process.isRunning)")
                if process.isRunning {
                    self?.debugLog("Calling process.terminate()")
                    process.terminate()
                    process.waitUntilExit()
                    self?.debugLog("process.terminate() completed, exit code: \(process.terminationStatus)")
                }
            } else if let pid = pidToKill {
                self?.debugLog("No managed process, killing PID \(pid) directly")
                self?.killPID(pid)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.debugLog("Refreshing after stop")
                self?.refresh()
            }
        }
    }
    
    private func killPID(_ pid: Int) {
        debugLog("killPID: killing PID \(pid)")
        
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/bin/kill")
        killProcess.arguments = ["-TERM", "\(pid)"]
        killProcess.standardOutput = FileHandle.nullDevice
        killProcess.standardError = FileHandle.nullDevice
        
        do {
            try killProcess.run()
            killProcess.waitUntilExit()
            debugLog("SIGTERM sent to PID \(pid)")
        } catch {
            debugLog("SIGTERM failed for PID \(pid): \(error)")
        }
    }
    
    private func killProcessOnPort() {
        guard let pid = gatewayPID else {
            debugLog("killProcessOnPort: no PID to kill")
            return
        }
        killPID(pid)
    }
    
    func restartGateway() {
        debugLog("restartGateway called")

        startFastPolling(expecting: .running)

        if launchMode == .launchd && launchdInstalled {
            restartViaLaunchd()
        } else {
            restartDirectProcess()
        }
    }
    
    private func restartViaLaunchd() {
        debugLog("restartViaLaunchd called")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.launchdLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            debugLog("launchctl kickstart completed")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refresh()
            }
        } catch {
            debugLog("launchctl kickstart error: \(error)")
            sendNotification(title: "Restart Failed", body: error.localizedDescription)
        }
    }
    
    private func restartDirectProcess() {
        debugLog("restartDirectProcess called")
        
        let managedProcess = gatewayProcess
        let pidToKill = gatewayPID
        gatewayProcess = nil
        
        debugLog("Stopping gateway in background...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let process = managedProcess {
                self?.debugLog("Terminating managed process...")
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                    self?.debugLog("Process terminated with code: \(process.terminationStatus)")
                }
            } else if let pid = pidToKill {
                self?.debugLog("Killing PID \(pid)...")
                self?.killPID(pid)
                Thread.sleep(forTimeInterval: 0.5)
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.debugLog("Waiting for port to become available...")
                self?.waitForPortAvailable(timeout: 10) { [weak self] available in
                    self?.debugLog("Port available: \(available)")
                    if available {
                        self?.debugLog("Starting gateway...")
                        self?.startDirectProcess()
                    } else {
                        self?.debugLog("Port did not become available in time")
                        self?.sendNotification(title: "Restart Failed", body: "Port did not become available in time")
                    }
                }
            }
        }
    }
    
    // MARK: - Utilities
    
    func openLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Self.logPath))
    }
    
    func openWebUI() {
        if let url = URL(string: "http://127.0.0.1:\(Self.gatewayPort)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Update & Rebuild

    func getClawdbotDirectory() -> String? {
        // Use configured path first
        if !clawdbotPath.isEmpty {
            return NSString(string: clawdbotPath).expandingTildeInPath
        }

        // Otherwise derive from detected script path
        guard let scriptPath = detectedScriptPath else { return nil }

        // Script path is typically .../dist/index.js, we want parent of dist
        let scriptURL = URL(fileURLWithPath: scriptPath)
        if scriptPath.contains("/dist/") {
            return scriptURL.deletingLastPathComponent().deletingLastPathComponent().path
        }

        return scriptURL.deletingLastPathComponent().path
    }

    private func detectPnpmPath() -> String? {
        // Try 'which pnpm' first
        if let path = runCommand("/usr/bin/which", arguments: ["pnpm"]) {
            return path
        }

        // Common pnpm locations
        let homeDir = NSString(string: "~").expandingTildeInPath
        let commonPaths = [
            "/usr/local/bin/pnpm",
            "/opt/homebrew/bin/pnpm",
            "\(homeDir)/.local/share/pnpm/pnpm",
            "\(homeDir)/.pnpm/pnpm"
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func runCommandSync(_ command: String, arguments: [String], workingDir: String? = nil) -> (output: String?, success: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        if let dir = workingDir {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Set PATH to include common locations
        var env = ProcessInfo.processInfo.environment
        let homeDir = NSString(string: "~").expandingTildeInPath
        let additionalPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(homeDir)/.local/share/pnpm",
            NSString(string: "~/.nvm/versions/node").expandingTildeInPath,
            "/usr/bin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = additionalPaths.joined(separator: ":") + ":" + currentPath
        process.environment = env

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            return (output, process.terminationStatus == 0)
        } catch {
            return (nil, false)
        }
    }

    func updateAndRebuild() {
        guard !isUpdating else { return }
        guard let workingDir = getClawdbotDirectory() else {
            sendNotification(title: "Update Failed", body: "Could not determine clawdbot directory")
            return
        }

        isUpdating = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Step 1: Stop the gateway
            DispatchQueue.main.async {
                self.updateStatus = "Stopping gateway..."
            }
            self.debugLog("Update: Stopping gateway")

            // Stop synchronously
            if self.gatewayStatus == .running {
                if self.launchMode == .launchd && self.launchdInstalled {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    process.arguments = ["bootout", "gui/\(getuid())/\(Self.launchdLabel)"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try? process.run()
                    process.waitUntilExit()
                } else if let pid = self.gatewayPID {
                    self.killPID(pid)
                }

                // Wait for port to be available
                var attempts = 0
                while !self.isPortAvailable() && attempts < 20 {
                    Thread.sleep(forTimeInterval: 0.5)
                    attempts += 1
                }
            }

            // Step 2: Git operations
            DispatchQueue.main.async {
                self.updateStatus = "Pulling latest changes..."
            }
            self.debugLog("Update: Git operations in \(workingDir)")

            let (branchOutput, _) = self.runCommandSync("/usr/bin/git", arguments: ["branch", "--show-current"], workingDir: workingDir)
            let branch = branchOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            self.debugLog("Update: Current branch is '\(branch)'")

            if branch == "main" {
                let (pullOutput, pullSuccess) = self.runCommandSync("/usr/bin/git", arguments: ["pull"], workingDir: workingDir)
                self.debugLog("Update: git pull result: \(pullSuccess), output: \(pullOutput ?? "nil")")
            } else {
                let (fetchOutput, fetchSuccess) = self.runCommandSync("/usr/bin/git", arguments: ["fetch", "origin", "main"], workingDir: workingDir)
                self.debugLog("Update: git fetch result: \(fetchSuccess), output: \(fetchOutput ?? "nil")")
            }

            // Step 3: Build
            DispatchQueue.main.async {
                self.updateStatus = "Building..."
            }
            self.debugLog("Update: Running pnpm build")

            if let pnpmPath = self.detectPnpmPath() {
                let (buildOutput, buildSuccess) = self.runCommandSync(pnpmPath, arguments: ["run", "build"], workingDir: workingDir)
                self.debugLog("Update: pnpm build result: \(buildSuccess), output: \(buildOutput ?? "nil")")

                if !buildSuccess {
                    DispatchQueue.main.async {
                        self.updateStatus = ""
                        self.isUpdating = false
                        self.sendNotification(title: "Update Failed", body: "Build failed. Check logs for details.")
                    }
                    return
                }
            } else {
                DispatchQueue.main.async {
                    self.updateStatus = ""
                    self.isUpdating = false
                    self.sendNotification(title: "Update Failed", body: "pnpm not found")
                }
                return
            }

            // Step 4: Start the gateway
            DispatchQueue.main.async {
                self.updateStatus = "Starting gateway..."
                self.debugLog("Update: Starting gateway")
                self.startGateway()

                // Delay before clearing status
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.updateStatus = ""
                    self.isUpdating = false
                    self.sendNotification(title: "Update Complete", body: "Clawdbot has been updated and restarted")
                }
            }
        }
    }
}
