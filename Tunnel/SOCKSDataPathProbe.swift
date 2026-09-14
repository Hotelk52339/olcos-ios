import Foundation
import Network

// boc #484: probe the EXISTING extension listener, not MobileRuntime.Ping (which
// starts a second client). URLSession's optional SOCKS proxy can fall back to
// direct; a raw loopback connection has no alternate route. A SOCKS greeting or
// CONNECT alone is not health: require a framed DNS reply after sending a query
// through the remote TCP stream. The configured IPv4 OS resolver is the target.
final class SOCKSDataPathProbe {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let host: String
    private let transactionID = UInt16.random(in: 0...UInt16.max)
    private var deadline: DispatchSourceTimer?
    private var completion: ((Bool) -> Void)?
    private var beganHandshake = false

    init?(port: Int, dnsHost: String, queue: DispatchQueue) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0),
              port.rawValue != 0, VPNConfig.supportsPacketDNS(dnsHost) else { return nil }
        self.connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.host = dnsHost
        self.queue = queue
    }

    /// All methods/callbacks run on the provider's serial work queue. Exactly
    /// one completion; one absolute deadline covers connect, send and every read.
    func start(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(false) }
        deadline = timer
        timer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.completion != nil else { return }
            switch state {
            case .ready:
                guard !self.beganHandshake else { return }
                self.beganHandshake = true
                self.greet()
            case .failed, .cancelled: self.finish(false)
            default: break // `.waiting` is bounded by the same absolute deadline.
            }
        }
        connection.start(queue: queue)
    }

    func cancel() { finish(false) }

    private func finish(_ success: Bool) {
        guard let callback = completion else { return }
        completion = nil
        deadline?.cancel()
        deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        callback(success)
    }

    private func send(_ data: Data, then: @escaping () -> Void) {
        guard completion != nil else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, self.completion != nil else { return }
            if error != nil { self.finish(false) } else { then() }
        })
    }

    private func read(_ count: Int, collected: Data = Data(), then: @escaping (Data) -> Void) {
        guard completion != nil, count > 0, count <= 4096 else { finish(false); return }
        let remaining = count - collected.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, eof, error in
            guard let self, self.completion != nil else { return }
            let bytes = collected + (data ?? Data())
            // A final TCP segment may contain the whole answer AND EOF.
            if error == nil, bytes.count == count { then(bytes) }
            else if error != nil || eof || data?.isEmpty != false { self.finish(false) }
            else { self.read(count, collected: bytes, then: then) }
        }
    }

    private func greet() {
        send(Data([5, 1, 0])) { [weak self] in
            self?.read(2) { [weak self] reply in
                guard let self else { return }
                guard reply == Data([5, 0]) else { self.finish(false); return }
                self.connectResolver()
            }
        }
    }

    private func connectResolver() {
        let address = host.split(separator: ".").compactMap { UInt8($0) }
        send(Data([5, 1, 0, 1] + address + [0, 53])) { [weak self] in
            self?.read(4) { [weak self] header in
                guard let self else { return }
                guard header[0] == 5, header[1] == 0, header[2] == 0 else {
                    self.finish(false); return
                }
                switch header[3] {
                case 1: self.readBoundAddress(6)
                case 4: self.readBoundAddress(18)
                case 3:
                    self.read(1) { [weak self] size in
                        guard size[0] > 0 else { self?.finish(false); return }
                        self?.readBoundAddress(Int(size[0]) + 2)
                    }
                default: self.finish(false)
                }
            }
        }
    }

    private func readBoundAddress(_ count: Int) {
        read(count) { [weak self] _ in self?.queryDNS() }
    }

    private func queryDNS() {
        let query = VPNDataPathHealth.dnsQuery(id: transactionID)
        send(Data([UInt8(query.count >> 8), UInt8(query.count & 255)]) + query) { [weak self] in
            self?.read(2) { [weak self] length in
                guard let self else { return }
                let count = Int(length[0]) * 256 + Int(length[1])
                guard (17...4096).contains(count) else { self.finish(false); return }
                self.read(count) { [weak self] response in
                    guard let self else { return }
                    self.finish(VPNDataPathHealth.validDNSResponse(response, id: self.transactionID))
                }
            }
        }
    }
}
// eoc #484
