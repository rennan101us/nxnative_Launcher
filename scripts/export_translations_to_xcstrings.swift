import Foundation

@main
struct ExportTranslations {
    static func main() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // scripts
            .deletingLastPathComponent() // nxnative
        
        let outputURL = repoRoot
            .appendingPathComponent("gui")
            .appendingPathComponent("Sources")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Localizable.xcstrings")
        
        let languages: [AppLanguage] = [
            .en, .ptBR, .ptPT, .es, .ja, .fr, .de, .it,
            .zhHans, .zhHant, .ko, .pl, .ru, .sv
        ]
        
        print("==> Carregando dicionários de tradução para \(languages.count) idiomas...")
        
        var allKeys = Set<String>()
        var languageDicts: [String: [String: String]] = [:]
        
        for lang in languages {
            let dict = Translations.dictionary(for: lang)
            languageDicts[lang.rawValue] = dict
            for key in dict.keys {
                allKeys.insert(key)
            }
            print("  - [\(lang.rawValue)] \(dict.count) chaves")
        }
        
        print("==> Total de chaves únicas encontradas: \(allKeys.count)")
        
        let sortedKeys = allKeys.sorted()
        var stringsObject: [String: Any] = [:]
        
        let enDict = languageDicts["en"] ?? [:]
        
        for key in sortedKeys {
            var localizationsObject: [String: Any] = [:]
            let fallbackEn = enDict[key] ?? key
            
            for lang in languages {
                let code = lang.rawValue
                let val = languageDicts[code]?[key] ?? fallbackEn
                localizationsObject[code] = [
                    "stringUnit": [
                        "state": "translated",
                        "value": val
                    ]
                ]
            }
            
            stringsObject[key] = [
                "extractionState": "manual",
                "localizations": localizationsObject
            ]
        }
        
        let catalogObject: [String: Any] = [
            "sourceLanguage": "en",
            "strings": stringsObject,
            "version": "1.0"
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: catalogObject, options: [.prettyPrinted, .sortedKeys])
        
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData.write(to: outputURL)
        
        print("==> Arquivo String Catalog gerado com sucesso!")
        print("    Caminho: \(outputURL.path)")
        print("    Tamanho: \(jsonData.count) bytes")
    }
}
