/// Hides the tail of an IP address for the "hide IP" setting,
/// e.g. while sharing the screen.
public enum IPMasker {
    /// `203.0.113.57` → `203.0.•••.•••`; IPv6 keeps the first two groups.
    public static func mask(_ ip: String) -> String {
        if ip.contains(":") {
            let groups = ip.split(separator: ":", omittingEmptySubsequences: false)
            guard groups.count > 2 else { return "•••" }
            return groups.prefix(2).joined(separator: ":") + ":•••"
        }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return "•••" }
        return parts.prefix(2).joined(separator: ".") + ".•••.•••"
    }
}
