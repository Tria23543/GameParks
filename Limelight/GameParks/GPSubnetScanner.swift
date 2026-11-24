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

@objc final class GPSubnetScanner: NSObject {
    /// The GameStream HTTP port (Sunshine / GeForce Experience).
    private static let gameStreamPort: UInt16 = 47989
    private static let probeTimeoutMs: Int32 = 700
    /// Upper bound on one address's validation. discoverHost performs
    /// synchronous HTTP whose waits are bounded only by NSURLSession's
    /// longest timeout; a host that accepts TCP but never answers
    /// would otherwise park the probe — and with it the whole scan.
    private static let validationTimeout: TimeInterval = 8
    private static let maxConcurrentProbes = 40

    /// Bounded-concurrency probe pool. (v1.1 enqueued one block per
    /// address on a concurrent GCD queue and parked ~253 threads on a
    /// semaphore to gate them; an OperationQueue expresses the same
    /// limit structurally, without the parked threads.)
    private let probeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrentProbes
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var generation = 0
    private let generationLock = NSLock()

    /// Invalidates any sweep still running; its remaining probes are
    /// skipped and its hosts are dropped.
    @objc func cancel() {
        _ = bumpGeneration()
    }

    /// Increment-and-read as ONE locked operation: two concurrent
    /// scans can never end up sharing a generation (and so failing
    /// to invalidate each other).
    private func bumpGeneration() -> Int {
        generationLock.lock()
        generation += 1
        let gen = generation
        generationLock.unlock()
        return gen
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    /// Sweeps the phone's Wi-Fi subnet once. `onHost` is called (on a
    /// background queue) for every newly validated host; `completion`
    /// is called exactly once, on the main queue, with true if the
    /// sweep ran to completion and false if it was superseded,
    /// cancelled, or there was no subnet to sweep.
    @objc func scan(discoveryManager: DiscoveryManager,
              onHost: @escaping (TemporaryHost) -> Void,
              completion: @escaping (Bool) -> Void) {
        let gen = bumpGeneration()
        guard let addresses = Self.localSubnetAddresses() else {
            // No Wi-Fi subnet is NOT the same as "no PCs found" —
            // report it distinctly so the caller does not throttle
            // the next attempt as if a sweep had really run.
            DispatchQueue.main.async { completion(false) }
            return
        }
        let group = DispatchGroup()
        for address in addresses {
            group.enter()
            probeQueue.addOperation {
                // leave() is guaranteed whatever happens below,
                // including a validation that has to be abandoned.
                defer { group.leave() }
                guard self.currentGeneration() == gen,
                      Self.isGameStreamPortOpen(address),
                      // Re-check after the probe: a cancel that landed
                      // during it must not start a full validation
                      // for a sweep already declared invalid.
                      self.currentGeneration() == gen else {
                    return
                }
                if let host = self.validate(address: address, discoveryManager: discoveryManager,
                                            isCurrent: { self.currentGeneration() == gen }),
                   self.currentGeneration() == gen {
                    onHost(host)
                }
            }
        }
        group.notify(queue: .main) {
            completion(self.currentGeneration() == gen)
        }
    }

    /// GP v2.6 (B-12): synchronised hand-off for one validation
    /// result. The discoverHost callback can land after the wait
    /// below has timed out and validate has returned; the lock +
    /// abandonment flag mean the orphaned block never writes the
    /// result unsynchronised after abandonment. (This guards the
    /// hand-off only — the probe-slot design itself is unchanged;
    /// see A-59, still partial.)
    private final class ValidateBox {
        private let lock = NSLock()
        private var stored: TemporaryHost?
        private var abandoned = false

        func store(_ host: TemporaryHost?) {
            lock.lock()
            if !abandoned { stored = host }
            lock.unlock()
        }

        func abandon() {
            lock.lock()
            abandoned = true
            lock.unlock()
        }

        /// GP v2.7 (C-18): the same abandonment flag, read by the
        /// shouldAddToDiscovery closure in validate — abandoning a
        /// timed-out validation must also stop its orphaned
        /// discoverHost from adding the host to the discovery queue.
        var isAbandoned: Bool {
            lock.lock()
            defer { lock.unlock() }
            return abandoned
        }

        var host: TemporaryHost? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Runs DiscoveryManager.discoverHost on a side queue and waits
    /// with a bound. On timeout the probe is abandoned (nil); the
    /// orphaned request is left to time out on its own queue, so one
    /// silent host can no longer stall the sweep or its completion.
    private func validate(address: String, discoveryManager: DiscoveryManager,
                          isCurrent: @escaping () -> Bool) -> TemporaryHost? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ValidateBox()
        DispatchQueue.global(qos: .userInitiated).async {
            // GP v2.5 (A-57): the token-aware variant re-checks the
            // sweep generation immediately before discoverHost would
            // add the host to the discovery queue, so a validation that
            // finishes after this sweep was cancelled/superseded has
            // no discovery side effect.
            discoveryManager.discoverHost(address, withCallback: { host, _ in
                box.store(host)
                semaphore.signal()
            }, shouldAddToDiscovery: { !box.isAbandoned && isCurrent() })
        }
        guard semaphore.wait(timeout: .now() + Self.validationTimeout) == .success else {
            box.abandon()
            return nil
        }
        return box.host
    }

    // MARK: - Subnet

    /// Every usable address on the phone's Wi-Fi (en0) subnet except
    /// the phone's own — never wider than a /24: home networks are
    /// /24, and a wider sweep would be too slow to be useful.
    private static func localSubnetAddresses() -> [String]? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        // Consider every IPv4 entry on en0 and prefer a private,
        // non-link-local one: the first entry can be a 169.254.x.x
        // link-local address (DHCP failure), which would sweep the
        // wrong subnet and silently find nothing.
        var best: (addr: UInt32, mask: UInt32)?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            cursor = current.pointee.ifa_next
            let interface = current.pointee
            guard let addrPtr = interface.ifa_addr,
                  Int32(addrPtr.pointee.sa_family) == AF_INET,
                  String(cString: interface.ifa_name) == "en0" else {
                continue
            }
            let addr = UInt32(bigEndian: addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            })
            var mask: UInt32 = 0
            if let maskPtr = interface.ifa_netmask {
                mask = UInt32(bigEndian: maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr
                })
            }
            // GP v2.5 (A-58): rank candidates — RFC1918 beats any
            // other non-link-local address, which beats link-local —
            // instead of "first non-link-local wins".
            if best == nil || addressRank(addr) > addressRank(best!.addr) {
                best = (addr, mask)
            }
        }
        guard let chosen = best, chosen.addr != 0 else { return nil }
        NSLog("GPSubnetScanner: sweeping from en0 address %@ mask %@",
              ipString(chosen.addr), ipString(chosen.mask))
        var mask = chosen.mask
        if mask == 0 {
            mask = 0xFFFFFF00
        }
        // Assumes a contiguous netmask (universal on home networks).
        // Narrower-or-equal wins: a /25 stays /25, a /16 is capped to
        // the /24 around the phone.
        let effectiveMask = max(mask, 0xFFFFFF00)
        let network = chosen.addr & effectiveMask
        let broadcast = network | ~effectiveMask
        guard broadcast - network >= 2 else { return nil }

        var result: [String] = []
        var candidate = network + 1
        while candidate < broadcast {
            if candidate != chosen.addr {
                result.append(ipString(candidate))
            }
            candidate += 1
        }
        return result
    }

    private static func isLinkLocal(_ addr: UInt32) -> Bool {
        return (addr & 0xFFFF0000) == 0xA9FE0000 // 169.254.0.0/16
    }

    private static func isRFC1918(_ addr: UInt32) -> Bool {
        return (addr & 0xFF000000) == 0x0A000000        // 10.0.0.0/8
            || (addr & 0xFFF00000) == 0xAC100000        // 172.16.0.0/12
            || (addr & 0xFFFF0000) == 0xC0A80000        // 192.168.0.0/16
    }

    private static func addressRank(_ addr: UInt32) -> Int {
        if isRFC1918(addr) { return 2 }
        if isLinkLocal(addr) { return 0 }
        return 1
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

        // If making the socket non-blocking fails, bail out: a failed
        // F_SETFL would silently turn the probe into a blocking
        // connect with no timeout bound at all.
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

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
        // errno is only meaningful read immediately after the call.
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd()
        pfd.fd = fd
        pfd.events = Int16(POLLOUT)
        // GP v2.5 (A-59): absolute deadline — an EINTR retry re-arms
        // only the time REMAINING to the deadline, so interruptions
        // can no longer stretch one probe to ~3x the timeout.
        let deadline = Date().addingTimeInterval(Double(probeTimeoutMs) / 1000.0)
        var ready: Int32 = -1
        while ready < 0 {
            let remainingMs = Int32(deadline.timeIntervalSinceNow * 1000)
            if remainingMs <= 0 { break }
            ready = poll(&pfd, 1, remainingMs)
            if ready < 0 && errno != EINTR {
                break // A real poll error, not an interruption.
            }
        }
        guard ready > 0, pfd.revents & Int16(POLLOUT) != 0 else { return false }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}
