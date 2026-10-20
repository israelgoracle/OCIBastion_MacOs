import Foundation

@main
struct ArchiveTunnelTests {
    static func main() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        try testLegacyMerge(fixtures: fixtures)
        try testNamedExportAndTunnel()
        try testCurrentOnlyExport()
        try testAllExportAndNamedImport()
        try testPreviouslyGeneratedArchive(fixtures: fixtures)
        try testNamedOnlyFixture(fixtures: fixtures)
        testPortFormattingAndOwnership()
        print("7 comprobaciones de archivos y túneles correctas")
    }

    private static func testLegacyMerge(fixtures: URL) throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("LegacyArchive.json"))
        let archive = try JSONDecoder().decode(ConfigurationArchive.self, from: data)
        try archive.validate()
        var settings = Settings()
        settings.profile = "LOCAL"
        let untouched = SavedConnection(id: UUID(), name: "Otra conexión", snapshot: ConnectionSnapshot(settings: settings))
        let collision = SavedConnection(id: UUID(), name: "Example instance", snapshot: ConnectionSnapshot(settings: settings))
        settings.savedConnections = [untouched, collision]
        precondition(archive.conflictingNames(with: settings) == ["Example instance"])
        let merged = archive.merged(into: settings)
        precondition(merged.savedConnections?.count == 2)
        precondition(merged.savedConnections?.first?.id == untouched.id)
        precondition(merged.savedConnections?.first?.snapshot.profile == "LOCAL")
        precondition(merged.savedConnections?.last?.id == collision.id)
        precondition(merged.savedConnections?.last?.snapshot.profile == "SAMPLE")
        precondition(merged.profile == "SAMPLE")
        precondition(merged.selectedSavedConnectionID == collision.id)
    }

    private static func testNamedExportAndTunnel() throws {
        var settings = Settings()
        settings.profile = "EDITADO"
        var tunnel = LocalTunnel()
        tunnel.name = "Agente"
        tunnel.host = "10.0.0.47"
        tunnel.privateKeyPath = "/tmp/example-agent.key"
        tunnel.localPort = 19081
        tunnel.remotePort = 9081
        settings.tunnels = [tunnel]
        var savedSettings = Settings()
        savedSettings.profile = "ANTERIOR"
        let saved = SavedConnection(id: UUID(), name: "Example agent", snapshot: ConnectionSnapshot(settings: savedSettings))
        settings.savedConnections = [saved]
        settings.selectedSavedConnectionID = saved.id
        let data = try JSONEncoder().encode(ConfigurationArchive(settings: settings, scope: .active))
        let archive = try JSONDecoder().decode(ConfigurationArchive.self, from: data)
        try archive.validate()
        precondition(archive.current == nil)
        precondition(archive.savedConnections.count == 1)
        precondition(archive.savedConnections[0].snapshot.profile == "EDITADO")
        precondition(archive.savedConnections[0].snapshot.tunnels == [tunnel])
        let command = try SSHCommands.localTunnel(tunnel, socksPort: 20000)
        precondition(command.contains("ProxyCommand=/usr/bin/nc -X 5 -x 127.0.0.1:20000 %h %p"))
        precondition(command.contains("-L '127.0.0.1:19081:127.0.0.1:9081'"))
        precondition(command.contains("-N"))
        precondition(command.contains("'opc@10.0.0.47'"))
    }

    private static func testCurrentOnlyExport() throws {
        var settings = Settings()
        settings.profile = "NUEVO"
        let archive = ConfigurationArchive(settings: settings, scope: .active)
        precondition(archive.current != nil && archive.savedConnections.isEmpty)
        var existing = Settings()
        existing.profile = "VIEJO"
        let saved = SavedConnection(id: UUID(), name: "Guardada", snapshot: ConnectionSnapshot(settings: existing))
        existing.savedConnections = [saved]
        let merged = archive.merged(into: existing)
        precondition(merged.profile == "NUEVO")
        precondition(merged.savedConnections == [saved])
    }

    private static func testAllExportAndNamedImport() throws {
        var original = Settings()
        original.profile = "ORIGINAL"
        let first = SavedConnection(id: UUID(), name: "Uno", snapshot: ConnectionSnapshot(settings: original))
        original.savedConnections = [first]
        original.selectedSavedConnectionID = first.id
        let all = try JSONDecoder().decode(ConfigurationArchive.self,
                                           from: JSONEncoder().encode(ConfigurationArchive(settings: original, scope: .all)))
        try all.validate()
        precondition(all.current?.profile == "ORIGINAL")
        precondition(all.savedConnections == [first])
        precondition(all.selectedSavedConnectionID == first.id)

        var other = Settings()
        other.profile = "SIN CAMBIAR"
        other.savedConnections = [SavedConnection(id: UUID(), name: "Otra", snapshot: ConnectionSnapshot(settings: other))]
        let namedOnly = ConfigurationArchive(settings: original, scope: .active)
        let merged = namedOnly.merged(into: other)
        precondition(merged.profile == "SIN CAMBIAR")
        precondition(merged.savedConnections?.count == 2)
        precondition(merged.savedConnections?.last?.name == "Uno")
    }

    private static func testNamedOnlyFixture(fixtures: URL) throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("NamedOnlyArchive.json"))
        let archive = try JSONDecoder().decode(ConfigurationArchive.self, from: data)
        try archive.validate()
        precondition(archive.current == nil)
        var existing = Settings()
        existing.profile = "PERFIL ACTUAL"
        let merged = archive.merged(into: existing)
        precondition(merged.profile == "PERFIL ACTUAL")
        precondition(merged.savedConnections?.count == 1)
    }

    private static func testPreviouslyGeneratedArchive(fixtures: URL) throws {
        let url = fixtures.appendingPathComponent("FromScriptArchive.json")
        let archive = try JSONDecoder().decode(ConfigurationArchive.self, from: Data(contentsOf: url))
        try archive.validate()
        precondition(archive.savedConnections.count == 2)
    }

    private static func testPortFormattingAndOwnership() {
        precondition(19081.formatted(.number.grouping(.never)) == "19081")
        let token = UUID()
        let record = OwnedTunnelRecord(pid: 123, token: token, port: 20000, target: "session@bastion.example")
        let command = "/usr/bin/ssh -N -D 127.0.0.1:20000 -o SetEnv=OCIBASTION_TUNNEL_ID=\(token.uuidString) session@bastion.example"
        precondition(record.matches(command: command))
        precondition(!record.matches(command: command.replacingOccurrences(of: token.uuidString, with: UUID().uuidString)))
        precondition(!record.matches(command: command.replacingOccurrences(of: "20000", with: "20001")))
    }
}
