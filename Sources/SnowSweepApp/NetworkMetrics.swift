import Foundation
import SystemConfiguration
import Darwin

/// 快速面板用的网络概览：主接口、类型、IPv4。
/// 只用 SystemConfiguration 与 getifaddrs，不起 `ifconfig` / `netstat` 进程，也不需要定位权限。
struct NetworkSnapshot: Sendable {
    let connected: Bool
    let kind: String
    let interfaceName: String?
    let ipv4: String?
    let ipv6: String?
}

enum NetworkMetrics {
    static func read() -> NetworkSnapshot {
        let primary = primaryInterfaceName()
        let addresses = interfaceAddresses()
        let name = primary ?? addresses.keys.sorted().first
        guard let name, let address = addresses[name], address.ipv4 != nil || address.ipv6 != nil else {
            return NetworkSnapshot(connected: false, kind: "未连接", interfaceName: name, ipv4: nil, ipv6: nil)
        }
        return NetworkSnapshot(
            connected: true,
            kind: interfaceKind(name),
            interfaceName: name,
            ipv4: address.ipv4,
            ipv6: address.ipv6
        )
    }

    private static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "SnowSweepNetwork" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return value["PrimaryInterface"] as? String
    }

    private struct Address {
        let ipv4: String?
        let ipv6: String?
    }

    private static func interfaceAddresses() -> [String: Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }

        var result: [String: (String?, String?)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var address = addr.pointee
            let text: String? = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    guard getnameinfo(sock, socklen_t(sock.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
                    else { return nil }
                    return String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            guard let text, !text.hasPrefix("fe80::") else { continue }
            var pair = result[name] ?? (nil, nil)
            if family == UInt8(AF_INET), pair.0 == nil {
                pair.0 = text
            } else if family == UInt8(AF_INET6), pair.1 == nil {
                pair.1 = text
            }
            result[name] = pair
        }
        return result.mapValues { Address(ipv4: $0.0, ipv6: $0.1) }
    }

    private static func interfaceKind(_ bsdName: String) -> String {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for interface in interfaces {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  name == bsdName,
                  let type = SCNetworkInterfaceGetInterfaceType(interface)
            else { continue }
            if CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) { return "Wi‑Fi" }
            if CFEqual(type, kSCNetworkInterfaceTypeEthernet) { return "有线" }
            if CFEqual(type, kSCNetworkInterfaceTypeWWAN) { return "蜂窝" }
            return "其他"
        }
        return bsdName.hasPrefix("en") ? "网络" : "其他"
    }
}
