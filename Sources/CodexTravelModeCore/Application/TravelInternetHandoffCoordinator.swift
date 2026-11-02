import Foundation

public actor TravelInternetHandoffCoordinator {
    private let lidProvider: any LidStateProviding
    private let engine: TravelInternetHandoffEngine
    private let scheduler: any HandoffScheduling
    private let policy: HandoffRetryPolicy

    private var context: HandoffSessionContext?
    private var previousLid: LidState?
    private var previousPath: HandoffPathClassification?
    private var lastHealthyTargetAt: Duration?
    private var pendingRecoveryAt: Duration?
    private var pendingTrigger: HandoffTrigger?
    private var episodeSequence = 0
    private var episodeTask: Task<Void, Never>?
    private var currentEpisodeID: String?
    private var currentEpisodeToken: HandoffEpisodeToken?
    private var currentEpisodeTrigger: HandoffTrigger?
    private var reopenCancelledEpisodeID: String?
    private var publication = TravelInternetStatePublication(
        sessionID: nil,
        generation: nil,
        episodeID: nil,
        state: .inactive
    )

    public init(
        lidProvider: any LidStateProviding,
        engine: TravelInternetHandoffEngine,
        scheduler: any HandoffScheduling = ContinuousHandoffScheduler(),
        policy: HandoffRetryPolicy = .production
    ) {
        self.lidProvider = lidProvider
        self.engine = engine
        self.scheduler = scheduler
        self.policy = policy
    }

    @discardableResult
    public func activate(_ newContext: HandoffSessionContext) async -> TravelInternetStatePublication {
        guard context == nil, episodeTask == nil else {
            return publication
        }
        context = newContext
        previousLid = nil
        previousPath = nil
        lastHealthyTargetAt = nil
        pendingRecoveryAt = nil
        pendingTrigger = nil
        episodeSequence = 0
        currentEpisodeToken = nil
        publish(.waitingForConnection, episodeID: nil, context: newContext)
        await observe(generation: newContext.generation, activationSample: true)
        return publication
    }

    @discardableResult
    public func tick(generation: UUID) async -> TravelInternetStatePublication {
        await observe(generation: generation, activationSample: false)
        return publication
    }

    @discardableResult
    public func retry(generation: UUID) -> TravelInternetStatePublication {
        guard let context, context.generation == generation, episodeTask == nil else {
            return publication
        }
        guard case .failed = publication.state, publication.episodeID != nil else {
            return publication
        }
        startEpisode(trigger: .explicitRetry, context: context)
        return publication
    }

    public func invalidate(generation: UUID) -> Task<Void, Never>? {
        guard context?.generation == generation else { return nil }
        let task = episodeTask
        let token = currentEpisodeToken
        context = nil
        previousLid = nil
        previousPath = nil
        lastHealthyTargetAt = nil
        pendingRecoveryAt = nil
        pendingTrigger = nil
        currentEpisodeID = nil
        currentEpisodeToken = nil
        currentEpisodeTrigger = nil
        reopenCancelledEpisodeID = nil
        episodeTask = nil
        task?.cancel()
        publication = TravelInternetStatePublication(
            sessionID: nil,
            generation: nil,
            episodeID: nil,
            state: .inactive
        )
        guard task != nil || token != nil else { return nil }
        return Task { [engine] in
            if let token {
                await engine.cancelEpisode(token)
            }
            _ = await task?.value
        }
    }

    public func currentPublication() -> TravelInternetStatePublication {
        publication
    }
}

