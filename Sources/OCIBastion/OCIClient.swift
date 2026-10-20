import Foundation

struct BastionItem: Identifiable, Hashable {
    let id: String
    let name: String
}

struct CompartmentItem: Identifiable, Hashable {
    let id: String
    let label: String
}

struct CompartmentRecord: Hashable {
    let id: String
    let name: String
    let parentID: String
}

struct CompartmentPage {
    let tenancyID: String
    let records: [CompartmentRecord]
    let nextPage: String?
}

struct BastionSession {
    let id: String
    let sshTarget: String
    let expiresAt: Date?
}

struct OCIClient {
    let settings: Settings
    let proxy: ProxyEndpoint?

    init(settings: Settings, proxy: ProxyEndpoint? = nil) {
        self.settings = settings
        self.proxy = proxy
    }

    private var executable: String {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = ["/opt/homebrew/bin/oci", "/usr/local/bin/oci", "/usr/bin/oci"] + pathEntries.map { $0 + "/oci" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "oci"
    }

    private func call(_ arguments: [String]) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AppError.message("No se encuentra OCI CLI. Instálalo o añade su ejecutable a /opt/homebrew/bin o /usr/local/bin.")
        }
        let base = ["--config-file", settings.configPath, "--profile", settings.profile]
        var environment = ProcessInfo.processInfo.environment
        for key in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"] {
            environment.removeValue(forKey: key)
        }
        if let proxy {
            let value = "http://" + proxy.address
            environment["http_proxy"] = value
            environment["https_proxy"] = value
        }
        let result = try await CommandRunner.run(executable, base + arguments, environment: environment)
        return try CommandRunner.requireSuccess(result, label: "OCI CLI")
    }

    func listCompartments(page: String? = nil) async throws -> CompartmentPage {
        let tenancyID = try OCIConfig.tenancyID(at: settings.configPath, profile: settings.profile)
        var arguments = [
            "iam", "compartment", "list", "--compartment-id", tenancyID,
            "--compartment-id-in-subtree", "true", "--access-level", "ACCESSIBLE", "--limit", "100"
        ]
        if let page { arguments += ["--page", page] }
        let object = try JSONValue.object(try await call(arguments))
        guard let items = object["data"] as? [[String: Any]] else {
            throw AppError.message("OCI devolvió una lista de compartimentos inesperada.")
        }
        let records = items.compactMap { item -> CompartmentRecord? in
            guard (item["lifecycle-state"] as? String) == "ACTIVE",
                  let id = item["id"] as? String else { return nil }
            return CompartmentRecord(id: id,
                                     name: (item["name"] as? String) ?? id,
                                     parentID: (item["compartment-id"] as? String) ?? tenancyID)
        }
        return CompartmentPage(tenancyID: tenancyID,
                               records: records,
                               nextPage: object["opc-next-page"] as? String)
    }

    static func compartmentItems(tenancyID: String, records: [CompartmentRecord]) -> [CompartmentItem] {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        func label(for record: CompartmentRecord) -> String {
            var parts: [String] = []
            var current = record
            var visited = Set<String>()
            while visited.insert(current.id).inserted {
                parts.append(current.name)
                guard current.parentID != tenancyID,
                      let parent = byID[current.parentID] else { break }
                current = parent
            }
            return parts.reversed().joined(separator: " / ")
        }
        let children = records.map { CompartmentItem(id: $0.id, label: label(for: $0)) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return [CompartmentItem(id: tenancyID, label: "Tenancy (raíz)")] + children
    }

    func listBastions() async throws -> [BastionItem] {
        let output = try await call(["bastion", "bastion", "list", "--compartment-id", settings.compartmentID, "--all"])
        let object = try JSONValue.object(output)
        guard let items = object["data"] as? [[String: Any]] else {
            throw AppError.message("OCI devolvió una lista de bastiones inesperada.")
        }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return BastionItem(id: id, name: (item["name"] as? String) ?? (item["display-name"] as? String) ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func getOwnedSession(id: String) async throws -> BastionSession? {
        let output = try await call(["bastion", "session", "get", "--session-id", id])
        let data = try JSONValue.data(JSONValue.object(output))
        guard (data["lifecycle-state"] as? String) == "ACTIVE",
              (data["bastion-id"] as? String) == settings.bastionID else { return nil }
        return try session(from: data)
    }

    func createSession(publicKey: String) async throws -> BastionSession {
        let name = "OCIBastion-" + UUID().uuidString
        let details = try JSONSerialization.data(withJSONObject: ["publicKeyContent": publicKey])
        let keyDetails = String(decoding: details, as: UTF8.self)
        _ = try await call([
            "bastion", "session", "create-session-create-dynamic-port-forwarding-session-target-resource-details",
            "--bastion-id", settings.bastionID,
            "--key-type", "PUB", "--key-details", keyDetails,
            "--session-ttl-in-seconds", String(settings.ttlSeconds),
            "--display-name", name, "--wait-for-state", "SUCCEEDED"
        ])
        for _ in 0..<12 {
            let output = try await call(["bastion", "session", "list", "--bastion-id", settings.bastionID, "--all"])
            let object = try JSONValue.object(output)
            if let items = object["data"] as? [[String: Any]],
               let item = items.first(where: { ($0["display-name"] as? String) == name && ($0["lifecycle-state"] as? String) == "ACTIVE" }),
               let id = item["id"] as? String,
               let session = try await getOwnedSession(id: id) {
                return session
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw AppError.message("OCI creó la sesión, pero no apareció como activa. Comprueba las sesiones del Bastion.")
    }

    private func session(from data: [String: Any]) throws -> BastionSession {
        guard let id = data["id"] as? String,
              let metadata = data["ssh-metadata"] as? [String: Any],
              let command = metadata["command"] as? String else {
            throw AppError.message("La sesión no incluye un comando SSH válido.")
        }
        let pattern = #"[A-Za-z0-9._-]+@[A-Za-z0-9._-]+"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.matches(in: command, range: range).last,
              let matchRange = Range(match.range, in: command) else {
            throw AppError.message("No se pudo encontrar el destino SSH en la respuesta de OCI.")
        }
        let target = String(command[matchRange])
        let created = (data["time-created"] as? String).flatMap { value -> Date? in
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        let ttl = data["session-ttl-in-seconds"] as? Int
        return BastionSession(id: id, sshTarget: target, expiresAt: created.flatMap { date in ttl.map { date.addingTimeInterval(TimeInterval($0)) } })
    }
}

enum KeyValidation {
    static func fingerprint(path: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw AppError.message("No existe la clave: \(path)")
        }
        let result = try await CommandRunner.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", path])
        let output = try CommandRunner.requireSuccess(result, label: "No se pudo leer la clave SSH")
        guard let value = output.split(whereSeparator: \.isWhitespace).dropFirst().first else {
            throw AppError.message("No se pudo obtener la huella de la clave SSH.")
        }
        return String(value)
    }

    static func checkPair(publicPath: String, privatePath: String) async throws -> String {
        let publicFingerprint = try await fingerprint(path: publicPath)
        let privateFingerprint = try await fingerprint(path: privatePath)
        guard publicFingerprint == privateFingerprint else {
            throw AppError.message("La clave pública y la privada del Bastion no forman pareja.")
        }
        return publicFingerprint
    }
}
