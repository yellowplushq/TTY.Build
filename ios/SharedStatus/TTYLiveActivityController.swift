import ActivityKit
import Foundation
import PedalsKit

@MainActor
public final class TTYLiveActivityController {
    public static let shared = TTYLiveActivityController()

    private var observing = false
    private var observationTasks: [Task<Void, Never>] = []
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var stateTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Call once during app launch. It covers both app-created and APNs-created
    /// activities and keeps every rotating ActivityKit token registered.
    public func startObservingPushTokens() {
        guard !observing else { return }
        observing = true

        observationTasks.append(Task { [weak self] in
            for await token in Activity<TTYActivityAttributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                await PushEndpointRegistrar.registerOrQueue(
                    .init(
                        surface: .iOSLiveActivityStart,
                        token: token.pedalsHexString
                    )
                )
                guard self != nil else { return }
            }
        })

        for activity in Activity<TTYActivityAttributes>.activities {
            observe(activity)
        }

        observationTasks.append(Task { [weak self] in
            for await activity in Activity<TTYActivityAttributes>.activityUpdates {
                guard !Task.isCancelled else { return }
                self?.observe(activity)
            }
        })
    }

    public func stopObservingPushTokens() {
        observationTasks.forEach { $0.cancel() }
        tokenTasks.values.forEach { $0.cancel() }
        stateTasks.values.forEach { $0.cancel() }
        observationTasks.removeAll()
        tokenTasks.removeAll()
        stateTasks.removeAll()
        observing = false
    }

    #if DEBUG
    /// Dev-only visual fixture: the production activity is APNs
    /// push-to-start only, which a simulator cannot receive, so this renders
    /// the identical UI from a locally requested activity.
    /// `PEDALS_LA_FIXTURE="ttys:running:waiting:done:state"`.
    public func startFixtureActivity(spec: String) {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5,
              let ttys = Int(parts[0]), let running = Int(parts[1]),
              let waiting = Int(parts[2]), let done = Int(parts[3])
        else { return }
        let agentState = String(parts[4])
        Task { @MainActor in
            for activity in Activity<TTYActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            let state = TTYActivityAttributes.ContentState(
                totalRunning: ttys,
                agentsRunning: running,
                agentsWaiting: waiting,
                agentsDone: done,
                recentAgentComputerID: agentState == "terminal" ? nil : "fixture",
                recentAgentState: agentState == "terminal" ? nil : agentState,
                recentAgentUpdatedAt: agentState == "terminal" ? nil : .now,
                recentAgentSealed: agentState == "terminal" ? nil : "fixture",
                recentAgentDisplay: agentState == "terminal"
                    ? nil
                    : fixtureDisplay(state: agentState),
                onlineComputerCount: 1,
                offlineComputerCount: 0,
                updatedAt: .now,
                sequence: 1
            )
            _ = try? Activity<TTYActivityAttributes>.request(
                attributes: TTYActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil)
            )
        }
    }
    #endif

    private func observe(_ activity: Activity<TTYActivityAttributes>) {
        observeUpdateToken(for: activity)
        observeState(for: activity)
    }

    /// Keeps the aggregate activity current in the foreground. A normal first
    /// appearance is requested locally and silently. Remote push-to-start is
    /// reserved for attention events because Apple requires those starts to
    /// carry an alert.
    public func synchronize(with snapshot: TTYStatusSnapshot) async throws {
        StatusSharedStore.saveSnapshot(snapshot)
        // The activity lives while anything is active: a running TTY or a
        // running/waiting/recently-done agent (the Worker uses the same rule).
        let totalActive =
            snapshot.totalRunning + snapshot.agentsRunning
            + snapshot.agentsWaiting + snapshot.agentsDone
        var state = TTYActivityAttributes.ContentState(snapshot: snapshot)
        let recent = Self.latestAgentState(
            from: Activity<TTYActivityAttributes>.activities.map {
                $0.content.state
            }
        )
        if state.totalAgents > 0, let recent {
            state.recentAgentComputerID = recent.recentAgentComputerID
            state.recentAgentState = recent.recentAgentState
            state.recentAgentUpdatedAt = recent.recentAgentUpdatedAt
            state.recentAgentSealed = recent.recentAgentSealed
            state.recentAgentDisplay = recent.recentAgentDisplay
        }
        let activities = Activity<TTYActivityAttributes>.activities
        let content = ActivityContent(
            state: state,
            staleDate: snapshot.updatedAt.addingTimeInterval(5 * 60),
            relevanceScore: totalActive > 0 ? 100 : 0
        )

        if totalActive == 0 {
            for activity in activities {
                await activity.end(content, dismissalPolicy: .immediate)
            }
            return
        }

        if activities.isEmpty {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let activity = try Activity<TTYActivityAttributes>.request(
                attributes: TTYActivityAttributes(),
                content: content,
                pushType: .token
            )
            observe(activity)
        } else {
            for activity in activities {
                await activity.update(content)
            }
        }
    }

    /// Foreground E2EE relay snapshots use the same card as Home immediately,
    /// without waiting for an APNs round trip. The local update is sealed in
    /// the same format because the widget extension, not the app, renders it.
    public func synchronizeRecentAgent(
        _ info: AgentInfo?, binding: ComputerBinding?
    ) async {
        let activities = Activity<TTYActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        var agentContent: AgentActivity.Content?
        var sealedText: String?
        if let info, let binding {
            let content = AgentActivity.Content(info: info)
            agentContent = content
            do {
                let sealed = try AgentActivity.seal(
                    content,
                    key: AgentActivity.activityKey(secret: binding.secret),
                    computerID: binding.computerID
                )
                if sealed.count <= RelayMetadata.AgentActivityEnvelope.maxSealedBytes {
                    sealedText = sealed.base64EncodedString()
                }
            } catch {
                // Home already has the decrypted content. Keep the local
                // ActivityKit presentation useful and let a later key/push
                // synchronization repair the encrypted envelope.
            }
        }

        let attention = switch info?.state {
        case .waiting, .error, .done: true
        case .running, nil: false
        }
        for activity in activities {
            var state = activity.content.state
            if let info, let binding, let agentContent {
                state.recentAgentComputerID = binding.computerID
                state.recentAgentState = info.state.rawValue
                state.recentAgentUpdatedAt = Date(timeIntervalSince1970: info.updatedAt)
                state.recentAgentSealed = sealedText
                state.recentAgentDisplay = .init(content: agentContent)
            } else if state.totalAgents == 0 {
                state.recentAgentComputerID = nil
                state.recentAgentState = nil
                state.recentAgentUpdatedAt = nil
                state.recentAgentSealed = nil
                state.recentAgentDisplay = nil
            }

            await activity.update(ActivityContent(
                state: state,
                staleDate: state.updatedAt.addingTimeInterval(5 * 60),
                relevanceScore: attention ? 100 : 60
            ))
        }
    }

    private func observeUpdateToken(for activity: Activity<TTYActivityAttributes>) {
        guard tokenTasks[activity.id] == nil else { return }
        tokenTasks[activity.id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await PushEndpointRegistrar.registerOrQueue(
                    .init(
                        surface: .iOSLiveActivityUpdate,
                        token: token.pedalsHexString,
                        activityId: activity.id
                    )
                )
            }
            self?.tokenTasks.removeValue(forKey: activity.id)
        }
    }

    private func observeState(for activity: Activity<TTYActivityAttributes>) {
        guard stateTasks[activity.id] == nil else { return }
        stateTasks[activity.id] = Task { [weak self] in
            if Self.isTerminal(activity.activityState) {
                await self?.removeEndpoint(for: activity.id)
                return
            }
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if Self.isTerminal(state) {
                    await self?.removeEndpoint(for: activity.id)
                    return
                }
            }
            self?.stateTasks.removeValue(forKey: activity.id)
        }
    }

    private func removeEndpoint(for activityId: String) async {
        // Stop token rotation first. The durable mutation identity is shared
        // with PUT, so a terminal DELETE safely wins even if a registration
        // was already in flight in another App Group process.
        tokenTasks.removeValue(forKey: activityId)?.cancel()
        await PushEndpointRegistrar.unregisterOrQueue(
            .iOSLiveActivityUpdate,
            activityId: activityId
        )
        stateTasks.removeValue(forKey: activityId)
    }

    private static func isTerminal(_ state: ActivityState) -> Bool {
        state == .ended || state == .dismissed
    }

    private nonisolated static func latestAgentState(
        from states: [TTYActivityAttributes.ContentState]
    ) -> TTYActivityAttributes.ContentState? {
        var latest: TTYActivityAttributes.ContentState?
        var latestDate = Date.distantPast
        for candidate in states {
            guard candidate.recentAgentDisplay != nil
                    || candidate.recentAgentSealed != nil
            else { continue }
            let candidateDate = candidate.recentAgentDisplay?.updatedAt
                ?? candidate.recentAgentUpdatedAt ?? .distantPast
            if latest == nil || candidateDate > latestDate {
                latest = candidate
                latestDate = candidateDate
            }
        }
        return latest
    }

    #if DEBUG
    private func fixtureDisplay(
        state rawState: String
    ) -> TTYActivityAttributes.ContentState.RecentAgentDisplay? {
        guard let state = AgentState(rawValue: rawState) else { return nil }
        return .init(content: .init(
            id: "fixture",
            agent: "codex",
            state: state,
            sessionName: "Polish agent monitoring",
            project: "pedals",
            prompt: "Review the Live Activity experience",
            action: "Build: PedalsWidgets",
            message: state == .done
                ? "Live Activity is ready" : "Choose how to continue",
            sessionId: 1,
            updatedAt: Date.now.timeIntervalSince1970
        ))
    }
    #endif
}
