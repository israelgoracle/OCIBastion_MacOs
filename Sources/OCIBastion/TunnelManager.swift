import AppKit
import Foundation

@MainActor
final class TunnelManager: ObservableObject {
    @Published var settings = Settings.load()
    @Published var profiles: [String] = []
    @Published var compartments: [CompartmentItem] = []
    @Published var isLoadingCompartments = false
    @Published var hasMoreCompartments = false
    @Published var loadedCompartmentCount = 0
    @Published var bastions: [BastionItem] = []
    @Published var status = "Desconectado"
    @Published var detail = ""
    @Published var isConnected = false
    @Published var isRunning = false
    @Published var sessionExpiresAt: Date?
    @Published var proxyDescription = ""
    @Published var activeBastionCommand: String?

    private var connectionTask: Task<Void, Never>?
    private var tunnelProcess: Process?
    private var ownedTunnelRecord: OwnedTunnelRecord?
    private var activeSocksPort: Int?
    private var loadedConfigPath = ""
    private var compartmentRecords: [CompartmentRecord] = []
    private var nextCompartmentPage: String?
    private var compartmentTenancyID = ""
    private var cachedProxy: (key: String, endpoint: ProxyEndpoint?, source: String)?

    init() {
        if let selected = settings.selectedSavedConnectionID,
           !(settings.savedConnections ?? []).contains(where: { $0.id == selected }) {
            settings.selectedSavedConnectionID = nil
        }
        loadedConfigPath = settings.configPath
        if !settings.configPath.isEmpty { reloadProfiles() }
    }

    var savedConnections: [SavedConnection] { settings.savedConnections ?? [] }

    var selectedConnection: SavedConnection? {
        savedConnections.first { $0.id == settings.selectedSavedConnectionID }
    }

    var selectedConnectionHasChanges: Bool {
        guard let selectedConnection else { return false }
        return selectedConnection.snapshot != ConnectionSnapshot(settings: settings)
    }

