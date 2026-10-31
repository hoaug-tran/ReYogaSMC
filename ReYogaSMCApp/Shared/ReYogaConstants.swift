import Foundation

public enum ReYogaConstants {
    public static let suiteName = "org.reyoga.ReYogaSMC"
    public static var repositoryURL: String {
        Bundle.main.object(forInfoDictionaryKey: "ReYogaRepositoryURL") as? String
            ?? "https://github.com/hoaug-tran/ReYogaSMC"
    }
    public static var hardwareDefaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }
    public static var userDefaults: UserDefaults {
        .standard
    }
}
