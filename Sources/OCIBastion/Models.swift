import Foundation

struct Destination: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var host: String = ""
    var user: String = "opc"
    var port: Int = 22
    var privateKeyPath: String = ""
}

struct LocalTunnel: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var host: String = ""
    var user: String = "opc"
    var sshPort: Int = 22
    var privateKeyPath: String = ""
    var localPort: Int = 0
    var remoteHost: String = "127.0.0.1"
    var remotePort: Int = 0
}

struct Settings: Codable {
    var configPath: String = ""
    var profile: String = "DEFAULT"
    var compartmentID: String = ""
    var bastionID: String = ""
    var publicKeyPath: String = ""
    var privateKeyPath: String = ""
    var socksPort: Int = 2222
    var ttlSeconds: Int = 10800
    var proxyHost: String = ""
    var proxyPort: Int = 0
    var proxyMode: ProxyMode? = nil
    var terminalApp: TerminalApp? = nil
    var destinations: [Destination] = []
    var tunnels: [LocalTunnel]? = nil
    var ownedSessionID: String = ""
    var ownedSessionKeyFingerprint: String = ""
    var savedConnections: [SavedConnection]? = nil
    var selectedSavedConnectionID: UUID? = nil

    var effectiveProxyMode: ProxyMode {
        proxyMode ?? (proxyHost.isEmpty ? .automatic : .manual)
    }

    var effectiveTerminalApp: TerminalApp { terminalApp ?? .terminal }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OCIBastion/settings.json")
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return value
    }

    func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ProxyMode: String, Codable, CaseIterable {
    case automatic
    case manual
    case direct
}

enum TerminalApp: String, Codable, CaseIterable {
    case terminal
    case iterm
}

struct ConnectionSnapshot: Codable, Equatable {
    var configPath: String
    var profile: String
    var compartmentID: String
    var bastionID: String
    var publicKeyPath: String
    var privateKeyPath: String
    var socksPort: Int
    var ttlSeconds: Int
    var proxyHost: String
    var proxyPort: Int
    var proxyMode: ProxyMode?
    var terminalApp: TerminalApp?
    var destinations: [Destination]
    var tunnels: [LocalTunnel]?

    init(settings: Settings) {
        configPath = settings.configPath
        profile = settings.profile
        compartmentID = settings.compartmentID
        bastionID = settings.bastionID
        publicKeyPath = settings.publicKeyPath
        privateKeyPath = settings.privateKeyPath
        socksPort = settings.socksPort
        ttlSeconds = settings.ttlSeconds
        proxyHost = settings.proxyHost
        proxyPort = settings.proxyPort
        proxyMode = settings.proxyMode
        terminalApp = settings.terminalApp
        destinations = settings.destinations
        tunnels = settings.tunnels
    }

    func apply(to settings: inout Settings) {
        let sameSession = settings.configPath == configPath && settings.profile == profile &&
            settings.bastionID == bastionID && settings.publicKeyPath == publicKeyPath &&
            settings.privateKeyPath == privateKeyPath
        settings.configPath = configPath
        settings.profile = profile
        settings.compartmentID = compartmentID
        settings.bastionID = bastionID
        settings.publicKeyPath = publicKeyPath
        settings.privateKeyPath = privateKeyPath
        settings.socksPort = socksPort
        settings.ttlSeconds = ttlSeconds
        settings.proxyHost = proxyHost
        settings.proxyPort = proxyPort
        settings.proxyMode = proxyMode
        settings.terminalApp = terminalApp
        settings.destinations = destinations
        settings.tunnels = tunnels
        if !sameSession {
            settings.ownedSessionID = ""
            settings.ownedSessionKeyFingerprint = ""
        }
    }
}

struct SavedConnection: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var snapshot: ConnectionSnapshot
}

enum ExportScope {
    case all
    case active
}

struct ConfigurationArchive: Codable {
    let formatVersion: Int
    let current: ConnectionSnapshot?
    let savedConnections: [SavedConnection]
    let selectedSavedConnectionID: UUID?

