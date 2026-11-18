import Foundation
import AppKit

@MainActor
extension MenuBarManager {
    private struct SystemMenuLabels {
        let file: String
        let edit: String
        let view: String
        let window: String
        let help: String
        let services: String
        let hideApp: String
        let hideOthers: String
        let showAll: String
        let close: String
        let newWindow: String
        let undo: String
        let redo: String
        let cut: String
        let copy: String
        let paste: String
        let delete: String
        let selectAll: String
        let toggleSidebar: String
        let toggleFullScreen: String
        let zoom: String
        let bringAllToFront: String
        let helpApp: String
    }

    internal func syncMainMenuLocalization() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let lang = LocalizationService.shared.effectiveLanguage
        let labels = systemMenuLabels(for: lang)

        for (index, topItem) in mainMenu.items.enumerated() {
            guard let sub = topItem.submenu else { continue }

            if index == 0 {
                topItem.title = "NxNative Launcher"
                sub.title = "NxNative Launcher"
                localizeAppSubmenu(sub, labels: labels)
                continue
            }

            let kind = identifyTopMenuKind(topItem: topItem, submenu: sub)
            switch kind {
            case .file:
                topItem.title = labels.file
                sub.title = labels.file
            case .edit:
                topItem.title = labels.edit
                sub.title = labels.edit
            case .view:
                topItem.title = labels.view
                sub.title = labels.view
            case .window:
                topItem.title = labels.window
                sub.title = labels.window
            case .help:
                topItem.title = labels.help
                sub.title = labels.help
            case .unknown:
                break
            }

            localizeStandardSubmenuItems(sub, labels: labels)
        }
    }

    private enum TopMenuKind {
        case file, edit, view, window, help, unknown
    }

    private func identifyTopMenuKind(topItem: NSMenuItem, submenu: NSMenu) -> TopMenuKind {
        if submenu === NSApp.windowsMenu { return .window }
        if submenu === NSApp.helpMenu { return .help }

        let actions = Set(submenu.items.compactMap { $0.action.map { NSStringFromSelector($0) } })
        if actions.contains("undo:") || actions.contains("copy:") || actions.contains("paste:") {
            return .edit
        }
        if actions.contains("toggleSidebar:") || actions.contains("toggleFullScreen:") || actions.contains("toggleToolbarShown:") {
            return .view
        }
        if actions.contains("performMiniaturize:") || actions.contains("arrangeInFront:") || actions.contains("performZoom:") {
            return .window
        }
        if actions.contains("performClose:") || actions.contains("newDocument:") || actions.contains("saveDocument:") {
            return .file
        }
        if actions.contains("showHelp:") {
            return .help
        }

        let lowered = (topItem.title.isEmpty ? submenu.title : topItem.title).lowercased()
        if ["file", "arquivo", "ficheiro", "archivo", "fichier", "datei"].contains(lowered) { return .file }
        if ["edit", "editar", "édition", "edición", "bearbeiten", "modifica"].contains(lowered) { return .edit }
        if ["view", "visualizar", "ver", "présentation", "ansicht", "vista"].contains(lowered) { return .view }
        if ["window", "janela", "ventana", "fenêtre", "fenster", "finestra"].contains(lowered) { return .window }
        if ["help", "ajuda", "ayuda", "aide", "hilfe", "aiuto"].contains(lowered) { return .help }
        return .unknown
    }

    private func localizeAppSubmenu(_ submenu: NSMenu, labels: SystemMenuLabels) {
        if let first = submenu.items.first, !first.isSeparatorItem {
            first.title = L10n.t("about.title")
        }
        for item in submenu.items {
            let key = item.keyEquivalent.lowercased()
            let hasCmd = item.keyEquivalentModifierMask.contains(.command)
            let selector = item.action.map { NSStringFromSelector($0) }

            if key == "u" && hasCmd {
                item.title = L10n.t("about.check_updates")
            } else if key == "q" && hasCmd || selector == "terminate:" {
                item.title = L10n.t("menubar.quit")
            } else if item.submenu != nil && (item.submenu === NSApp.servicesMenu || item.submenu?.items.isEmpty == true) {
                item.title = labels.services
                item.submenu?.title = labels.services
            } else if selector == "hide:" {
                item.title = labels.hideApp
            } else if selector == "hideOtherApplications:" {
                item.title = labels.hideOthers
            } else if selector == "unhideAllApplications:" {
                item.title = labels.showAll
            }
        }
    }

    private func localizeStandardSubmenuItems(_ submenu: NSMenu, labels: SystemMenuLabels) {
        for item in submenu.items {
            let key = item.keyEquivalent.lowercased()
            let hasCmd = item.keyEquivalentModifierMask.contains(.command)
            let selector = item.action.map { NSStringFromSelector($0) }

            if (key == "m" && hasCmd) || selector == "performMiniaturize:" {
                item.title = L10n.t("menubar.minimize")
            } else if selector == "newDocument:" {
                item.title = labels.newWindow
            } else if selector == "performClose:" {
                item.title = labels.close
            } else if selector == "undo:" {
                item.title = labels.undo
            } else if selector == "redo:" {
                item.title = labels.redo
            } else if selector == "cut:" {
                item.title = labels.cut
            } else if selector == "copy:" {
                item.title = labels.copy
            } else if selector == "paste:" {
                item.title = labels.paste
            } else if selector == "delete:" {
                item.title = labels.delete
            } else if selector == "selectAll:" {
                item.title = labels.selectAll
            } else if selector == "toggleSidebar:" {
                item.title = labels.toggleSidebar
            } else if selector == "toggleFullScreen:" {
                item.title = labels.toggleFullScreen
            } else if selector == "performZoom:" {
                item.title = labels.zoom
            } else if selector == "arrangeInFront:" {
                item.title = labels.bringAllToFront
            } else if selector == "showHelp:" {
                item.title = labels.helpApp
            }
        }
    }

    private func systemMenuLabels(for language: AppLanguage) -> SystemMenuLabels {
        switch language {
        case .system:
            return systemMenuLabels(for: AppLanguage.resolve())
        case .en:
            return SystemMenuLabels(
                file: "File", edit: "Edit", view: "View", window: "Window", help: "Help",
                services: "Services", hideApp: "Hide NxNative Launcher", hideOthers: "Hide Others", showAll: "Show All",
                close: "Close", newWindow: "New Window", undo: "Undo", redo: "Redo", cut: "Cut", copy: "Copy",
                paste: "Paste", delete: "Delete", selectAll: "Select All", toggleSidebar: "Toggle Sidebar",
                toggleFullScreen: "Toggle Full Screen", zoom: "Zoom", bringAllToFront: "Bring All to Front",
                helpApp: "NxNative Launcher Help"
            )
        case .ptBR:
            return SystemMenuLabels(
                file: "Arquivo", edit: "Editar", view: "Visualizar", window: "Janela", help: "Ajuda",
                services: "Serviços", hideApp: "Ocultar NxNative Launcher", hideOthers: "Ocultar Outros", showAll: "Mostrar Tudo",
                close: "Fechar", newWindow: "Nova Janela", undo: "Desfazer", redo: "Refazer", cut: "Recortar", copy: "Copiar",
                paste: "Colar", delete: "Apagar", selectAll: "Selecionar Tudo", toggleSidebar: "Alternar Barra Lateral",
                toggleFullScreen: "Alternar Tela Cheia", zoom: "Ampliar/Reduzir", bringAllToFront: "Trazer Todas para a Frente",
                helpApp: "Ajuda do NxNative Launcher"
            )
        case .ptPT:
            return SystemMenuLabels(
                file: "Ficheiro", edit: "Editar", view: "Visualização", window: "Janela", help: "Ajuda",
                services: "Serviços", hideApp: "Ocultar NxNative Launcher", hideOthers: "Ocultar Outras", showAll: "Mostrar Tudo",
                close: "Fechar", newWindow: "Nova Janela", undo: "Desfazer", redo: "Refazer", cut: "Cortar", copy: "Copiar",
                paste: "Colar", delete: "Apagar", selectAll: "Selecionar Tudo", toggleSidebar: "Alternar Barra Lateral",
                toggleFullScreen: "Alternar Ecrã Completo", zoom: "Ampliar", bringAllToFront: "Passar Tudo para a Frente",
                helpApp: "Ajuda de NxNative Launcher"
            )
        case .es:
            return SystemMenuLabels(
                file: "Archivo", edit: "Edición", view: "Visualización", window: "Ventana", help: "Ayuda",
                services: "Servicios", hideApp: "Ocultar NxNative Launcher", hideOthers: "Ocultar otros", showAll: "Mostrar todo",
                close: "Cerrar", newWindow: "Nueva ventana", undo: "Deshacer", redo: "Rehacer", cut: "Cortar", copy: "Copiar",
                paste: "Pegar", delete: "Eliminar", selectAll: "Seleccionar todo", toggleSidebar: "Alternar barra lateral",
                toggleFullScreen: "Pantalla completa", zoom: "Zoom", bringAllToFront: "Traer todo al frente",
                helpApp: "Ayuda de NxNative Launcher"
            )
        case .ja:
            return SystemMenuLabels(
                file: "ファイル", edit: "編集", view: "表示", window: "ウインドウ", help: "ヘルプ",
                services: "サービス", hideApp: "NxNative Launcherを非表示", hideOthers: "ほかを非表示", showAll: "すべてを表示",
                close: "閉じる", newWindow: "新規ウインドウ", undo: "取り消す", redo: "やり直す", cut: "カット", copy: "コピー",
                paste: "ペースト", delete: "削除", selectAll: "すべてを選択", toggleSidebar: "サイドバーを切り替え",
                toggleFullScreen: "フルスクリーン切り替え", zoom: "拡大/縮小", bringAllToFront: "すべてを手前に移動",
                helpApp: "NxNative Launcherヘルプ"
            )
        case .fr:
            return SystemMenuLabels(
                file: "Fichier", edit: "Édition", view: "Présentation", window: "Fenêtre", help: "Aide",
                services: "Services", hideApp: "Masquer NxNative Launcher", hideOthers: "Masquer les autres", showAll: "Tout afficher",
                close: "Fermer", newWindow: "Nouvelle fenêtre", undo: "Annuler", redo: "Rétablir", cut: "Couper", copy: "Copier",
                paste: "Coller", delete: "Supprimer", selectAll: "Tout sélectionner", toggleSidebar: "Afficher/Masquer la barre latérale",
                toggleFullScreen: "Mode plein écran", zoom: "Réduire/Agrandir", bringAllToFront: "Tout ramener au premier plan",
                helpApp: "Aide NxNative Launcher"
            )
        case .de:
            return SystemMenuLabels(
                file: "Ablage", edit: "Bearbeiten", view: "Darstellung", window: "Fenster", help: "Hilfe",
                services: "Dienste", hideApp: "NxNative Launcher ausblenden", hideOthers: "Andere ausblenden", showAll: "Alle einblenden",
                close: "Schließen", newWindow: "Neues Fenster", undo: "Widerrufen", redo: "Wiederholen", cut: "Ausschneiden", copy: "Kopieren",
                paste: "Einsetzen", delete: "Löschen", selectAll: "Alles auswählen", toggleSidebar: "Seitenleiste ein-/ausblenden",
                toggleFullScreen: "Vollbildmodus", zoom: "Zoomen", bringAllToFront: "Alle nach vorne bringen",
                helpApp: "NxNative Launcher-Hilfe"
            )
        case .it:
            return SystemMenuLabels(
                file: "File", edit: "Modifica", view: "Vista", window: "Finestra", help: "Aiuto",
                services: "Servizi", hideApp: "Nascondi NxNative Launcher", hideOthers: "Nascondi altre", showAll: "Mostra tutte",
                close: "Chiudi", newWindow: "Nuova finestra", undo: "Annulla", redo: "Ripristina", cut: "Taglia", copy: "Copia",
                paste: "Incolla", delete: "Elimina", selectAll: "Seleziona tutto", toggleSidebar: "Mostra/Nascondi barra laterale",
                toggleFullScreen: "Attiva/Disattiva schermo intero", zoom: "Ridimensiona", bringAllToFront: "Porta tutto in primo piano",
                helpApp: "Aiuto NxNative Launcher"
            )
        case .zhHans:
            return SystemMenuLabels(
                file: "文件", edit: "编辑", view: "显示", window: "窗口", help: "帮助",
                services: "服务", hideApp: "隐藏 NxNative Launcher", hideOthers: "隐藏其他", showAll: "全部显示",
                close: "关闭", newWindow: "新建窗口", undo: "撤销", redo: "重做", cut: "剪切", copy: "拷贝",
                paste: "粘贴", delete: "删除", selectAll: "全选", toggleSidebar: "切换边栏",
                toggleFullScreen: "切换全屏", zoom: "缩放", bringAllToFront: "前置全部窗口",
                helpApp: "NxNative Launcher 帮助"
            )
        case .zhHant:
            return SystemMenuLabels(
                file: "檔案", edit: "編輯", view: "顯示方式", window: "視窗", help: "輔助說明",
                services: "服務", hideApp: "隱藏 NxNative Launcher", hideOthers: "隱藏其他", showAll: "顯示全部",
                close: "關閉", newWindow: "新增視窗", undo: "還原", redo: "重做", cut: "剪下", copy: "拷貝",
                paste: "貼上", delete: "刪除", selectAll: "全選", toggleSidebar: "切換側邊欄",
                toggleFullScreen: "切換全螢幕", zoom: "縮放", bringAllToFront: "將此程式所有視窗移至最前",
                helpApp: "NxNative Launcher 輔助說明"
            )
        case .ko:
            return SystemMenuLabels(
                file: "파일", edit: "편집", view: "보기", window: "윈도우", help: "도움말",
                services: "서비스", hideApp: "NxNative Launcher 가리기", hideOthers: "기타 가리기", showAll: "모두 보기",
                close: "닫기", newWindow: "새로운 윈도우", undo: "실행 취소", redo: "실행 복귀", cut: "오려두기", copy: "복사하기",
                paste: "붙여넣기", delete: "삭제", selectAll: "전체 선택", toggleSidebar: "사이드바 토글",
                toggleFullScreen: "전체 화면 전환", zoom: "확대/축소", bringAllToFront: "모두 앞으로 가져오기",
                helpApp: "NxNative Launcher 도움말"
            )
        case .pl:
            return SystemMenuLabels(
                file: "Plik", edit: "Edycja", view: "Widok", window: "Okno", help: "Pomoc",
                services: "Usługi", hideApp: "Ukryj NxNative Launcher", hideOthers: "Ukryj pozostałe", showAll: "Pokaż wszystko",
                close: "Zamknij", newWindow: "Nowe okno", undo: "Cofnij", redo: "Przywróć", cut: "Wytnij", copy: "Kopiuj",
                paste: "Wklej", delete: "Usuń", selectAll: "Zaznacz wszystko", toggleSidebar: "Przełącz pasek boczny",
                toggleFullScreen: "Tryb pełnoekranowy", zoom: "Powiększ/Zmniejsz", bringAllToFront: "Przenieś wszystkie na wierzch",
                helpApp: "Pomoc NxNative Launcher"
            )
        case .ru:
            return SystemMenuLabels(
                file: "Файл", edit: "Правка", view: "Вид", window: "Окно", help: "Справка",
                services: "Службы", hideApp: "Скрыть NxNative Launcher", hideOthers: "Скрыть остальные", showAll: "Показать все",
                close: "Закрыть", newWindow: "Новое окно", undo: "Отменить", redo: "Повторить", cut: "Вырезать", copy: "Скопировать",
                paste: "Вставить", delete: "Удалить", selectAll: "Выбрать все", toggleSidebar: "Показать/скрыть боковое меню",
                toggleFullScreen: "Полноэкранный режим", zoom: "Изменить масштаб", bringAllToFront: "Все окна — на передний план",
                helpApp: "Справка NxNative Launcher"
            )
        case .sv:
            return SystemMenuLabels(
                file: "Arkiv", edit: "Redigera", view: "Innehåll", window: "Fönster", help: "Hjälp",
                services: "Tjänster", hideApp: "Göm NxNative Launcher", hideOthers: "Göm övriga", showAll: "Visa alla",
                close: "Stäng", newWindow: "Nytt fönster", undo: "Ångra", redo: "Gör om", cut: "Klipp ut", copy: "Kopiera",
                paste: "Klistra in", delete: "Radera", selectAll: "Markera allt", toggleSidebar: "Växla sidofält",
                toggleFullScreen: "Helskärmsläge", zoom: "Zooma", bringAllToFront: "Lägg alla överst",
                helpApp: "NxNative Launcher Hjälp"
            )
        }
    }
}
