import Foundation

/// Reserved, obviously fake values. Never put real keys or servers in tests.
enum Fake {
    static let uuid = "00000000-0000-0000-0000-000000000000"
    /// 32 zero bytes in base64: a well-formed but useless REALITY public key.
    static let realityKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    static func urlSafeBase64NoPadding(_ text: String) -> String {
        base64(text)
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static let vlessReality =
        "vless://\(uuid)@nl.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality"
        + "&sni=www.example.org&fp=chrome&pbk=\(realityKey)&sid=0a1b&spx=%2F&type=tcp"
        + "#%F0%9F%87%B3%F0%9F%87%B1%20%D0%9D%D0%B8%D0%B4%D0%B5%D1%80%D0%BB%D0%B0%D0%BD%D0%B4%D1%8B"

    static let hysteria2 =
        "hysteria2://test-password@192.0.2.10:443?sni=hy.example.com&obfs=salamander"
        + "&obfs-password=test-obfs&insecure=1#FI%20Hysteria2"
}
