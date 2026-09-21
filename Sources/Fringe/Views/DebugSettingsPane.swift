import AppKit
import SwiftUI

/// What the geometry actually resolved to, and what is actually on disk.
///
/// This pane exists because of a specific afternoon: a `simulateNotch`
/// preference had been dropped from the UI but stayed in `UserDefaults`,
/// where it kept quietly replacing the measured cutout with a hardcoded
/// guess. Every number on screen looked plausible and none of them could be
/// inspected, so the only way to find it was to go looking in the code.
///
/// The numbers themselves live on `GeometryReport`. This view only renders
/// them — so a test can assert the same readout the pane shows.
struct DebugSettingsPane: View {
    let settings: NotchSettings
    let library: ScriptLibrary
    let state: NotchState

    var body: some View {
        let report = makeReport()

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Display") {
                    row("Screen", report.screenDescription)
                    row("Frame", GeometryReport.format(report.screenFrame))
                    row("Backing scale", "\(GeometryReport.number(report.backingScale))×")
                }

                section("Notch") {
                    row("Source", report.notchSource)
                    row("Size", GeometryReport.format(report.notch))
                }

                section("Grid") {
                    row("Cells", "\(report.columns) × \(report.rows)")
                    row("Cell / gutter", "\(GeometryReport.number(report.cellSize)) / \(GeometryReport.number(report.spacing)) pt")
                    row("Board", GeometryReport.format(report.boardSize))
                    row("Board origin", GeometryReport.format(report.boardOrigin))
                }

                section("Panel") {
                    row("Collapsed", GeometryReport.format(report.collapsed))
                    row("Expanded", GeometryReport.format(report.expanded))
                    row("Window", GeometryReport.format(report.window))
                }

                section("Placement") {
                    if report.widgets.isEmpty {
                        row("—", "No widgets placed")
                    }
                    ForEach(report.widgets, id: \.id) { widget in
                        row(widget.id, widget.detail)
                    }
                }

                section("Stored preferences") {
                    if report.stored.isEmpty {
                        row("—", "Nothing stored yet")
                    }
                    ForEach(report.stored, id: \.key) { entry in
                        row(entry.key, entry.value, isForeign: entry.isForeign)
                    }
                }

                HStack {
                    Spacer()
                    Button("Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.plainText, forType: .string)
                    }
                }
            }
            .padding(20)
        }
    }

    private func makeReport() -> GeometryReport {
        let screen = NSScreen.notchHost()
        let arrangement = BoardArrangement(settings: settings, library: library)
        let domain = UserDefaults.standard.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? ""
        ) ?? [:]

        return GeometryReport(
            screenName: screen?.localizedName ?? "",
            screenFrame: screen?.frame ?? .zero,
            backingScale: screen?.backingScaleFactor ?? 1,
            metrics: state.metrics,
            settings: settings,
            placements: arrangement.placements,
            unplaced: arrangement.unplaced.map(\.id),
            stored: NotchSettings.inventory(of: domain)
        )
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 3) {
                content()
            }
        }
    }

    private func row(_ label: String, _ value: String, isForeign: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isForeign ? .orange : .primary)
                .textSelection(.enabled)
            if isForeign {
                Text("unknown key")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
    }
}
