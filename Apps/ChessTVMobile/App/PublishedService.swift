import Foundation

/// The one place the shipped service's address lives. The published source carries a
/// placeholder here, so a public checkout builds against a host of its own choosing.
enum PublishedService {
    static let host = "follow.example.com"
    static let url = URL(string: "https://\(host)")!
    static let privacyPolicy = URL(string: "https://\(host)/privacy")!
    static let support = URL(string: "https://\(host)/support")!
}
