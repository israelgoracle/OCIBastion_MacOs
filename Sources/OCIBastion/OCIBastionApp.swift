import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

@main
struct OCIBastionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = TunnelManager()

    var body: some Scene {
        WindowGroup("OCI Bastion", id: "main") {
            MainView(manager: manager)
                .frame(minWidth: 850, minHeight: 650)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            StatusMenu(manager: manager)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .overlay(alignment: .bottomTrailing) {
                    if manager.isConnected {
                        Circle().fill(.green).frame(width: 5, height: 5)
                    }
                }
                .accessibilityLabel("OCI Bastion")
        }
    }
}

struct StatusMenu: View {
    @ObservedObject var manager: TunnelManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(manager.status)
        if !manager.detail.isEmpty { Text(manager.detail) }
        Divider()
        Button("Abrir OCI Bastion") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if manager.isRunning {
            Button("Desconectar") { manager.disconnect() }
        } else {
            Button("Conectar") { manager.connect() }
        }
        Divider()
        Button("Salir") { manager.disconnect(); NSApp.terminate(nil) }
    }
}

struct MainView: View {
    @ObservedObject var manager: TunnelManager
    @State private var showSaveConnection = false
    @State private var showRenameConnection = false
    @State private var showDeleteConnection = false
    @State private var showExportChoice = false
    @State private var showImportConfirmation = false
    @State private var importPlan: ConfigurationImportPlan?
    @State private var connectionName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                GroupBox("Conexiones guardadas") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Conexión").frame(width: 125, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { manager.settings.selectedSavedConnectionID?.uuidString ?? "" },
                                set: { manager.loadConnection(id: UUID(uuidString: $0)) }
                            )) {
                                Text("Configuración actual").tag("")
                                ForEach(manager.savedConnections) { record in
                                    Text(record.name).tag(record.id.uuidString)
                                }
                            }.labelsHidden().frame(maxWidth: .infinity)
                                .disabled(manager.isRunning)
                        }
                        HStack {
                            Button("Guardar como…") {
                                connectionName = ""
                                showSaveConnection = true
                            }
                            .alert("Guardar conexión", isPresented: $showSaveConnection) {
                                TextField("Nombre", text: $connectionName)
                                Button("Guardar") { manager.saveCurrentAsConnection(named: connectionName) }
                                Button("Cancelar", role: .cancel) { }
                            } message: { Text("Guarda el perfil, Bastion, claves, proxy, terminal y destinos actuales.") }

                            Button("Actualizar") { manager.updateSelectedConnection() }
                                .disabled(manager.selectedConnection == nil)
                            Button("Renombrar…") {
                                connectionName = manager.selectedConnection?.name ?? ""
                                showRenameConnection = true
                            }
                            .disabled(manager.selectedConnection == nil)
                            .alert("Renombrar conexión", isPresented: $showRenameConnection) {
                                TextField("Nombre", text: $connectionName)
                                Button("Renombrar") { manager.renameSelectedConnection(to: connectionName) }
                                Button("Cancelar", role: .cancel) { }
                            }

                            Button("Eliminar") { showDeleteConnection = true }
                                .disabled(manager.selectedConnection == nil)
                                .confirmationDialog("Eliminar la conexión guardada", isPresented: $showDeleteConnection) {
                                    Button("Eliminar conexión", role: .destructive) { manager.deleteSelectedConnection() }
                                } message: { Text("Los datos que están en pantalla permanecerán disponibles.") }
                            Spacer()
                            if manager.selectedConnectionHasChanges {
                                Text("Cambios sin actualizar").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        HStack {
                            Button("Exportar configuración…") {
                                showExportChoice = true
                            }
                            .confirmationDialog("¿Qué quieres exportar?", isPresented: $showExportChoice) {
                                Button("Todas las conexiones y la configuración actual") { exportConfiguration(scope: .all) }
                                Button("Solo la configuración activa") { exportConfiguration(scope: .active) }
                                Button("Cancelar", role: .cancel) { }
                            } message: {
                                Text("La configuración activa incluye los cambios que aparecen ahora en pantalla.")
                            }
                            Button("Importar configuración…") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.json, .plainText]
                                panel.canChooseFiles = true
                                panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    if let plan = manager.prepareImport(from: url) {
                                        if plan.needsConfirmation {
                                            importPlan = plan
                                            showImportConfirmation = true
                                        } else {
                                            manager.applyImport(plan)
                                        }
                                    }
                                }
                            }
                            .disabled(manager.isRunning)
                            .confirmationDialog("Confirmar sobrescritura", isPresented: $showImportConfirmation) {
                                Button("Importar y sobrescribir", role: .destructive) {
                                    if let importPlan { manager.applyImport(importPlan) }
                                    importPlan = nil
                                }
                                Button("Cancelar", role: .cancel) { importPlan = nil }
                            } message: {
                                Text(importWarning)
                            }
                            Spacer()
                        }
                    }.padding(8)
                }
                GroupBox("OCI CLI") {
                    VStack(alignment: .leading, spacing: 10) {
                        fileField("Archivo config", path: $manager.settings.configPath) { manager.reloadProfiles() }
                        HStack {
                            Text("Perfil").frame(width: 125, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { manager.settings.profile },
                                set: { manager.selectProfile($0) }
                            )) {
                                ForEach(manager.profiles, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(maxWidth: .infinity)
                            Button("Recargar") { manager.reloadProfiles() }
                        }
                        HStack {
                            Text("Compartimento").frame(width: 125, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { manager.settings.compartmentID },
                                set: { manager.selectCompartment($0) }
                            )) {
                                Text("Seleccionar…").tag("")
                                ForEach(manager.compartments) { Text($0.label).tag($0.id) }
                                if !manager.settings.compartmentID.isEmpty && !manager.compartments.contains(where: { $0.id == manager.settings.compartmentID }) {
                                    Text("Compartimento guardado").tag(manager.settings.compartmentID)
                                }
                            }.labelsHidden().frame(maxWidth: .infinity)
                            Button(manager.isLoadingCompartments ? "Cargando…" : "Cargar compartimentos") { manager.refreshCompartments() }
                                .disabled(manager.isLoadingCompartments)
                        }
                        HStack {
                            Text("OCID manual").frame(width: 125, alignment: .leading)
                            TextField("Pega el OCID si no puedes listar", text: Binding(
                                get: { manager.settings.compartmentID },
                                set: { manager.editCompartmentID($0) }
                            ))
                            Button("Buscar bastiones") { manager.refreshBastions() }
                        }
                        if !manager.compartments.isEmpty {
                            HStack {
                                Text("\(manager.loadedCompartmentCount) compartimentos cargados")
                                    .font(.caption).foregroundStyle(.secondary)
                                if manager.hasMoreCompartments {
                                    Button(manager.isLoadingCompartments ? "Cargando…" : "Cargar 100 más") {
                                        manager.loadMoreCompartments()
                                    }.disabled(manager.isLoadingCompartments)
                                }
                            }
                        }
                        HStack {
                            Text("Bastion").frame(width: 125, alignment: .leading)
                            Picker("", selection: $manager.settings.bastionID) {
                                Text("Seleccionar…").tag("")
                                ForEach(manager.bastions) { Text($0.name).tag($0.id) }
                                if !manager.settings.bastionID.isEmpty && !manager.bastions.contains(where: { $0.id == manager.settings.bastionID }) {
                                    Text("Bastion guardado").tag(manager.settings.bastionID)
                                }
                            }.labelsHidden().frame(maxWidth: .infinity)
                        }
                        HStack {
                            Text("OCID manual").frame(width: 125, alignment: .leading)
                            TextField("Pega el OCID si no puedes listar", text: $manager.settings.bastionID)
                        }
                    }.padding(8)
                }

                GroupBox("Sesión SOCKS5") {
                    VStack(alignment: .leading, spacing: 10) {
                        fileField("Clave pública", path: $manager.settings.publicKeyPath)
                        fileField("Clave privada", path: $manager.settings.privateKeyPath)
                        HStack {
                            Text("Puerto local").frame(width: 125, alignment: .leading)
                            TextField("2222", value: $manager.settings.socksPort, format: .number.grouping(.never)).frame(width: 90)
                            Text("Duración (seg)").padding(.leading, 15)
                            TextField("10800", value: $manager.settings.ttlSeconds, format: .number.grouping(.never)).frame(width: 90)
                            Spacer()
                        }
                        HStack {
                            Text("Proxy HTTP").frame(width: 125, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { manager.settings.effectiveProxyMode },
                                set: { manager.settings.proxyMode = $0 }
                            )) {
                                Text("Automático").tag(ProxyMode.automatic)
                                Text("Manual").tag(ProxyMode.manual)
                                Text("Directo").tag(ProxyMode.direct)
                            }.labelsHidden().frame(width: 150)
                            if manager.settings.effectiveProxyMode == .manual {
                                TextField("Host", text: $manager.settings.proxyHost)
                                TextField("Puerto", value: $manager.settings.proxyPort, format: .number.grouping(.never)).frame(width: 90)
                            }
                        }
                        if !manager.proxyDescription.isEmpty {
                            Text(manager.proxyDescription).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }

                GroupBox("Destinos SSH") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Aplicación de terminal").frame(width: 145, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { manager.settings.effectiveTerminalApp },
                                set: { manager.settings.terminalApp = $0 }
                            )) {
                                Text("Terminal").tag(TerminalApp.terminal)
                                Text("iTerm2").tag(TerminalApp.iterm)
                            }.labelsHidden().frame(width: 170)
                            Spacer()
                        }
                        ForEach($manager.settings.destinations) { $destination in
                            DestinationEditor(destination: $destination,
                                              open: { manager.openDestination(destination) },
                                              copy: { manager.copyDestinationCommand(destination) },
                                              remove: { manager.removeDestination(destination.id) })
                            Divider()
                        }
                        HStack {
                            Button("Añadir destino") { manager.settings.destinations.append(Destination()) }
                            Spacer()
                            Text("La clave de la instancia puede ser distinta de la del Bastion.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }

                GroupBox("Túneles SSH locales") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Binding<[LocalTunnel]>(
                            get: { manager.settings.tunnels ?? [] },
                            set: { manager.settings.tunnels = $0 }
                        )) { $tunnel in
                            LocalTunnelEditor(tunnel: $tunnel,
                                              open: { manager.openLocalTunnel(tunnel) },
                                              copy: { manager.copyLocalTunnelCommand(tunnel) },
                                              remove: { manager.removeLocalTunnel(tunnel.id) })
                            Divider()
                        }
                        HStack {
                            Button("Añadir túnel") {
                                var records = manager.settings.tunnels ?? []
                                records.append(LocalTunnel())
                                manager.settings.tunnels = records
                            }
                            Spacer()
                            Text("Requiere el SOCKS5 del Bastion activo; el puerto local solo escucha en 127.0.0.1.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }

                HStack {
                    Button("Guardar") { manager.save() }
                    Button("Limpiar campos") { manager.clearCurrentConfiguration() }
                        .disabled(manager.isRunning)
                    if manager.isRunning {
                        Button("Desconectar") { manager.disconnect() }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Conectar Bastion") { manager.connect() }.buttonStyle(.borderedProminent)
                    }
                    Button("Copiar SSH Bastion") { manager.copyBastionCommand() }
                        .disabled(manager.activeBastionCommand == nil)
                    Spacer()
                    Text(manager.status).fontWeight(.semibold)
                }
                if !manager.detail.isEmpty {
                    Text(manager.detail).font(.caption).foregroundStyle(manager.status == "Conectado" ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
                if let expires = manager.sessionExpiresAt {
                    Text("Sesión OCI hasta: \(expires.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OCI Bastion").font(.largeTitle).fontWeight(.bold)
            Text("Gestiona una sesión SOCKS5 y abre SSH a instancias privadas.")
                .foregroundStyle(.secondary)
        }
    }

    private var importWarning: String {
        guard let importPlan else { return "" }
        var changes: [String] = []
        if importPlan.archive.current != nil { changes.append("la configuración actual") }
        if !importPlan.conflictingNames.isEmpty {
            changes.append("las conexiones con el mismo nombre: " + importPlan.conflictingNames.joined(separator: ", "))
        }
        return "El archivo \(importPlan.fileName) sobrescribirá " + changes.joined(separator: " y ") + ". Las demás conexiones se conservarán."
    }

    private func exportConfiguration(scope: ExportScope) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = scope == .all ? "OCI-Bastion-todo.json" : "OCI-Bastion-activa.json"
        if panel.runModal() == .OK, let url = panel.url {
            manager.exportConfiguration(to: url, scope: scope)
        }
    }

    private func fileField(_ title: String, path: Binding<String>, afterPick: @escaping () -> Void = {}) -> some View {
        HStack {
            Text(title).frame(width: 125, alignment: .leading)
            TextField("Selecciona un archivo", text: path)
            Button("Elegir…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.showsHiddenFiles = true
                if panel.runModal() == .OK, let url = panel.url {
                    path.wrappedValue = url.path
                    afterPick()
                }
            }
        }
    }
}

struct DestinationEditor: View {
    @Binding var destination: Destination
    let open: () -> Void
    let copy: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Nombre", text: $destination.name).frame(width: 160)
                TextField("IP privada o DNS", text: $destination.host)
                TextField("Usuario", text: $destination.user).frame(width: 100)
                TextField("Puerto", value: $destination.port, format: .number.grouping(.never)).frame(width: 65)
                Button("Abrir SSH", action: open)
                Button("Copiar SSH", action: copy)
                Button("Eliminar", action: remove)
            }
            HStack {
                Text("Clave instancia").font(.caption).frame(width: 105, alignment: .leading)
                TextField("Ruta de la clave privada", text: $destination.privateKeyPath)
                Button("Elegir…") {
                    let panel = NSOpenPanel()
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { destination.privateKeyPath = url.path }
                }
            }
        }
    }
}

