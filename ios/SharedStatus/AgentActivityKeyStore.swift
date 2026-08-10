import Foundation
import os
import Security

/// Per-computer Live Activity content keys shared by the app and widget.
///
/// The App Group file is the primary transport because Live Activity views are
/// rendered by WidgetKit/chronod, where a shared Keychain lookup can
/// intermittently be unavailable even though the containing app can use it.
/// The file contains only HKDF-derived Live Activity keys, is protected until
/// the device's first unlock, and is excluded from backup. Root pairing
/// secrets and relay traffic keys never leave the app's private Keychain.
public enum AgentActivityKeyStore {
    public static let appGroup = "group.air.build.pedals"
    public static let accessGroup = "QDJ93ZUQ9B.air.build.pedals.shared"

    static let service = "air.build.pedals.live-activity-keys"
    static let fileName = "live-activity-keys-v1.json"

    private static let logger = Logger(
        subsystem: "air.build.pedals",
        category: "LiveActivityKeys"
    )

    public struct SynchronizationResult: Equatable, Sendable {
        public let appGroupStored: Bool
        public let keychainFailureCount: Int
    }

    /// Replaces the authoritative key set. The App Group copy is used by new
    /// builds; the Keychain mirror keeps an update compatible with an already
    /// running extension or a temporarily unavailable group container.
    @discardableResult
    public static func setKeys(
        _ keys: [String: Data]
    ) -> SynchronizationResult {
        let validated = keys.filter {
            AgentActivityKeyFileStore.isValidComputerID($0.key)
                && AgentActivityKeyFileStore.isValidKey($0.value)
        }
        if validated.count != keys.count {
            logger.error("Rejected invalid Live Activity key material")
        }

        var appGroupStored = false
        do {
            guard let fileStore else {
                throw AgentActivityKeyFileStore.StoreError
                    .missingAppGroupContainer
            }
            try fileStore.replace(with: validated)
            appGroupStored = true
        } catch {
            logger.error(
                "Could not write Live Activity App Group keys: \(error.localizedDescription, privacy: .public)"
            )
        }

        let keychainFailureCount = replaceKeychainKeys(with: validated)
        if keychainFailureCount > 0 {
            logger.error(
                "Live Activity Keychain mirror had \(keychainFailureCount, privacy: .public) failures"
            )
        }
        return .init(
            appGroupStored: appGroupStored,
            keychainFailureCount: keychainFailureCount
        )
    }

    public static func key(forComputer computerID: String) -> Data? {
        guard AgentActivityKeyFileStore.isValidComputerID(computerID)
        else { return nil }

        if let fileStore {
            do {
                if let key = try fileStore.key(forComputer: computerID) {
                    return key
                }
            } catch {
                logger.error(
                    "Could not read Live Activity App Group keys: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return keychainKey(forComputer: computerID)
    }

    static var fileStore: AgentActivityKeyFileStore? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { return nil }
        return .init(fileURL: container.appendingPathComponent(
            fileName, isDirectory: false
        ))
    }

    private static func replaceKeychainKeys(
        with keys: [String: Data]
    ) -> Int {
        var failures = 0
        let existing = allKeychainAccounts()
        for account in existing where keys[account] == nil {
            let status = SecItemDelete([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecAttrAccessGroup: accessGroup,
            ] as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                failures += 1
            }
        }
        for (computerID, key) in keys {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: computerID,
                kSecAttrAccessGroup: accessGroup,
            ]
            var status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData: key] as CFDictionary
            )
            if status == errSecItemNotFound {
                var create = query
                create[kSecValueData] = key
                create[kSecAttrAccessible] =
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(create as CFDictionary, nil)
            }
            if status != errSecSuccess {
                failures += 1
            }
        }
        return failures
    }

    private static func keychainKey(
        forComputer computerID: String
    ) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: computerID,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result)
                == errSecSuccess,
              let data = result as? Data,
              AgentActivityKeyFileStore.isValidKey(data)
        else { return nil }
        return data
    }

    private static func allKeychainAccounts() -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result)
                == errSecSuccess,
              let items = result as? [[CFString: Any]]
        else { return [] }
        return items.compactMap { $0[kSecAttrAccount] as? String }
    }
}

struct AgentActivityKeyFileStore: Sendable {
    static let computerIDLength = 32
    static let keyByteCount = 32

    enum StoreError: Error, LocalizedError {
        case missingAppGroupContainer
        case unsupportedVersion(Int)
        case invalidArchive

        var errorDescription: String? {
            switch self {
            case .missingAppGroupContainer:
                "The TTY.Build App Group container is unavailable."
            case .unsupportedVersion(let version):
                "Unsupported Live Activity key archive version \(version)."
            case .invalidArchive:
                "The Live Activity key archive is invalid."
            }
        }
    }

    private struct Archive: Codable {
        static let currentVersion = 1

        var version: Int
        var keys: [String: Data]
    }

    let fileURL: URL

    func replace(with keys: [String: Data]) throws {
        guard keys.allSatisfy({
            Self.isValidComputerID($0.key) && Self.isValidKey($0.value)
        }) else {
            throw StoreError.invalidArchive
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Archive(
            version: Archive.currentVersion,
            keys: keys
        ))
        try data.write(
            to: fileURL,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedURL = fileURL
        try protectedURL.setResourceValues(resourceValues)
    }

    func key(forComputer computerID: String) throws -> Data? {
        guard Self.isValidComputerID(computerID) else { return nil }
        guard FileManager.default.fileExists(atPath: fileURL.path)
        else { return nil }
        let archive = try JSONDecoder().decode(
            Archive.self, from: Data(contentsOf: fileURL)
        )
        guard archive.version == Archive.currentVersion else {
            throw StoreError.unsupportedVersion(archive.version)
        }
        guard archive.keys.allSatisfy({
            Self.isValidComputerID($0.key) && Self.isValidKey($0.value)
        }) else {
            throw StoreError.invalidArchive
        }
        return archive.keys[computerID]
    }

    static func isValidComputerID(_ value: String) -> Bool {
        value.count == computerIDLength
            && value.allSatisfy {
                $0.isASCII
                    && ($0.isNumber || ("a" ... "f").contains($0))
            }
    }

    static func isValidKey(_ value: Data) -> Bool {
        value.count == keyByteCount
    }
}
