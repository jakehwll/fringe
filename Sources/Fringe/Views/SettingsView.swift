import AppKit
import SwiftUI

/// Content of the preference window. The toolbar that switches panes lives on
/// the `NSWindow` itself — that is what makes it look like a Mac settings
/// window rather than a SwiftUI form stuffed into a dialog.
struct SettingsView: View {
    let chrome: SettingsChrome
    @Bindable var settings: NotchSettings
    let library: ScriptLibrary
    let state: NotchState

    var body: some View {
        Group {
            switch chrome.pane {
            case .general:
                GeneralSettingsPane(settings: settings)
            case .grid:
                GridSettingsPane(settings: settings)
            case .widgets:
                WidgetsSettingsPane(library: library, settings: settings)
            case .debug:
                DebugSettingsPane(settings: settings, library: library, state: state)
            }
        }
        .frame(width: SettingsPane.contentWidth, height: chrome.pane.contentHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Bindable var settings: NotchSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Notch") {
                    Text(notchDescription)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("""
                    Measured from the display. On a Mac without a cutout \
                    the notch is drawn at a standard size instead.
                    """)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        settings.resetToDefaults()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var notchDescription: String {
        guard let screen = NSScreen.notchHost() else { return "No display" }
        let metrics = NotchMetrics.resolve(for: screen, settings: settings)
        let size = "\(Int(metrics.size.width)) × \(Int(metrics.size.height)) pt"
        return metrics.isPhysical ? size : "\(size) (simulated)"
    }
}

// MARK: - Grid

private struct GridSettingsPane: View {
    @Bindable var settings: NotchSettings

    var body: some View {
        Form {
            Section {
                stepper("Columns", value: $settings.columns, range: NotchSettings.columnRange)
                stepper("Rows", value: $settings.rows, range: NotchSettings.rowRange)
            } footer: {
                let size = settings.grid.contentSize
                Text("""
                    Widgets occupy whole cells. \
                    The panel is \(Int(size.width)) × \(Int(size.height)) points \
                    at the current cell size.
                    """)
            }

            Section("Preview") {
                GridPreview(columns: settings.columns, rows: settings.rows)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        LabeledContent(title) {
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .monospacedDigit()
                    .frame(minWidth: 16, alignment: .trailing)
            }
            .fixedSize()
        }
    }
}

private struct GridPreview: View {
    let columns: Int
    let rows: Int

    var body: some View {
        let cell: CGFloat = 18
        let gap: CGFloat = 4
        VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.accentColor.opacity(0.35))
                            .overlay {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                            }
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .accessibilityLabel("\(columns) by \(rows) grid")
    }
}

// MARK: - Widgets

private struct WidgetsSettingsPane: View {
    let library: ScriptLibrary
    @Bindable var settings: NotchSettings

    private var ordered: [ScriptedWidget] {
        library.widgets(orderedBy: settings.widgetOrder)
    }

    /// Recomputed here so a widget that cannot fit can say so, rather than
    /// silently not appearing on the board.
    private var unplaced: Set<String> {
        Set(BoardArrangement(settings: settings, library: library).unplaced.map(\.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(ordered) { widget in
                    row(for: widget)
                }
                .onMove(perform: move)
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .overlay {
                if library.widgets.isEmpty {
                    Text("No widgets in the scripts folder")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("Open in Finder") { library.revealInFinder() }
                Button("Reload") { library.reload() }
                Spacer()
                Text("Drag to reorder. Minus or drag off the panel to hide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func row(for widget: ScriptedWidget) -> some View {
        let isEnabled = settings.isEnabled(widget.id)
        let span = settings.span(for: widget.id, declared: widget.span)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: enabled(widget.id))
                    .labelsHidden()
                    .controlSize(.mini)
                    .help("Show this widget on the board")

                VStack(alignment: .leading, spacing: 1) {
                    Text(widget.name)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    subtitle(for: widget, isEnabled: isEnabled)
                }

                Spacer()

                Text("\(span.columns)×\(span.rows)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if !widget.settingsSpec.isEmpty {
                ForEach(widget.settingsSpec) { spec in
                    settingField(spec, widget: widget)
                }
                .padding(.leading, 28)
            }

            if widget.declaredPermissions.network || widget.declaredPermissions.media
                || widget.declaredPermissions.battery {
                grants(for: widget)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func settingField(_ spec: WidgetSettingSpec, widget: ScriptedWidget) -> some View {
        switch spec.kind {
        case .string:
            TextField(spec.label, text: stringBinding(spec, widget: widget))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        case .number:
            HStack {
                Text(spec.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(
                    spec.label,
                    value: numberBinding(spec, widget: widget),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
            }
        case .boolean:
            Toggle(spec.label, isOn: boolBinding(spec, widget: widget))
                .toggleStyle(.switch)
                .controlSize(.mini)
        case .choice:
            Picker(spec.label, selection: stringBinding(spec, widget: widget)) {
                ForEach(spec.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    private func stringBinding(_ spec: WidgetSettingSpec, widget: ScriptedWidget) -> Binding<String> {
        Binding(
            get: {
                spec.resolved(settings.widgetValue(widget.id, key: spec.id)) as? String
                    ?? spec.stringDefault
            },
            set: { value in
                settings.setWidgetValue(value, widgetID: widget.id, key: spec.id)
                widget.forceRender()
            }
        )
    }

    private func numberBinding(_ spec: WidgetSettingSpec, widget: ScriptedWidget) -> Binding<Double> {
        Binding(
            get: {
                spec.resolved(settings.widgetValue(widget.id, key: spec.id)) as? Double
                    ?? spec.numberDefault
            },
            set: { value in
                settings.setWidgetValue(value, widgetID: widget.id, key: spec.id)
                widget.forceRender()
            }
        )
    }

    private func boolBinding(_ spec: WidgetSettingSpec, widget: ScriptedWidget) -> Binding<Bool> {
        Binding(
            get: {
                spec.resolved(settings.widgetValue(widget.id, key: spec.id)) as? Bool
                    ?? spec.booleanDefault
            },
            set: { value in
                settings.setWidgetValue(value, widgetID: widget.id, key: spec.id)
                widget.forceRender()
            }
        )
    }

    @ViewBuilder
    private func subtitle(for widget: ScriptedWidget, isEnabled: Bool) -> some View {
        if let failure = widget.failure {
            Text(failure).font(.caption).foregroundStyle(.red).lineLimit(1)
        } else if !isEnabled {
            Text("Hidden").font(.caption).foregroundStyle(.secondary)
        } else if unplaced.contains(widget.id) {
            Text("No room on the grid").font(.caption).foregroundStyle(.orange)
        } else {
            let caps = widget.permissions.labels
            let pending = widget.declaredPermissions.labels.filter { label in
                !caps.contains(label)
            }
            if pending.isEmpty {
                Text(caps.isEmpty ? widget.id : "\(widget.id) · \(caps.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(widget.id) · \(pending.joined(separator: ", ")) blocked")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func grants(for widget: ScriptedWidget) -> some View {
        HStack(spacing: 12) {
            if widget.declaredPermissions.network {
                Toggle("Network", isOn: grantBinding(widget, key: "network"))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if widget.declaredPermissions.media {
                Toggle("Media", isOn: grantBinding(widget, key: "media"))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if widget.declaredPermissions.battery {
                Toggle("Battery", isOn: grantBinding(widget, key: "battery"))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            Spacer(minLength: 0)
        }
    }

    private func grantBinding(_ widget: ScriptedWidget, key: String) -> Binding<Bool> {
        Binding(
            get: {
                settings.grantedCapabilities(for: widget.id).keys.contains(key)
            },
            set: { allowed in
                var granted = settings.grantedCapabilities(for: widget.id)
                switch key {
                case "network": granted.network = allowed
                case "media": granted.media = allowed
                case "battery": granted.battery = allowed
                default: break
                }
                settings.setGranted(granted, for: widget.id)
                widget.applyGrants()
                library.refreshIslands(force: true)
            }
        )
    }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(id) },
            set: { settings.setEnabled($0, for: id) }
        )
    }

    /// Writes the whole arrangement back, not just the moved rows — the stored
    /// order is the list of filenames, and a partial update would leave it
    /// disagreeing with what is on screen.
    private func move(from source: IndexSet, to destination: Int) {
        var identifiers = ordered.map(\.id)
        identifiers.move(fromOffsets: source, toOffset: destination)
        settings.widgetOrder = identifiers
    }
}
