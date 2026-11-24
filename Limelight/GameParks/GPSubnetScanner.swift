//
//  GPSubnetScanner.swift
//  GameParks
//
//  Finds GameStream PCs (Sunshine / GeForce Experience) on the local
//  network WITHOUT Bonjour. It works out the phone's Wi-Fi subnet and
//  probes every address on it directly, so it needs only Local Network
//  permission.
//
//  Why this exists: GameParks runs inside LiveContainer, and Bonjour
//  browsing is governed by the RUNNING process's Info.plist — the
//  container's, not GameParks'. If the container's plist does not
//  declare _nvstream._tcp, Bonjour silently finds nothing (the same
//  code discovers fine in the standalone app, whose own plist governs).
//  A subnet scan has no such dependency.
//
//  The scan is only a fast TCP filter. Every address that answers on
//  the GameStream HTTP port is validated — and its TemporaryHost
//  built — by the exact same code as manual add-by-IP,
//  DiscoveryManager.discoverHost, so there is a single protocol path
//  and found hosts join the same discovery queue as any other host.
//

import Foundation

final class GPSubnetScanner {
    /// The GameStream HTTP port (Sunshine / GeForce Experience).
    private static let gameStreamPort: UInt16 = 47989
    private static let probeTimeoutMs: Int32 = 700
    private static let maxConcurrentProbes = 40

    private let scanQueue = DispatchQueue(label: "com.gameparks.subnetscan",
                                          qos: .userInitiated,
                                          attributes: .concurrent)
    private var generation = 0
    private let generationLock = NSLock()

    /// Invalidates any sweep still running; its remaining probes are
    /// skipped and its hosts are dropped.
    func cancel() {
        generationLock.lock()
        generation += 1
        generationLock.unlock()
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    /// Sweeps the phone's Wi-Fi subnet once. `onHost` is called (on a
    /// background queue) for every newly validated host; `completion`
    /// is called on the main queue when the sweep ends.
    func scan(discoveryManager: DiscoveryManager,
              onHost: @escaping (TemporaryHost) -> Void,
              completion: @escaping () -> Void) {
        cancel()
        let gen = currentGeneration()
        guard let addresses = Self.localSubnetAddresses() else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: Self.maxConcurrentProbes)
        for address in addresses {
            group.enter()
            scanQueue.async {
                semaphore.wait()
                if self.currentGeneration() == gen, Self.isGameStreamPortOpen(address) {
                    // Validates /serverinfo and builds the host exactly
                    // like manual add-by-IP. It blocks until answered,
                    // so it runs here on the scan queue, never on main.
                    discoveryManager.discoverHost(address) { host, _ in
                        if let host = host, self.currentGeneration() == gen {
                            onHost(host)
                        }
                    }
                }
                semaphore.signal()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion()
        }
    }

    // MARK: - Subnet

    /// Every usable address on the phone's Wi-Fi (en0) subnet except
    /// the phone's own — never wider than a /24: home networks are
    /// /24, and a wider sweep would be too slow to be useful.
    private static func localSubnetAddresses() -> [String]? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var own: UInt32 = 0
        var mask: UInt32 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            cursor = current.pointee.ifa_next
            let interface = current.pointee
            guard let addrPtr = interface.ifa_addr,
                  Int32(addrPtr.pointee.sa_family) == AF_INET,
                  String(cString: interface.ifa_name) == "en0" else {
                continue
            }
            own = UInt32(bigEndian: addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            })
            if let maskPtr = interface.ifa_netmask {
                mask = UInt32(bigEndian: maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr
                })
            }
            break
        }
        guard own != 0 else { return nil }
        if mask == 0 {
            mask = 0xFFFFFF00
        }
        // Narrower-or-equal wins: a /25 stays /25, a /16 is capped to
        // the /24 around the phone.
        let effectiveMask = max(mask, 0xFFFFFF00)
        let network = own & effectiveMask
        let broadcast = network | ~effectiveMask
        guard broadcast - network >= 2, broadcast - network <= 256 else { return nil }

        var result: [String] = []
        var candidate = network + 1
        while candidate < broadcast {
            if candidate != own {
                result.append(ipString(candidate))
            }
            candidate += 1
        }
        return result
    }

    private static func ipString(_ value: UInt32) -> String {
        return "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    // MARK: - TCP probe

    /// Fast non-blocking connect with a short timeout: true only if
    /// something accepts TCP connections on the GameStream port.
    private static func isGameStreamPortOpen(_ address: String) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = gameStreamPort.bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return false }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            return true
        }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd()
        pfd.fd = fd
        pfd.events = Int16(POLLOUT)
        let ready = poll(&pfd, 1, probeTimeoutMs)
        guard ready > 0, pfd.revents & Int16(POLLOUT) != 0 else { return false }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}
