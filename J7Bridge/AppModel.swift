import Foundation
import Combine
import Network
import Darwin

@MainActor
final class AppModel: ObservableObject {
    @Published var bleStatus = "Disconnected"
    @Published var deviceName = "-"
    @Published var callStatus = "IDLE"
    @Published var number = ""
    @Published var callerName = ""
    @Published var voiceStatus = "CLOSED"
    @Published var wifiStatus = "Waiting for BLE peer discovery"
    @Published var j7Host: String {
        didSet {
            UserDefaults.standard.set(j7Host, forKey: "j7bridge.j7Host")
            wifi.setJ7Host(j7Host)
        }
    }
    @Published var dialString = ""
    @Published var logs: [String] = []
    @Published var battery = "-"
    @Published var firmware = "-"
    @Published var imei = "-"
    @Published var isMuted = false
    @Published private(set) var callStartedAt: Date?

    @Published var autoConnect: Bool {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: "j7bridge.autoConnect")
            ble.autoReconnect = autoConnect
        }
    }
    @Published var resolveCallerNames: Bool {
        didSet { UserDefaults.standard.set(resolveCallerNames, forKey: "j7bridge.resolveCallerNames") }
    }
    @Published var missedCallNotifications: Bool {
        didSet { UserDefaults.standard.set(missedCallNotifications, forKey: "j7bridge.missedCallNotifications") }
    }
    @Published var simSlot: Int {
        didSet { UserDefaults.standard.set(simSlot, forKey: "j7bridge.simSlot") }
    }

    let ble: BLEManager
    let callKit: CallKitManager
    let contacts: ContactsManager
    let history: CallHistoryStore
    let notifications = NotificationManager()
    let wifi: WiFiTransport
    let wifiVoice: WiFiVoiceEngine

    private var currentDirection: CallDirection?
    private var currentContactName: String?
    private var callAudioActive = false
    private var remoteVoiceOpen = false
    private var gsmCallReady = false
    private var voiceOpenCommandSent = false
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "com.callshare.hybrid.network-monitor")
    private var lastAnnouncedIPv4: String?
    private var didStart = false

    init() {
        autoConnect = UserDefaults.standard.object(forKey: "j7bridge.autoConnect") as? Bool ?? true
        resolveCallerNames = UserDefaults.standard.object(forKey: "j7bridge.resolveCallerNames") as? Bool ?? true
        missedCallNotifications = UserDefaults.standard.object(forKey: "j7bridge.missedCallNotifications") as? Bool ?? true
        simSlot = UserDefaults.standard.object(forKey: "j7bridge.simSlot") as? Int ?? 0
        let rememberedHost = UserDefaults.standard.string(forKey: "j7bridge.j7Host") ?? "192.168.93.232"
        j7Host = rememberedHost

        ble = BLEManager()
        callKit = CallKitManager()
        wifi = WiFiTransport(j7Host: rememberedHost, port: 50005)
        wifiVoice = WiFiVoiceEngine(transport: wifi)
        contacts = ContactsManager()
        history = CallHistoryStore()

        ble.autoReconnect = autoConnect

        ble.onLog = { [weak self] line in self?.log(line) }
        ble.onStatus = { [weak self] status in
            guard let self else { return }
            self.bleStatus = status
            self.log("[BLE] STATUS \(status)")
            if status == "Disconnected" { self.lastAnnouncedIPv4 = nil }
        }
        ble.onDevice = { [weak self] name in self?.deviceName = name ?? "IKOS K7 / CALLSHARE J7" }
        ble.onControlPayload = { [weak self] payload in self?.handleControl(payload) }
        // BLE audio notifications are intentionally ignored in R1. Wi-Fi R2 is the sole audio plane.
        ble.onAudioPayload = { [weak self] payload in
            guard let self, !payload.isEmpty else { return }
            self.log("[BLE] Legacy audio payload ignored in HYBRID R1; Wi-Fi R2 owns voice")
        }
        ble.onReady = { [weak self] in
            guard let self else { return }
            self.log("[HYBRID] GATT ready; announcing current iPhone Wi-Fi IPv4")
            self.announceCurrentIPv4ToJ7(force: true)
        }

        wifi.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.wifiStatus = status
                self?.log(status)
            }
        }
        wifi.onJ7HostDiscovered = { [weak self] host in
            Task { @MainActor [weak self] in
                guard let self, Self.isIPv4(host), self.j7Host != host else { return }
                self.log("[WIFI R2] Peer IP confirmed by valid audio packet: \(host)")
                self.j7Host = host
            }
        }
        // The UDP control port is deliberately not the call-control channel in HYBRID R1.
        wifi.onControl = { [weak self] control, payload in
            Task { @MainActor [weak self] in
                self?.log("[WIFI R2] ignored legacy UDP control \(control) len=\(payload.count); BLE owns call control")
            }
        }
        wifi.onAudioPCM = { [weak self] pcm, rate, channels, frames in
            self?.wifiVoice.receivePCM(pcm, sampleRate: rate, channels: channels, frames: frames)
        }
        wifiVoice.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.voiceStatus = status
                self?.log(status)
            }
        }

        callKit.onLog = { [weak self] line in self?.log(line) }
        callKit.onStart = { [weak self] number in self?.beginOutgoing(number) }
        callKit.onAnswer = { [weak self] in
            guard let self else { return }
            self.ble.sendAnswer()
            self.log("[CALLKIT] ANSWER -> BLE GATT opcode 0x05; waiting for J7 answer event")
        }
        callKit.onEnd = { [weak self] in self?.endFromCallKit() }
        callKit.onMute = { [weak self] muted in
            self?.isMuted = muted
            self?.wifiVoice.setMuted(muted)
        }
        callKit.onDTMF = { [weak self] digits in self?.sendDTMFString(digits) }
        callKit.onPrepareAudio = { [weak self] in self?.wifiVoice.prepareForCallAudio() }
        callKit.onAudioActivated = { [weak self] in
            guard let self else { return }
            self.callAudioActive = true
            self.log("[CALLKIT] AUDIO ACTIVATED")
            self.requestVoiceOpenIfReady()
            self.maybeStartVoice()
        }
        callKit.onAudioDeactivated = { [weak self] in
            guard let self else { return }
            self.callAudioActive = false
            if self.voiceOpenCommandSent || self.remoteVoiceOpen { self.ble.sendVoiceClose() }
            self.voiceOpenCommandSent = false
            self.remoteVoiceOpen = false
            self.gsmCallReady = false
            self.wifi.setAudioReceiveEnabled(false)
            self.wifiVoice.stop()
            self.log("[CALLKIT] AUDIO DEACTIVATED; BLE voice gate closed")
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        wifi.start()
        ble.startScan()
        startNetworkMonitor()
        notifications.requestPermission()
        if contacts.authorization == .authorized { contacts.load() }
        log("[HYBRID R1] Started: BLE GATT control + Wi-Fi R2 PCM audio")
    }

    func answerTest() { ble.sendAnswer() }

    func makeCall() {
        let cleaned = dialString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        beginCall(number: cleaned, direction: .outgoing, name: contacts.resolveName(for: cleaned))
        callKit.startOutgoing(number: cleaned)
    }

    func endCall() { callKit.endCurrentCall() }

    func tapDialpad(_ digit: String) {
        if callStatus == "ACTIVE" { sendDTMFString(digit) }
        else { dialString.append(digit) }
    }

    func backspaceDialpad() {
        guard callStatus != "ACTIVE", !dialString.isEmpty else { return }
        dialString.removeLast()
    }

    func requestContacts() { contacts.requestAccessAndLoad() }
    func clearHistory() { history.clear() }

    func requestDeviceInfo() {
        ble.requestDeviceCheck()
        ble.requestBattery()
        ble.requestFirmware()
        ble.requestIMEI()
    }

    func sendDTMFString(_ digits: String) {
        for character in digits {
            switch character {
            case "0"..."9", "*", "#":
                ble.sendDTMF(UInt8(String(character).utf8.first!))
            default: break
            }
        }
    }

    func handleControl(_ payload: Data) {
        guard let op = payload.first else { return }
        switch op {
        case K7Protocol.evtReceiveCall:
            handleIncoming(payload)
        case K7Protocol.evtAnswer:
            callStatus = "ACTIVE"
            log("[CALL] BLE ANSWER EVENT / ACTIVE; waiting for physical GSM OFFHOOK before opening audio")
            if currentDirection == .outgoing { callKit.reportOutgoingConnected() }
            callKit.fulfillAnswerIfNeeded()
            beginCallIfNeeded(direction: currentDirection ?? .incoming)
            requestVoiceOpenIfReady()
        case K7Protocol.evtReceiveCallEnd:
            handleRemoteEnd()
        case K7Protocol.evtVoiceOpen:
            remoteVoiceOpen = true
            log("[BLE] VOICE OPEN EVENT")
            maybeStartVoice()
        case K7Protocol.evtVoiceClose:
            remoteVoiceOpen = false
            voiceOpenCommandSent = false
            gsmCallReady = false
            log("[BLE] VOICE CLOSE EVENT")
            wifi.setAudioReceiveEnabled(false)
            wifiVoice.stop()
        case K7Protocol.evtMakeCall:
            callStatus = "DIALING"
            log("[CALL] BLE MAKE_CALL accepted \(K7Protocol.hex(payload)); waiting for physical GSM OFFHOOK")
            callKit.reportOutgoingConnecting()
        case K7Protocol.evtReadBattery:
            if payload.count >= 5 { battery = String(payload[4]) }
            log("[K7] BATTERY \(battery)")
        case K7Protocol.evtFirmwareVersion:
            firmware = K7Protocol.decodeASCIIBlock(payload, offset: 1)
            log("[K7] FIRMWARE \(firmware)")
        case K7Protocol.evtIMEIInfo:
            imei = K7Protocol.decodeASCIIBlock(payload, offset: 3)
            log("[K7] IMEI \(imei)")
        case K7Protocol.evtCallshareGSMOffhook:
            gsmCallReady = true
            log("[HYBRID] J7 GSM OFFHOOK event received; CallKit=\(callAudioActive ? "active" : "not active")")
            requestVoiceOpenIfReady()
        case K7Protocol.evtCallshareJ7IPv4:
            handleJ7IPv4(payload)
        case K7Protocol.evtCallshareSMS:
            handleSMS(payload)
        case K7Protocol.cmdCallsharePeerIPv4:
            log("[HYBRID] Unexpected iPhone-peer-IP opcode from J7")
        default:
            log("[BLE] CONTROL \(String(format: "%02X", op)) \(K7Protocol.hex(payload))")
        }
    }

    private func handleIncoming(_ payload: Data) {
        guard callStatus == "IDLE" || callStatus == "ENDED" else {
            log("[CALL] duplicate incoming ignored")
            return
        }
        let incomingNumber = K7Protocol.decodeIncomingNumber(payload)
        let name = resolveCallerNames ? contacts.resolveName(for: incomingNumber) : nil
        number = incomingNumber
        callerName = name ?? ""
        currentContactName = name
        currentDirection = .incoming
        callStartedAt = Date()
        callAudioActive = false
        remoteVoiceOpen = false
        gsmCallReady = false
        voiceOpenCommandSent = false
        callStatus = "RINGING"
        log("[CALL] INCOMING over BLE \(name.map { "\($0) / " } ?? "")\(incomingNumber)")
        // Critical: report to CallKit immediately; never wait for UDP/IP/audio readiness.
        callKit.reportIncoming(number: incomingNumber, callerName: name)
        announceCurrentIPv4ToJ7(force: true)
    }

    private func beginOutgoing(_ outgoingNumber: String) {
        number = outgoingNumber
        callerName = contacts.resolveName(for: outgoingNumber) ?? ""
        currentContactName = callerName.isEmpty ? nil : callerName
        dialString = ""
        beginCall(number: outgoingNumber, direction: .outgoing, name: currentContactName)
        ble.sendMakeCall(number: outgoingNumber, simId: UInt8(simSlot))
        callStatus = "DIALING"
        log("[CALL] OUTGOING requested over BLE GATT; SIM slot=\(simSlot)")
    }

    private func beginCall(number: String, direction: CallDirection, name: String?) {
        self.number = number
        currentDirection = direction
        currentContactName = name
        callStartedAt = Date()
        callAudioActive = false
        remoteVoiceOpen = false
        gsmCallReady = false
        voiceOpenCommandSent = false
        if direction == .outgoing { callStatus = "DIALING" }
    }

    private func beginCallIfNeeded(direction: CallDirection) {
        if callStartedAt == nil { callStartedAt = Date() }
        currentDirection = direction
        if direction == .incoming && callerName.isEmpty { callerName = currentContactName ?? "" }
    }

    private func requestVoiceOpenIfReady() {
        let outgoingMayOpen = currentDirection == .outgoing && callStatus == "DIALING"
        let incomingMayOpen = currentDirection == .incoming && callStatus == "ACTIVE"
        guard callAudioActive, gsmCallReady, outgoingMayOpen || incomingMayOpen else { return }
        guard !voiceOpenCommandSent else { return }
        voiceOpenCommandSent = true
        ble.sendVoiceOpen()
        log("[HYBRID] BLE VOICE_OPEN sent: CallKit audio active + GSM call accepted/started")
    }

    private func maybeStartVoice() {
        let outgoingMediaMayStart = (currentDirection == .outgoing && callStatus == "DIALING")
        guard callStatus == "ACTIVE" || outgoingMediaMayStart else {
            log("[VOICE] WAIT call state=\(callStatus)")
            return
        }
        guard remoteVoiceOpen else {
            log("[VOICE] WAIT J7 VOICE_OPEN over BLE")
            return
        }
        guard callAudioActive else {
            log("[VOICE] WAIT CallKit audio activation")
            return
        }
        log("[HYBRID] Voice gate passed: CallKit active + GSM active + BLE VOICE_OPEN; starting Wi-Fi R3 audio")
        if wifiVoice.start() {
            wifi.setAudioReceiveEnabled(true)
        } else {
            wifi.setAudioReceiveEnabled(false)
            log("[VOICE] Wi-Fi voice engine start failed; inspect audio logs")
        }
    }

    private func endFromCallKit() {
        ble.sendVoiceClose()
        ble.sendHangup()
        callAudioActive = false
        wifi.setAudioReceiveEnabled(false)
        wifiVoice.stop()
        voiceOpenCommandSent = false
        remoteVoiceOpen = false
        gsmCallReady = false
        finishHistory(direction: currentDirection ?? .outgoing)
        callStatus = "ENDED"
        callKit.clearCurrentCall()
    }

    private func handleRemoteEnd() {
        let wasRinging = callStatus == "RINGING"
        let direction = currentDirection ?? .incoming
        ble.sendVoiceClose()
        callAudioActive = false
        wifi.setAudioReceiveEnabled(false)
        wifiVoice.stop()
        voiceOpenCommandSent = false
        remoteVoiceOpen = false
        gsmCallReady = false
        finishHistory(direction: wasRinging ? .missed : direction)
        callStatus = "ENDED"
        log("[CALL] END EVENT over BLE")
        callKit.reportRemoteEnd()
    }

    private func finishHistory(direction: CallDirection) {
        let duration = callStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        if !number.isEmpty {
            history.add(number: number, name: currentContactName, direction: direction, duration: duration)
            if direction == .missed, missedCallNotifications {
                notifications.sendMissedCall(number: number, name: currentContactName)
            }
        }
        callStartedAt = nil
        currentDirection = nil
        currentContactName = nil
        callAudioActive = false
    }

    private func handleJ7IPv4(_ payload: Data) {
        guard payload.count > 1,
              let host = String(data: payload.dropFirst(), encoding: .utf8),
              Self.isIPv4(host) else {
            log("[HYBRID] Ignored invalid J7 IPv4 event payload=\(K7Protocol.hex(payload))")
            return
        }
        if j7Host != host {
            log("[HYBRID] J7 IP updated through BLE: \(j7Host) -> \(host)")
            j7Host = host
        } else {
            log("[HYBRID] J7 IP confirmed through BLE: \(host)")
        }
        announceCurrentIPv4ToJ7(force: true)
    }

    private func handleSMS(_ payload: Data) {
        guard payload.count > 1 else { return }
        let jsonData = Data(payload.dropFirst())
        guard let parsed = try? JSONSerialization.jsonObject(with: jsonData),
              let object = parsed as? [String: String] else {
            log("[SMS] Invalid CALLSHARE SMS event JSON")
            return
        }
        let sender = object["from"] ?? "Unknown sender"
        let body = object["body"] ?? ""
        notifications.sendSMS(sender: sender, body: body)
        log("[SMS] Notification received from \(sender), body length=\(body.count)")
    }

    private func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log("[NETWORK] Wi-Fi path status=\(path.status == .satisfied ? "satisfied" : "unavailable")")
                if path.status == .satisfied { self.announceCurrentIPv4ToJ7(force: false) }
            }
        }
        networkMonitor = monitor
        monitor.start(queue: networkQueue)
    }

    private func announceCurrentIPv4ToJ7(force: Bool) {
        guard ble.isReady else { return }
        guard let address = Self.currentWiFiIPv4() else {
            log("[NETWORK] No en0 Wi-Fi IPv4 currently available")
            return
        }
        guard force || lastAnnouncedIPv4 != address else { return }
        lastAnnouncedIPv4 = address
        ble.sendCallsharePeerIPv4(address)
        log("[HYBRID] Sent iPhone peer IP over BLE: \(address)")
    }

    private static func currentWiFiIPv4() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let current = cursor {
            let item = current.pointee
            if String(cString: item.ifa_name) == "en0",
               let address = item.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let result = String(cString: buffer)
                    if !result.hasPrefix("127.") { return result }
                }
            }
            cursor = item.ifa_next
        }
        return nil
    }

    private static func isIPv4(_ host: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }

    func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logs.append("[\(stamp)] \(line)")
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }
}
