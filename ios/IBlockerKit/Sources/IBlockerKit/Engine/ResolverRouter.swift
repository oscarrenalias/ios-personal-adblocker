import Foundation

public enum ResolverRouterError: Error, Equatable, Sendable {
    case timeout
    case alternativeFailed(String)
}

/// Routes each query to the network's DNS or the user-selected alternative.
///
/// Rules, in order: `local` / `*.local` get NXDOMAIN with no upstream; with the
/// alternative off everything goes to `network`; network-only names go to
/// `network` without probing. Alternative-on routing (health, failover,
/// probes) is layered on top of this. With the alternative healthy, queries go
/// to it with a 2 s timeout; failures follow the fallback policy.
public final class ResolverRouter: DNSUpstream, @unchecked Sendable {
    private static let log = Log(category: "router")

    public typealias Alternative = (upstream: DNSUpstream, name: String, encrypted: Bool)

    /// Router-enforced limit on a single alternative query.
    public static let alternativeTimeout: TimeInterval = 2

    private let network: DNSUpstream
    private let alternative: Alternative?
    private let policy: FallbackPolicy
    private let onStatusChange: (@Sendable (ResolverStatus) -> Void)?
    private let lock = NSLock()
    private var breaker: CircuitBreaker
    private var lastStatus: ResolverStatus

    public init(
        network: DNSUpstream,
        alternative: Alternative?,
        policy: FallbackPolicy,
        breaker: CircuitBreaker? = nil,
        onStatusChange: (@Sendable (ResolverStatus) -> Void)? = nil
    ) {
        self.onStatusChange = onStatusChange
        self.network = network
        self.alternative = alternative
        self.policy = policy
        self.breaker = breaker ?? CircuitBreaker(
            name: alternative?.name ?? "none",
            effect: policy == .networkDNS ? "using network DNS" : "queries fail"
        )
        self.lastStatus = .network
        lastStatus = lock.withLock { computeStatus() }
    }

    /// Current routing status: off -> network, healthy -> alternative,
    /// down + network fallback -> fallingBack, down + no fallback -> failing.
    public var status: ResolverStatus {
        lock.withLock { computeStatus() }
    }

    /// The network changed: reset the breaker and probe the alternative right away.
    /// No-op when the alternative is off.
    public func networkChanged() {
        guard let alternative else { return }
        let (changed, probe): (ResolverStatus?, Int?) = lock.withLock {
            breaker.networkChange()
            return (noteStatusChange(), startProbeIfDue())
        }
        notify(changed)
        if let generation = probe { runProbe(alternative, generation: generation) }
    }

    public func resolve(_ query: Data) async throws -> Data {
        do {
            return try await resolveWithRoute(query).0
        } catch let error as RoutedError {
            throw error.underlying
        }
    }

    public func resolveWithRoute(_ query: Data) async throws -> (Data, UpstreamRoute) {
        let parsed = try? DNSParser.parseQuery(query)

        if let parsed, Self.isLocal(parsed.questionName) {
            Self.logRoute(parsed, rule: "local-nxdomain")
            return (DNSResponseBuilder.nxdomain(for: parsed), .local)
        }
        if alternative == nil {
            Self.logRoute(parsed, rule: "alternative-off")
            return try await viaNetwork(query, route: .network)
        }
        if let parsed, NetworkOnlyNames.matches(parsed.questionName) {
            Self.logRoute(parsed, rule: "network-only")
            return try await viaNetwork(query, route: .networkOnlyName)
        }
        guard let alternative else { return try await viaNetwork(query, route: .network) }
        return try await resolveViaAlternative(query, parsed: parsed, alternative: alternative)
    }

    private func viaNetwork(_ query: Data, route: UpstreamRoute) async throws -> (Data, UpstreamRoute) {
        do {
            return (try await network.resolve(query), route)
        } catch {
            throw RoutedError(route: route, underlying: error)
        }
    }

    /// Tries the alternative when its breaker is healthy; otherwise (or on failure)
    /// applies the fallback policy. Unparseable queries follow the same path.
    private func resolveViaAlternative(_ query: Data, parsed: DNSQuery?, alternative: Alternative) async throws -> (Data, UpstreamRoute) {
        let attempt: (healthy: Bool, generation: Int) = lock.withLock { (!breaker.isDown, breaker.generation) }
        guard attempt.healthy else {
            let probe: Int? = lock.withLock { startProbeIfDue() }
            if let generation = probe { runProbe(alternative, generation: generation) }
            Self.logRoute(parsed, rule: "failing")
            return try await fallBack(query, parsed: parsed, error: "alternative resolver marked down", elapsed: 0)
        }

        Self.logRoute(parsed, rule: "alternative")
        let start = Date()
        do {
            let response = try await Self.withTimeout(Self.alternativeTimeout) {
                try await alternative.upstream.resolve(query)
            }
            let changed: ResolverStatus? = lock.withLock {
                breaker.recordSuccess(generation: attempt.generation)
                return noteStatusChange()
            }
            notify(changed)
            return (response, .alternative)
        } catch {
            let changed: ResolverStatus? = lock.withLock {
                breaker.recordFailure(generation: attempt.generation)
                return noteStatusChange()
            }
            notify(changed)
            return try await fallBack(
                query, parsed: parsed, error: "\(error)", elapsed: Date().timeIntervalSince(start)
            )
        }
    }

