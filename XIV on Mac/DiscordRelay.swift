//
//  DiscordRelay.swift
//  XIV on Mac
//
//  Wine on macOS cannot create AF_UNIX sockets (WSAEAFNOSUPPORT), so xbridge cannot
//  reach Discord's IPC socket directly. This relay listens on 127.0.0.1 and forwards
//  each authenticated TCP connection to the Discord Unix socket as a plain byte stream.
//
//  Handshake from the client: <32 hex token chars> <1 slot digit '0'...'9'>.
//

import Darwin
import Foundation
import OSLog

final class DiscordRelay {
    static let shared = DiscordRelay()

    private let logger = Logger(subsystem: "XIV on Mac", category: "DiscordRelay")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var port: UInt16 = 0
    private var token = ""
    private var socketDirectory: () -> String = { "/tmp/" }

    private static let tokenLength = 32
    private static let helloTimeout: Int = 5

    private init() {}

    /// Starts the relay once per app run and returns its endpoint. Safe to call repeatedly.
    func start(socketDirectory: @escaping () -> String) throws -> (port: UInt16, token: String) {
        lock.lock()
        defer { lock.unlock() }
        self.socketDirectory = socketDirectory
        if listenFD >= 0 { return (port, token) }

        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw POSIXError(.EIO)
        }
        let newToken = bytes.map { String(format: "%02x", $0) }.joined()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }

        listenFD = fd
        port = UInt16(bigEndian: addr.sin_port)
        token = newToken
        logger.info("[relay] listening on 127.0.0.1:\(self.port)")
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
        return (port, token)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                logger.error("[relay] accept failed: errno \(errno)")
                return
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        var tv = timeval(tv_sec: Self.helloTimeout, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let helloLength = Self.tokenLength + 1
        var hello = [UInt8](repeating: 0, count: helloLength)
        var got = 0
        while got < helloLength {
            let n = hello.withUnsafeMutableBytes {
                read(client, $0.baseAddress! + got, helloLength - got)
            }
            if n <= 0 {
                close(client)
                return
            }
            got += n
        }

        let expected = Array(token.utf8)
        var diff: UInt8 = 0
        for i in 0..<Self.tokenLength { diff |= hello[i] ^ expected[i] }
        let slot = hello[Self.tokenLength]
        guard diff == 0, slot >= UInt8(ascii: "0"), slot <= UInt8(ascii: "9") else {
            logger.warning("[relay] rejected connection with bad handshake")
            close(client)
            return
        }

        tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let upstream = connectDiscord(slot: Int(slot - UInt8(ascii: "0"))) else {
            close(client)
            return
        }
        let done = DispatchGroup()
        for (from, to) in [(client, upstream), (upstream, client)] {
            done.enter()
            Thread.detachNewThread {
                Self.pump(from: from, to: to)
                done.leave()
            }
        }
        done.wait()
        close(client)
        close(upstream)
    }

    private func connectDiscord(slot: Int) -> Int32? {
        let path = socketDirectory() + "discord-ipc-\(slot)"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else {
            logger.error("[relay] socket path too long: \(path)")
            close(fd)
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { strlcpy($0, path, capacity) }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            logger.info("[relay] cannot connect to \(path): errno \(errno)")
            close(fd)
            return nil
        }
        return fd
    }

    /// Copies bytes until EOF or error, then half-closes the destination so the peer sees EOF.
    private static func pump(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        outer: while true {
            let capacity = buffer.count
            let n = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress!, capacity) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            var offset = 0
            while offset < n {
                let w = buffer.withUnsafeBytes { write(to, $0.baseAddress! + offset, n - offset) }
                if w < 0 && errno == EINTR { continue }
                if w <= 0 { break outer }
                offset += w
            }
        }
        shutdown(to, SHUT_WR)
        shutdown(from, SHUT_RD)
    }
}