    func saveCurrentAsConnection(named rawName: String) {
        do {
            let name = try InputCheck.singleLine(rawName, name: "Nombre de conexión")
            guard !savedConnections.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw AppError.message("Ya existe una conexión con ese nombre.")
            }
            var records = savedConnections
            let record = SavedConnection(id: UUID(), name: name, snapshot: ConnectionSnapshot(settings: settings))
            records.append(record)
            settings.savedConnections = records
            settings.selectedSavedConnectionID = record.id
            save()
            detail = "Conexión «\(name)» guardada."
        } catch { detail = error.localizedDescription }
    }

    func loadConnection(id: UUID?) {
        guard !isRunning else {
            detail = "Desconecta el túnel antes de cambiar de conexión."
            return
        }
        guard let id else {
            settings.selectedSavedConnectionID = nil
            save()
            return
        }
        guard let record = savedConnections.first(where: { $0.id == id }) else { return }
        record.snapshot.apply(to: &settings)
        settings.selectedSavedConnectionID = id
        loadedConfigPath = settings.configPath
        if !settings.configPath.isEmpty { reloadProfiles() }
        else {
            profiles = []
            compartments = []
            bastions = []
        }
        save()
        detail = "Conexión «\(record.name)» cargada."
    }

    func updateSelectedConnection() {
        guard let id = settings.selectedSavedConnectionID else { return }
        var records = savedConnections
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].snapshot = ConnectionSnapshot(settings: settings)
        settings.savedConnections = records
        save()
        detail = "Conexión «\(records[index].name)» actualizada."
    }

    func renameSelectedConnection(to rawName: String) {
        do {
            guard let id = settings.selectedSavedConnectionID else { return }
            let name = try InputCheck.singleLine(rawName, name: "Nombre de conexión")
            var records = savedConnections
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            guard !records.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw AppError.message("Ya existe una conexión con ese nombre.")
            }
            records[index].name = name
            settings.savedConnections = records
            save()
            detail = "Conexión renombrada como «\(name)»."
        } catch { detail = error.localizedDescription }
    }

    func deleteSelectedConnection() {
        guard let id = settings.selectedSavedConnectionID else { return }
        settings.savedConnections = savedConnections.filter { $0.id != id }
        settings.selectedSavedConnectionID = nil
        save()
        detail = "Conexión guardada eliminada; los datos actuales siguen en pantalla."
    }

    func clearCurrentConfiguration() {
        guard !isRunning else {
            detail = "Desconecta el túnel antes de limpiar los campos."
            return
        }
        var cleared = Settings()
        cleared.profile = ""
        cleared.savedConnections = savedConnections
        do {
            try cleared.save()
            settings = cleared
            loadedConfigPath = ""
            profiles = []
            compartments = []
            compartmentRecords = []
            nextCompartmentPage = nil
            compartmentTenancyID = ""
            hasMoreCompartments = false
            loadedCompartmentCount = 0
            bastions = []
            cachedProxy = nil
            proxyDescription = ""
            activeBastionCommand = nil
            sessionExpiresAt = nil
            detail = "Campos limpiados; las conexiones guardadas siguen disponibles."
        } catch {
            detail = "No se pudieron limpiar los campos: \(error.localizedDescription)"
        }
    }

    func exportConfiguration(to url: URL, scope: ExportScope) {
        do {
            let archive = ConfigurationArchive(settings: settings, scope: scope)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(archive)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            detail = "Configuración exportada a \(url.lastPathComponent)."
        } catch {
            detail = "No se pudo exportar la configuración: \(error.localizedDescription)"
        }
    }

    func prepareImport(from url: URL) -> ConfigurationImportPlan? {
        guard !isRunning else {
            detail = "Desconecta el túnel antes de importar una configuración."
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let archive = try JSONDecoder().decode(ConfigurationArchive.self, from: data)
            try archive.validate()
            return ConfigurationImportPlan(archive: archive, fileName: url.lastPathComponent,
                                           conflictingNames: archive.conflictingNames(with: settings))
        } catch {
            detail = "No se pudo leer el archivo de importación: \(error.localizedDescription)"
            return nil
        }
    }

    func applyImport(_ plan: ConfigurationImportPlan) {
        guard !isRunning else {
            detail = "Desconecta el túnel antes de importar una configuración."
            return
        }
        do {
            let imported = plan.archive.merged(into: settings)
            try imported.save()
            settings = imported
            if plan.archive.current != nil {
                loadedConfigPath = imported.configPath
                profiles = (try? OCIConfig.profiles(at: imported.configPath)) ?? []
                compartments = []
                compartmentRecords = []
                nextCompartmentPage = nil
                hasMoreCompartments = false
                loadedCompartmentCount = 0
                bastions = []
                cachedProxy = nil
                proxyDescription = ""
                activeBastionCommand = nil
                sessionExpiresAt = nil
            }
            detail = "Importación completada: \(plan.archive.savedConnections.count) conexiones procesadas."
        } catch {
            detail = "No se pudo importar la configuración: \(error.localizedDescription)"
        }
    }

    func save() {
        do { try settings.save() }
        catch { detail = "No se pudo guardar la configuración: \(error.localizedDescription)" }
    }

    private func resolvedProxy(for value: Settings, fresh: Bool = false) async throws -> (endpoint: ProxyEndpoint?, source: String) {
        let key = "\(value.effectiveProxyMode.rawValue)|\(value.proxyHost)|\(value.proxyPort)|\(value.profile)|\(value.configPath)"
        if !fresh, let cachedProxy, cachedProxy.key == key {
            return (cachedProxy.endpoint, cachedProxy.source)
        }
        let result = try await ProxyResolver.resolve(settings: value)
        cachedProxy = (key, result.endpoint, result.source)
        proxyDescription = result.endpoint.map { "\(result.source): \($0.address)" } ?? result.source
        return result
    }

    func reloadProfiles() {
        do {
            let configChanged = loadedConfigPath != settings.configPath
            profiles = try OCIConfig.profiles(at: settings.configPath)
            let oldProfile = settings.profile
            if !profiles.contains(settings.profile), let first = profiles.first { settings.profile = first }
            if configChanged || settings.profile != oldProfile {
                settings.compartmentID = ""
                settings.bastionID = ""
            }
            loadedConfigPath = settings.configPath
            compartments = []
            compartmentRecords = []
            nextCompartmentPage = nil
            hasMoreCompartments = false
            loadedCompartmentCount = 0
            bastions = []
            detail = ""
        } catch {
            profiles = []
            detail = "No se pudo leer el archivo OCI: \(error.localizedDescription)"
        }
    }

    func selectProfile(_ profile: String) {
        guard settings.profile != profile else { return }
        settings.profile = profile
        settings.compartmentID = ""
        settings.bastionID = ""
        compartments = []
        compartmentRecords = []
        nextCompartmentPage = nil
        hasMoreCompartments = false
        loadedCompartmentCount = 0
        bastions = []
        save()
    }

    func refreshCompartments() {
        loadCompartmentPage(reset: true)
    }

    func loadMoreCompartments() {
        loadCompartmentPage(reset: false)
    }

    private func loadCompartmentPage(reset: Bool) {
        guard !isLoadingCompartments else { return }
        if !reset && nextCompartmentPage == nil { return }
        let snapshot = settings
        let pageToken = reset ? nil : nextCompartmentPage
        if reset {
            compartments = []
            compartmentRecords = []
            nextCompartmentPage = nil
            hasMoreCompartments = false
            loadedCompartmentCount = 0
        }
        isLoadingCompartments = true
        Task {
            defer { isLoadingCompartments = false }
            do {
                let proxy = try await resolvedProxy(for: snapshot)
                let result = try await OCIClient(settings: snapshot, proxy: proxy.endpoint).listCompartments(page: pageToken)
                guard settings.profile == snapshot.profile, settings.configPath == snapshot.configPath else { return }
                compartmentTenancyID = result.tenancyID
                var recordsByID = Dictionary(uniqueKeysWithValues: compartmentRecords.map { ($0.id, $0) })
                for record in result.records { recordsByID[record.id] = record }
                compartmentRecords = Array(recordsByID.values)
                compartments = OCIClient.compartmentItems(tenancyID: compartmentTenancyID, records: compartmentRecords)
                nextCompartmentPage = result.nextPage?.isEmpty == false ? result.nextPage : nil
                hasMoreCompartments = nextCompartmentPage != nil
                loadedCompartmentCount = compartmentRecords.count
                detail = compartmentRecords.isEmpty && !hasMoreCompartments
                    ? "No se encontraron compartimentos accesibles bajo la tenancy." : ""
            } catch { detail = "No se pudieron cargar los compartimentos: \(error.localizedDescription)" }
        }
    }

    func selectCompartment(_ id: String) {
        guard settings.compartmentID != id else { return }
        settings.compartmentID = id
        settings.bastionID = ""
        bastions = []
        save()
    }

    func editCompartmentID(_ id: String) {
        guard settings.compartmentID != id else { return }
        settings.compartmentID = id
        settings.bastionID = ""
        bastions = []
    }

    func refreshBastions() {
        let snapshot = settings
        Task {
            do {
                _ = try InputCheck.singleLine(snapshot.compartmentID, name: "OCID del compartimento")
                let proxy = try await resolvedProxy(for: snapshot)
                let results = try await OCIClient(settings: snapshot, proxy: proxy.endpoint).listBastions()
                guard settings.profile == snapshot.profile,
                      settings.configPath == snapshot.configPath,
                      settings.compartmentID == snapshot.compartmentID else { return }
                bastions = results
                detail = bastions.isEmpty ? "No se encontraron bastiones en este compartimento." : ""
            } catch { detail = error.localizedDescription }
        }
    }

    func connect() {
        guard connectionTask == nil else { return }
        do { try validate(settings) }
        catch {
            status = "Requiere intervención"
            detail = error.localizedDescription
            return
        }
        save()
        isRunning = true
        connectionTask = Task { await connectionLoop() }
    }

    func disconnect() {
        connectionTask?.cancel()
        if let tunnelProcess, tunnelProcess.isRunning { tunnelProcess.terminate() }
        activeSocksPort = nil
        isConnected = false
        sessionExpiresAt = nil
        activeBastionCommand = nil
        proxyDescription = ""
        status = connectionTask == nil ? "Desconectado" : "Desconectando"
        detail = ""
    }

    func removeDestination(_ id: UUID) {
        settings.destinations.removeAll { $0.id == id }
        save()
    }

    func removeLocalTunnel(_ id: UUID) {
        settings.tunnels?.removeAll { $0.id == id }
        save()
    }

    private func validate(_ value: Settings) throws {
        _ = try InputCheck.singleLine(value.configPath, name: "Configuración OCI")
        _ = try InputCheck.singleLine(value.profile, name: "Perfil OCI")
        _ = try InputCheck.singleLine(value.bastionID, name: "OCID del Bastion")
        _ = try InputCheck.singleLine(value.publicKeyPath, name: "Clave pública")
        _ = try InputCheck.singleLine(value.privateKeyPath, name: "Clave privada")
        try InputCheck.port(value.socksPort)
        guard (1800...10800).contains(value.ttlSeconds) else {
            throw AppError.message("La duración de sesión debe estar entre 1800 y 10800 segundos.")
        }
        if value.effectiveProxyMode == .manual {
            _ = try InputCheck.sshToken(value.proxyHost, name: "Host del proxy corporativo")
            try InputCheck.port(value.proxyPort)
        }
    }

    private func connectionLoop() async {
        var retry = 1
        var failedSessionID = ""
        var failuresForSession = 0
        while !Task.isCancelled {
            do {
                let snapshot = settings
                try validate(snapshot)
                if try await OwnedTunnelRecord.reclaimPrevious() {
                    detail = "Se cerró un túnel SSH anterior de OCI Bastion."
                }
                if let pid = await OwnedTunnelRecord.listenerPID(port: snapshot.socksPort) {
                    throw TunnelPortError.inUse(port: snapshot.socksPort, pid: pid)
                }
                status = "Comprobando claves"
                let fingerprint = try await KeyValidation.checkPair(publicPath: snapshot.publicKeyPath, privatePath: snapshot.privateKeyPath)
                try Task.checkCancellation()

                status = "Detectando proxy"
                let resolvedProxy = try await resolvedProxy(for: snapshot, fresh: true)
                try Task.checkCancellation()

                status = "Preparando sesión OCI"
                let client = OCIClient(settings: snapshot, proxy: resolvedProxy.endpoint)
                var session: BastionSession?
                if !snapshot.ownedSessionID.isEmpty,
                   snapshot.ownedSessionKeyFingerprint == fingerprint,
                   !(snapshot.ownedSessionID == failedSessionID && failuresForSession >= 3) {
                    session = try? await client.getOwnedSession(id: snapshot.ownedSessionID)
                }
                if session == nil || (session!.expiresAt ?? .distantFuture) < Date().addingTimeInterval(90) {
                    let publicKey = try String(contentsOfFile: snapshot.publicKeyPath, encoding: .utf8)
                    session = try await client.createSession(publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    settings.ownedSessionID = session!.id
                    settings.ownedSessionKeyFingerprint = fingerprint
                    save()
                }
                try Task.checkCancellation()
                guard let activeSession = session else { throw AppError.message("No hay sesión Bastion activa.") }
                sessionExpiresAt = activeSession.expiresAt
                activeBastionCommand = try SSHCommands.bastion(target: activeSession.sshTarget,
                    privateKeyPath: snapshot.privateKeyPath, socksPort: snapshot.socksPort, proxy: resolvedProxy.endpoint)
                status = "Conectando túnel"
                let (process, record) = try startTunnel(session: activeSession, settings: snapshot, proxy: resolvedProxy.endpoint)
                tunnelProcess = process
                ownedTunnelRecord = record
                do { try await waitUntilListening(process: process, port: snapshot.socksPort) }
                catch {
                    if process.isRunning { process.terminate() }
                    _ = await waitForTunnel(process)
                    record.removeIfCurrent()
                    ownedTunnelRecord = nil
                    tunnelProcess = nil
                    if failedSessionID == activeSession.id { failuresForSession += 1 }
                    else { failedSessionID = activeSession.id; failuresForSession = 1 }
                    throw error
                }
                try Task.checkCancellation()
                status = "Conectado"
                detail = "SOCKS5 en 127.0.0.1:\(snapshot.socksPort)"
                isConnected = true
                activeSocksPort = snapshot.socksPort
                retry = 1
                let output = await waitForTunnel(process)
                record.removeIfCurrent()
                ownedTunnelRecord = nil
                tunnelProcess = nil
                isConnected = false
                activeSocksPort = nil
                if Task.isCancelled { break }
                if failedSessionID == activeSession.id { failuresForSession += 1 }
                else { failedSessionID = activeSession.id; failuresForSession = 1 }
                status = "Reconectando"
                detail = output.isEmpty ? "El túnel SSH terminó. Reintentando…" : output
                if output.contains("Permission denied") || output.contains("Host key verification failed") || output.contains("passphrase") {
                    status = "Requiere intervención"
                    break
                }
            } catch is CancellationError {
                break
            } catch let error as TunnelPortError {
                isConnected = false
                status = "Requiere intervención"
                detail = error.localizedDescription
                break
            } catch {
                isConnected = false
                status = "Reconectando"
                detail = error.localizedDescription
                if detail.contains("no forman pareja") || detail.contains("No existe la clave") || detail.contains("No se encuentra OCI CLI") || detail.contains("NotAuthorizedOrNotFound") || detail.contains("Permission denied") || detail.contains("Host key verification failed") || detail.contains("passphrase") || detail.contains("Address already in use") || detail.contains("Could not request local forwarding") {
                    status = "Requiere intervención"
                    break
                }
            }
            if Task.isCancelled { break }
            let delay = min(retry, 30)
            retry = min(retry * 2, 30)
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }
        if let tunnelProcess, tunnelProcess.isRunning {
            tunnelProcess.terminate()
            _ = await waitForTunnel(tunnelProcess)
        }
        ownedTunnelRecord?.removeIfCurrent()
        ownedTunnelRecord = nil
        tunnelProcess = nil
        isConnected = false
        activeSocksPort = nil
        activeBastionCommand = nil
        isRunning = false
        connectionTask = nil
        if status != "Requiere intervención" { status = "Desconectado" }
    }

    private func startTunnel(session: BastionSession, settings: Settings, proxy: ProxyEndpoint?) throws -> (Process, OwnedTunnelRecord) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let token = UUID()
        var args = [
            "-i", settings.privateKeyPath, "-N", "-D", "127.0.0.1:\(settings.socksPort)",
            "-p", "22", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "SetEnv=OCIBASTION_TUNNEL_ID=\(token.uuidString)"
        ]
        if let proxy {
            args += ["-o", "ProxyCommand=/usr/bin/nc -X connect -x \(proxy.address) %h %p"]
        }
        args.append(session.sshTarget)
        process.arguments = args
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let record = OwnedTunnelRecord(pid: process.processIdentifier, token: token,
                                       port: settings.socksPort, target: session.sshTarget)
        do { try record.save() }
        catch {
            process.terminate()
            throw error
        }
        return (process, record)
    }

    private func waitUntilListening(process: Process, port: Int) async throws {
        for _ in 0..<16 {
            try Task.checkCancellation()
            guard process.isRunning else {
                let data = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                let reason = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppError.message(reason.isEmpty ? "SSH terminó antes de abrir el puerto SOCKS5." : reason)
            }
            let result = try await CommandRunner.run("/usr/bin/nc", ["-z", "-w", "1", "127.0.0.1", String(port)])
            if result.status == 0 && process.isRunning {
                if let pid = await OwnedTunnelRecord.listenerPID(port: port) {
                    if pid == process.processIdentifier { return }
                    throw TunnelPortError.inUse(port: port, pid: pid)
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw AppError.message("SSH no abrió el puerto SOCKS5 a tiempo.")
    }

    private func waitForTunnel(_ process: Process) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let error = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                continuation.resume(returning: String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func openDestination(_ destination: Destination) {
        do {
            guard isConnected, let socksPort = activeSocksPort else { throw AppError.message("Conecta primero el túnel Bastion.") }
            let command = try SSHCommands.destination(destination, socksPort: socksPort)
            let terminalApp = settings.effectiveTerminalApp
            Task {
                do {
                    try await TerminalLauncher.open(command: command, in: terminalApp)
                } catch { detail = error.localizedDescription }
            }
        } catch { detail = error.localizedDescription }
    }

    func copyDestinationCommand(_ destination: Destination) {
        do {
            let command = try SSHCommands.destination(destination, socksPort: activeSocksPort ?? settings.socksPort)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            detail = "Comando SSH copiado. El túnel SOCKS5 debe estar activo al ejecutarlo."
        } catch { detail = error.localizedDescription }
    }

    func openLocalTunnel(_ tunnel: LocalTunnel) {
        do {
            guard isConnected, let socksPort = activeSocksPort else { throw AppError.message("Conecta primero el túnel Bastion.") }
            let command = try SSHCommands.localTunnel(tunnel, socksPort: socksPort)
            let terminalApp = settings.effectiveTerminalApp
            Task {
                do { try await TerminalLauncher.open(command: command, in: terminalApp) }
                catch { detail = error.localizedDescription }
            }
        } catch { detail = error.localizedDescription }
    }

    func copyLocalTunnelCommand(_ tunnel: LocalTunnel) {
        do {
            let command = try SSHCommands.localTunnel(tunnel, socksPort: activeSocksPort ?? settings.socksPort)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            detail = "Comando del túnel copiado. El SOCKS5 del Bastion debe estar activo al ejecutarlo."
        } catch { detail = error.localizedDescription }
    }

    func copyBastionCommand() {
        guard let activeBastionCommand else {
            detail = "Conecta el Bastion para obtener el comando de esta sesión."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(activeBastionCommand, forType: .string)
        detail = "Comando del túnel Bastion copiado."
    }
}