    /// Must be called with the lock held. Returns the generation to tag the probe with
    /// when the breaker says a probe is due.
    private func startProbeIfDue() -> Int? {
        breaker.probeDue(Date()) ? breaker.generation : nil
    }

    /// Fire-and-forget probe: A apple.com, IN, RD, 2 s timeout; NOERROR is success.
    private func runProbe(_ alternative: Alternative, generation: Int) {
        let query = Self.probeQuery()
        Task.detached { [self] in
            do {
                let response = try await Self.withTimeout(Self.alternativeTimeout) {
                    try await alternative.upstream.resolve(query)
                }
                guard response.count >= 12, response[3] & 0x0F == 0 else {
                    let rcode = response.count >= 4 ? Int(response[3] & 0x0F) : -1
                    let changed: ResolverStatus? = lock.withLock {
                        breaker.probeFailed(generation: generation, error: "rcode \(rcode)")
                        return noteStatusChange()
                    }
                    notify(changed)
                    return
                }
                let changed: ResolverStatus? = lock.withLock {
                    breaker.probeSucceeded(generation: generation)
                    return noteStatusChange()
                }
                notify(changed)
            } catch {
                let changed: ResolverStatus? = lock.withLock {
                    breaker.probeFailed(generation: generation, error: "\(error)")
                    return noteStatusChange()
                }
                notify(changed)
            }
        }
    }

    /// Must be called with the lock held.
    private func computeStatus() -> ResolverStatus {
        guard let alternative else { return .network }
        if !breaker.isDown { return .alternative(name: alternative.name, encrypted: alternative.encrypted) }
        return policy == .networkDNS ? .fallingBack(name: alternative.name) : .failing(name: alternative.name)
    }

    /// Invokes the status-change callback. Must be called with the lock released.
    private func notify(_ status: ResolverStatus?) {
        if let status { onStatusChange?(status) }
    }

    /// Must be called with the lock held. Logs when the status differs from the last one seen
    /// and returns the new status in that case, so the caller can `notify` after unlocking.
    private func noteStatusChange() -> ResolverStatus? {
        let new = computeStatus()
        guard new != lastStatus else { return nil }
        let old = lastStatus
        lastStatus = new
        Self.log.notice("resolver status \(old) -> \(new), encrypted \(Self.isEncrypted(new) ? "yes" : "no")")
        return new
    }

    private static func isEncrypted(_ status: ResolverStatus) -> Bool {
        if case .alternative(_, let encrypted) = status { return encrypted }
        return false
    }

    private static func probeQuery() -> Data {
        var bytes: [UInt8] = [
            UInt8.random(in: 0...255), UInt8.random(in: 0...255),
            0x01, 0x00,             // flags: RD
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        for label in "apple.com".split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01]) // root, A, IN
        return Data(bytes)
    }

    private func fallBack(_ query: Data, parsed: DNSQuery?, error: String, elapsed: TimeInterval) async throws -> (Data, UpstreamRoute) {
        switch policy {
        case .networkDNS:
            Self.logRoute(parsed, rule: "fallback")
            Self.log.debug("\(Self.target(parsed)) alternative failed, re-sending to network: \(error) after \(Int((elapsed * 1000).rounded())) ms")
            return try await viaNetwork(query, route: .fallback)
        case .none:
            Self.log.debug("\(Self.target(parsed)) alternative failed, no fallback: \(error)")
            throw RoutedError(route: .alternative, underlying: ResolverRouterError.alternativeFailed(error))
        }
    }

    /// Returns as soon as the operation finishes or the deadline passes, whichever is first.
    /// Unlike a task group, it does not wait for an operation that ignores cancellation;
    /// a late result from the abandoned operation is dropped.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = TimeoutGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let work = Task {
                    do { gate.finish(.success(try await operation())) }
                    catch { gate.finish(.failure(error)) }
                }
                let timer = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        gate.finish(.failure(ResolverRouterError.timeout))
                    } catch {}
                }
                gate.setTasks([work, timer])
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private static func target(_ query: DNSQuery?) -> String {
        guard let query else { return "unparseable" }
        return "domain=\(query.questionName) qtype=\(DNSRecordType.name(query.qtype))"
    }

    private static func isLocal(_ name: String) -> Bool {
        name == "local" || name.hasSuffix(".local")
    }

    private static func logRoute(_ query: DNSQuery?, rule: String) {
        log.debug(describe(query, rule: rule))
    }

    private static func describe(_ query: DNSQuery?, rule: String) -> String {
        guard let query else { return "route rule=\(rule) unparseable" }
        return "route domain=\(query.questionName) qtype=\(DNSRecordType.name(query.qtype)) rule=\(rule)"
    }
}

/// Resumes its continuation exactly once with the first result and cancels the other task.
private final class TimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false
    private var tasks: [Task<Void, Never>] = []

    func install(_ c: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = lock.withLock {
            if let r = pending { return r }
            continuation = c
            return nil
        }
        if let early { c.resume(with: early) }
    }

    func setTasks(_ t: [Task<Void, Never>]) {
        let cancelNow = lock.withLock { () -> Bool in
            tasks = t
            return done
        }
        if cancelNow { t.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<T, Error>) {
        let (c, toCancel): (CheckedContinuation<T, Error>?, [Task<Void, Never>]) = lock.withLock {
            guard !done else { return (nil, []) }
            done = true
            let c = continuation
            continuation = nil
            if c == nil { pending = result }
            return (c, tasks)
        }
        toCancel.forEach { $0.cancel() }
        c?.resume(with: result)
    }
}
