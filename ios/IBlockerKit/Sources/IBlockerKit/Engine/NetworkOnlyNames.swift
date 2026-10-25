import Foundation

/// Names that always resolve via the network's own DNS, under every fallback
/// policy. A name matches if it equals an entry or is a subdomain of one.
/// `*` in an entry matches exactly one label. Matching is case-insensitive and
/// tolerates a trailing dot. `local` is deliberately not in the list.
public enum NetworkOnlyNames {
    /// Entries without wildcards, lowercased.
    private static let exactEntries: Set<String> = {
        var entries: Set<String> = [
            "lan",
            "home.arpa",
            "service.arpa",
            "10.in-addr.arpa",
            "168.192.in-addr.arpa",
            "d.f.ip6.arpa",
            // Wi-Fi calling
            "pub.3gppnetwork.org",
            "epdg.epc.aptg.com.tw",
            "epdg.epc.att.net",
            "epdg.mobileone.net.sg",
            "primgw.vowifina.spcsdns.net",
            "swu-loopback-epdg.qualcomm.com",
            "vowifi.jio.com",
            "weconnect.globe.com.ph",
            "wlan.three.com.hk",
            "wo.vzwwo.com",
            "dengon.docomo.ne.jp",
            // Router and repeater setup names
            "dlinkap",
            "dlinkrouter",
            "edimax.setup",
            "fritz.box",
            "gateway.2wire.net",
            "miwifi.com",
            "my.firewall",
            "my.keenetic.net",
            "netis.cc",
            "pocket.wifi",
            "router.asus.com",
            "repeater.asus.com",
            "routerlogin.com",
            "routerlogin.net",
            "tendawifi.com",
            "tendawifi.net",
            "tplinklogin.net",
            "tplinkwifi.net",
            "tplinkrepeater.net",
            "oppowifi.com",
            "myrepeater.net",
            "mywifi.net",
            "setup.pix-link.net",
            "tplinkdeco.net",
            "tplinkextender.net",
            "www.asusrouter.com",
        ]
        for octet in 16...31 {
            entries.insert("\(octet).172.in-addr.arpa")
        }
        return entries
    }()

    /// Wildcard entries, as labels in written order (leftmost first).
    private static let wildcardEntries: [[Substring]] = [
        "b._dns-sd._udp.*.in-addr.arpa",
        "lb._dns-sd._udp.*.in-addr.arpa",
    ].map { $0.split(separator: ".", omittingEmptySubsequences: false) }

    /// True if `name` should always be answered by the network's DNS.
    public static func matches(_ name: String) -> Bool {
        var normalized = name.lowercased()
        if normalized.hasSuffix(".") { normalized.removeLast() }
        guard !normalized.isEmpty else { return false }

        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.contains(where: { $0.isEmpty }) else { return false }

        // Every suffix of the name (the name itself and each parent) against exact entries.
        for start in labels.indices {
            if exactEntries.contains(labels[start...].joined(separator: ".")) {
                return true
            }
        }

        for pattern in wildcardEntries where labels.count >= pattern.count {
            let tail = labels.suffix(pattern.count)
            let isMatch = zip(pattern, tail).allSatisfy { $0 == "*" || $0 == $1 }
            if isMatch { return true }
        }
        return false
    }
}
