import Foundation
import Network
import os.log
import ApplicationServices
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "HookServer")

@MainActor
class HookServer {
    enum RouteKind: Equatable {
        case permission
        case question
        case event
    }

    private let appState: AppState
    nonisolated static var socketPath: String { SocketPath.path }
    private var listener: NWListener?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        // Clean up stale socket
        unlink(HookServer.socketPath)

        // Set umask to 0o077 BEFORE the listener creates the socket file,
        // ensuring it is never world-readable even briefly (closes TOCTOU window).
        let previousUmask = umask(0o077)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: HookServer.socketPath)

        do {
            listener = try NWListener(using: params)
        } catch {
            umask(previousUmask)
            log.error("Failed to create NWListener: \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { [previousUmask] state in
            switch state {
            case .ready:
                // Restore previous umask now that the socket file exists with safe permissions
                umask(previousUmask)
                // Belt-and-suspenders: explicitly set 0o700 in case umask didn't take effect
                chmod(HookServer.socketPath, 0o700)
                log.info("HookServer listening on \(HookServer.socketPath)")
            case .failed(let error):
                umask(previousUmask)
                log.error("HookServer failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        // Delay socket removal so in-flight hooks can finish sending their payload
        // before the file disappears — prevents intermittent errors on session end (#45).
        let path = HookServer.socketPath
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            unlink(path)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveAll(connection: connection, accumulated: Data())
    }

    private static let maxPayloadSize = 1_048_576  // 1MB safety limit

    /// Recursively receive all data until EOF, then process
    private func receiveAll(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }

                // On error with no data, just drop the connection
                if error != nil && accumulated.isEmpty && content == nil {
                    connection.cancel()
                    return
                }

                var data = accumulated
                if let content { data.append(content) }

                // Safety: reject oversized payloads
                if data.count > Self.maxPayloadSize {
                    log.warning("Payload too large (\(data.count) bytes), dropping connection")
                    connection.cancel()
                    return
                }

                if isComplete || error != nil {
                    self.processRequest(data: data, connection: connection)
                } else {
                    self.receiveAll(connection: connection, accumulated: data)
                }
            }
        }
    }

    /// Internal tools that are safe to auto-approve without user confirmation.
    /// Read from user settings; defaults to all known internal tools.
    private static var autoApproveTools: Set<String> {
        SettingsManager.shared.autoApproveTools
    }

    /// User-configured cwd substring blocklist for plugin/background hooks (e.g. claude-mem).
    /// Empty default = no filtering. Trimmed, blank entries skipped.
    private static func eventMatchesExcludedCwd(_ cwd: String) -> Bool {
        cwdMatchesAnyPattern(cwd, patternsCSV: SettingsManager.shared.excludedHookCwdSubstrings)
    }

    /// Pure substring blocklist match — returns true if `cwd` contains any
    /// non-empty trimmed entry of `patternsCSV`. Extracted for testability;
    /// `nonisolated` because it touches no actor state.
    nonisolated static func cwdMatchesAnyPattern(_ cwd: String, patternsCSV: String) -> Bool {
        guard !patternsCSV.isEmpty else { return false }
        for entry in patternsCSV.split(separator: ",", omittingEmptySubsequences: false) {
            let pattern = entry.trimmingCharacters(in: .whitespaces)
            if !pattern.isEmpty, cwd.contains(pattern) { return true }
        }
        return false
    }

    /// Fire-and-forget POST of the hook event to a user-configured webhook URL.
    /// Wraps the raw event in a small envelope (event/source/session/cwd/tool/raw)
    /// so users on the receiving side don't need to dig through bridge-internal
    /// fields. Optional event-name allow-list filters noisy event types. (#115)
    private static func forwardEventToWebhook(_ event: HookEvent) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.webhookEnabled) else { return }
        // Trim whitespace — users routinely paste URLs with leading/trailing space
        // and URL(string:) silently rejects those (RFC 3986 forbids whitespace).
        let urlString = (defaults.string(forKey: SettingsKey.webhookURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty,
              let endpoint = URL(string: urlString) else { return }

        let normalizedName = EventNormalizer.normalize(event.eventName)

        // Event filter: comma-separated allow-list. Empty = forward all.
        // Match on either the normalized name (PreToolUse) or raw name (pre_tool_use).
        if let filter = defaults.string(forKey: SettingsKey.webhookEventFilter),
           !filter.trimmingCharacters(in: .whitespaces).isEmpty {
            let allowed = filter.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard allowed.contains(normalizedName) || allowed.contains(event.eventName) else { return }
        }

        // Suppress webhook when the user is actively at this Mac:
        // sound notifications on (so the user already gets local alerts) AND screen is unlocked.
        if defaults.bool(forKey: SettingsKey.webhookSuppressWhenActive),
           defaults.bool(forKey: SettingsKey.soundEnabled),
           !Self.isScreenLocked() {
            return
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let envelope: [String: Any] = [
            "event": normalizedName,
            "raw_event": event.eventName,
            "session_id": event.sessionId ?? "",
            "source": event.rawJSON["_source"] as? String ?? "",
            "cwd": event.rawJSON["cwd"] as? String ?? "",
            "tool_name": event.toolName ?? "",
            "timestamp": isoFormatter.string(from: Date()),
            "raw": event.rawJSON,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return }

        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodeIsland-Webhook/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, _, _ in
            // Fire-and-forget. Failures are intentionally swallowed: a flaky
            // webhook should never break the hook event pipeline.
        }.resume()
    }

    /// Returns `true` when the screen is locked or the login window is showing.
    /// Uses `CGSessionCopyCurrentDictionary` which returns a dict with key
    /// "CGSSessionScreenIsLocked" == 1 when the session is locked.
    private static func isScreenLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (info["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    static func routeKind(for event: HookEvent) -> RouteKind {
        let normalizedEventName = EventNormalizer.normalize(event.eventName)
        if normalizedEventName == "PermissionRequest" {
            return .permission
        }
        if normalizedEventName == "Notification", QuestionPayload.from(event: event) != nil {
            return .question
        }
        return .event
    }

    private func processRequest(data: Data, connection: NWConnection) {
        guard let event = HookEvent(from: data) else {
            sendResponse(connection: connection, data: Data("{\"error\":\"parse_failed\"}".utf8))
            return
        }

        if let rawSource = event.rawJSON["_source"] as? String,
           SessionSnapshot.normalizedSupportedSource(rawSource) == nil {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // User-configured cwd exclusion: drop hooks fired by background plugins
        // (e.g. claude-mem, agent loops) whose cwd matches any user-provided
        // substring. Default empty list = no filtering, matches existing behavior. (#125)
        if let cwd = event.rawJSON["cwd"] as? String,
           !cwd.isEmpty,
           Self.eventMatchesExcludedCwd(cwd) {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // User-configured webhook forwarding: fire-and-forget POST to an external URL.
        // Runs *before* the route handlers so it doesn't add latency to user-facing
        // permission/question UI. Disabled by default. (#115)
        Self.forwardEventToWebhook(event)

        switch Self.routeKind(for: event) {
        case .permission:
            let sessionId = event.sessionId ?? "default"

            // Auto-approve safe internal tools without showing UI
            if let toolName = event.toolName, Self.autoApproveTools.contains(toolName) {
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            // AskUserQuestion is a question, not a permission — route to QuestionBar
            if event.toolName == "AskUserQuestion" {
                monitorPeerDisconnect(connection: connection, sessionId: sessionId)
                Task {
                    let responseBody = await withCheckedContinuation { continuation in
                        appState.handleAskUserQuestion(event, continuation: continuation)
                    }
                    self.sendResponse(connection: connection, data: responseBody)
                }
                return
            }
            monitorPeerDisconnect(connection: connection, sessionId: sessionId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handlePermissionRequest(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }

        case .question:
            let questionSessionId = event.sessionId ?? "default"
            monitorPeerDisconnect(connection: connection, sessionId: questionSessionId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handleQuestion(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }

        case .event:
            appState.handleEvent(event)
            sendResponse(connection: connection, data: Data("{}".utf8))
        }
    }

    /// Per-connection state used by the disconnect monitor.
    /// `responded` flips to true once we've sent the response, so our own
    /// `connection.cancel()` inside `sendResponse` does not masquerade as a
    /// peer disconnect.
    private final class ConnectionContext {
        var responded: Bool = false
    }

    private var connectionContexts: [ObjectIdentifier: ConnectionContext] = [:]

    /// Watch for bridge process disconnect — indicates the bridge process actually died
    /// (e.g. user Ctrl-C'd Claude Code), NOT a normal half-close.
    ///
    /// Previously this used `connection.receive(min:1, max:1)` which triggered on EOF.
    /// But the bridge always does `shutdown(SHUT_WR)` after sending the request (see
    /// CodeIslandBridge/main.swift), which produces an immediate EOF on the read side.
    /// That caused every PermissionRequest to be auto-drained as `deny` before the UI
    /// card was even visible. We now rely on `stateUpdateHandler` transitioning to
    /// `cancelled`/`failed` — which only happens on real socket teardown, not half-close.
    private func monitorPeerDisconnect(connection: NWConnection, sessionId: String) {
        let context = ConnectionContext()
        let connId = ObjectIdentifier(connection)
        connectionContexts[connId] = context

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .cancelled, .failed:
                    if !context.responded {
                        self.appState.handlePeerDisconnect(sessionId: sessionId)
                    }
                    self.connectionContexts.removeValue(forKey: connId)
                default:
                    break
                }
            }
        }

        // Safety net: if the connection context is still around after 5 minutes
        // (e.g. stuck continuation, NWConnection never transitions), clean it up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)  // 5 minutes
            guard let self = self else { return }
            if self.connectionContexts.removeValue(forKey: connId) != nil {
                log.warning("Connection context for session \(sessionId) timed out — cleaning up")
                if !context.responded {
                    connection.cancel()
                }
            }
        }
    }

    private func sendResponse(connection: NWConnection, data: Data) {
        // Mark as responded BEFORE cancel() so the disconnect monitor ignores our own teardown.
        if let context = connectionContexts[ObjectIdentifier(connection)] {
            context.responded = true
        }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