    init(settings: Settings, scope: ExportScope) {
        formatVersion = 2
        let active = ConnectionSnapshot(settings: settings)
        switch scope {
        case .all:
            current = active
            savedConnections = settings.savedConnections ?? []
            selectedSavedConnectionID = settings.selectedSavedConnectionID
        case .active:
            if let selected = (settings.savedConnections ?? []).first(where: { $0.id == settings.selectedSavedConnectionID }) {
                current = nil
                savedConnections = [SavedConnection(id: selected.id, name: selected.name, snapshot: active)]
            } else {
                current = active
                savedConnections = []
            }
            selectedSavedConnectionID = nil
        }
    }

    func validate() throws {
        guard formatVersion == 1 || formatVersion == 2 else {
            throw AppError.message("Versión de archivo no compatible: \(formatVersion).")
        }
        guard current != nil || !savedConnections.isEmpty else {
            throw AppError.message("El archivo no contiene ninguna configuración.")
        }
        let ids = Set(savedConnections.map(\.id))
        let names = Set(savedConnections.map { Self.normalizedName($0.name) })
        guard ids.count == savedConnections.count, names.count == savedConnections.count,
              savedConnections.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AppError.message("El archivo contiene conexiones duplicadas o sin nombre.")
        }
        if let selectedSavedConnectionID, !ids.contains(selectedSavedConnectionID) {
            throw AppError.message("La conexión seleccionada no existe en el archivo.")
        }
    }

    func conflictingNames(with settings: Settings) -> [String] {
        let existing = Set((settings.savedConnections ?? []).map { Self.normalizedName($0.name) })
        return savedConnections.filter { existing.contains(Self.normalizedName($0.name)) }.map(\.name)
    }

    func merged(into settings: Settings) -> Settings {
        var result = settings
        var records = settings.savedConnections ?? []
        var importedIDs: [UUID: UUID] = [:]
        for imported in savedConnections {
            if let index = records.firstIndex(where: { Self.normalizedName($0.name) == Self.normalizedName(imported.name) }) {
                records[index].name = imported.name
                records[index].snapshot = imported.snapshot
                importedIDs[imported.id] = records[index].id
            } else {
                let id = records.contains(where: { $0.id == imported.id }) ? UUID() : imported.id
                records.append(SavedConnection(id: id, name: imported.name, snapshot: imported.snapshot))
                importedIDs[imported.id] = id
            }
        }
        result.savedConnections = records
        if let current {
            current.apply(to: &result)
            result.selectedSavedConnectionID = selectedSavedConnectionID.flatMap { importedIDs[$0] }
        }
        return result
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct ConfigurationImportPlan {
    let archive: ConfigurationArchive
    let fileName: String
    let conflictingNames: [String]

    var needsConfirmation: Bool { archive.current != nil || !conflictingNames.isEmpty }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

enum OCIConfig {
    static func profiles(at path: String) throws -> [String] {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let values = contents.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.first == "[", trimmed.last == "]" else { return nil }
            return String(trimmed.dropFirst().dropLast())
        }
        return Array(Set(values)).sorted()
    }

    static func tenancyID(at path: String, profile: String) throws -> String {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        var currentProfile = ""
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.first == "[", trimmed.last == "]" {
                currentProfile = String(trimmed.dropFirst().dropLast())
                continue
            }
            guard currentProfile == profile,
                  !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
                  let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            if key == "tenancy" {
                let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                return try InputCheck.singleLine(value, name: "OCID de la tenancy")
            }
        }
        throw AppError.message("El perfil \(profile) no contiene el campo tenancy en el archivo OCI.")
    }
}

enum InputCheck {
    static func singleLine(_ value: String, name: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw AppError.message("\(name) no puede estar vacío ni contener saltos de línea.")
        }
        return trimmed
    }

    static func sshToken(_ value: String, name: String) throws -> String {
        let checked = try singleLine(value, name: name)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard !checked.hasPrefix("-"), checked.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AppError.message("\(name) contiene caracteres no admitidos.")
        }
        return checked
    }

    static func port(_ value: Int) throws {
        guard (1...65535).contains(value) else { throw AppError.message("El puerto debe estar entre 1 y 65535.") }
    }
}
