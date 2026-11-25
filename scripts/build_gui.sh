#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUI_DIR="$REPO_ROOT/gui"
WORKSPACE_DIR="$(cd "$REPO_ROOT/.." && pwd)"
BUILD_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

TOOLS_READY=0
if [ -x "$GUI_DIR/Resources/python/bin/python3" ] \
    && [ -x "$GUI_DIR/Resources/tools/bin/glslangValidator" ] \
    && [ -x "$GUI_DIR/Resources/tools/bin/spirv-cross" ] \
    && "$GUI_DIR/Resources/python/bin/python3" -c "import zbic" 2>/dev/null; then
    TOOLS_READY=1
fi

if [ "$TOOLS_READY" -ne 1 ]; then
    RUNNING_RES=""
    if [ -n "${NXNATIVE_RUNNING_APP:-}" ]; then
        RUNNING_RES="$NXNATIVE_RUNNING_APP/Contents/Resources"
    fi
    for CAND_RES in \
        "${EXISTING_APP_RESOURCES:-}" \
        "$RUNNING_RES" \
        "$WORKSPACE_DIR/NxNative_Launcher.app/Contents/Resources" \
        "/Applications/NxNative_Launcher.app/Contents/Resources" \
        "$HOME/Applications/NxNative_Launcher.app/Contents/Resources" \
        "$REPO_ROOT/NxNative_Launcher.app/Contents/Resources"; do
        if [ -n "$CAND_RES" ] && [ -x "$CAND_RES/python/bin/python3" ] && [ -d "$CAND_RES/tools/bin" ] && "$CAND_RES/python/bin/python3" -c "import zbic" 2>/dev/null; then
            echo "==> Reusing standalone Python runtime and tools from existing bundle: $CAND_RES"
            mkdir -p "$GUI_DIR/Resources"
            if [ ! -x "$GUI_DIR/Resources/python/bin/python3" ] || ! "$GUI_DIR/Resources/python/bin/python3" -c "import zbic" 2>/dev/null; then
                rm -rf "$GUI_DIR/Resources/python"
                ditto "$CAND_RES/python" "$GUI_DIR/Resources/python"
                chmod +x "$GUI_DIR/Resources/python/bin/"* 2>/dev/null || true
            fi
            if [ ! -x "$GUI_DIR/Resources/tools/bin/glslangValidator" ] || [ ! -x "$GUI_DIR/Resources/tools/bin/spirv-cross" ]; then
                rm -rf "$GUI_DIR/Resources/tools"
                ditto "$CAND_RES/tools" "$GUI_DIR/Resources/tools"
                chmod +x "$GUI_DIR/Resources/tools/bin/"* 2>/dev/null || true
            fi
            TOOLS_READY=1
            break
        fi
    done
fi

if [ "$TOOLS_READY" -ne 1 ]; then
    echo "==> Standalone Python or tools resources missing/incomplete. Running bundle_tools.sh..."
    "$SCRIPT_DIR/bundle_tools.sh" "$GUI_DIR/Resources"
fi

echo "==> Compilando NXNative GUI em modo release..."
cd "$GUI_DIR"
swift build -c release

RELEASE_BIN="$GUI_DIR/.build/release/NXNativeGUI"
ICON_ICNS="$GUI_DIR/Resources/AppIcon.icns"
ICON_PNG="$GUI_DIR/Resources/AppIcon.png"