private extension TravelInternetHandoffCoordinator {
    func observe(generation: UUID, activationSample: Bool) async {
        guard let sampledContext = context, sampledContext.generation == generation else { return }
        let lidReading = await lidProvider.readLidState(timeout: policy.providerTimeout)
        guard isActive(sampledContext) else { return }
        guard case .value(let lid) = lidReading else {
            if episodeTask == nil {
                publish(
                    .failed(lidFailure(lidReading.failure)),
                    episodeID: nil,
                    context: sampledContext
                )
            }
            return
        }

        let priorLid = previousLid
        previousLid = lid
        if priorLid == .closed, lid == .open {
            pendingRecoveryAt = nil
            await cancelClosedEpisodeForReopen(context: sampledContext)
        }

        let trigger = lidTrigger(prior: priorLid, current: lid, activationSample: activationSample)
        if episodeTask != nil {
            if trigger == .lidClosed {
                pendingTrigger = .lidClosed
            }
            return
        }
        if let trigger {
            startEpisode(trigger: trigger, context: sampledContext)
            return
        }
        await observePath(lid: lid, context: sampledContext)
    }

    func lidTrigger(
        prior: LidState?,
        current: LidState,
        activationSample: Bool
    ) -> HandoffTrigger? {
        if prior == nil, current == .closed {
            return .initiallyClosed
        }
        if prior == .open, current == .closed {
            return .lidClosed
        }
        return nil
    }

    func observePath(lid: LidState, context sampledContext: HandoffSessionContext) async {
        let now = await scheduler.now()
        do {
            let path = try await engine.inspect(
                context: sampledContext,
                deadline: now + .seconds(8),
                scheduler: scheduler
            )
            guard isActive(sampledContext), episodeTask == nil else { return }
            reducePath(path.classification, lid: lid, now: await scheduler.now(), context: sampledContext)
        } catch is CancellationError {
            return
        } catch {
            guard isActive(sampledContext) else { return }
            publish(
                .failed(HandoffFailure(
                    kind: .connectivityProviderFailed,
                    detail: "Connectivity monitoring was interrupted.",
                    retryable: true
                )),
                episodeID: nil,
                context: sampledContext
            )
        }
    }

    func reducePath(
        _ path: HandoffPathClassification,
        lid: LidState,
        now: Duration,
        context sampledContext: HandoffSessionContext
    ) {
        let prior = previousPath
        if case .providerFailure(let failure) = path {
            // A provider gap must break the adjacent open-lid disconnection edge,
            // but it must not erase the last verified closed target. The next
            // authoritative closed sample still owns target-loss recovery.
            if lid == .open {
                previousPath = nil
            }
            if hasLatchedEpisodeFailure {
                return
            }
            publish(.failed(failure), episodeID: nil, context: sampledContext)
            return
        }
        previousPath = path
        if lid == .open {
            pendingRecoveryAt = nil
            reduceOpenPath(path, prior: prior, context: sampledContext)
            return
        }
        reduceClosedPath(path, prior: prior, now: now, context: sampledContext)
    }

    func reduceOpenPath(
        _ path: HandoffPathClassification,
        prior: HandoffPathClassification?,
        context sampledContext: HandoffSessionContext
    ) {
        if hasLatchedEpisodeFailure, !path.isAuthoritativelyHealthy {
            return
        }
        if prior?.isAuthoritativelyHealthy == true, case .ordinaryDisconnected = path {
            startEpisode(trigger: .openDisconnection, context: sampledContext)
            return
        }
        switch path {
        case .healthyTarget(let ssid), .healthyOther(let ssid):
            publish(.preservingCurrentNetwork(ssid), episodeID: nil, context: sampledContext)
        case .ordinaryDisconnected:
            publish(.waitingForConnection, episodeID: nil, context: sampledContext)
        case .partial(let failure):
            publish(.failed(failure), episodeID: nil, context: sampledContext)
        case .providerFailure:
            break
        }
    }

