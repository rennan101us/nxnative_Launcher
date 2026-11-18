import SwiftUI
import AppKit

// MARK: - Global & Local Keyboard Bridge View (Modal & Text Input Safe)
public struct KeyboardNavBridge: NSViewRepresentable {
    public let viewModel: AppViewModel?
    public let onKey: (String) -> Void

    public init(viewModel: AppViewModel? = nil, onKey: @escaping (String) -> Void) {
        self.viewModel = viewModel
        self.onKey = onKey
    }

    public func makeNSView(context: Context) -> KeyboardListenerNSView {
        let view = KeyboardListenerNSView()
        view.viewModel = viewModel
        view.onKey = onKey
        return view
    }

    public func updateNSView(_ nsView: KeyboardListenerNSView, context: Context) {
        nsView.viewModel = viewModel
        nsView.onKey = onKey
    }

    public class KeyboardListenerNSView: NSView {
        var viewModel: AppViewModel?
        var onKey: ((String) -> Void)?
        private var monitor: Any?
        private var textBeginObserver: Any?
        private var textEndObserver: Any?
        private var controlBeginObserver: Any?
        private var controlEndObserver: Any?

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                setupObservers()
            } else {
                tearDownObservers()
            }
        }

        private func isCurrentTextInputActive() -> Bool {
            let target = window?.attachedSheet ?? window ?? NSApp.keyWindow
            guard let fr = target?.firstResponder else { return false }
            if fr is NSTextField { return true }
            if let tv = fr as? NSTextView {
                return tv.isEditable
            }
            if fr is NSTextInputClient { return true }
            return false
        }

        private func syncTextInputState() {
            let active = isCurrentTextInputActive()
            if viewModel?.isTextInputActive != active {
                viewModel?.isTextInputActive = active
            }
        }

        private func setupObservers() {
            guard monitor == nil else { return }

            textBeginObserver = NotificationCenter.default.addObserver(
                forName: NSText.didBeginEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.syncTextInputState() }

            textEndObserver = NotificationCenter.default.addObserver(
                forName: NSText.didEndEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.syncTextInputState() }

            controlBeginObserver = NotificationCenter.default.addObserver(
                forName: NSControl.textDidBeginEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.syncTextInputState() }

            controlEndObserver = NotificationCenter.default.addObserver(
                forName: NSControl.textDidEndEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.syncTextInputState() }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }

                // Yield all keyboard events when user is rebinding controls
                if InputProfileManager.shared.listeningTarget != nil {
                    return event
                }

                // 1. Text input guard: disable all navigation hotkeys while typing
                let textActive = self.isCurrentTextInputActive()
                if self.viewModel?.isTextInputActive != textActive {
                    self.viewModel?.isTextInputActive = textActive
                }

                let modalActive = (self.viewModel?.isAnyModalPresented == true) ||
                                  (self.window?.attachedSheet != nil) ||
                                  (NSApp.modalWindow != nil)

                if textActive {
                    let target = self.window?.attachedSheet ?? self.window ?? NSApp.keyWindow

                    // Smart Escape: unfocuses text input and immediately re-enables hotkeys
                    if event.keyCode == 53 {
                        target?.makeFirstResponder(nil)
                        self.viewModel?.isTextInputActive = false
                        self.viewModel?.isSearchFieldProgrammaticallyFocused = false
                        self.viewModel?.isNewProfileTextFocused = false
                        return nil
                    }

                    // Down Arrow: unfocus text field (when not typing inside modal forms)
                    if !modalActive && event.keyCode == 125 { // Down Arrow
                        target?.makeFirstResponder(nil)
                        self.viewModel?.isTextInputActive = false
                        self.viewModel?.isSearchFieldProgrammaticallyFocused = false
                        self.viewModel?.handleUnifiedNavigation(.navigateDown)
                        return nil
                    }
                    if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                        target?.makeFirstResponder(nil)
                        self.viewModel?.isTextInputActive = false
                        self.viewModel?.isSearchFieldProgrammaticallyFocused = false
                        self.viewModel?.isNewProfileTextFocused = false
                        if modalActive {
                            if self.viewModel?.showNewControllerProfileModal == true {
                                self.onKey?("return")
                            }
                        } else {
                            self.viewModel?.handleUnifiedNavigation(.confirm)
                        }
                        return nil
                    }

                    // When header search input is empty, Left/Right/Up unfocus and navigate
                    if !modalActive {
                        let isSearchEmpty: Bool = {
                            guard let vm = self.viewModel else { return true }
                            if vm.selectedTab == 1 { return vm.compatibilitySearchText.isEmpty }
                            return vm.librarySearchText.isEmpty
                        }()
                        if isSearchEmpty {
                            switch event.keyCode {
                            case 123: // Left
                                target?.makeFirstResponder(nil)
                                self.viewModel?.isTextInputActive = false
                                self.viewModel?.isSearchFieldProgrammaticallyFocused = false
                                self.onKey?("left")
                                return nil
                            case 124: // Right
                                target?.makeFirstResponder(nil)
                                self.viewModel?.isTextInputActive = false
                                self.viewModel?.isSearchFieldProgrammaticallyFocused = false
                                self.onKey?("right")
                                return nil
                            case 126: // Up
                                target?.makeFirstResponder(nil)
                                self.viewModel?.isTextInputActive = false
                                self.viewModel?.isSearchFieldProgrammaticallyFocused = false
                                self.onKey?("up")
                                return nil
                            default:
                                break
                            }
                        }
                    }

                    // Pass keystrokes directly to the text field without hotkey interception
                    return event
                }

                // 2. Modal guard: forward modal navigation keys while trapping background hotkeys
                if modalActive {
                    // Never intercept native file open/save panels or OS alerts
                    if let modalWin = NSApp.modalWindow,
                       modalWin is NSSavePanel || modalWin.className.contains("Alert") {
                        return event
                    }
                    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                        return event
                    }

                    switch event.keyCode {
                    case 48: // Tab / Shift+Tab
                        let isShift = event.modifierFlags.contains(.shift)
                        self.onKey?(isShift ? "shifttab" : "tab")
                        return nil
                    case 33: self.onKey?("["); return nil
                    case 30: self.onKey?("]"); return nil
                    case 123: self.onKey?("left"); return nil
                    case 124: self.onKey?("right"); return nil
                    case 126: self.onKey?("up"); return nil
                    case 125: self.onKey?("down"); return nil
                    case 36, 76: self.onKey?("return"); return nil
                    case 53: self.onKey?("escape"); return nil
                    case 49: self.onKey?("space"); return nil
                    case 51: self.onKey?("backspace"); return nil
                    case 116: self.onKey?("pageup"); return nil
                    case 121: self.onKey?("pagedown"); return nil
                    case 115: self.onKey?("home"); return nil
                    case 119: self.onKey?("end"); return nil
                    default: break
                    }

                    if let chars = event.charactersIgnoringModifiers, let first = chars.first {
                        let str = String(first).lowercased()
                        switch str {
                        case "q": self.onKey?("["); return nil
                        case "e": self.onKey?("]"); return nil
                        case "x", "y", "o": self.onKey?(str); return nil
                        default: break
                        }
                    }
                    return event
                }

                // 3. Navigation hotkeys enabled: process launcher navigation keys
                // System command guard: Never swallow macOS Command/Control shortcuts (e.g. Cmd+Q, Cmd+W, Cmd+C, Cmd+M, etc.)
                if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                    return event
                }

                switch event.keyCode {
                case 48: // Tab key
                    let isShift = event.modifierFlags.contains(.shift)
                    self.onKey?(isShift ? "shifttab" : "tab")
                    return nil
                case 33: // [ key
                    self.onKey?("[")
                    return nil
                case 30: // ] key
                    self.onKey?("]")
                    return nil
                case 123: // Left Arrow
                    self.onKey?("left")
                    return nil
                case 124: // Right Arrow
                    self.onKey?("right")
                    return nil
                case 126: // Up Arrow
                    self.onKey?("up")
                    return nil
                case 125: // Down Arrow
                    self.onKey?("down")
                    return nil
                case 36, 76: // Return / Enter
                    self.onKey?("return")
                    return nil
                case 53: // Escape
                    self.onKey?("escape")
                    return nil
                case 49: // Spacebar
                    self.onKey?("space")
                    return nil
                case 51: // Backspace / Delete
                    self.onKey?("backspace")
                    return nil
                case 116: // Page Up
                    self.onKey?("pageup")
                    return nil
                case 121: // Page Down
                    self.onKey?("pagedown")
                    return nil
                case 115: // Home
                    self.onKey?("home")
                    return nil
                case 119: // End
                    self.onKey?("end")
                    return nil
                default:
                    break
                }

                // Layout-independent character keys (numbers, letters, symbols)
                if let chars = event.charactersIgnoringModifiers, let first = chars.first {
                    let str = String(first).lowercased()
                    if str == "=" || str == "+" {
                        self.onKey?("zoomin")
                        return nil
                    }
                    if str == "-" {
                        self.onKey?("zoomout")
                        return nil
                    }
                    if ("1"..."7").contains(str) || ["o", ",", "r", "c", "k", "i", "u", "q", "e", "x", "y", "g", "m", "/"].contains(str) {
                        if str == "q" {
                            self.onKey?("[")
                            return nil
                        }
                        if str == "e" {
                            self.onKey?("]")
                            return nil
                        }
                        self.onKey?(str)
                        return nil
                    }
                }

                return event
            }
        }

        private func tearDownObservers() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            if let o = textBeginObserver { NotificationCenter.default.removeObserver(o); textBeginObserver = nil }
            if let o = textEndObserver { NotificationCenter.default.removeObserver(o); textEndObserver = nil }
            if let o = controlBeginObserver { NotificationCenter.default.removeObserver(o); controlBeginObserver = nil }
            if let o = controlEndObserver { NotificationCenter.default.removeObserver(o); controlEndObserver = nil }
        }

        deinit {
            tearDownObservers()
        }
    }
}
