import Foundation
import Combine

public final class LocalizationService: ObservableObject {
    public static let shared = LocalizationService()
    
    private let resolvedSystemLanguage: AppLanguage = AppLanguage.resolve()
    
    @Published public var currentLanguage: AppLanguage = .system {
        didSet {
            clearBundleCache()
        }
    }
    
    private let lock = NSLock()
    private var cachedTargetBundle: Bundle?
    private var cachedTargetLanguage: AppLanguage?
    private var cachedEnglishBundle: Bundle?
    
    private init() {}
    
    public var effectiveLanguage: AppLanguage {
        if currentLanguage == .system {
            return resolvedSystemLanguage
        }
        return currentLanguage
    }
    
    public func t(_ key: String, _ args: CVarArg...) -> String {
        format(key: key, arguments: args)
    }
    
    public func format(key: String, arguments: [CVarArg]) -> String {
        let formatStr = localizedString(for: key)
        if arguments.isEmpty {
            return formatStr
        }
        return String(format: formatStr, arguments: arguments)
    }
    
    public func localizedString(for key: String) -> String {
        let lang = effectiveLanguage
        let target = getTargetBundle(for: lang)
        
        let missingSentinel = "\u{0000}__NX_MISSING__\u{0000}"
        
        // 1. Tenta carregar no bundle do idioma ativo
        if let target = target {
            let val = target.localizedString(forKey: key, value: missingSentinel, table: "Localizable")
            if val != missingSentinel {
                return val
            }
        }
        
        // 2. Fallback para Inglês caso o idioma ativo não seja inglês
        if lang != .en {
            let enBundle = getEnglishBundle()
            if let en = enBundle {
                let val = en.localizedString(forKey: key, value: missingSentinel, table: "Localizable")
                if val != missingSentinel {
                    return val
                }
            }
        }
        
        // 3. Fallback final para a chave crua
        return key
    }
    
    private func clearBundleCache() {
        lock.lock()
        cachedTargetBundle = nil
        cachedTargetLanguage = nil
        cachedEnglishBundle = nil
        lock.unlock()
    }
    
    private func getTargetBundle(for lang: AppLanguage) -> Bundle? {
        lock.lock()
        if cachedTargetLanguage == lang, let bundle = cachedTargetBundle {
            lock.unlock()
            return bundle
        }
        lock.unlock()
        
        let resolved = resolveBundle(for: lang.rawValue)
        
        lock.lock()
        cachedTargetLanguage = lang
        cachedTargetBundle = resolved
        lock.unlock()
        
        return resolved
    }
    
    private func getEnglishBundle() -> Bundle? {
        lock.lock()
        if let bundle = cachedEnglishBundle {
            lock.unlock()
            return bundle
        }
        lock.unlock()
        
        let resolved = resolveBundle(for: "en")
        
        lock.lock()
        cachedEnglishBundle = resolved
        lock.unlock()
        
        return resolved
    }
    
    private func resolveBundle(for langCode: String) -> Bundle? {
        // 1. Busca em Bundle.main (NxNative_Launcher.app/Contents/Resources/<langCode>.lproj)
        if let path = Bundle.main.path(forResource: langCode, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        
        // 2. Busca em Bundle.main em subpasta de Resources (se empacotado diferente)
        if let resPath = Bundle.main.resourcePath {
            let candidate = (resPath as NSString).appendingPathComponent("\(langCode).lproj")
            if FileManager.default.fileExists(atPath: candidate), let b = Bundle(path: candidate) {
                return b
            }
        }
        
        // 3. Busca no Bundle.module do SwiftPM (desenvolvimento / linha de comando / swift run)
        #if SWIFT_PACKAGE
        if let path = Bundle.module.path(forResource: langCode, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        if let resPath = Bundle.module.resourcePath {
            let candidate = (resPath as NSString).appendingPathComponent("\(langCode).lproj")
            if FileManager.default.fileExists(atPath: candidate), let b = Bundle(path: candidate) {
                return b
            }
        }
        #endif
        
        return nil
    }
}

public enum L10n {
    public static func t(_ key: String, _ args: CVarArg...) -> String {
        LocalizationService.shared.format(key: key, arguments: args)
    }

    public static func t(_ key: String, default defVal: String) -> String {
        let val = LocalizationService.shared.localizedString(for: key)
        return val == key ? defVal : val
    }
}