    func reduceClosedPath(
        _ path: HandoffPathClassification,
        prior: HandoffPathClassification?,
        now: Duration,
        context sampledContext: HandoffSessionContext
    ) {
        if case .healthyTarget(let ssid) = path {
            lastHealthyTargetAt = now
            pendingRecoveryAt = nil
            publish(.connectedViaConfiguredHotspot(ssid), episodeID: nil, context: sampledContext)
            return
        }
        if prior?.isHealthyTarget == true {
            let eligibleAt = (lastHealthyTargetAt ?? now) + policy.recoveryCooldown
            if now >= eligibleAt {
                startEpisode(trigger: .closedPathLost, context: sampledContext)
            } else {
                pendingRecoveryAt = eligibleAt
                publish(
                    .failed(pathFailure(path)),
                    episodeID: nil,
                    context: sampledContext
                )
            }
            return
        }
        if let eligibleAt = pendingRecoveryAt, now >= eligibleAt {
            pendingRecoveryAt = nil
            startEpisode(trigger: .closedPathLost, context: sampledContext)
            return
        }
        if case .failed = publication.state, publication.episodeID != nil {
            return
        }
        switch path {
        case .healthyOther(let ssid):
            publish(.preservingCurrentNetwork(ssid), episodeID: nil, context: sampledContext)
        case .ordinaryDisconnected:
            publish(.waitingForConnection, episodeID: nil, context: sampledContext)
        case .partial(let failure):
            publish(.failed(failure), episodeID: nil, context: sampledContext)
        case .healthyTarget, .providerFailure:
            break
        }
    }
}

private extension TravelInternetHandoffCoordinator {
    func startEpisode(trigger: HandoffTrigger, context sampledContext: HandoffSessionContext) {
        guard isActive(sampledContext) else { return }
        guard episodeTask == nil else {
            pendingTrigger = trigger
            return
        }
        pendingTrigger = nil
        episodeSequence += 1
        let episodeID = "\(sampledContext.sessionID):\(episodeSequence)"
        let token = HandoffEpisodeToken(context: sampledContext, episodeID: episodeID)
        currentEpisodeID = episodeID
        currentEpisodeToken = token
        currentEpisodeTrigger = trigger
        reopenCancelledEpisodeID = nil
        publish(.handoffPending(episodeID: episodeID, trigger: trigger), episodeID: episodeID, context: sampledContext)
        episodeTask = Task { [weak self] in
            guard let self else { return }
            await self.runEpisode(token: token, trigger: trigger, context: sampledContext)
        }
    }

    func runEpisode(
        token: HandoffEpisodeToken,
        trigger: HandoffTrigger,
        context sampledContext: HandoffSessionContext
    ) async {
        let id = token.episodeID
        let startedAt = await scheduler.now()
        let deadline = startedAt + policy.episodeBudget
        var lastFailure = deadlineFailure()
        do {
            try requireCurrent(token: token, context: sampledContext)
            if let authorizationFailure = await engine.authorizeEpisode(token) {
                try requireCurrent(token: token, context: sampledContext)
                await finishFailure(authorizationFailure, token: token, context: sampledContext)
                return
            }
            try requireCurrent(token: token, context: sampledContext)
            for attempt in 1...policy.maxAttempts {
                try requireCurrent(token: token, context: sampledContext)
                guard await scheduler.now() < deadline else { break }
                let result = try await engine.performAttempt(
                    context: sampledContext,
                    episode: token,
                    attempt: attempt,
                    deadline: deadline,
                    scheduler: scheduler,
                    phase: { [weak self] phase in
                        await self?.publishPhase(
                            phase,
                            attempt: attempt,
                            episodeID: id,
                            context: sampledContext
                        )
                    }
                )
                try requireCurrent(token: token, context: sampledContext)
                switch result {
                case .succeeded:
                    await finishSuccess(token: token, context: sampledContext)
                    return
                case .failed(let failure):
                    lastFailure = failure
                    guard failure.retryable, attempt < policy.maxAttempts else {
                        await finishFailure(failure, token: token, context: sampledContext)
                        return
                    }
                }
                guard try await backoff(after: attempt, deadline: deadline, token: token, context: sampledContext) else {
                    break
                }
            }
            await finishFailure(
                lastFailure.kind == .deadlineExceeded ? lastFailure : deadlineFailure(),
                token: token,
                context: sampledContext
            )
        } catch is CancellationError {
            await finishCancellation(token: token, context: sampledContext)
        } catch {
            await finishFailure(lastFailure, token: token, context: sampledContext)
        }
    }

