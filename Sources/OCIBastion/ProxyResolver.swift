import Foundation

struct ProxyEndpoint: Equatable {
    let host: String
    let port: Int

    init(host: String, port: Int) throws {
        self.host = try InputCheck.sshToken(host, name: "Host del proxy")
        try InputCheck.port(port)
        self.port = port
    }

    var address: String { "\(host):\(port)" }
}

enum ProxyResolver {
    static func resolve(settings: Settings) async throws -> (endpoint: ProxyEndpoint?, source: String) {
        switch settings.effectiveProxyMode {
        case .direct:
            return (nil, "Conexión directa")
        case .manual:
            return (try ProxyEndpoint(host: settings.proxyHost, port: settings.proxyPort), "Proxy manual")
        case .automatic:
            let environment = ProcessInfo.processInfo.environment
            for key in ["http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY"] {
                if let value = environment[key], let endpoint = endpoint(fromURL: value) {
                    return (endpoint, "Variable \(key)")
                }
            }
            if let endpoint = await systemProxy() { return (endpoint, "Proxy del sistema") }
            if let endpoint = await wpadProxy() { return (endpoint, "WPAD") }
            return (nil, "Sin proxy detectado; conexión directa")
        }
    }

    static func endpoint(fromURL value: String) -> ProxyEndpoint? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let parts = URLComponents(string: normalized),
              parts.scheme?.lowercased() == "http",
              parts.user == nil, parts.password == nil,
              let host = parts.host else { return nil }
        return try? ProxyEndpoint(host: host, port: parts.port ?? 80)
    }

    static func endpoint(fromWPAD contents: String) -> ProxyEndpoint? {
        let proxyLine = contents.split(whereSeparator: \.isNewline)
            .first { $0.range(of: "proxies\\s*=", options: [.regularExpression, .caseInsensitive]) != nil }
        if let proxyLine, let endpoint = firstHostPort(in: String(proxyLine)) { return endpoint }
        let pattern = #"(?i)\bPROXY\s+([A-Za-z0-9._-]+):(\d{1,5})"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let match = regex?.firstMatch(in: contents, range: range),
              let hostRange = Range(match.range(at: 1), in: contents),
              let portRange = Range(match.range(at: 2), in: contents),
              let port = Int(contents[portRange]) else { return nil }
        return try? ProxyEndpoint(host: String(contents[hostRange]), port: port)
    }

    private static func firstHostPort(in value: String) -> ProxyEndpoint? {
        let pattern = #"([A-Za-z0-9._-]+):(\d{1,5})"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex?.firstMatch(in: value, range: range),
              let hostRange = Range(match.range(at: 1), in: value),
              let portRange = Range(match.range(at: 2), in: value),
              let port = Int(value[portRange]) else { return nil }
        return try? ProxyEndpoint(host: String(value[hostRange]), port: port)
    }

    private static func systemProxy() async -> ProxyEndpoint? {
        guard let result = try? await CommandRunner.run("/usr/sbin/scutil", ["--proxy"]),
              result.status == 0 else { return nil }
        var values: [String: String] = [:]
        for line in result.output.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pieces.count == 2 { values[pieces[0]] = pieces[1] }
        }
        for prefix in ["HTTP", "HTTPS"] {
            guard values[prefix + "Enable"] == "1",
                  let host = values[prefix + "Proxy"],
                  let portString = values[prefix + "Port"],
                  let port = Int(portString) else { continue }
            if let endpoint = try? ProxyEndpoint(host: host, port: port) { return endpoint }
        }
        return nil
    }

    private static func wpadProxy() async -> ProxyEndpoint? {
        guard let result = try? await CommandRunner.run("/usr/bin/curl", [
            "--silent", "--show-error", "--fail", "--max-time", "5", "--noproxy", "*", "http://wpad/wpad.dat"
        ]), result.status == 0 else { return nil }
        return endpoint(fromWPAD: result.output)
    }
}
