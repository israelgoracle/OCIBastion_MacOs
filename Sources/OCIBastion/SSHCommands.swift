import Foundation

enum SSHCommands {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func destination(_ destination: Destination, socksPort: Int) throws -> String {
        let host = try InputCheck.sshToken(destination.host, name: "Host")
        let user = try InputCheck.sshToken(destination.user, name: "Usuario")
        let key = try InputCheck.singleLine(destination.privateKeyPath, name: "Clave privada de la instancia")
        try InputCheck.port(destination.port)
        try InputCheck.port(socksPort)
        let proxy = "ProxyCommand=/usr/bin/nc -X 5 -x 127.0.0.1:\(socksPort) %h %p"
        return [
            "ssh", "-i", quote(key),
            "-o", quote("IdentitiesOnly=yes"),
            "-o", quote(proxy),
            "-o", quote("ServerAliveInterval=30"),
            "-o", quote("ServerAliveCountMax=3"),
            "-p", String(destination.port), quote("\(user)@\(host)")
        ].joined(separator: " ")
    }

    static func localTunnel(_ tunnel: LocalTunnel, socksPort: Int) throws -> String {
        let host = try InputCheck.sshToken(tunnel.host, name: "Host SSH")
        let user = try InputCheck.sshToken(tunnel.user, name: "Usuario SSH")
        let remoteHost = try InputCheck.sshToken(tunnel.remoteHost, name: "Host destino del túnel")
        let key = try InputCheck.singleLine(tunnel.privateKeyPath, name: "Clave privada del túnel")
        try InputCheck.port(tunnel.sshPort)
        try InputCheck.port(tunnel.localPort)
        try InputCheck.port(tunnel.remotePort)
        try InputCheck.port(socksPort)
        let proxy = "ProxyCommand=/usr/bin/nc -X 5 -x 127.0.0.1:\(socksPort) %h %p"
        let forwarding = "127.0.0.1:\(tunnel.localPort):\(remoteHost):\(tunnel.remotePort)"
        return [
            "ssh", "-i", quote(key),
            "-o", quote("IdentitiesOnly=yes"),
            "-o", quote(proxy),
            "-o", quote("ExitOnForwardFailure=yes"),
            "-o", quote("ServerAliveInterval=30"),
            "-o", quote("ServerAliveCountMax=3"),
            "-N", "-L", quote(forwarding),
            "-p", String(tunnel.sshPort), quote("\(user)@\(host)")
        ].joined(separator: " ")
    }

    static func bastion(target: String, privateKeyPath: String, socksPort: Int, proxy: ProxyEndpoint?) throws -> String {
        let key = try InputCheck.singleLine(privateKeyPath, name: "Clave privada del Bastion")
        try InputCheck.port(socksPort)
        let parts = target.split(separator: "@")
        guard parts.count == 2 else { throw AppError.message("Destino SSH del Bastion no válido.") }
        _ = try InputCheck.sshToken(String(parts[0]), name: "Usuario de sesión")
        _ = try InputCheck.sshToken(String(parts[1]), name: "Host del Bastion")
        var arguments = [
            "ssh", "-i", quote(key), "-N", "-D", "127.0.0.1:\(socksPort)",
            "-p", "22", "-o", quote("ServerAliveInterval=30"),
            "-o", quote("ServerAliveCountMax=3"),
            "-o", quote("ExitOnForwardFailure=yes")
        ]
        if let proxy {
            arguments += ["-o", quote("ProxyCommand=/usr/bin/nc -X connect -x \(proxy.address) %h %p")]
        }
        arguments.append(quote(target))
        return arguments.joined(separator: " ")
    }
}

enum TerminalLauncher {
    static func open(command: String, in app: TerminalApp) async throws {
        let arguments: [String]
        let name: String
        switch app {
        case .terminal:
            name = "Terminal"
            let script = """
            on run argv
                tell application "Terminal"
                    activate
                    do script (item 1 of argv)
                end tell
            end run
            """
            arguments = ["-e", script, command]
        case .iterm:
            name = "iTerm2"
            guard let script = Bundle.main.url(forResource: "LaunchITerm", withExtension: "applescript") else {
                throw AppError.message("No se encuentra el script de apertura de iTerm2 en la aplicación.")
            }
            arguments = [script.path, command]
        }
        let result = try await CommandRunner.run("/usr/bin/osascript", arguments)
        _ = try CommandRunner.requireSuccess(result, label: "No se pudo abrir \(name)")
    }
}
