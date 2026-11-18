import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || MenuBarManager.shared.isMinimizedToMenuBar {
            MenuBarManager.shared.restoreMainWindow()
            return true
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        MenuBarManager.shared.createDockMenu()
    }
}

@main
struct NXNativeGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = AppViewModel()
    @ObservedObject private var localizationService = LocalizationService.shared
    
    var body: some Scene {
        let _ = localizationService.effectiveLanguage
        WindowGroup {
            MainView(viewModel: viewModel)
                .frame(minWidth: 920, idealWidth: 1280, maxWidth: .infinity, minHeight: 640, idealHeight: 800, maxHeight: .infinity)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    viewModel.handleDroppedURLs([url], openPortModalForSingleGame: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentSize)
        .commands {
            SidebarCommands()
            
            CommandGroup(replacing: .appInfo) {
                Button(L10n.t("about.title")) {
                    SoundEffectService.shared.play(.click)
                    viewModel.showAboutSheet = true
                }
            }
            
            CommandGroup(after: .appInfo) {
                Button(L10n.t("about.check_updates")) {
                    SoundEffectService.shared.play(.click)
                    viewModel.openUpdateCheckerAndAutoInstall()
                }
                .keyboardShortcut("U", modifiers: [.command])
                
                Divider()
            }
            
            CommandGroup(replacing: .windowList) {
                Button(L10n.t("menubar.minimize")) {
                    MenuBarManager.shared.minimizeToMenuBar()
                }
                .keyboardShortcut("M", modifiers: [.command])
            }
            
            CommandGroup(replacing: .appTermination) {
                Button(L10n.t("menubar.quit")) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }
}
