import Foundation

public final class CloudSourceManager {
    public static let shared = CloudSourceManager()
    
    private let storageKey = "nxnative_saved_cloud_sources_v1"
    private let queue = DispatchQueue(label: "com.nxnative.cloud.sources", qos: .utility)
    
    private init() {}
    
    public func loadSources() -> [CloudGameSource] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode([CloudGameSource].self, from: data)
        } catch {
            NSLog("[CloudSourceManager] Failed to decode saved cloud sources: %@", error.localizedDescription)
            return []
        }
    }
    
    public func saveSources(_ sources: [CloudGameSource]) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(sources)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            NSLog("[CloudSourceManager] Failed to encode cloud sources: %@", error.localizedDescription)
        }
    }
    
    public func addSource(name: String, urlString: String) -> CloudGameSource {
        var current = loadSources()
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? (URL(string: trimmedURL)?.host ?? "Nuvem") : trimmedName
        
        let newSource = CloudGameSource(
            id: UUID(),
            name: finalName,
            urlString: trimmedURL,
            isEnabled: true
        )
        current.append(newSource)
        saveSources(current)
        return newSource
    }
    
    public func removeSource(id: UUID) {
        var current = loadSources()
        current.removeAll { $0.id == id }
        saveSources(current)
    }
    
    public func updateSource(_ source: CloudGameSource) {
        var current = loadSources()
        if let idx = current.firstIndex(where: { $0.id == source.id }) {
            current[idx] = source
            saveSources(current)
        }
    }
}