build_app_bundle() {
    local DEST_DIR="$1"
    local APP_BUNDLE="$DEST_DIR/NxNative_Launcher.app"
    
    # Remove old name if exists
    rm -rf "$DEST_DIR/NXNative.app"
    
    echo "==> Criando bundle em: $APP_BUNDLE"
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"
    
    cp "$RELEASE_BIN" "$APP_BUNDLE/Contents/MacOS/NXNativeGUI"
    chmod +x "$APP_BUNDLE/Contents/MacOS/NXNativeGUI"
    strip -x "$APP_BUNDLE/Contents/MacOS/NXNativeGUI" 2>/dev/null || true
    
    # Compila String Catalog (.xcstrings) para recursos .lproj do bundle
    if [ -f "$GUI_DIR/Sources/Resources/Localizable.xcstrings" ]; then
        echo "==> Compilando String Catalog para recursos do bundle..."
        xcrun xcstringstool compile "$GUI_DIR/Sources/Resources/Localizable.xcstrings" \
            --output-directory "$APP_BUNDLE/Contents/Resources"
    fi

    # Copia bundle de recursos SPM se gerado pelo build (suporte Bundle.module)
    SPM_BUNDLE="$(find "$GUI_DIR/.build" -name "NXNativeGUI_NXNativeGUI.bundle" 2>/dev/null | head -n 1)"
    if [ -n "$SPM_BUNDLE" ] && [ -d "$SPM_BUNDLE" ]; then
        echo "==> Copiando bundle SPM para Resources..."
        cp -R "$SPM_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    fi
    
    if [ -d "$GUI_DIR/Resources" ]; then
        # Copy primary icon sets and menu bar icons (avoid redundant 1024x1024 iOS PNG clones)
        cp "$GUI_DIR/Resources/"*.icns "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
        
        # Sincroniza o tema de ícone salvo no UserDefaults (se existir) como AppIcon.icns principal
        SAVED_ICON_MODE="$(defaults read org.nxnative.launcher NXNative_SavedIconAppearanceMode_v2 2>/dev/null || echo 'Default')"
        case "$SAVED_ICON_MODE" in
            "Dark") ICON_SRC="AppIcon-Dark.icns" ;;
            "Clear Light"|"ClearLight") ICON_SRC="AppIcon-ClearLight.icns" ;;
            "Clear Dark"|"ClearDark") ICON_SRC="AppIcon-ClearDark.icns" ;;
            "Tinted Light"|"TintedLight") ICON_SRC="AppIcon-TintedLight.icns" ;;
            "Tinted Dark"|"TintedDark"|"Monochrome"|"Mono") ICON_SRC="AppIcon-TintedDark.icns" ;;
            *) ICON_SRC="AppIcon-Default.icns" ;;
        esac
        if [ -f "$APP_BUNDLE/Contents/Resources/$ICON_SRC" ]; then
            cp "$APP_BUNDLE/Contents/Resources/$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
        fi
        
        cp "$GUI_DIR/Resources/MenuBarIcon-"*.png "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
        cp "$GUI_DIR/Resources/"*.svg "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
        cp "$GUI_DIR/Resources/"*.tsv "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
        if [ -d "$GUI_DIR/Resources/NxNative_Launcher.icon" ]; then
            cp -R "$GUI_DIR/Resources/NxNative_Launcher.icon" "$APP_BUNDLE/Contents/Resources/"
        fi
        if [ -d "$GUI_DIR/Resources/patches" ]; then
            mkdir -p "$APP_BUNDLE/Contents/Resources/patches"
            cp -R "$GUI_DIR/Resources/patches/" "$APP_BUNDLE/Contents/Resources/patches/"
        fi
        if [ -d "$GUI_DIR/Resources/python" ]; then
            echo "==> Copiando runtime Python standalone embutido (otimizado)..."
            cp -R "$GUI_DIR/Resources/python" "$APP_BUNDLE/Contents/Resources/"
            # Remove development headers, pip and bytecode caches from target bundle
            rm -rf "$APP_BUNDLE/Contents/Resources/python/include" \
                   "$APP_BUNDLE/Contents/Resources/python/lib/python"*/site-packages/pip* \
                   "$APP_BUNDLE/Contents/Resources/python/lib/python"*/ensurepip 2>/dev/null || true
            find "$APP_BUNDLE/Contents/Resources/python" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
        fi
        if [ -d "$GUI_DIR/Resources/tools" ]; then
            echo "==> Copiando ferramentas standalone embutidas..."
            cp -R "$GUI_DIR/Resources/tools" "$APP_BUNDLE/Contents/Resources/"
        fi
        if [ -d "$GUI_DIR/Resources/engine" ]; then
            echo "==> Copiando motores nativos otimizados (engine)..."
            cp -R "$GUI_DIR/Resources/engine" "$APP_BUNDLE/Contents/Resources/"
        fi
        if [ -d "$REPO_ROOT/dm/ios/DmIOS.xcodeproj" ]; then
            echo "==> Copiando projeto DmIOS.xcodeproj para provisionamento nativo..."
            mkdir -p "$APP_BUNDLE/Contents/Resources/dm/ios"
            cp -R "$REPO_ROOT/dm/ios/DmIOS.xcodeproj" "$APP_BUNDLE/Contents/Resources/dm/ios/"
        fi
    fi
    
    cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>pt-BR</string>
        <string>pt-PT</string>
        <string>es</string>
        <string>ja</string>
        <string>fr</string>
        <string>de</string>
        <string>it</string>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
        <string>ko</string>
        <string>pl</string>
        <string>ru</string>
        <string>sv</string>
    </array>
    <key>CFBundleDisplayName</key>
    <string>NxNative Launcher</string>
    <key>CFBundleExecutable</key>
    <string>NXNativeGUI</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>org.nxnative.launcher</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>NxNative Launcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.3.4</string>
    <key>CFBundleVersion</key>
    <string>60</string>
    <key>NXBuildCommit</key>
    <string>$BUILD_COMMIT</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>NxNative Unpacked Package (NUP)</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>nup</string>
            </array>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.nxnative.nup</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>NS Game Package</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>nsp</string>
                <string>nsz</string>
                <string>xci</string>
                <string>xcz</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.nxnative.nup</string>
            <key>UTTypeDescription</key>
            <string>NxNative Unpacked Package (NUP)</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
                <string>public.archive</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>nup</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

    # Remove stale caches and Finder/resource-fork detritus to preserve strict codesign verification
    find "$APP_BUNDLE" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "$APP_BUNDLE" \( -name "*.pyc" -o -name ".DS_Store" -o -name "._*" -o -name $'Icon\r' \) -delete 2>/dev/null || true
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true

    echo "==> Assinando bundle ad-hoc..."
    codesign --force --deep --sign - "$APP_BUNDLE"
    xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
    touch "$APP_BUNDLE/Contents/Info.plist" "$APP_BUNDLE"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" 2>/dev/null || true
}

# Remove qualquer cópia duplicada interna no repositório
rm -rf "$REPO_ROOT/NxNative_Launcher.app" 2>/dev/null || true

# Cria apenas um aplicativo na pasta raiz de trabalho
build_app_bundle "$WORKSPACE_DIR"

# Limpa artefatos intermediários pesados do build para economizar espaço
rm -rf "$GUI_DIR/.build" 2>/dev/null || true

echo "==> Sucesso! Aplicativo criado com ícone em:"
echo "    $WORKSPACE_DIR/NxNative_Launcher.app"
