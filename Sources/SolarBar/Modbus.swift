import Foundation
import Network

enum ModbusError: LocalizedError, Equatable {
    case timeout, closed, invalidResponse, exception(UInt8), noData, network(String)

    var errorDescription: String? {
        switch self {
        case .timeout: "The GX did not respond. Check its address, network, and Modbus TCP setting."
        case .closed: "The GX closed the connection before returning a reading."
        case .invalidResponse: "The server did not return a valid Victron Modbus response."
        case .exception(let code): "The GX returned Modbus error \(code). Check that system service ID 100 is available."
        case .noData: "The GX responded but reported no power readings. Check its System Overview."
        case .network(let reason): "Cannot reach GX: \(reason)"
        }
    }
}

struct RegisterRead: Sendable {
    let start: UInt16
    let count: UInt16
    let id: UInt16

    var request: Data {
        // MBAP header, system unit 100, function 4 (Read Input Registers).
        Data(bytes(id) + [0, 0, 0, 6, 100, 4] + bytes(start) + bytes(count))
    }

    func bodyLength(_ header: Data) throws -> Int {
        let h = Array(header)
        guard h.count == 7, word(h[0], h[1]) == id, h[2] == 0, h[3] == 0, h[6] == 100 else {
            throw ModbusError.invalidResponse
        }
        let pdu = Int(word(h[4], h[5])) - 1
        guard pdu == 2 || pdu == 2 + Int(count) * 2 else { throw ModbusError.invalidResponse }
        return pdu
    }

    func decode(_ body: Data) throws -> [UInt16: UInt16] {
        let p = Array(body)
        if p.count == 2, p[0] == 0x84 { throw ModbusError.exception(p[1]) }
        guard p.count == 2 + Int(count) * 2, p[0] == 4, Int(p[1]) == Int(count) * 2 else {
            throw ModbusError.invalidResponse
        }
        var values: [UInt16: UInt16] = [:]
        for i in 0..<Int(count) {
            let offset = 2 + 2 * i
            values[start + UInt16(i)] = word(p[offset], p[offset + 1])
        }
        return values
    }

    private func bytes(_ word: UInt16) -> [UInt8] { [UInt8(word >> 8), UInt8(truncatingIfNeeded: word)] }
    private func word(_ hi: UInt8, _ lo: UInt8) -> UInt16 { (UInt16(hi) << 8) | UInt16(lo) }
}

enum GXClient {
    static func sample(_ settings: ConnectionSettings) async throws -> Telemetry {
        try await GXPoll(host: settings.host, port: settings.port).run()
    }
}

// All mutable state and Network callbacks are confined to the poll's serial queue.
private final class GXPoll: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SolarBar.GXPoll")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Telemetry, any Error>?
    private var cancelled = false
    private var started = false
    private var pending: [(UInt16, UInt16)] = [(840, 4), (850, 1), (808, 19), (860, 1)]
    private var registers: [UInt16: UInt16] = [:]
    private var id: UInt16 = 0
    private var firstException: ModbusError?

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func run() async throws -> Telemetry {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func start(_ continuation: CheckedContinuation<Telemetry, any Error>) {
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.continuation != nil else { return }
            switch state {
            case .ready where !self.started:
                self.started = true
                self.next()
            case .failed(let error): self.finish(.failure(ModbusError.network(error.localizedDescription)))
            case .cancelled: self.finish(.failure(ModbusError.closed))
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in self?.finish(.failure(ModbusError.timeout)) }
        connection.start(queue: queue)
    }

    private func next() {
        guard continuation != nil else { return }
        guard !pending.isEmpty else {
            let value = Telemetry(registers: registers)
            finish(value.hasData || value.source != nil ? .success(value) : .failure(firstException ?? .noData))
            return
        }
        let (start, count) = pending.removeFirst()
        id &+= 1
        let read = RegisterRead(start: start, count: count, id: id)
        connection.send(content: read.request, completion: .contentProcessed { error in
            if let error { self.finish(.failure(ModbusError.network(error.localizedDescription))); return }
            self.receive(7) { header in
                do {
                    self.receive(try read.bodyLength(header)) { body in self.process(body, for: read) }
                } catch { self.finish(.failure(error)) }
            }
        })
    }

    private func receive(_ size: Int, handler: @escaping @Sendable (Data) -> Void) {
        guard continuation != nil else { return }
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { data, _, _, error in
            guard self.continuation != nil else { return }
            if let error { self.finish(.failure(ModbusError.network(error.localizedDescription))); return }
            guard let data, data.count == size else { self.finish(.failure(ModbusError.closed)); return }
            handler(data)
        }
    }

    private func process(_ body: Data, for read: RegisterRead) {
        do {
            registers.merge(try read.decode(body)) { _, new in new }
        } catch let error as ModbusError {
            if error == .exception(2) {
                // Some GX versions reject a whole range when any single reading is unavailable.
                if read.count > 1 {
                    let left = read.count / 2
                    pending.insert(contentsOf: [(read.start, left), (read.start + left, read.count - left)], at: 0)
                } else if firstException == nil { firstException = error }
            } else { finish(.failure(error)); return }
        } catch { finish(.failure(error)); return }
        next()
    }

    private func finish(_ result: Result<Telemetry, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