struct LocalTunnelEditor: View {
    @Binding var tunnel: LocalTunnel
    let open: () -> Void
    let copy: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Nombre", text: $tunnel.name).frame(width: 160)
                TextField("IP privada o DNS SSH", text: $tunnel.host)
                TextField("Usuario", text: $tunnel.user).frame(width: 100)
                TextField("Puerto SSH", value: $tunnel.sshPort, format: .number.grouping(.never)).frame(width: 85)
            }
            HStack {
                Text("Clave instancia").font(.caption).frame(width: 105, alignment: .leading)
                TextField("Ruta de la clave privada", text: $tunnel.privateKeyPath)
                Button("Elegir…") {
                    let panel = NSOpenPanel()
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { tunnel.privateKeyPath = url.path }
                }
            }
            HStack {
                Text("Puerto local (origen)").font(.caption)
                TextField("19081", value: $tunnel.localPort, format: .number.grouping(.never)).frame(width: 85)
                Text("Host remoto").font(.caption)
                TextField("127.0.0.1", text: $tunnel.remoteHost).frame(width: 140)
                Text("Puerto remoto (destino)").font(.caption)
                TextField("9081", value: $tunnel.remotePort, format: .number.grouping(.never)).frame(width: 85)
                Spacer()
                Button("Abrir túnel", action: open)
                Button("Copiar SSH", action: copy)
                Button("Eliminar", action: remove)
            }
        }
    }
}
