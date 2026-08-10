import XCTest

@testable import TTYBuild

final class PushMutationStateTests: XCTestCase {
    func testCredentialRotationRequeuesDesiredPutsAndDropsOldDeletes() {
        let widget = PendingPushEndpointMutation.put(.init(
            surface: .iOSWidget,
            token: "widget-token"
        ))
        let activity = PendingPushEndpointMutation.put(.init(
            surface: .iOSLiveActivityUpdate,
            token: "activity-token",
            activityId: "activity-1"
        ))
        var state = PushMutationState()
        state.enqueue(widget)
        state.enqueue(activity)

        // Successful delivery removes work, not the durable desired tokens.
        state.removePending(widget)
        state.removePending(activity)
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertEqual(Set(state.desired.values), [widget, activity])

        // An ended activity is no longer desired; its DELETE applies only to
        // the old identity and must not be sent to a replacement client.
        let delete = PendingPushEndpointMutation.delete(
            .iOSLiveActivityUpdate,
            activityId: "activity-1"
        )
        state.enqueue(delete)
        XCTAssertTrue(state.installCredential(credential(client: "new-client")))

        XCTAssertEqual(Array(state.pending.values), [widget])
        XCTAssertEqual(Array(state.desired.values), [widget])
    }

    func testOldClaimCannotCommitAcrossCredentialRotation() throws {
        let widget = PendingPushEndpointMutation.put(.init(
            surface: .iOSWidget,
            token: "widget-token"
        ))
        var state = PushMutationState()
        state.enqueue(widget)
        state.installCredential(credential(client: "old-client"))

        let oldClaim = try XCTUnwrap(state.claimNext(
            now: date(0),
            claimID: "old-claim"
        ).delivery?.claim)
        XCTAssertTrue(state.installCredential(credential(client: "new-client")))

        // The old request may return after rotation. Its compare-and-commit is
        // stale and must not remove the PUT requeued for the new client.
        state.complete(oldClaim)
        XCTAssertEqual(state.pending[widget.identity], widget)

        let newDelivery = try XCTUnwrap(state.claimNext(
            now: date(1),
            claimID: "new-claim"
        ).delivery)
        XCTAssertEqual(newDelivery.credential.clientID, "new-client")
        state.complete(newDelivery.claim)
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertEqual(state.desired[widget.identity], widget)
    }

