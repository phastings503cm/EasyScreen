import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static let repositoryURL = URL(string: "https://github.com/phastings503cm/EasyScreen")!
}
