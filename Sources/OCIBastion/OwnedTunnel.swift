import Darwin
import Foundation

struct OwnedTunnelRecord: Codable, Equatable {
    let pid: Int32
    let token: UUID
    let port: Int
    let target: String

    static var fileURL: URL {
        Settings.fileURL.deletingLastPathComponent().appendingPathComponent("owned-tunnel.json")
    }

    static func load() -> OwnedTunnelRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(OwnedTunnelRecord.self, from: data)
    }

    func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func removeIfCurrent() {
        guard Self.load() == self else { return }
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    func matches(command: String) -> Bool {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("/usr/bin/ssh ") &&
            value.contains("SetEnv=OCIBASTION_TUNNEL_ID=\(token.uuidString)") &&
            value.contains("-D 127.0.0.1:\(port) ") &&
            value.contains(target)
    }

    func isRunning() async -> Bool {
        guard let result = try? await CommandRunner.run("/bin/ps", ["-ww", "-p", String(pid), "-o", "command="]),
              result.status == 0 else { return false }
        return matches(command: result.output)
    }

    func terminateIfRunning() async throws -> Bool {
        guard await isRunning() else {
            removeIfCurrent()
            return false
        }
        guard Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH else {
            throw TunnelPortError.ownedCouldNotStop(pid: pid)
        }
        for _ in 0..<30 {
            if !(await isRunning()) {
                removeIfCurrent()
                return true
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TunnelPortError.ownedCouldNotStop(pid: pid)
    }

    static func reclaimPrevious() async throws -> Bool {
        guard let record = load() else { return false }
        return try await record.terminateIfRunning()
    }

    static func listenerPID(port: Int) async -> Int32? {
        guard let result = try? await CommandRunner.run("/usr/sbin/lsof", [
            "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"
        ]), result.status == 0 else { return nil }
        return result.output.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("p") })
            .flatMap { Int32($0.dropFirst()) }
    }
}

enum TunnelPortError: LocalizedError {
    case inUse(port: Int, pid: Int32)
    case ownedCouldNotStop(pid: Int32)

    var errorDescription: String? {
        switch self {
        case .inUse(let port, let pid):
            return "El puerto local \(port) está ocupado por el proceso \(pid), que no está identificado como túnel propio de OCI Bastion. Libera ese puerto o selecciona otro."
        case .ownedCouldNotStop(let pid):
            return "El SSH propio (PID \(pid)) sigue activo; no se iniciará otro túnel hasta que salga."
        }
    }
}
