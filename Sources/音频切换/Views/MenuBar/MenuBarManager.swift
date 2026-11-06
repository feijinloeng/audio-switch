import AppKit
import SwiftUI
import os

enum PopoverPlacement {
    static func anchor(in bounds: CGRect) -> CGRect {
        bounds
    }
}

enum PopoverRepositionPolicy {
    static func shouldReposition(from oldSize: CGSize, to newSize: CGSize) -> Bool {
        abs(oldSize.width - newSize.width) > 1
    }
}

enum PopoverDismissalPolicy {
    static func shouldDismiss(
        capturedPresentationGeneration: UInt64,
        currentPresentationGeneration: UInt64
    ) -> Bool {
        capturedPresentationGeneration == currentPresentationGeneration
    }
}

enum MenuBarLifecyclePolicy {
    static func shouldStart(hasStatusItem: Bool, hasPopover: Bool) -> Bool {
        !hasStatusItem && !hasPopover
    }
}

@MainActor
enum PopoverActivation {
    static func focus(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
    }
}

/// Manages the menu bar status item and popover.
@MainActor
final class MenuBarManager: NSObject {
    private let logger = Logger(subsystem: "com.mankeipun.yinpinqiehuan", category: "MenuBar")
    private(set) var statusItem: NSStatusItem?
    private(set) var popover: NSPopover?
    private var eventMonitor: Any?
    private var presentationGeneration: UInt64 = 0
    let audioEngine: AudioEngineFacade

    init(audioEngine: AudioEngineFacade) {
        self.audioEngine = audioEngine
        super.init()
    }

    func start(settingsManager: SettingsManager? = nil) {
        guard MenuBarLifecyclePolicy.shouldStart(
            hasStatusItem: statusItem != nil,
            hasPopover: popover != nil
        ) else {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            updateIcon(button: button)
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item

        let popover = NSPopover()
        let sizeProxy = PopoverSizeProxy()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopupView(
                audioEngine: audioEngine,
                sizeProxy: sizeProxy
            )
        )
        self.popover = popover
        sizeProxy.onSizeChanged = { [weak self] size in
            guard let self, let popover = self.popover else { return }
            let newSize = NSSize(width: ceil(size.width), height: ceil(size.height))
            let shouldReposition = PopoverRepositionPolicy.shouldReposition(
                from: popover.contentSize,
                to: newSize
            )
            popover.contentSize = newSize
            if shouldReposition {
                self.repositionShownPopover()
            }
        }

        // 监听弹窗外部的点击事件
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let capturedPresentationGeneration = self?.presentationGeneration
            Task { @MainActor [weak self] in
                guard let capturedPresentationGeneration else { return }
                self?.closePopover(ifCurrentPresentationGeneration: capturedPresentationGeneration)
            }
        }

    }

    func stop() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        popover = nil
    }

    private func updateIcon(button: NSStatusBarButton) {
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "音频切换")
    }

    func closePopover() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
    }

    private func closePopover(ifCurrentPresentationGeneration capturedPresentationGeneration: UInt64) {
        guard PopoverDismissalPolicy.shouldDismiss(
            capturedPresentationGeneration: capturedPresentationGeneration,
            currentPresentationGeneration: presentationGeneration
        ) else {
            return
        }
        closePopover()
    }

    func showPopover() {
        guard let popover else { return }
        presentationGeneration &+= 1
        let shownPresentationGeneration = presentationGeneration

        // 交给 NSPopover 避让当前屏幕边界：靠边时保证内容完整，箭头仍指向图标中心。
        popover.behavior = .applicationDefined
        positionPopover()
        PopoverActivation.focus(popover.contentViewController?.view.window)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak popover] in
            Task { @MainActor [weak self, weak popover] in
                guard let self,
                      let popover,
                      popover.isShown,
                      PopoverDismissalPolicy.shouldDismiss(
                        capturedPresentationGeneration: shownPresentationGeneration,
                        currentPresentationGeneration: self.presentationGeneration
                      ) else {
                    return
                }
                popover.behavior = .transient
            }
        }
    }

    private func repositionShownPopover() {
        guard let popover, popover.isShown else { return }
        // 内容尺寸变化后重新执行完整定位，让 AppKit 同时处理箭头方向与屏幕安全边界。
        positionPopover()
    }

    private func positionPopover() {
        guard let button = statusItem?.button, let popover else { return }
        popover.show(
            relativeTo: PopoverPlacement.anchor(in: button.bounds),
            of: button,
            preferredEdge: .minY
        )
    }

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }
}
