import AppKit
import SwiftUI

enum SettingsWindowMetrics {
    static func maximumContentSize(
        visibleScreenSize: CGSize,
        windowChromeSize: CGSize
    ) -> CGSize {
        CGSize(
            width: max(320, visibleScreenSize.width - windowChromeSize.width - 48),
            height: max(240, visibleScreenSize.height - windowChromeSize.height - 48)
        )
    }
}

struct SettingsWindowMetricsReader: NSViewRepresentable {
    let onChange: (CGSize) -> Void

    func makeNSView(context: Context) -> MetricsView {
        let view = MetricsView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: MetricsView, context: Context) {
        nsView.onChange = onChange
        DispatchQueue.main.async { [weak nsView] in
            nsView?.refreshMetrics()
        }
    }

    final class MetricsView: NSView {
        var onChange: ((CGSize) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)

            guard let window else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(refreshMetrics),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(refreshMetrics),
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
            DispatchQueue.main.async { [weak self] in
                self?.refreshMetrics()
            }
        }

        @objc func refreshMetrics() {
            guard let maximumContentSize = currentMaximumContentSize() else { return }
            onChange?(maximumContentSize)
        }

        func currentMaximumContentSize() -> CGSize? {
            guard let window, let screen = window.screen else { return nil }
            let chromeSize = CGSize(
                width: max(0, window.frame.width - window.contentLayoutRect.width),
                height: max(0, window.frame.height - window.contentLayoutRect.height)
            )
            return SettingsWindowMetrics.maximumContentSize(
                visibleScreenSize: screen.visibleFrame.size,
                windowChromeSize: chromeSize
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
