import AppKit
import HarborCore
@testable import HarborUI
import SwiftUI
import Testing

/// Renders the tab strip offscreen. Set HARBOR_SNAPSHOT_DIR to keep the PNGs for review.
@Suite("Tab strip rendering")
@MainActor
struct TabStripSnapshotTests {
    static let sample: [TabItemState] = [
        TabItemState(id: SessionID(), title: "dan@nexus-tx", subtitle: "sudo apt-get upgrade -y", subtitleIsCommand: true,
                     commandByAssistant: true, status: .busy, hostColor: .orange, isSelected: true, assistantActive: true,
                     busySince: Date().addingTimeInterval(-74)),
        TabItemState(id: SessionID(), title: "deploy@web-1", subtitle: "docker compose ps", subtitleIsCommand: true,
                     failedExitCode: 1, commandByAssistant: true, status: .idleAfterFailure(1), hostColor: .green, isSelected: false),
        TabItemState(id: SessionID(), title: "harbor", subtitle: "swift test --parallel", subtitleIsCommand: true,
                     status: .newOutput, isSelected: false),
        TabItemState(id: SessionID(), title: "root@db-2", subtitle: "Connecting…", status: .starting, hostColor: .red, isSelected: false),
        TabItemState(id: SessionID(), title: "~", subtitle: "tail -f /var/log/system.log", subtitleIsCommand: true,
                     status: .streaming, isSelected: false),
    ]

    @Test(arguments: [true, false])
    func rendersTwoLineTabs(dark: Bool) throws {
        let theme = dark ? BuiltInThemes.harborMidnight : BuiltInThemes.harborDaylight
        let strip = HStack(spacing: TabStripContent.tabSpacing) {
            ForEach(Self.sample) { item in
                TabItemLabel(item: item, width: 220, isHovered: false, showsInsertionMark: false) {}
            }
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).frame(width: 30)
            Spacer(minLength: 0)
        }
        .padding(.leading, 92)
        .padding(.trailing, 8)
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: 1300, height: 52)
        .background(theme.background.color)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 2600)

        if let directory = ProcessInfo.processInfo.environment["HARBOR_SNAPSHOT_DIR"] {
            let rep = NSBitmapImageRep(cgImage: image)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appending(path: "tab-strip-\(dark ? "dark" : "light").png"))
        }
    }

    @Test func extractsUserAtHostFromRemoteTitles() {
        #expect(TabItemState.userAtHost(in: "dan@nexus-tx: ~/src") == "dan@nexus-tx")
        #expect(TabItemState.userAtHost(in: "vim README.md") == nil)
    }
}
