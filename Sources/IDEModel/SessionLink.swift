import Foundation
import IDEProtocol

/// `com.magicelklabs.lantern://session/<sessionKey>`: what the menu-bar extra opens Lantern with to show one session's tab (the app
/// declares the scheme, `CFBundleURLTypes`).
public enum SessionLink {
    public static let scheme = "com.magicelklabs.lantern"

    public static func url(for sessionKey: SessionKey) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "session"
        components.path = "/" + sessionKey
        return components.url
    }

    /// The session `url` names; nil for any other URL.
    public static func sessionKey(in url: URL) -> SessionKey? {
        guard url.scheme == scheme, url.host() == "session" else { return nil }
        let key = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return key.isEmpty || key.contains("/") ? nil : key
    }
}
