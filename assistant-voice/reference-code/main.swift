// AssistantVoice — macOS menu bar client for a personal AI voice server.
// Sanitized: hostnames replaced with example.com placeholders, home LAN
// replaced with the standard 192.168.1.0/24 example. Edit the `servers`
// list and `allowedSubnets` list for your setup before building.

import Cocoa
import AVFoundation
import Network

// MARK: - Configuration

let appVersion = "1.0.0"

struct VoiceServer {
    let name: String
    let host: String
    let url: String
}

let servers: [VoiceServer] = [
    VoiceServer(name: "Main", host: "voice.example.com", url: "wss://voice.example.com:8889/stream"),
    VoiceServer(name: "Demo", host: "demo.example.com", url: "wss://demo.example.com:8889/stream"),
]

let serverDefaultsKey = "selectedServerIndex"

let pingInterval: TimeInterval = 15.0
let pongTimeout: TimeInterval = 10.0
let baseReconnectDelay: TimeInterval = 3.0
let maxReconnectDelay: TimeInterval = 60.0

// Reconnect only when on these networks. Edit this list to match your
// home LAN range and any VPN ranges (e.g. Tailscale, WireGuard, etc.).
let allowedSubnets: [(network: UInt32, mask: UInt32)] = [
    cidr("192.168.1.0/24"),   // Example home LAN
    cidr("100.64.0.0/10"),    // Tailscale CGNAT range
]

// MARK: - Network Utilities

func cidr(_ notation: String) -> (network: UInt32, mask: UInt32) {
    let parts = notation.split(separator: "/")
    let octets = parts[0].split(separator: ".").map { UInt32($0)! }
    let bits = UInt32(parts[1])!
    let ip = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
    let mask: UInt32 = bits == 0 ? 0 : ~((1 << (32 - bits)) - 1)
    return (ip & mask, mask)
}

func checkNetwork() -> (allowed: Bool, detail: String) {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
        return (false, "No network")
    }
    defer { freeifaddrs(ifaddr) }

    let tailscaleNet = cidr("100.64.0.0/10").network

    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: ptr.pointee.ifa_name)
        guard name != "lo0" else { continue }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let ip = String(cString: host)

        let octets = ip.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4 else { continue }
        let ipVal = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]

        for subnet in allowedSubnets {
            if (ipVal & subnet.mask) == subnet.network {
                if subnet.network == tailscaleNet {
                    return (true, "Tailscale (\(ip))")
                }
                return (true, "\(name) (\(ip))")
            }
        }
    }
    return (false, "Foreign network")
}

// MARK: - Voice Client App

class VoiceClientApp: NSObject, NSApplicationDelegate, URLSessionWebSocketDelegate {

    // Menu bar
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var statusMenuItem: NSMenuItem!
    private var networkMenuItem: NSMenuItem!

    // WebSocket
    private var session: URLSession!
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var shouldReconnect = true

    // Ping/pong heartbeat
    private var pingTimer: Timer?
    private var pongPending = false

    // Reconnection
    private var currentDelay: TimeInterval = baseReconnectDelay
    private var reconnectTimer: Timer?
    private var networkAllowed = false

