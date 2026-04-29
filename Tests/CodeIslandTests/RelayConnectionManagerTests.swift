import XCTest
@testable import CodeIsland

final class RelayConnectionManagerTests: XCTestCase {
    func testWebSocketURLNormalizesHTTPServerURL() {
        XCTAssertEqual(
            RelayConnectionManager.webSocketURL(from: "https://relay.example.com")?.absoluteString,
            "wss://relay.example.com/ws"
        )
        XCTAssertEqual(
            RelayConnectionManager.webSocketURL(from: "http://localhost:8787")?.absoluteString,
            "ws://localhost:8787/ws"
        )
    }

    func testRegisterURLNormalizesWebSocketScheme() {
        XCTAssertEqual(
            RelayConnectionManager.registerURL(from: "wss://relay.example.com")?.absoluteString,
            "https://relay.example.com/api/register"
        )
        XCTAssertEqual(
            RelayConnectionManager.registerURL(from: "ws://relay.example.com")?.absoluteString,
            "http://relay.example.com/api/register"
        )
    }

    func testResourceURLNormalizesServerURL() {
        XCTAssertEqual(
            RelayConnectionManager.resourceURL(from: "https://relay.example.com", path: "/resources/install.sh")?.absoluteString,
            "https://relay.example.com/resources/install.sh"
        )
    }

    func testWebSocketURLPreservesSubpath() {
        XCTAssertEqual(
            RelayConnectionManager.webSocketURL(from: "https://example.com/subpath/relay")?.absoluteString,
            "wss://example.com/subpath/relay/ws"
        )
        XCTAssertEqual(
            RelayConnectionManager.webSocketURL(from: "https://example.com/subpath/relay/")?.absoluteString,
            "wss://example.com/subpath/relay/ws"
        )
    }

    func testRegisterURLPreservesSubpath() {
        XCTAssertEqual(
            RelayConnectionManager.registerURL(from: "https://example.com/subpath/relay")?.absoluteString,
            "https://example.com/subpath/relay/api/register"
        )
    }

    func testResourceURLPreservesSubpath() {
        XCTAssertEqual(
            RelayConnectionManager.resourceURL(from: "https://example.com/subpath/relay", path: "/resources/install.sh")?.absoluteString,
            "https://example.com/subpath/relay/resources/install.sh"
        )
    }

    func testRelayHostIdIsNamespacedOnce() {
        XCTAssertEqual(RelayConnectionManager.relayHostId(from: "devbox"), "relay:devbox")
        XCTAssertEqual(RelayConnectionManager.relayHostId(from: "relay:devbox"), "relay:devbox")
    }

    func testServerAuthErrorsUseUserFacingMessage() {
        XCTAssertEqual(
            RelayConnectionManager.userFacingServerError(code: "invalid_api_key", message: "unauthorized"),
            "Invalid API Key"
        )
        XCTAssertEqual(
            RelayConnectionManager.userFacingServerError(code: nil, message: "unauthorized"),
            "Invalid API Key"
        )
    }
}
