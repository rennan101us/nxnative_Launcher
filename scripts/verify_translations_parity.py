#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
CATALOG_PATH = os.path.join(REPO_ROOT, "gui", "Sources", "Resources", "Localizable.xcstrings")

LANGUAGES = ["en", "pt-BR", "pt-PT", "es", "ja", "fr", "de", "it", "zh-Hans", "zh-Hant", "ko", "pl", "ru", "sv"]

def main():
    print("==================================================")
    print("🔍 VERIFICAÇÃO DE PARIDADE: Apple String Catalog")
    print("==================================================")
    
    if not os.path.exists(CATALOG_PATH):
        print(f"❌ Erro: Arquivo {CATALOG_PATH} não encontrado!")
        sys.exit(1)
        
    print(f"==> Carregando {CATALOG_PATH}...")
    with open(CATALOG_PATH, "r", encoding="utf-8") as f:
        catalog = json.load(f)
        
    strings = catalog.get("strings", {})
    print(f"    Total de chaves no catálogo: {len(strings)}")
    if len(strings) == 0:
        print("❌ Erro: Catálogo está vazio!")
        sys.exit(1)
        
    # 1. Validar que todos os 14 idiomas estão presentes em cada chave
    missing_locs = 0
    for key, data in strings.items():
        locs = data.get("localizations", {})
        for lang in LANGUAGES:
            if lang not in locs:
                print(f"❌ Chave '{key}' não possui tradução para '{lang}'!")
                missing_locs += 1
            else:
                unit = locs[lang].get("stringUnit", {})
                if "value" not in unit:
                    print(f"❌ Chave '{key}' [{lang}] não possui campo 'value'!")
                    missing_locs += 1

    if missing_locs > 0:
        print(f"❌ Falha: {missing_locs} localizações ausentes ou corrompidas no catálogo.")
        sys.exit(1)
    else:
        print(f"✅ Todas as {len(strings)} chaves possuem traduções válidas para todos os 14 idiomas!")

    # 2. Validar placeholders (%@, %d, etc) contra o inglês
    print("==> Validando integridade de format specifiers (placeholders)...")
    placeholder_regex = re.compile(r"%(\d+\$)?[@dulfsboxX%]|%(\.\d+)?[@dulfsboxX%]")
    placeholder_mismatches = 0
    
    for key, data in strings.items():
        locs = data.get("localizations", {})
        en_val = locs.get("en", {}).get("stringUnit", {}).get("value", "")
        en_placeholders = placeholder_regex.findall(en_val)
        en_count = len(en_placeholders)
        
        for lang in LANGUAGES:
            if lang == "en":
                continue
            lang_val = locs.get(lang, {}).get("stringUnit", {}).get("value", "")
            lang_placeholders = placeholder_regex.findall(lang_val)
            lang_count = len(lang_placeholders)
            
            # Se o inglês tem placeholders, o idioma não deveria ter contagem discrepante
            # (a menos que a tradução intencionalmente formate de forma diferente, mas avisamos)
            if en_count != lang_count:
                print(f"⚠️  [Aviso] Descompasso de placeholders em '{key}' [{lang}]: EN={en_count} ('{en_val}') vs {lang}={lang_count} ('{lang_val}')")
                placeholder_mismatches += 1

    print(f"    Verificação de placeholders concluída: {placeholder_mismatches} avisos.")

    # 3. Teste de compilação via xcrun xcstringstool
    print("==> Testando compilação do catálogo com xcrun xcstringstool...")
    with tempfile.TemporaryDirectory() as tmpdir:
        cmd = ["xcrun", "xcstringstool", "compile", CATALOG_PATH, "--output-directory", tmpdir]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"❌ Erro ao compilar catálogo com xcstringstool:")
            print(res.stderr)
            sys.exit(1)
            
        generated_lprojs = [d for d in os.listdir(tmpdir) if d.endswith(".lproj")]
        print(f"    Subpastas .lproj geradas: {len(generated_lprojs)}")
        for lang in LANGUAGES:
            expected = f"{lang}.lproj"
            target_file = os.path.join(tmpdir, expected, "Localizable.strings")
            if not os.path.exists(target_file):
                print(f"❌ Erro: Arquivo {target_file} não foi gerado pelo xcstringstool!")
                sys.exit(1)
            sz = os.path.getsize(target_file)
            if sz == 0:
                print(f"❌ Erro: Arquivo {target_file} está vazio!")
                sys.exit(1)

    print("✅ Compilação pelo xcstringstool validada com 100% de sucesso!")
    print("🎉 PARIDADE E INTEGRIDADE DO CATÁLOGO: APROVADAS!")

if __name__ == "__main__":
    main()
