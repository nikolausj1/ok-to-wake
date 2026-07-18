import Foundation

/// UserDefaults-backed store for the two persisted models (PRD Section 8).
/// JSON-encoded Codable structs; no database by decision.
final class PersistenceStore {
    static let shared = PersistenceStore()

    private enum Key {
        static let settings = "appSettings"
        static let session = "activeSession"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Survives forever; falls back to PRD defaults when absent or undecodable.
    var settings: AppSettings {
        get {
            guard let data = defaults.data(forKey: Key.settings),
                  let decoded = try? decoder.decode(AppSettings.self, from: data) else {
                return AppSettings()
            }
            return decoded
        }
        set {
            if let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: Key.settings)
            }
        }
    }

    /// Exists only while a session is logically running (crash recovery,
    /// PRD edge rows 1-2). Write BEFORE any session side effect begins;
    /// clear on every session end path (PRD invariants).
    var activeSession: ActiveSession? {
        get {
            guard let data = defaults.data(forKey: Key.session),
                  let decoded = try? decoder.decode(ActiveSession.self, from: data) else {
                return nil
            }
            return decoded
        }
        set {
            if let session = newValue, let data = try? encoder.encode(session) {
                defaults.set(data, forKey: Key.session)
            } else {
                defaults.removeObject(forKey: Key.session)
            }
        }
    }

    func clearActiveSession() {
        defaults.removeObject(forKey: Key.session)
    }
}
