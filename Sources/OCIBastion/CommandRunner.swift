import Foundation

struct CommandResult {
    let status: Int32
    let output: String
    let error: String
}

enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                let output = Pipe()
                let error = Pipe()
                process.standardOutput = output
                process.standardError = error
                do {
                    try process.run()
                    let group = DispatchGroup()
                    var outputData = Data()
                    var errorData = Data()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        outputData = output.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errorData = error.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    process.waitUntilExit()
                    group.wait()
                    continuation.resume(returning: CommandResult(
                        status: process.terminationStatus,
                        output: String(decoding: outputData, as: UTF8.self),
                        error: String(decoding: errorData, as: UTF8.self)
                    ))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func requireSuccess(_ result: CommandResult, label: String) throws -> String {
        guard result.status == 0 else {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message("\(label): \(detail.isEmpty ? "salida \(result.status)" : detail)")
        }
        return result.output
    }
}

enum JSONValue {
    static func object(_ data: String) throws -> [String: Any] {
        guard let parsed = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            throw AppError.message("OCI devolvió una respuesta JSON inesperada.")
        }
        return parsed
    }

    static func data(_ object: [String: Any]) throws -> [String: Any] {
        guard let value = object["data"] as? [String: Any] else {
            throw AppError.message("La respuesta de OCI no contiene los datos esperados.")
        }
        return value
    }
}
