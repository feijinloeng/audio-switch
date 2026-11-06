import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum CompanionDistribution {
    static let appStoreURL = URL(
        string: "https://apps.apple.com/app/%E9%9F%B3%E9%A2%91%E5%88%87%E6%8D%A2%E4%BC%B4%E4%BE%A3/id6795223287"
    )!
}

enum CompanionQRCodeGenerator {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(
            by: CGAffineTransform(scaleX: 10, y: 10)
        )
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(
            scaledImage,
            from: scaledImage.extent
        ) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height)
        )
    }
}

struct CompanionDownloadButton: View {
    let title: String
    @State private var showsDownload = false

    var body: some View {
        Button(title) {
            showsDownload = true
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .popover(isPresented: $showsDownload, arrowEdge: .trailing) {
            CompanionDownloadView()
        }
        .accessibilityHint("显示 iPhone 伴侣下载二维码和分享选项")
    }
}

struct CompanionDownloadView: View {
    @State private var didCopyLink = false

    private var qrCodeImage: NSImage? {
        CompanionQRCodeGenerator.image(
            for: CompanionDistribution.appStoreURL.absoluteString
        )
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Label("下载音频切换伴侣", systemImage: "iphone")
                .font(.headline)

            Text("使用 iPhone 相机扫描二维码，在 App Store 中下载。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let qrCodeImage {
                Image(nsImage: qrCodeImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .accessibilityLabel("音频切换伴侣 App Store 下载二维码")
            } else {
                ContentUnavailableView(
                    "二维码生成失败",
                    systemImage: "qrcode",
                    description: Text("请复制下载链接并发送到 iPhone。")
                )
                .frame(width: 180, height: 180)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    copyDownloadLink()
                } label: {
                    Label(
                        didCopyLink ? "已复制" : "复制链接",
                        systemImage: didCopyLink ? "checkmark" : "doc.on.doc"
                    )
                }

                ShareLink(item: CompanionDistribution.appStoreURL) {
                    Label("发送到 iPhone", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("非公开 App 无法通过 App Store 搜索，请使用此链接下载。")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 286)
    }

    private func copyDownloadLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        didCopyLink = pasteboard.setString(
            CompanionDistribution.appStoreURL.absoluteString,
            forType: .string
        )
    }
}
