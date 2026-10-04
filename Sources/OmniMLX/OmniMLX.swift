import Foundation
import AudioCore
import AudioRuntime
import AudioHTTP
import Vapor
#if os(macOS)
import MLXAudioBackend
#endif

@main
struct OmniMLXCommand {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, ["serve", "check-config"].contains(args[0]), args[1] == "--config" else {
            print("Usage: omni-mlx <serve|check-config> --config <path>")
            throw ServiceError("invalid_arguments", "Supply a command and configuration path.")
        }
        let catalog = try AudioCatalog.load(URL(fileURLWithPath: args[2]))
        if args[0] == "check-config" {
            print("Configuration is valid: \(catalog.models.count) models, \(catalog.voices.count) voices.")
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let key: String?
        if let name = catalog.configuration.server.apiKeyEnv {
            guard let value = environment[name], !value.isEmpty else { throw ServiceError("invalid_configuration", "server.api_key_env: required environment variable is missing") }
            key = value
        } else { key = nil }
        #if os(macOS)
        let audio = try await makeAudioApplication(catalog: catalog, embeddedEngineFactory: { catalog, id in
            try await makeMLXAudioEngine(catalog: catalog, backendID: id)
        })
        #else
        let audio = try await makeAudioApplication(catalog: catalog)
        #endif
        let app = try await Application.make(Environment(name: "production", arguments: [CommandLine.arguments[0], "serve"]))
        app.http.server.configuration.hostname = catalog.configuration.server.host
        app.http.server.configuration.port = catalog.configuration.server.port
        var adminApp: Application?
        do {
            let keys: FileAPIKeyStore?
            if let admin = catalog.configuration.admin {
                let url = URL(fileURLWithPath: admin.keysFile, relativeTo: catalog.configurationURL.deletingLastPathComponent()).standardizedFileURL
                let store = try FileAPIKeyStore(url: url)
                keys = store
                let local = try await Application.make(Environment(name: "production", arguments: [CommandLine.arguments[0]]))
                adminApp = local
                local.http.server.configuration.port = admin.port
                configureLocalAdminHTTP(local, keys: store, audioPort: catalog.configuration.server.port, fixedKeyEnabled: key != nil, audioAPIURL: admin.audioAPIURL)
            } else { keys = nil }
            configureAudioHTTP(app, audio: audio, apiKey: key, apiKeys: keys)
            try await audio.start()
            if let adminApp {
                try await adminApp.asyncBoot()
                try await adminApp.server.start(address: nil)
            }
            try await app.execute()
        } catch {
            if let adminApp { try await adminApp.asyncShutdown() }
            await audio.shutdown(); try await app.asyncShutdown(); throw error
        }
        if let adminApp { try await adminApp.asyncShutdown() }
        await audio.shutdown(); try await app.asyncShutdown()
    }
}
