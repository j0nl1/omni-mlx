import AudioCore
import AudioRuntime

@MainActor
public func makeMLXAudioEngine(catalog: AudioCatalog, backendID: String) throws -> any EmbeddedAudioEngine {
    let groups = Set(catalog.configuration.backends.values.filter { $0.mode == .embedded }.map(\.resourceGroup))
    guard groups.count == 1 else {
        throw ServiceError("invalid_configuration", "Embedded MLX backends on this device must share one resource group.")
    }
    return try NativeAudio(catalog: catalog, backendID: backendID)
}
