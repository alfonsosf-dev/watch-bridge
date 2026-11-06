import CoreBluetooth
import UIKit
import os.log

/// Phase-1 internet tunnel probe (local addition for Xiaomi Watch 5).
///
/// The watch opens an L2CAP channel to the PSM we publish (PSM is exposed on
/// the …B7 characteristic) and sends framed requests:
///
///   frame   = [type: 1 byte][length: 4 bytes big-endian][payload]
///   0x01 ECHO   payload → reply 0x81 with the same payload
///   0x02 FETCH  payload = URL (UTF-8) → reply 0x82 with
///               [httpStatus: 2 BE][iosElapsedMs: 4 BE][body]   (status 0 = error, body = message)
///
/// The goal is to measure BLE throughput and whether iOS keeps serving these
/// requests while the app is in the background / the phone is locked.
final class TunnelServer: NSObject, StreamDelegate {

    static let shared = TunnelServer()

    private let logger = Logger(subsystem: "com.wearos.ancsbridge", category: "Tunnel")
    private var channel: CBL2CAPChannel?
    private var inBuf = Data()
    private var outBuf = Data()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private(set) var requestCount = 0

    // MARK: - Channel lifecycle

    func accept(_ newChannel: CBL2CAPChannel) {
        close()
        channel = newChannel
        inBuf.removeAll()
        outBuf.removeAll()
        for stream in [newChannel.inputStream as Stream, newChannel.outputStream as Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        logger.info("L2CAP channel opened (psm=\(newChannel.psm))")
    }

    func close() {
        guard let ch = channel else { return }
        for stream in [ch.inputStream as Stream, ch.outputStream as Stream] {
            stream.close()
            stream.remove(from: .main, forMode: .default)
        }
        channel = nil
        logger.info("L2CAP channel closed")
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred, .endEncountered:
            logger.info("L2CAP stream ended (event \(eventCode.rawValue))")
            close()
        default:
            break
        }
    }

    // MARK: - Framing

    private func readAvailable() {
        guard let input = channel?.inputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let n = input.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            inBuf.append(buffer, count: n)
        }
        parseFrames()
    }

    private func parseFrames() {
        while inBuf.count >= 5 {
            let header = [UInt8](inBuf.prefix(5))
            let length = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
            guard inBuf.count >= 5 + length else { return }
            let payload = Data(inBuf.dropFirst(5).prefix(length))
            inBuf = Data(inBuf.dropFirst(5 + length))
            handleFrame(type: header[0], payload: payload)
        }
    }

    private func handleFrame(type: UInt8, payload: Data) {
        requestCount += 1
        switch type {
        case 0x01:
            send(type: 0x81, payload: payload)
        case 0x02:
            fetch(payload)
        default:
            logger.warning("Unknown tunnel frame type \(type)")
        }
    }

    private func fetch(_ payload: Data) {
        guard let text = String(data: payload, encoding: .utf8), let url = URL(string: text) else {
            sendFetchReply(status: 0, elapsedMs: 0, body: Data("bad url".utf8))
            return
        }
        let start = Date()
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "tunnel-fetch") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        let state = UIApplication.shared.applicationState == .background ? "background" : "foreground"
        logger.info("FETCH \(url.absoluteString, privacy: .public) (app \(state, privacy: .public))")

        session.dataTask(with: url) { [weak self] data, response, error in
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                if let error = error {
                    self?.sendFetchReply(status: 0, elapsedMs: elapsed, body: Data(error.localizedDescription.utf8))
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self?.sendFetchReply(status: status, elapsedMs: elapsed, body: data ?? Data())
                }
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
        }.resume()
    }

    private func sendFetchReply(status: Int, elapsedMs: Int, body: Data) {
        var payload = Data()
        payload.append(UInt8((status >> 8) & 0xFF))
        payload.append(UInt8(status & 0xFF))
        for shift in stride(from: 24, through: 0, by: -8) {
            payload.append(UInt8((elapsedMs >> shift) & 0xFF))
        }
        payload.append(body)
        send(type: 0x82, payload: payload)
    }

    private func send(type: UInt8, payload: Data) {
        var frame = Data([type])
        let length = payload.count
        for shift in stride(from: 24, through: 0, by: -8) {
            frame.append(UInt8((length >> shift) & 0xFF))
        }
        frame.append(payload)
        outBuf.append(frame)
        flush()
    }

    private func flush() {
        guard let output = channel?.outputStream else { return }
        while !outBuf.isEmpty && output.hasSpaceAvailable {
            let chunk = min(outBuf.count, 4096)
            let written = outBuf.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base, maxLength: chunk)
            }
            if written <= 0 { break }
            outBuf.removeFirst(written)
        }
    }
}
