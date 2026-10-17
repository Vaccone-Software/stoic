import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A minimal HTTP/1.1 server on the loopback interface, for the tests that
/// need a real TCP connection: whether a transport that stops reading really
/// makes the server wait, and what a connection that dies mid-body leaves a
/// reader. A `URLProtocol` stub cannot say either: it hands the session its
/// bytes whatever the session decides about reading.
///
/// It serves one handler for every connection: the handler gets the request's
/// path and headers, and writes whatever it likes, bytes at a time, with
/// blocking sends (which is what makes a stalled reader visible: the send
/// does not return). Nothing leaves the machine.
final class LoopbackServer: Sendable {
    /// One accepted connection, as the handler sees it.
    struct Connection: Sendable {
        let path: String
        let headers: [String: String]
        fileprivate let descriptor: Int32
        fileprivate let server: LoopbackServer

        /// Sends all of `bytes`, blocking while the peer's window is closed.
        /// Returns `false` when the peer has gone.
        func write(_ bytes: [UInt8]) -> Bool {
            var sent = 0
            while sent < bytes.count {
                let count = bytes.withUnsafeBytes { buffer -> Int in
                    #if canImport(Darwin)
                    unsafe send(descriptor, buffer.baseAddress! + sent, buffer.count - sent, 0)
                    #else
                    unsafe send(descriptor, buffer.baseAddress! + sent, buffer.count - sent, Int32(MSG_NOSIGNAL))
                    #endif
                }
                if count <= 0 {
                    server.state.withLock { $0.peerGone += 1 }
                    return false
                }
                sent += count
                server.state.withLock { $0.written += count }
            }
            return true
        }

        /// The status line and headers of a response.
        func writeHead(_ status: Int = 200, _ headers: [String: String] = [:]) -> Bool {
            var text = "HTTP/1.1 \(status) OK\r\n"
            for (name, value) in headers { text += "\(name): \(value)\r\n" }
            text += "Connection: close\r\n\r\n"
            return write(Array(text.utf8))
        }
    }

    private struct State {
        var written = 0
        var peerGone = 0
        var accepted = 0
    }

    typealias Handler = @Sendable (Connection) -> Void

    let port: UInt16
    private let listener: Int32
    private let state = Mutex(State())

    /// Bytes the server has sent so far, over every connection.
    var bytesWritten: Int { state.withLock { $0.written } }
    /// How many sends found the peer gone.
    var peerGoneCount: Int { state.withLock { $0.peerGone } }
    var acceptedCount: Int { state.withLock { $0.accepted } }

    init(_ handler: @escaping Handler) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        unsafe setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe getsockname(listener, $0, &length)
            }
        }
        self.listener = listener
        port = UInt16(bigEndian: address.sin_port)
        let server = self
        Thread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                server.state.withLock { $0.accepted += 1 }
                #if canImport(Darwin)
                var one: Int32 = 1
                unsafe setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                #endif
                Thread {
                    if let request = Self.readRequest(client) {
                        handler(Connection(path: request.path, headers: request.headers, descriptor: client, server: server))
                    }
                    close(client)
                }.start()
            }
        }.start()
    }

    /// Stops accepting; connections already served finish their handlers.
    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private static func readRequest(_ client: Int32) -> (path: String, headers: [String: String])? {
        var received: [UInt8] = []
        var byte: UInt8 = 0
        while received.count < 16_384 {
            let count = unsafe recv(client, &byte, 1, 0)
            if count <= 0 { return nil }
            received.append(byte)
            if received.suffix(4) == [13, 10, 13, 10] { break }
        }
        let lines = String(decoding: received, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (String(first[1]), headers)
    }
}
