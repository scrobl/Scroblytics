import Foundation

/// Runs `operation` on a detached task and hands back its result.
///
/// Every `@ModelActor` in this app exists to keep SwiftData reads off the main thread — but a
/// model actor only runs on a background thread when it is called from a DETACHED task. Awaited
/// from main-actor code, or from a `Task {}` that inherits the main actor, its work executes on the
/// main thread. Verified directly with a standalone SwiftData program (a `@ModelActor` method
/// reported `Thread.isMainThread == true` from `await` and from `Task {}`, `false` only from
/// `Task.detached`; creating the actor inside a detached task changes nothing). Measured: after a first sync the "background" readers put the main thread at 58–100% busy for
/// over a minute. So every model-actor call goes through here.
func offMain<T: Sendable>(
    priority: TaskPriority = .utility,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await Task.detached(priority: priority) { try await operation() }.value
}

func offMain<T: Sendable>(
    priority: TaskPriority = .utility,
    _ operation: @escaping @Sendable () async -> T
) async -> T {
    await Task.detached(priority: priority) { await operation() }.value
}