    func testExpiredClaimIsRecoveredAfterConsumerCrash() throws {
        let widget = PendingPushEndpointMutation.put(.init(
            surface: .watchWidget,
            token: "watch-token"
        ))
        var state = PushMutationState()
        state.enqueue(widget)
        state.installCredential(credential(client: "client"))

        let abandoned = try XCTUnwrap(state.claimNext(
            now: date(0),
            lease: 30,
            claimID: "abandoned"
        ).delivery?.claim)
        // Simulate process death: only the JSON transaction survives.
        state = try JSONDecoder.ttybuild.decode(
            PushMutationState.self,
            from: JSONEncoder.ttybuild.encode(state)
        )
        let waiting = state.claimNext(
            now: date(29),
            lease: 30,
            claimID: "too-early"
        )
        XCTAssertNil(waiting.delivery)
        XCTAssertEqual(waiting.nextAttemptAt, date(30))

        let recovered = try XCTUnwrap(state.claimNext(
            now: date(30),
            lease: 30,
            claimID: "recovered"
        ).delivery?.claim)
        XCTAssertNotEqual(recovered.id, abandoned.id)

        // A late completion from the abandoned process cannot steal the new
        // claim or remove its pending mutation.
        state.complete(abandoned)
        XCTAssertEqual(state.activeClaim?.id, recovered.id)
        XCTAssertEqual(state.pending[widget.identity], widget)
        state.complete(recovered)
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testTransientFailureBecomesClaimableAtPersistedRetryDeadline() throws {
        let widget = PendingPushEndpointMutation.put(.init(
            surface: .iOSWidget,
            token: "widget-token"
        ))
        var state = PushMutationState()
        state.enqueue(widget)
        state.installCredential(credential(client: "client"))
        let failed = try XCTUnwrap(state.claimNext(
            now: date(100),
            claimID: "first"
        ).delivery?.claim)

        XCTAssertEqual(state.fail(failed, now: date(100)), date(102))
        let beforeDeadline = state.claimNext(
            now: date(101),
            claimID: "early"
        )
        XCTAssertNil(beforeDeadline.delivery)
        XCTAssertEqual(beforeDeadline.nextAttemptAt, date(102))

        let retry = try XCTUnwrap(state.claimNext(
            now: date(102),
            claimID: "retry"
        ).delivery?.claim)
        XCTAssertEqual(retry.mutation, widget)
    }

    func testEnqueueDuringInflightClaimPreservesLatestMutation() throws {
        let put = PendingPushEndpointMutation.put(.init(
            surface: .iOSWidget,
            token: "widget-token"
        ))
        let delete = PendingPushEndpointMutation.delete(.iOSWidget)
        var state = PushMutationState()
        state.enqueue(put)
        state.installCredential(credential(client: "client"))
        let claim = try XCTUnwrap(state.claimNext(
            now: date(0),
            claimID: "put"
        ).delivery?.claim)

        state.enqueue(delete)
        state.complete(claim)
        XCTAssertEqual(state.pending[delete.identity], delete)
        XCTAssertNil(state.desired[delete.identity])
    }

    func testTimelineReactivatesTokenObservedBeforeWidgetConfiguration() throws {
        let registration = PushEndpointRegistration(
            surface: .watchWidget,
            token: "watch-token"
        )
        let delete = PendingPushEndpointMutation.delete(.watchWidget)
        let put = PendingPushEndpointMutation.put(registration)
        var state = PushMutationState()

        state.observeWidgetRegistration(
            registration,
            hasConfiguredWidgets: false
        )
        XCTAssertEqual(state.pending[delete.identity], delete)
        XCTAssertNil(state.desired[delete.identity])

        // The token cache survives the same Codable round trip used by the
        // shared App Group transaction file.
        state = try JSONDecoder.ttybuild.decode(
            PushMutationState.self,
            from: JSONEncoder.ttybuild.encode(state)
        )
        XCTAssertTrue(state.activateObservedWidgetRegistration(.watchWidget))
        XCTAssertEqual(state.pending[put.identity], put)
        XCTAssertEqual(state.desired[put.identity], put)

        state.removePending(put)
        XCTAssertFalse(state.activateObservedWidgetRegistration(.watchWidget))
        XCTAssertTrue(state.pending.isEmpty)

        state.observeWidgetRegistration(
            registration,
            hasConfiguredWidgets: false
        )
        XCTAssertEqual(state.pending[delete.identity], delete)
        XCTAssertNil(state.desired[delete.identity])

        // Adding the widget again can use the unchanged cached token even if
        // WidgetKit doesn't repeat its configuration-change callback.
        XCTAssertTrue(state.activateObservedWidgetRegistration(.watchWidget))
        XCTAssertEqual(state.pending[put.identity], put)
    }

    func testWatchContextRoundTripsCredentialURLAndSnapshot() throws {
        let snapshot = TTYStatusSnapshot(
            totalRunning: 2,
            computers: [],
            updatedAt: date(42),
            sequence: 7
        )
        let context = WatchStatusContext(
            credential: credential(client: "watch-client"),
            snapshot: snapshot
        )

        let decoded = try XCTUnwrap(
            WatchStatusContext(applicationContext: context.applicationContext)
        )
        XCTAssertEqual(decoded.credential, context.credential)
        XCTAssertEqual(decoded.snapshot, snapshot)
    }

    private func credential(client: String) -> TTYBuildStatusCredential {
        .init(
            serviceURL: URL(string: "https://ttybuild.example")!,
            clientID: client,
            statusToken: "status-\(client)"
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
