import Foundation
import os

/// Typed request dispatch: register one body per `DaemonMethod`, then answer `IDERequestHandler.handle` with `route`.
///
/// `route` maps failures onto `DaemonError`: unregistered method => `unknownMethod`, params that do not decode into
/// `M.Params` => `badParams`, a `DaemonError` thrown by the body => passed through unchanged, anything else (including
/// an unencodable result) => `internal`.
public final class IDERouter: Sendable {
    private typealias Route = @Sendable (JSONValue, IDEConnection) async throws -> JSONValue

    private let routes = OSAllocatedUnfairLock<[String: Route]>(initialState: [:])

    public init() {}

    /// Registers the body for `method`. Register every method before serving; registering a method twice is a
    /// programming error.
    public func on<M: DaemonMethod>(_ method: M.Type, _ body: @escaping @Sendable (M.Params, IDEConnection) async throws -> M.Result) {
        let route: Route = { params, connection in
            let decoded: M.Params
            do {
                decoded = try WireJSON.decode(M.Params.self, from: params)
            } catch {
                throw BadParams(underlying: error)
            }
            return try WireJSON.value(try await body(decoded, connection))
        }
        let duplicate = routes.withLock { $0.updateValue(route, forKey: M.name) != nil }
        precondition(!duplicate, "IDERouter: \(M.name) registered twice")
    }

    public func route(_ request: Request, from connection: IDEConnection) async -> Response {
        guard let route = routes.withLock({ $0[request.method] }) else {
            return Response(id: request.id, error: DaemonError(.unknownMethod, "unknown method \(request.method)"))
        }
        do {
            return Response(id: request.id, result: try await route(request.params, connection))
        } catch let error as BadParams {
            return Response(id: request.id, error: DaemonError(.badParams, "\(request.method): \(error.underlying)"))
        } catch let error as DaemonError {
            return Response(id: request.id, error: error)
        } catch {
            return Response(id: request.id, error: DaemonError(.internal, "\(request.method): \(error)"))
        }
    }
}

private struct BadParams: Error {
    let underlying: any Error
}
