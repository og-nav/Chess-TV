// The request context, and the two things it carries beyond Hummingbird's own: the authenticated
// device and a body limit small enough that a request cannot be used to fill the VPS's disk.

import Foundation
import FollowKit
import Hummingbird
import Logging
import NIOCore
import NIOFoundationCompat

public struct FollowRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// Set by `BearerAuthMiddleware`. Nil on the two endpoints that need no token.
    public var deviceId: String?

    public init(source: Source) {
        coreContext = CoreRequestContextStorage(source: source)
        deviceId = nil
    }

    /// The largest body any endpoint accepts. The biggest legitimate one is a
    /// `NotificationPreferences` with three alert sets in it — well under a kilobyte — so 32 KB
    /// is generous by a factor of thirty.
    public var maxUploadSize: Int { 32 * 1024 }

    /// The device this request is acting as, or a 401.
    public func requireDevice() throws -> String {
        guard let deviceId else { throw HTTPError(.unauthorized) }
        return deviceId
    }
}

/// JSON in, JSON out, through FollowKit's coders so the server and the app cannot disagree about
/// a date format.
public enum JSONBody {

    public static func decode<T: Decodable>(_ type: T.Type, from request: Request, context: FollowRequestContext) async throws -> T {
        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(upTo: context.maxUploadSize)
        } catch {
            throw HTTPError(.contentTooLarge, message: "body over \(context.maxUploadSize) bytes")
        }
        do {
            return try FollowJSON.decoder.decode(T.self, from: Data(buffer: buffer))
        } catch {
            throw HTTPError(.badRequest, message: "body is not a valid \(String(describing: type))")
        }
    }

    public static func response(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try FollowJSON.encoder.encode(value)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: buffer)
        )
    }

    public static let empty = Response(status: .noContent)
}
