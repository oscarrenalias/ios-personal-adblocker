#if canImport(Darwin)
import Foundation
import Darwin
import dnssd
import IBlockerKit

/// Resolves through the system resolver on the physical network interface
/// using `DNSServiceQueryRecord`, so the answer comes from whatever DNS the
/// current network (Wi-Fi/cellular, VPN-free) hands out. It never queries the
/// tunnel's own virtual DNS addresses, which would loop back into the tunnel.
public struct NetworkDNSUpstream: DNSUpstream {
    /// Returns the physical interface index to query on, or nil when no
    /// usable network is available.
    public typealias InterfaceIndexProvider = @Sendable () -> UInt32?

    private let interfaceIndex: InterfaceIndexProvider
    private let timeout: TimeInterval

    public init(interfaceIndex: @escaping InterfaceIndexProvider, timeout: TimeInterval = 3) {
        self.interfaceIndex = interfaceIndex
        self.timeout = timeout
    }

    public func resolve(_ query: Data) async throws -> Data {
        let parsed: DNSQuery
        do {
            parsed = try DNSParser.parseQuery(query)
        } catch {
            throw UpstreamError.badResponse
        }
        // Index 0 is kDNSServiceInterfaceIndexAny, which could route via the tunnel.
        guard let index = interfaceIndex(), index != 0 else {
            throw UpstreamError.connectionFailed("no network interface")
        }

        let session = QuerySession(name: parsed.questionName, type: parsed.qtype,
                                   klass: parsed.qclass, interfaceIndex: index, timeout: timeout)
        let outcome = try await session.run()
        switch outcome {
        case .answer(let rcode, let records):
            return DNSResponseBuilder.response(for: parsed, rcode: rcode, records: records)
        }
    }
}

private enum QueryOutcome {
    case answer(rcode: UInt8, records: [DNSResponseBuilder.ResourceRecord])
}

/// One in-flight dns_sd query. All mutable state is touched only on `queue`.
private final class QuerySession: @unchecked Sendable {
    private let name: String
    private let type: UInt16
    private let klass: UInt16
    private let interfaceIndex: UInt32
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "NetworkDNSUpstream.query")

    private var serviceRef: DNSServiceRef?
    private var completion: DNSQueryCompletion
    private var continuation: CheckedContinuation<QueryOutcome, Error>?
    private var selfRetain: Unmanaged<QuerySession>?
    private var finished = false

    init(name: String, type: UInt16, klass: UInt16, interfaceIndex: UInt32, timeout: TimeInterval) {
        self.name = name
        self.type = type
        self.klass = klass
        self.interfaceIndex = interfaceIndex
        self.timeout = timeout
        self.completion = DNSQueryCompletion(qtype: type)
    }

    func run() async throws -> QueryOutcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<QueryOutcome, Error>) in
                queue.async { self.start(cont) }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ cont: CheckedContinuation<QueryOutcome, Error>) {
        continuation = cont
        if finished {
            // Cancelled before start.
            finish(.failure(CancellationError()))
            return
        }
        let retained = Unmanaged.passRetained(self)
        selfRetain = retained

        var ref: DNSServiceRef?
        let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)
        let err = DNSServiceQueryRecord(&ref, flags, interfaceIndex, name, type, klass,
                                        { _, flags, _, errorCode, fullname, rrtype, rrclass, rdlen, rdata, ttl, ctx in
            guard let ctx else { return }
            let session = Unmanaged<QuerySession>.fromOpaque(ctx).takeUnretainedValue()
            var bytes: [UInt8] = []
            if let rdata, rdlen > 0 {
                bytes = [UInt8](UnsafeBufferPointer(start: rdata.assumingMemoryBound(to: UInt8.self),
                                                    count: Int(rdlen)))
            }
            let owner = fullname.map { String(cString: $0) } ?? ""
            session.handle(flags: flags, errorCode: errorCode, owner: owner,
                           type: rrtype, klass: rrclass, ttl: ttl, rdata: bytes)
        }, retained.toOpaque())

        guard err == kDNSServiceErr_NoError, let ref else {
            finish(.failure(UpstreamError.connectionFailed("DNSServiceQueryRecord error \(err)")))
            return
        }
        serviceRef = ref
        let status = DNSServiceSetDispatchQueue(ref, queue)
        guard status == kDNSServiceErr_NoError else {
            finish(.failure(UpstreamError.connectionFailed("DNSServiceSetDispatchQueue error \(status)")))
            return
        }
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            finish(.failure(UpstreamError.timeout))
        }
    }

    // Runs on `queue` (dns_sd dispatches callbacks there).
    fileprivate func handle(flags: DNSServiceFlags, errorCode: DNSServiceErrorType, owner: String,
                            type: UInt16, klass: UInt16, ttl: UInt32, rdata: [UInt8]) {
        guard !finished else { return }
        if errorCode != kDNSServiceErr_NoError {
            switch errorCode {
            case DNSServiceErrorType(kDNSServiceErr_NoSuchName):
                apply(completion.negative(.noSuchName))
            case DNSServiceErrorType(kDNSServiceErr_NoSuchRecord):
                apply(completion.negative(.noSuchRecord))
            default:
                finish(.failure(UpstreamError.connectionFailed("dns_sd error \(errorCode)")))
            }
            return
        }
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
            completion.recordAdded(.init(name: Self.wireName(owner), type: type, class: klass, ttl: ttl, rdata: rdata))
        }
        if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
            apply(completion.batchEnded())
        }
    }

    private func apply(_ decision: DNSQueryCompletion.Decision) {
        if case .complete(let rcode, let records) = decision {
            finish(.success(.answer(rcode: rcode, records: records)))
        }
    }

    private func finish(_ result: Result<QueryOutcome, Error>) {
        if finished, continuation == nil { return }
        finished = true
        if let ref = serviceRef {
            DNSServiceRefDeallocate(ref)
            serviceRef = nil
        }
        selfRetain?.release()
        selfRetain = nil
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }

    private static func wireName(_ dotted: String) -> [UInt8] {
        var out: [UInt8] = []
        for label in dotted.split(separator: ".", omittingEmptySubsequences: true) {
            let utf8 = Array(label.utf8.prefix(63))
            out.append(UInt8(utf8.count))
            out.append(contentsOf: utf8)
        }
        out.append(0)
        return out
    }
}
#endif
