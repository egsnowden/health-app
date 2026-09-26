import Foundation

enum VaultBookmarkError: Error {
    case notStored
}

struct VaultBookmark {
    private static let dataKey = "probe.vault.bookmark"
    private static let storedAtKey = "probe.vault.bookmark.storedAt"

    static func store(_ url: URL) throws {
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: dataKey)
        UserDefaults.standard.set(Date(), forKey: storedAtKey)
    }

    static var storedAt: Date? {
        UserDefaults.standard.object(forKey: storedAtKey) as? Date
    }

    static func resolve() throws -> (url: URL, isStale: Bool) {
        guard let data = UserDefaults.standard.data(forKey: dataKey) else {
            throw VaultBookmarkError.notStored
        }
        var isStale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [],
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: dataKey)
        UserDefaults.standard.removeObject(forKey: storedAtKey)
    }
}
