import Foundation
import TTYBuildKit
import XCTest

@testable import TTYBuildDaemonCore

final class HostIdentityResetTests: XCTestCase {
    private var home: TTYBuildHome!
    private let serviceURL = URL(string: "https://ttybuild.example")!

    override func setUpWithError() throws {
        home = TTYBuildHome(
            directory: URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("ttybuild-reset-\(UUID().uuidString)", isDirectory: true)
        )
        try home.ensureDirectoryExists()
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home.directory) }
    }

    func testOfflineDeleteFailureKeepsOldIdentityAndClearsJournal() throws {
        let previous = try makeIdentity(number: 1)
        try home.save(identity: previous)
        let createCalled = ResetLockedValue(false)
        let serviceURL = serviceURL
        let actions = ServiceActions(
            createComputer: { _ in
                createCalled.set(true)
                return try Self.makeIdentity(number: 2, serviceURL: serviceURL)
            },
            deleteComputer: { _ in throw TestError.deleteFailed }
        )

        XCTAssertThrowsError(
            try resetHostIdentity(
                home: home,
                previous: previous,
                replacementServiceURL: serviceURL,
                actions: actions
            )
        ) { error in
            guard case HostIdentityResetError.revocationFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(createCalled.value)
        XCTAssertEqual(try home.loadIdentity(), previous)
        XCTAssertNil(try home.loadIdentityResetState())
    }

    func testReplacementCreatedPhaseFinalizesWithoutCreatingOrDeletingAgain() throws {
        let previous = try makeIdentity(number: 1)
        let replacement = try makeIdentity(number: 2)
        try home.save(identity: previous)
        try home.save(
            identityResetState: HostIdentityResetState(
                phase: .replacementCreated,
                previous: previous,
                replacementServiceURL: serviceURL,
                replacement: replacement
            )
        )
        let actions = ServiceActions(
            createComputer: { _ in throw TestError.unexpectedCall },
            deleteComputer: { _ in throw TestError.unexpectedCall }
        )

        let result = try resetHostIdentity(
            home: home,
            previous: previous,
            replacementServiceURL: serviceURL,
            actions: actions
        )

        XCTAssertEqual(result, replacement)
        XCTAssertEqual(try home.loadIdentity(), replacement)
        XCTAssertNil(try home.loadIdentityResetState())
    }

    func testRevokingJournalRetriesIdempotentDeleteThenCreatesReplacement() throws {
        let previous = try makeIdentity(number: 1)
        let replacement = try makeIdentity(number: 2)
        try home.save(identity: previous)
        try home.save(
            identityResetState: HostIdentityResetState(
                phase: .revoking,
                previous: previous,
                replacementServiceURL: serviceURL
            )
        )
        let events = ResetLockedValue<[String]>([])
        let actions = ServiceActions(
            createComputer: { _ in
                events.mutate { $0.append("create") }
                return replacement
            },
            deleteComputer: { identity in
                events.mutate { $0.append("delete:\(identity.computer.computerID)") }
            }
        )

        let result = try resetHostIdentity(
            home: home,
            previous: previous,
            replacementServiceURL: serviceURL,
            actions: actions
        )

        XCTAssertEqual(result, replacement)
        XCTAssertEqual(events.value, ["delete:\(previous.computer.computerID)", "create"])
        XCTAssertNil(try home.loadIdentityResetState())
    }

    func testCorruptJournalFailsClosed() throws {
        try Data("not json".utf8).write(to: home.identityResetURL)
        XCTAssertThrowsError(try home.loadIdentityResetState()) { error in
            XCTAssertEqual(error as? HostIdentityResetError, .corruptJournal)
        }
    }

    func testCorruptIdentityDoesNotRegisterOrOverwriteRemoteState() throws {
        try Data("not an identity".utf8).write(to: home.identityURL)
        let createCount = ResetLockedValue(0)
        let serviceURL = serviceURL
        let actions = ServiceActions(
            createComputer: { _ in
                createCount.mutate { $0 += 1 }
                return try Self.makeIdentity(number: 2, serviceURL: serviceURL)
            },
            deleteComputer: { _ in throw TestError.unexpectedCall }
        )

        XCTAssertThrowsError(
            try registerHostIdentity(
                home: home, serviceURL: serviceURL, actions: actions
            )
        )
        XCTAssertEqual(createCount.value, 0)
        XCTAssertEqual(try Data(contentsOf: home.identityURL), Data("not an identity".utf8))
    }

    func testConcurrentOfflineRegistrationCreatesOnlyOneRemoteIdentity() throws {
        let home = try XCTUnwrap(home)
        let serviceURL = serviceURL
        let fresh = try makeIdentity(number: 2)
        let createCount = ResetLockedValue(0)
        let enteredCreate = DispatchSemaphore(value: 0)
        let allowCreate = DispatchSemaphore(value: 0)
        let results = ResetLockedValue<[String]>([])
        let actions = ServiceActions(
            createComputer: { _ in
                let count = createCount.transform {
                    $0 += 1
                    return $0
                }
                if count == 1 {
                    enteredCreate.signal()
                    _ = allowCreate.wait(timeout: .now() + 2)
                }
                return fresh
            },
            deleteComputer: { _ in throw TestError.unexpectedCall }
        )
        let group = DispatchGroup()

        func launch() {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let identity = try registerHostIdentity(
                        home: home, serviceURL: serviceURL, actions: actions
                    )
                    results.mutate { $0.append("ok:\(identity.computer.computerID)") }
                } catch {
                    results.mutate { $0.append("error:\(error)") }
                }
            }
        }

        launch()
        XCTAssertEqual(enteredCreate.wait(timeout: .now() + 2), .success)
        launch()
        allowCreate.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 4), .success)

        XCTAssertEqual(createCount.value, 1)
        XCTAssertEqual(results.value, Array(repeating: "ok:\(fresh.computer.computerID)", count: 2))
        XCTAssertEqual(try home.loadIdentity(), fresh)
    }

    func testConcurrentOfflineResetCannotOverwriteFirstReplacement() throws {
        let home = try XCTUnwrap(home)
        let serviceURL = serviceURL
        let previous = try makeIdentity(number: 1)
        let replacement = try makeIdentity(number: 2)
        try home.save(identity: previous)
        let deleteCount = ResetLockedValue(0)
        let createCount = ResetLockedValue(0)
        let enteredDelete = DispatchSemaphore(value: 0)
        let allowDelete = DispatchSemaphore(value: 0)
        let results = ResetLockedValue<[String]>([])
        let actions = ServiceActions(
            createComputer: { _ in
                createCount.mutate { $0 += 1 }
                return replacement
            },
            deleteComputer: { _ in
                let count = deleteCount.transform {
                    $0 += 1
                    return $0
                }
                if count == 1 {
                    enteredDelete.signal()
                    _ = allowDelete.wait(timeout: .now() + 2)
                }
            }
        )
        let group = DispatchGroup()

        func launch() {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let identity = try resetHostIdentity(
                        home: home,
                        previous: previous,
                        replacementServiceURL: serviceURL,
                        actions: actions
                    )
                    results.mutate { $0.append("ok:\(identity.computer.computerID)") }
                } catch {
                    results.mutate { $0.append("error:\(error)") }
                }
            }
        }

        launch()
        XCTAssertEqual(enteredDelete.wait(timeout: .now() + 2), .success)
        launch()
        allowDelete.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 4), .success)

        XCTAssertEqual(deleteCount.value, 1)
        XCTAssertEqual(createCount.value, 1)
        XCTAssertEqual(results.value.filter { $0.hasPrefix("ok:") }.count, 1)
        XCTAssertEqual(results.value.filter { $0.contains("identity changed") }.count, 1)
        XCTAssertEqual(try home.loadIdentity(), replacement)
        XCTAssertNil(try home.loadIdentityResetState())
    }

    func testDaemonDeinitReleasesStartupIdentityLock() throws {
        let home = try XCTUnwrap(home)
        let identity = try makeIdentity(number: 1)
        try home.save(identity: identity)
        let actions = inertActions(identity: identity)
        var daemon: Daemon? = try Daemon(
            home: home,
            sessionOptions: SessionManager.Options(shell: "/bin/sh", shellArguments: []),
            serviceActions: actions
        )
        XCTAssertNotNil(daemon)
        let acquired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if let lock = try? home.acquireIdentityLock() {
                lock.unlock()
                acquired.signal()
            }
        }
        XCTAssertEqual(acquired.wait(timeout: .now() + 0.05), .timedOut)

        daemon = nil

        XCTAssertEqual(acquired.wait(timeout: .now() + 2), .success)
    }

    func testDaemonFailedStartReleasesStartupIdentityLock() throws {
        let longDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                String(repeating: "p", count: 100) + UUID().uuidString,
                isDirectory: true
            )
        let longHome = TTYBuildHome(directory: longDirectory)
        defer { try? FileManager.default.removeItem(at: longDirectory) }
        let identity = try makeIdentity(number: 1)
        try longHome.save(identity: identity)
        let daemon = try Daemon(
            home: longHome,
            sessionOptions: SessionManager.Options(shell: "/bin/sh", shellArguments: []),
            serviceActions: inertActions(identity: identity)
        )

        XCTAssertThrowsError(try daemon.start())

        let acquired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if let lock = try? longHome.acquireIdentityLock() {
                lock.unlock()
                acquired.signal()
            }
        }
        XCTAssertEqual(acquired.wait(timeout: .now() + 2), .success)
    }

    private enum TestError: Error {
        case deleteFailed
        case unexpectedCall
    }

    private func makeIdentity(number: UInt8) throws -> HostIdentity {
        try Self.makeIdentity(number: number, serviceURL: serviceURL)
    }

    private static func makeIdentity(number: UInt8, serviceURL: URL) throws -> HostIdentity {
        let id = String(format: "%032x", Int(number))
        return HostIdentity(
            computer: try ComputerBinding(
                serviceURL: serviceURL,
                computerID: id,
                secret: Data(repeating: number, count: ComputerBinding.secretByteCount)
            ),
            hostToken: "host-\(id)"
        )
    }

    private func inertActions(identity: HostIdentity) -> ServiceActions {
        ServiceActions(
            createComputer: { _ in identity },
            deleteComputer: { _ in }
        )
    }
}

private final class ResetLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func set(_ value: Value) {
        lock.withLock { stored = value }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&stored) }
    }

    func transform<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&stored) }
    }
}
