// Two middlewares: one that refuses a request that did not arrive over TLS, and one that turns a
// bearer token into a device.

import Foundation
import HTTPTypes
import Hummingbird
import Logging

/// Refuses anything that did not reach Caddy over https.
///
/// The install token is a bearer credential; if it ever travels in the clear the device is
/// compromised and there is no way to know. Caddy terminates TLS and sets `X-Forwarded-Proto`, so
/// the check is on that header, and the middleware is configured off when the server is run
/// directly on a laptop.
public struct RequireHTTPSMiddleware<Context: RequestContext>: RouterMiddleware {
    private let enabled: Bool
    private static var forwardedProto: HTTPField.Name { HTTPField.Name("x-forwarded-proto")! }

    public init(enabled: Bool) { self.enabled = enabled }

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard enabled else { return try await next(request, context) }
        let proto = request.headers[Self.forwardedProto]?.lowercased()
        guard proto == "https" else {
            throw HTTPError(.forbidden, message: "https required")
        }
        return try await next(request, context)
    }
}

/// Rejects an oversized body before it is read.
///
/// `RequestContext.maxUploadSize` already caps what is collected; this catches the declared length
/// first, so a client that announces a gigabyte is answered immediately rather than streamed.
public struct BodyLimitMiddleware<Context: RequestContext>: RouterMiddleware {
    private let limit: Int

    public init(limit: Int) { self.limit = limit }

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if let declared = request.headers[.contentLength].flatMap(Int.init), declared > limit {
            throw HTTPError(.contentTooLarge, message: "body over \(limit) bytes")
        }
        return try await next(request, context)
    }
}

/// `Authorization: Bearer <install token>` → a device id on the context.
///
/// The token is looked up by its SHA-256, which is the only form the database holds, so this is
/// an indexed lookup rather than a comparison of secrets. A device that APNs has told us is gone
/// is still allowed in: that is how the app re-registers or rotates its token and gets its
/// follows back.
public struct BearerAuthMiddleware: RouterMiddleware {
    public typealias Context = FollowRequestContext

    private let store: FollowStore
    private let logger: Logger

    public init(store: FollowStore, logger: Logger = ServerLog.make("auth")) {
        self.store = store
        self.logger = logger
    }

    public func handle(
        _ request: Request,
        context: FollowRequestContext,
        next: (Request, FollowRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else {
            throw HTTPError(.unauthorized, message: "bearer token required")
        }
        let token = String(header.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, let device = try await store.device(installToken: token) else {
            // Never log the token, and never say which half was wrong.
            logger.notice("rejected a bearer token", metadata: ["token": .redacted(token)])
            throw HTTPError(.unauthorized, message: "unknown token")
        }

        var context = context
        context.deviceId = device.id
        try? await store.touch(deviceId: device.id)
        return try await next(request, context)
    }
}
