import Foundation
import Combine
import CodeIslandCore

@MainActor
final class RelayConnectionManager: NSObject, ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    static let shared = RelayConnectionManager()

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var isRegistering = false
    @Published private(set) var lastMessage: String = ""

    private weak var appState: AppState?
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var pendingHelloAPIKey: String?
    private var terminalConnectionError: String?
    private var reconnectAttempt = 0
    private var shouldReconnect = false
    private var seenRelayHostIds: Set<String> = []
    private let defaults = UserDefaults.standard
    private lazy var webSocketSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private static let reconnectBackoffSeconds = [5, 15, 45, 120, 300]

    private override init() {
        super.init()
    }

    func attach(appState: AppState) {
        self.appState = appState
    }

    func startup() {
        guard defaults.bool(forKey: SettingsKey.relayAutoConnect) else { return }
        guard !relayServerURL.isEmpty, !relayAPIKey.isEmpty else { return }
        reconnectAttempt = 0
        shouldReconnect = true
        connectInternal()
    }

    func shutdown() {
        disconnect(removeSessions: true)
    }

    var relayServerURL: String {
        defaults.string(forKey: SettingsKey.relayServerURL) ?? SettingsDefaults.relayServerURL
    }

    var relayAPIKey: String {
        defaults.string(forKey: SettingsKey.relayAPIKey) ?? SettingsDefaults.relayAPIKey
    }

    func register(serverURL: String) async {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.registerURL(from: trimmed) else {
            status = .failed("invalid server URL")
            lastMessage = "invalid server URL"
            return
        }

        isRegistering = true
        defer { isRegistering = false }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "client": "CodeIsland",
            "version": AppVersion.current,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                status = .failed("registration failed")
                lastMessage = "registration failed"
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apiKey = json["apiKey"] as? String,
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status = .failed("registration response missing apiKey")
                lastMessage = "registration response missing apiKey"
                return
            }
            defaults.set(trimmed, forKey: SettingsKey.relayServerURL)
            defaults.set(apiKey, forKey: SettingsKey.relayAPIKey)
            lastMessage = "registered"
        } catch {
            status = .failed(error.localizedDescription)
            lastMessage = error.localizedDescription
        }
    }

    func connect() {
        reconnectAttempt = 0
        shouldReconnect = true
        disconnect(removeSessions: true, updateStatus: false)
        connectInternal()
    }

    func disconnect(removeSessions: Bool = true) {
        shouldReconnect = false
        disconnect(removeSessions: removeSessions, updateStatus: true)
    }

    private func disconnect(removeSessions: Bool, updateStatus: Bool) {
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingHelloAPIKey = nil
        terminalConnectionError = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        if removeSessions {
            removeSeenRelaySessions()
        }
        if updateStatus {
            status = .disconnected
            lastMessage = ""
        }
    }

    private func connectInternal() {
        guard webSocketTask == nil else { return }
        guard let url = Self.webSocketURL(from: relayServerURL) else {
            status = .failed("invalid server URL")
            lastMessage = "invalid server URL"
            return
        }
        let apiKey = relayAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            status = .failed("missing API key")
            lastMessage = "missing API key"
            return
        }

        status = .connecting
        lastMessage = url.absoluteString
        pendingHelloAPIKey = apiKey
        terminalConnectionError = nil

        let task = webSocketSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
    }

    private func handleWebSocketDidOpen(taskIdentifier: Int) {
        guard webSocketTask?.taskIdentifier == taskIdentifier,
              let task = webSocketTask,
              let apiKey = pendingHelloAPIKey else {
            return
        }
        pendingHelloAPIKey = nil
        receiveNext(on: task)
        sendHello(apiKey: apiKey)
    }

    private func handleWebSocketCompletion(taskIdentifier: Int, message: String) {
        guard webSocketTask?.taskIdentifier == taskIdentifier else { return }
        if let terminalConnectionError {
            status = .failed(terminalConnectionError)
            lastMessage = terminalConnectionError
            webSocketTask = nil
            pendingHelloAPIKey = nil
            self.terminalConnectionError = nil
            return
        }
        pendingHelloAPIKey = nil
        handleConnectionLoss(message)
    }

    private func sendHello(apiKey: String) {
        let hello: [String: Any] = [
            "type": "hello",
            "role": "viewer",
            "apiKey": apiKey,
            "client": "CodeIsland",
            "protocolVersion": 1,
        ]
        sendJSON(hello) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.handleConnectionLoss(error.localizedDescription)
            }
        }
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            Task { @MainActor in
                guard let self, let task, self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    self.handleWebSocketMessage(message)
                    self.receiveNext(on: task)
                case .failure(let error):
                    self.handleConnectionLoss(error.localizedDescription)
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            data = nil
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        switch type {
        case "hello_ack":
            status = .connected
            reconnectAttempt = 0
            lastMessage = "connected"
        case "event":
            handleRelayEvent(object)
        case "request_resolved":
            handleRelayRequestResolved(object)
        case "error":
            handleServerError(object)
        case "ack":
            break
        default:
            break
        }
    }

    private func handleServerError(_ object: [String: Any]) {
        let code = object["code"] as? String
        let rawMessage = object["message"] as? String
        let message = Self.userFacingServerError(code: code, message: rawMessage)
        terminalConnectionError = message
        shouldReconnect = false
        pendingHelloAPIKey = nil
        status = .failed(message)
        lastMessage = message
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func handleRelayEvent(_ envelope: [String: Any]) {
        guard var payload = envelope["payload"] as? [String: Any] else {
            if let requestId = envelope["requestId"] as? String {
                sendResponse(requestId: requestId, payload: [:])
            }
            return
        }

        let requestId = envelope["requestId"] as? String
        let expectsResponse = Self.boolValue(envelope["expectsResponse"]) ?? (requestId != nil)
        let hostId = Self.firstNonEmptyString(
            envelope["hostId"] as? String,
            payload["_remote_host_id"] as? String
        )
        let hostName = Self.firstNonEmptyString(
            envelope["hostName"] as? String,
            payload["_remote_host_name"] as? String
        )

        if let requestId {
            payload["_relay_request_id"] = requestId
        }
        if let hostId {
            let relayHostId = Self.relayHostId(from: hostId)
            payload["_remote_host_id"] = payload["_remote_host_id"] as? String ?? relayHostId
            seenRelayHostIds.insert(relayHostId)
        }
        if let hostName {
            payload["_remote_host_name"] = payload["_remote_host_name"] as? String ?? hostName
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let event = HookEvent(from: data) else {
            if let requestId {
                sendResponse(requestId: requestId, payload: Self.defaultResponse(for: payload))
            }
            return
        }

        if let rawSource = event.rawJSON["_source"] as? String,
           SessionSnapshot.normalizedSupportedSource(rawSource) == nil {
            if let requestId {
                sendResponse(requestId: requestId, payload: [:])
            }
            return
        }

        if let cwd = event.rawJSON["cwd"] as? String,
           !cwd.isEmpty,
           HookServer.cwdMatchesAnyPattern(cwd, patternsCSV: SettingsManager.shared.excludedHookCwdSubstrings) {
            if let requestId {
                sendResponse(requestId: requestId, payload: [:])
            }
            return
        }

        guard expectsResponse, let requestId else {
            HookServer.forwardEventToWebhook(event)
            appState?.handleEvent(event)
            return
        }

        HookServer.forwardEventToWebhook(event)

        let normalizedEventName = EventNormalizer.normalize(event.eventName)
        if normalizedEventName == "PermissionRequest",
           let toolName = event.toolName,
           SettingsManager.shared.autoApproveTools.contains(toolName) {
            let response = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": ["behavior": "allow"],
                ],
            ]
            sendResponse(requestId: requestId, payload: response)
            return
        }

        if normalizedEventName == "PermissionRequest" {
            guard let appState else {
                sendResponse(requestId: requestId, payload: Self.defaultResponse(for: payload))
                return
            }
            let sessionId = event.sessionId ?? "default"
            if event.toolName == "AskUserQuestion" {
                Task { @MainActor in
                    let timeoutTask = self.scheduleRelayTimeout(sessionId: sessionId)
                    let responseBody = await withCheckedContinuation { continuation in
                        appState.handleAskUserQuestion(event, continuation: continuation)
                    }
                    timeoutTask.cancel()
                    self.sendResponse(requestId: requestId, data: responseBody)
                }
            } else {
                Task { @MainActor in
                    let timeoutTask = self.scheduleRelayTimeout(sessionId: sessionId)
                    let responseBody = await withCheckedContinuation { continuation in
                        appState.handlePermissionRequest(event, continuation: continuation)
                    }
                    timeoutTask.cancel()
                    self.sendResponse(requestId: requestId, data: responseBody)
                }
            }
            return
        }

        if normalizedEventName == "Notification", QuestionPayload.from(event: event) != nil {
            guard let appState else {
                sendResponse(requestId: requestId, payload: Self.defaultResponse(for: payload))
                return
            }
            let sessionId = event.sessionId ?? "default"
            Task { @MainActor in
                let timeoutTask = self.scheduleRelayTimeout(sessionId: sessionId)
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handleQuestion(event, continuation: continuation)
                }
                timeoutTask.cancel()
                self.sendResponse(requestId: requestId, data: responseBody)
            }
            return
        }

        appState?.handleEvent(event)
        sendResponse(requestId: requestId, payload: [:])
    }

    /// Safety net: if a relay PermissionRequest / Question continuation is not
    /// resolved within 5 minutes, drain it via handlePeerDisconnect to prevent
    /// hanging. Mirrors HookServer's `monitorPeerDisconnect` 5-minute timeout.
    private func scheduleRelayTimeout(sessionId: String) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)  // 5 minutes
            guard !Task.isCancelled else { return }
            self?.appState?.handlePeerDisconnect(sessionId: sessionId)
        }
    }

    private func handleRelayRequestResolved(_ envelope: [String: Any]) {
        guard let requestId = envelope["requestId"] as? String else { return }
        appState?.handleRelayRequestResolved(requestId: requestId)
    }

    private func sendResponse(requestId: String, data: Data) {
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        sendResponse(requestId: requestId, payload: payload)
    }

    private func sendResponse(requestId: String, payload: [String: Any]) {
        sendJSON([
            "type": "response",
            "requestId": requestId,
            "payload": payload,
        ])
    }

    private func sendJSON(_ object: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard let task = webSocketTask,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            completion?(nil)
            return
        }
        task.send(.string(text)) { error in
            completion?(error)
        }
    }

    private func handleConnectionLoss(_ message: String) {
        if let terminalConnectionError {
            status = .failed(terminalConnectionError)
            lastMessage = terminalConnectionError
            self.terminalConnectionError = nil
            return
        }
        pendingHelloAPIKey = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        removeSeenRelaySessions()
        status = .failed(message)
        lastMessage = message

        guard shouldReconnect,
              defaults.bool(forKey: SettingsKey.relayAutoConnect) else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let index = min(max(reconnectAttempt - 1, 0), Self.reconnectBackoffSeconds.count - 1)
        let delay = Self.reconnectBackoffSeconds[index]
        lastMessage = "reconnecting in \(delay)s"
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await MainActor.run {
                guard let self, self.shouldReconnect, self.webSocketTask == nil else { return }
                self.reconnectTask = nil
                self.connectInternal()
            }
        }
    }

    private func removeSeenRelaySessions() {
        guard let appState else {
            seenRelayHostIds.removeAll()
            return
        }
        for hostId in seenRelayHostIds {
            appState.removeRemoteSessions(hostId: hostId)
        }
        seenRelayHostIds.removeAll()
    }

    private static func defaultResponse(for payload: [String: Any]) -> [String: Any] {
        let eventName = firstNonEmptyString(
            payload["hook_event_name"] as? String,
            payload["hookEventName"] as? String,
            payload["event_name"] as? String,
            payload["eventName"] as? String
        ) ?? ""
        let normalized = EventNormalizer.normalize(eventName)
        if normalized == "PermissionRequest" {
            return [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": ["behavior": "deny"],
                ],
            ]
        }
        if normalized == "Notification" {
            return ["hookSpecificOutput": ["hookEventName": "Notification"]]
        }
        return [:]
    }

    nonisolated static func relayHostId(from hostId: String) -> String {
        let trimmed = hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("relay:") { return trimmed }
        return "relay:\(trimmed)"
    }

    nonisolated static func webSocketURL(from raw: String) -> URL? {
        normalizedURL(from: raw, path: "/ws", schemeMap: [
            "http": "ws",
            "https": "wss",
            "ws": "ws",
            "wss": "wss",
        ])
    }

    nonisolated static func registerURL(from raw: String) -> URL? {
        normalizedURL(from: raw, path: "/api/register", schemeMap: [
            "http": "http",
            "https": "https",
            "ws": "http",
            "wss": "https",
        ])
    }

    nonisolated static func resourceURL(from raw: String, path: String) -> URL? {
        normalizedURL(from: raw, path: path, schemeMap: [
            "http": "http",
            "https": "https",
            "ws": "http",
            "wss": "https",
        ])
    }

    private nonisolated static func normalizedURL(
        from raw: String,
        path: String,
        schemeMap: [String: String]
    ) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "http://\(text)"
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let mappedScheme = schemeMap[scheme],
              components.host != nil else {
            return nil
        }
        components.scheme = mappedScheme
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private nonisolated static func firstNonEmptyString(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    nonisolated static func userFacingServerError(code: String?, message: String?) -> String {
        switch code {
        case "invalid_api_key":
            return "Invalid API Key"
        case "invalid_hello":
            return "Invalid connection request"
        default:
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed == "unauthorized" { return "Invalid API Key" }
            return trimmed.isEmpty ? "Server error" : trimmed
        }
    }

}

extension RelayConnectionManager: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let taskIdentifier = webSocketTask.taskIdentifier
        Task { @MainActor [weak self] in
            self?.handleWebSocketDidOpen(taskIdentifier: taskIdentifier)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let taskIdentifier = task.taskIdentifier
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.handleWebSocketCompletion(taskIdentifier: taskIdentifier, message: message)
        }
    }
}