    // Network monitoring
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "network-monitor")

    // Audio
    private var audioPlayer: AVAudioPlayer?
    private var audioDelegate: AudioDelegate?
    private var audioQueue: [Data] = []
    private var isPlaying = false

    // Mute
    private var isMuted = false
    private var muteMenuItem: NSMenuItem!
    private var mutedSpeakingTimer: Timer?

    // Icons (SF Symbols)
    private let iconDisconnected = "bubble.left"
    private let iconConnected = "bubble.left.fill"
    private let iconPlaying = "ellipsis.bubble.fill"

    // Server selection
    private var selectedServerIndex: Int = 0
    private var serverMenuItems: [NSMenuItem] = []

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let saved = UserDefaults.standard.integer(forKey: serverDefaultsKey)
        selectedServerIndex = saved >= 0 && saved < servers.count ? saved : 0

        setupMenuBar()
        setupWebSocket()
        startNetworkMonitor()

        let (allowed, detail) = checkNetwork()
        networkAllowed = allowed
        updateNetworkStatus(detail)

        if allowed {
            connect()
        } else {
            updateStatus("Waiting for home network")
            print("Not on allowed network (\(detail)), waiting...")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shouldReconnect = false
        stopPingTimer()
        reconnectTimer?.invalidate()
        pathMonitor?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            updateIcon(iconDisconnected)
            button.toolTip = "Voice Client"
        }

        menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        networkMenuItem = NSMenuItem(title: "Network: checking...", action: nil, keyEquivalent: "")
        networkMenuItem.isEnabled = false
        menu.addItem(networkMenuItem)

        menu.addItem(NSMenuItem.separator())

        for (index, server) in servers.enumerated() {
            let item = NSMenuItem(title: server.name, action: #selector(serverClicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selectedServerIndex ? .on : .off
            serverMenuItems.append(item)
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(reconnectClicked), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        muteMenuItem = NSMenuItem(title: "Mute", action: #selector(muteClicked), keyEquivalent: "m")
        muteMenuItem.target = self
        muteMenuItem.state = isMuted ? .on : .off
        menu.addItem(muteMenuItem)

        menu.addItem(NSMenuItem.separator())

        let versionItem = NSMenuItem(title: "v\(appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateIcon(_ symbolName: String) {
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }
                if self.isMuted {
                    let image = self.imageWithSlash(baseImage)
                    image.isTemplate = true
                    button.image = image
                } else {
                    baseImage.isTemplate = true
                    button.image = baseImage
                }
            }
        }
    }

    private func imageWithSlash(_ base: NSImage) -> NSImage {
        let size = base.size
        let result = NSImage(size: size)
        result.lockFocus()

        // Draw the base icon
        base.draw(in: NSRect(origin: .zero, size: size))

        // Erase a diagonal band through the icon (alpha subtraction).
        // This punches a transparent stripe visible in any menu bar theme.
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(2.0)
        ctx.move(to: CGPoint(x: size.width * 0.1, y: size.height * 0.9))
        ctx.addLine(to: CGPoint(x: size.width * 0.9, y: size.height * 0.1))
        ctx.strokePath()

        result.unlockFocus()
        return result
    }

    private func updateStatus(_ status: String) {
        DispatchQueue.main.async {
            self.statusMenuItem.title = status
        }
    }

    private func updateNetworkStatus(_ detail: String) {
        DispatchQueue.main.async {
            self.networkMenuItem.title = "Network: \(detail)"
        }
    }

    @objc private func serverClicked(_ sender: NSMenuItem) {
        let newIndex = sender.tag
        guard newIndex != selectedServerIndex, newIndex >= 0, newIndex < servers.count else { return }

        selectedServerIndex = newIndex
        UserDefaults.standard.set(newIndex, forKey: serverDefaultsKey)

        for item in serverMenuItems {
            item.state = item.tag == newIndex ? .on : .off
        }

        // Reconnect to new server
        currentDelay = baseReconnectDelay
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        disconnect()
        connect()
    }

    @objc private func reconnectClicked() {
        // Manual reconnect bypasses network check
        currentDelay = baseReconnectDelay
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        disconnect()
        connect()
    }

    @objc private func muteClicked() {
        isMuted.toggle()
        muteMenuItem.state = isMuted ? .on : .off
        refreshIcon()
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    private func refreshIcon() {
        if isPlaying {
            updateIcon(iconPlaying)
        } else if isConnected {
            updateIcon(iconConnected)
        } else {
            updateIcon(iconDisconnected)
        }
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleNetworkChange(path)
            }
        }
        pathMonitor?.start(queue: monitorQueue)
    }

    private func handleNetworkChange(_ path: NWPath) {
        let (allowed, detail) = checkNetwork()
        networkAllowed = allowed
        updateNetworkStatus(detail)

        print("Network change: \(detail) (allowed: \(allowed), connected: \(isConnected))")

        if allowed && !isConnected {
            // Back on allowed network, reconnect immediately
            print("Allowed network detected, reconnecting...")
            currentDelay = baseReconnectDelay
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            connect()
        } else if allowed && isConnected {
            // Interface changed (e.g. WiFi to Ethernet), verify connection with ping
            sendPing()
        } else if !allowed {
            // Foreign network, stop reconnection attempts
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            if !isConnected {
                updateStatus("Waiting for home network")
            }
        }
    }

    // MARK: - WebSocket

    private func setupWebSocket() {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    private func connect() {
        let server = servers[selectedServerIndex]
        guard let url = URL(string: server.url) else {
            print("Invalid WebSocket URL: \(server.url)")
            return
        }
        guard !isConnected else { return }
        guard webSocketTask == nil else { return } // Connection attempt already in progress

        print("Connecting to \(server.name) (\(server.host))...")
        updateStatus("Connecting to \(server.name)...")

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()
    }

    private func disconnect() {
        stopPingTimer()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        updateIcon(iconDisconnected)
        updateStatus("Disconnected")
    }

    // MARK: - Ping/Pong Heartbeat

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
        pongPending = false
    }

    private func sendPing() {
        guard isConnected, webSocketTask != nil else { return }

        pongPending = true
        webSocketTask?.sendPing { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("Ping failed: \(error.localizedDescription)")
                self.handleConnectionLost()
            } else {
                self.pongPending = false
            }
        }

        // If no pong within timeout, connection is stale
        DispatchQueue.main.asyncAfter(deadline: .now() + pongTimeout) { [weak self] in
            guard let self = self, self.pongPending, self.isConnected else { return }
            print("Pong timeout, connection stale")
            self.handleConnectionLost()
        }
    }

    private func handleConnectionLost() {
        guard isConnected || webSocketTask != nil else { return }
        print("Connection lost, cleaning up...")
        isConnected = false
        stopPingTimer()
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        updateIcon(iconDisconnected)
        updateStatus("Connection lost")
        scheduleReconnect()
    }

    // MARK: - Reconnection (network-aware, exponential backoff)

    private func scheduleReconnect() {
        guard shouldReconnect else { return }

        let (allowed, _) = checkNetwork()
        if !allowed {
            print("Not on allowed network, suppressing reconnect")
            updateStatus("Waiting for home network")
            return
        }

        print("Reconnecting in \(Int(currentDelay))s...")
        updateStatus("Reconnecting in \(Int(currentDelay))s...")

        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: currentDelay, repeats: false) { [weak self] _ in
            self?.reconnectTimer = nil
            self?.connect()
        }

        // Exponential backoff: 3, 6, 12, 24, 48, 60 (capped)
        currentDelay = min(currentDelay * 2, maxReconnectDelay)
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()

            case .failure(let error):
                print("Receive error: \(error.localizedDescription)")
                self.handleConnectionLost()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            // JSON messages: connection confirmation or notification metadata
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String {
                if type == "connected" {
                    let clients = json["clients"] as? Int ?? 0
                    print("Server confirmed. Clients: \(clients)")
                } else if type == "notification" {
                    let title = json["title"] as? String ?? ""
                    let msg = json["message"] as? String ?? ""
                    print("Notification: \(title) - \(msg)")
                }
            }

        case .data(let data):
            // Raw audio binary from server
            queueAudio(data)

        @unknown default:
            break
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("WebSocket connected")
        isConnected = true
        currentDelay = baseReconnectDelay
        updateIcon(iconConnected)
        updateStatus("Connected to \(servers[selectedServerIndex].name)")
        startPingTimer()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("WebSocket closed: \(closeCode)")
        isConnected = false
        stopPingTimer()
        self.webSocketTask = nil
        updateIcon(iconDisconnected)
        updateStatus("Disconnected")
        scheduleReconnect()
    }

    // MARK: - Audio Playback

    private func queueAudio(_ data: Data) {
        if isMuted {
            // Show muted-speaking icon briefly so user sees activity
            updateIcon(iconPlaying)
            mutedSpeakingTimer?.invalidate()
            mutedSpeakingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self = self, self.isMuted else { return }
                self.refreshIcon()
            }
            return
        }
        audioQueue.append(data)
        playNextAudio()
    }

    private func playNextAudio() {
        guard !isPlaying, !audioQueue.isEmpty else { return }

        let audioData = audioQueue.removeFirst()
        isPlaying = true
        updateIcon(iconPlaying)

        do {
            audioPlayer?.stop()
            audioPlayer = nil

            let player = try AVAudioPlayer(data: audioData)
            player.prepareToPlay()
            audioDelegate = AudioDelegate { [weak self] in
                self?.audioFinished()
            }
            player.delegate = audioDelegate
            audioPlayer = player
            player.play()
        } catch {
            print("Audio error: \(error)")
            audioFinished()
        }
    }

    private func audioFinished() {
        isPlaying = false

        if audioQueue.isEmpty {
            updateIcon(isConnected ? iconConnected : iconDisconnected)
        } else {
            playNextAudio()
        }
    }
}

// MARK: - Audio Delegate Helper

class AudioDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish()
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = VoiceClientApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
