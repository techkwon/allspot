import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct AllspotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("검색 창 보이기") { appDelegate.showWindow() }
                    .keyboardShortcut("n")
            }
            CommandMenu("검색") {
                Button("검색어로 이동") { appDelegate.model.focusSearch(selectAll: true) }
                    .keyboardShortcut("f")
                Button("결과 내에서 다시 검색") { appDelegate.model.refineWithinResults() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("결과 내 검색 모두 지우기") { appDelegate.model.clearRefinements() }
                Divider()
                Button("유사 검색 켜기/끄기") { appDelegate.model.fuzzyMode.toggle() }
                    .keyboardShortcut("u")
                Divider()
                Button("색인 다시 만들기") { appDelegate.model.rebuildIndex() }
            }
            BookmarkCommands(model: appDelegate.model)
        }

        MenuBarExtra("Allspot", systemImage: "magnifyingglass") {
            MenuBarContent(model: appDelegate.model) { appDelegate.showWindow() }
        }
    }
}

/// 즐겨찾기 메뉴(앞의 9개는 ⌘1~9). 메뉴 막대는 Commands가 직접 모델을 지켜봐야 목록이 바뀐다.
struct BookmarkCommands: Commands {
    @ObservedObject var model: SearchModel

    var body: some Commands {
        CommandMenu("즐겨찾기") {
            Button(model.isCurrentBookmarked ? "지금 검색을 즐겨찾기에서 빼기" : "지금 검색을 즐겨찾기에 넣기") {
                model.toggleCurrentBookmark()
            }
            .keyboardShortcut("d")
            .disabled(model.currentBookmark == nil)
            if !model.bookmarks.isEmpty {
                Divider()
                ForEach(Array(model.bookmarks.enumerated()), id: \.element.id) { i, bookmark in
                    if i < 9 {
                        Button(bookmark.title) { model.openBookmark(bookmark) }
                            .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
                    } else {
                        Button(bookmark.title) { model.openBookmark(bookmark) }
                    }
                }
            }
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: SearchModel
    let showWindow: () -> Void

    var body: some View {
        Button("검색 창 열기 (\(model.hotKey.display))") { showWindow() }
        Divider()
        Text(model.statusLine)
        Button("색인 다시 만들기") { model.rebuildIndex() }
        SettingsLink { Text("설정…") }
        Divider()
        Button("Allspot 종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SearchModel()
    private var window: NSWindow?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Allspot"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ContentView().environmentObject(model))
        window.setContentSize(NSSize(width: 1040, height: 640))
        if !window.setFrameUsingName("AllspotMain") { window.center() }
        window.setFrameAutosaveName("AllspotMain")
        self.window = window

        model.registerHotKey = { [weak self] combo in
            guard let self else { return false }
            self.hotKey = nil
            guard let combo else { return true }
            self.hotKey = HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
                self?.toggleWindow()
            }
            return self.hotKey != nil
        }
        model.applyHotKey(model.hotKey)
        model.start()
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.controller.save(wait: true)
        model.contentIndexer.saveNow()
    }

    func showWindow() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.focusSearch(selectAll: true)
    }

    /// 단축키: 창이 앞에 있으면 숨기고, 아니면 불러온다(Everything의 전역 단축키처럼).
    func toggleWindow() {
        if let window, window.isKeyWindow, NSApp.isActive {
            NSApp.hide(nil)
        } else {
            showWindow()
        }
    }
}

/// Carbon 전역 단축키. 다른 앱을 쓰는 중에도 눌리고, 손쉬운 사용 권한이 필요 없다.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x414C_5350), id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            RemoveEventHandler(handlerRef)
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