    func backoff(
        after attempt: Int,
        deadline: Duration,
        token: HandoffEpisodeToken,
        context sampledContext: HandoffSessionContext
    ) async throws -> Bool {
        let id = token.episodeID
        let index = attempt - 1
        guard policy.backoffs.indices.contains(index) else { return false }
        let delay = policy.backoffs[index]
        let now = await scheduler.now()
        guard now + delay < deadline else { return false }
        publish(
            .retrying(episodeID: id, nextAttempt: attempt + 1, delay: delay),
            episodeID: id,
            context: sampledContext
        )
        try await scheduler.sleep(for: delay)
        try requireCurrent(token: token, context: sampledContext)
        return true
    }

    func publishPhase(
        _ phase: HandoffAttemptPhase,
        attempt: Int,
        episodeID: String,
        context sampledContext: HandoffSessionContext
    ) {
        guard isCurrent(id: episodeID, context: sampledContext) else { return }
        switch phase {
        case .associating:
            publish(.associating(episodeID: episodeID, attempt: attempt), episodeID: episodeID, context: sampledContext)
        case .verifying:
            publish(.verifying(episodeID: episodeID, attempt: attempt), episodeID: episodeID, context: sampledContext)
        }
    }

    func finishSuccess(
        token: HandoffEpisodeToken,
        context sampledContext: HandoffSessionContext
    ) async {
        let id = token.episodeID
        guard isCurrent(token: token, context: sampledContext) else { return }
        await engine.finishEpisode(token)
        guard !Task.isCancelled else {
            await finishCancellation(token: token, context: sampledContext)
            return
        }
        let finishedAt = await scheduler.now()
        guard !Task.isCancelled else {
            await finishCancellation(token: token, context: sampledContext)
            return
        }
        guard isCurrent(token: token, context: sampledContext) else { return }
        clearEpisode(id: id, preservePending: false)
        previousPath = .healthyTarget(sampledContext.targetSSID)
        lastHealthyTargetAt = finishedAt
        publish(
            .connectedViaConfiguredHotspot(sampledContext.targetSSID),
            episodeID: id,
            context: sampledContext
        )
    }

    func finishFailure(
        _ failure: HandoffFailure,
        token: HandoffEpisodeToken,
        context sampledContext: HandoffSessionContext
    ) async {
        let id = token.episodeID
        guard isCurrent(token: token, context: sampledContext) else { return }
        await engine.finishEpisode(token)
        guard !Task.isCancelled else {
            await finishCancellation(token: token, context: sampledContext)
            return
        }
        guard isCurrent(token: token, context: sampledContext) else { return }
        clearEpisode(id: id, preservePending: false)
        publish(.failed(failure), episodeID: id, context: sampledContext)
    }

    func finishCancellation(
        token: HandoffEpisodeToken,
        context sampledContext: HandoffSessionContext
    ) async {
        let id = token.episodeID
        guard currentEpisodeID == id else { return }
        await engine.cancelEpisode(token)
        guard currentEpisodeID == id else { return }
        let wasReopened = reopenCancelledEpisodeID == id
        let queuedTrigger = pendingTrigger
        clearEpisode(id: id, preservePending: true)
        guard wasReopened, isActive(sampledContext) else { return }
        publish(.waitingForConnection, episodeID: nil, context: sampledContext)
        if let trigger = queuedTrigger, triggerIsEligible(trigger) {
            pendingTrigger = nil
            startEpisode(trigger: trigger, context: sampledContext)
        } else {
            pendingTrigger = nil
        }
    }

