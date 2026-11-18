import AppKit

/// Builds the menu bar, following Terminal.app's layout and shortcuts where they exist.
/// Per-tab commands target the responder chain (the key terminal window); app-level
/// commands target the controller.
@MainActor
enum MainMenuBuilder {
    static func build(controller: HarborAppController) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(controller)))
        main.addItem(submenu(shellMenu(controller)))
        main.addItem(submenu(editMenu()))
        let view = viewMenu()
        view.delegate = controller
        main.addItem(submenu(view))
        let window = windowMenu()
        main.addItem(submenu(window))
        let help = helpMenu(controller)
        main.addItem(submenu(help))
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    // MARK: Menus

    private static func appMenu(_ controller: HarborAppController) -> NSMenu {
        let menu = NSMenu(title: "Harbor")
        menu.addItem(item("About Harbor", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        menu.addItem(item("Check for Updates…", #selector(HarborAppController.checkForUpdates(_:)), target: controller))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(HarborAppController.showSettings(_:)), ",", target: controller))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide Harbor", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option], target: NSApp))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item("Quit Harbor", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        return menu
    }

    private static func shellMenu(_ controller: HarborAppController) -> NSMenu {
        let menu = NSMenu(title: "Shell")
        menu.addItem(item("New Window", #selector(HarborAppController.newWindow(_:)), "n", target: controller))
        menu.addItem(item("New Tab", #selector(HarborAppController.newTab(_:)), "t", target: controller))
        menu.addItem(item("Duplicate Tab", #selector(TerminalWindowController.duplicateTab(_:)), "d", modifiers: [.command, .shift]))
        menu.addItem(item("Reopen Closed Tab", #selector(HarborAppController.reopenClosedTab(_:)), "t", modifiers: [.command, .shift], target: controller))
        menu.addItem(.separator())
        menu.addItem(item("Connect to Host…", #selector(HarborAppController.showQuickConnect(_:)), "k", modifiers: [.command, .shift], target: controller))
        menu.addItem(item("Manage Hosts…", #selector(HarborAppController.showHosts(_:)), "h", modifiers: [.command, .shift], target: controller))
        menu.addItem(item("GitHub Scripts & Playbooks…", #selector(HarborAppController.showGitHubScripts(_:)), "p", modifiers: [.command, .shift], target: controller))
        menu.addItem(.separator())
        menu.addItem(item("AI Command Assist…", #selector(TerminalWindowController.toggleCommandAssist(_:)), "i"))
        menu.addItem(item("Quick Redirect / Proxy…", #selector(TerminalWindowController.togglePortForwards(_:)), "l", modifiers: [.command, .shift]))
        menu.addItem(item("Show Files", #selector(TerminalWindowController.toggleFileBrowser(_:)), "b", modifiers: [.command, .shift]))
        menu.addItem(item("Rename Tab…", #selector(TerminalWindowController.renameTab(_:)), "i", modifiers: [.command, .shift]))
        menu.addItem(item("Reconnect", #selector(TerminalWindowController.reconnectSession(_:)), "r", modifiers: [.command, .shift]))
        menu.addItem(item("Reconnect All Disconnected", #selector(TerminalWindowController.reconnectAllSessions(_:)), "r", modifiers: [.command, .option, .shift]))
        menu.addItem(item("Export Text As…", #selector(TerminalWindowController.exportText(_:)), "s"))
        menu.addItem(.separator())
        menu.addItem(item("Secure Keyboard Entry", #selector(HarborAppController.toggleSecureKeyboardEntry(_:)), target: controller))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(TerminalWindowController.closeTab(_:)), "w"))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Clear Scrollback", #selector(TerminalWindowController.clearScrollback(_:)), "k"))
        menu.addItem(.separator())
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(item("Find…", #selector(TerminalWindowController.showFindBar(_:)), "f"))
        findMenu.addItem(item("Find Next", #selector(TerminalWindowController.findNext(_:)), "g"))
        findMenu.addItem(item("Find Previous", #selector(TerminalWindowController.findPrevious(_:)), "g", modifiers: [.command, .shift]))
        findMenu.addItem(item("Use Selection for Find", #selector(TerminalWindowController.useSelectionForFind(_:)), "e"))
        find.submenu = findMenu
        menu.addItem(find)
        menu.addItem(.separator())
        menu.addItem(item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", modifiers: [.command, .control]))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Bigger", #selector(TerminalWindowController.biggerFont(_:)), "+"))
        menu.addItem(alternate(item("Bigger", #selector(TerminalWindowController.biggerFont(_:)), "=")))
        menu.addItem(item("Smaller", #selector(TerminalWindowController.smallerFont(_:)), "-"))
        menu.addItem(item("Default Font Size", #selector(TerminalWindowController.defaultFontSize(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Jump to Previous Prompt", #selector(TerminalWindowController.jumpToPreviousPrompt(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        menu.addItem(item("Jump to Next Prompt", #selector(TerminalWindowController.jumpToNextPrompt(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Previous Tab", #selector(TerminalWindowController.showPreviousTab(_:)), "[", modifiers: [.command, .shift]))
        menu.addItem(item("Show Next Tab", #selector(TerminalWindowController.showNextTab(_:)), "]", modifiers: [.command, .shift]))
        menu.addItem(alternate(item("Show Previous Tab", #selector(TerminalWindowController.showPreviousTab(_:)), "\t", modifiers: [.control, .shift])))
        menu.addItem(alternate(item("Show Next Tab", #selector(TerminalWindowController.showNextTab(_:)), "\t", modifiers: [.control])))
        menu.addItem(item("Move Tab to New Window", #selector(TerminalWindowController.detachTab(_:))))
        menu.addItem(item("Merge All Windows", #selector(TerminalWindowController.mergeAllTerminalWindows(_:))))
        menu.addItem(.separator())
        for number in 1...9 {
            let tab = item(number == 9 ? "Last Tab" : "Tab \(number)", #selector(TerminalWindowController.selectTabByNumber(_:)), "\(number)")
            tab.tag = number
            menu.addItem(tab)
        }
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        return menu
    }

    private static func helpMenu(_ controller: HarborAppController) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Run Diagnostics…", #selector(HarborAppController.showDiagnostics(_:)), target: controller))
        menu.addItem(item("Connect an AI Assistant…", #selector(HarborAppController.showAssistants(_:)), target: controller))
        menu.addItem(item("Remote Access…", #selector(HarborAppController.showRemoteAccess(_:)), target: controller))
        menu.addItem(.separator())
        menu.addItem(item("Show Logs", #selector(HarborAppController.showLogs(_:)), target: controller))
        menu.addItem(item("Export Support Bundle…", #selector(HarborAppController.exportSupportBundle(_:)), target: controller))
        return menu
    }

    // MARK: Helpers

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }

    private static func findItem(_ title: String, tag: Int, _ key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, modifiers: modifiers)
        item.tag = tag
        return item
    }

    private static func alternate(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }
}
