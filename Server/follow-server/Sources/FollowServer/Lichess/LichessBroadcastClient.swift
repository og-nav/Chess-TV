// The Lichess client, over AsyncHTTPClient so that the streaming request works the same on Linux
// as it does here.
//
// The app's LichessKit is not used: it is Apple-only today (`os.Logger`, `URLSession.bytes(for:)`)
// and the server needs four endpoints, not the whole package. What the two do share is ChessCore,
// which is where the PGN actually gets parsed.
//
// Lichess terms, honoured here: an identifying `User-Agent` with a contact address on every
// request, one stream per watched round and only for rounds with a follower, and at least a
// minute of backoff after a 429.

import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat

public final class LichessBroadcastClient: BroadcastSource, Sendable {

    private let client: HTTPClient
    private let baseURL: String
    private let userAgent: String
    private let token: String?
    private let logger: Logger

    /// The most JSON this client will read from one response. A tier-5 open's round JSON with a
    /// hundred boards is a few hundred kilobytes; eight megabytes is a wrong answer, not a big one.
    private let maximumBodyBytes = 8 << 20

    public init(configuration: ServerConfig, client: HTTPClient, logger: Logger = ServerLog.make("lichess")) {
        self.client = client
        self.baseURL = configuration.lichessBaseURL.hasSuffix("/")
            ? String(configuration.lichessBaseURL.dropLast())
            : configuration.lichessBaseURL
        self.userAgent = configuration.userAgent
        self.token = configuration.lichessToken
        self.logger = logger
    }

    private func request(_ path: String, accept: String) -> HTTPClientRequest {
        var request = HTTPClientRequest(url: baseURL + path)
        request.headers.add(name: "User-Agent", value: userAgent)
        request.headers.add(name: "Accept", value: accept)
        if let token { request.headers.add(name: "Authorization", value: "Bearer \(token)") }
        return request
    }

    private func data(_ path: String, accept: String = "application/json") async throws -> Data {
        let response: HTTPClientResponse
        do {
            response = try await client.execute(request(path, accept: accept), timeout: .seconds(30))
        } catch {
            throw BroadcastSourceError.unavailable(String(describing: type(of: error)))
        }
        guard response.status.code != 429 else { throw BroadcastSourceError.rateLimited }
        guard response.status.code == 200 else { throw BroadcastSourceError.http(Int(response.status.code)) }
        let buffer = try await response.body.collect(upTo: maximumBodyBytes)
        return Data(buffer: buffer)
    }

    public func top() async throws -> BroadcastTop {
        try BroadcastDecoder.top(from: try await data("/api/broadcast/top"))
    }

    public func tour(id: String) async throws -> BroadcastTourDetail {
        try BroadcastDecoder.tourDetail(from: try await data("/api/broadcast/\(Self.escape(id))"))
    }

    public func round(id: String) async throws -> BroadcastRoundDetail {
        // The slug segments are ignored by Lichess; `-` is the documented placeholder.
        try BroadcastDecoder.roundDetail(from: try await data("/api/broadcast/-/-/\(Self.escape(id))"))
    }

    public func pgnStream(roundId: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = self.request("/api/stream/broadcast/round/\(Self.escape(roundId)).pgn", accept: "application/x-chess-pgn")
                    // No overall deadline: this connection is meant to stay open for the length
                    // of a round. AsyncHTTPClient's read timeout on the client configuration is
                    // what notices a dead connection.
                    let response = try await self.client.execute(request, timeout: .hours(12))
                    guard response.status.code != 429 else { throw BroadcastSourceError.rateLimited }
                    guard response.status.code == 200 else { throw BroadcastSourceError.http(Int(response.status.code)) }

                    var splitter = PGNStreamSplitter()
                    for try await buffer in response.body {
                        // Bytes, not `String(buffer:)`: a chunk boundary can fall inside a
                        // multi-byte sequence, and decoding each chunk on its own turns the two
                        // halves of a player's name into replacement characters that no later
                        // chunk can repair. The splitter decodes at newlines instead.
                        for block in splitter.append(bytes: buffer.readableBytesView) { continuation.yield(block) }
                    }
                    if let last = splitter.flush() { continuation.yield(last) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Lichess ids are `[A-Za-z0-9]{8}`; anything else in the path would be our bug, but it is
    /// not going to become a request to a different endpoint.
    private static func escape(_ component: String) -> String {
        component.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