    func clearEpisode(id: String, preservePending: Bool) {
        guard currentEpisodeID == id else { return }
        episodeTask = nil
        currentEpisodeID = nil
        currentEpisodeToken = nil
        currentEpisodeTrigger = nil
        reopenCancelledEpisodeID = nil
        if !preservePending {
            pendingTrigger = nil
        }
    }
}

private extension TravelInternetHandoffCoordinator {
    func cancelClosedEpisodeForReopen(
        context sampledContext: HandoffSessionContext
    ) async {
        guard let id = currentEpisodeID,
              let token = currentEpisodeToken,
              currentEpisodeTrigger?.isClosedOwned == true,
              let task = episodeTask else { return }
        reopenCancelledEpisodeID = id
        task.cancel()
        publish(.waitingForConnection, episodeID: nil, context: sampledContext)
        await engine.cancelEpisode(token)
    }

    func publish(
        _ state: TravelInternetRuntimeState,
        episodeID: String?,
        context sampledContext: HandoffSessionContext
    ) {
        guard isActive(sampledContext) else { return }
        publication = TravelInternetStatePublication(
            sessionID: sampledContext.sessionID,
            generation: sampledContext.generation,
            episodeID: episodeID,
            state: state
        )
    }

    func isActive(_ sampledContext: HandoffSessionContext) -> Bool {
        context?.sessionID == sampledContext.sessionID
            && context?.generation == sampledContext.generation
    }

    func isCurrent(id: String, context sampledContext: HandoffSessionContext) -> Bool {
        isActive(sampledContext) && currentEpisodeID == id
    }

    func isCurrent(
        token: HandoffEpisodeToken,
        context sampledContext: HandoffSessionContext
    ) -> Bool {
        isActive(sampledContext) && currentEpisodeToken == token
    }

    func requireCurrent(id: String, context sampledContext: HandoffSessionContext) throws {
        try Task.checkCancellation()
        guard isCurrent(id: id, context: sampledContext) else { throw CancellationError() }
    }

    func requireCurrent(
        token: HandoffEpisodeToken,
        context sampledContext: HandoffSessionContext
    ) throws {
        try Task.checkCancellation()
        guard isCurrent(token: token, context: sampledContext) else {
            throw CancellationError()
        }
    }

    func lidFailure(_ failure: ConnectivityProviderFailure?) -> HandoffFailure {
        HandoffFailure(
            kind: .lidProviderFailed,
            detail: failure?.detail ?? "Lid state is unavailable.",
            retryable: true
        )
    }

    func deadlineFailure() -> HandoffFailure {
        HandoffFailure(
            kind: .deadlineExceeded,
            detail: "The iPhone handoff did not complete within 30 seconds.",
            retryable: false
        )
    }

    var hasLatchedEpisodeFailure: Bool {
        if case .failed = publication.state, publication.episodeID != nil {
            return true
        }
        return false
    }

    func triggerIsEligible(_ trigger: HandoffTrigger) -> Bool {
        switch trigger {
        case .initiallyClosed, .lidClosed, .closedPathLost:
            return previousLid == .closed
        case .openDisconnection:
            return previousLid == .open
        case .explicitRetry:
            return true
        }
    }

    func pathFailure(_ path: HandoffPathClassification) -> HandoffFailure {
        switch path {
        case .ordinaryDisconnected:
            return HandoffFailure(
                kind: .partialConnectivity,
                detail: "The verified iPhone path disconnected; recovery is cooling down.",
                retryable: true
            )
        case .healthyOther(let ssid):
            return HandoffFailure(
                kind: .partialConnectivity,
                detail: "The default path moved to '\(ssid.stringValue)'; recovery is cooling down.",
                retryable: true
            )
        case .partial(let failure), .providerFailure(let failure):
            return failure
        case .healthyTarget:
            return HandoffFailure(
                kind: .partialConnectivity,
                detail: "The iPhone path is healthy.",
                retryable: false
            )
        }
    }
}
