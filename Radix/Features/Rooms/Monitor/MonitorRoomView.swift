import Charts
import SwiftUI

struct MonitorRoomView: View {
    @ObservedObject private var model = MonitorRoomModel.shared
    @State private var isWide = true

    private enum Card: Hashable {
        case cpu, memory, processes, ports, disk, battery
    }

    private var cards: [Card] {
        [.cpu, .memory, .processes, .ports, .disk] + (model.battery == nil ? [] : [.battery])
    }

    var body: some View {
        RoomPage(room: .monitor) {
            LiveBadge()
        } content: {
            Group {
                if isWide {
                    Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                        ForEach(Array(stride(from: 0, to: cards.count, by: 2)), id: \.self) { index in
                            GridRow {
                                card(cards[index])
                                    .gridCellColumns(index + 1 < cards.count ? 1 : 2)
                                if index + 1 < cards.count {
                                    card(cards[index + 1])
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        ForEach(cards, id: \.self, content: card)
                    }
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { isWide = $0 }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private func card(_ card: Card) -> some View {
        switch card {
        case .cpu: CPUCard(model: model)
        case .memory: MemoryCard(model: model)
        case .processes: ProcessesCard(model: model)
        case .ports: PortsCard(ports: model.ports)
        case .disk: DiskCard(history: model.diskHistory.elements, volume: model.volume)
        case .battery: if let battery = model.battery { BatteryCard(battery: battery) }
        }
    }
}

private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("Live", tableName: "Monitor")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(Text("Refreshed every second while this page is open.", tableName: "Monitor"))
    }
}

private struct MonitorCard<Accessory: View, Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        RoomCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                    accessory()
                }
                content()
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

extension MonitorCard where Accessory == EmptyView {
    init(title: String, systemImage: String, tint: Color, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, systemImage: systemImage, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(verbatim: value).monospacedDigit()
        }
        .font(.callout)
        .lineLimit(1)
    }
}

private struct HistoryPoint: Identifiable {
    let x: Int
    let value: Double
    let series: String
    var id: String { "\(series)\(x)" }
}

/// Newest sample at x = 0, older ones to the left, so the chart fills from the right.
private func historyPoints<T>(_ samples: [T], series: String, value: (T) -> Double) -> [HistoryPoint] {
    samples.enumerated().map { HistoryPoint(x: $0.offset - samples.count + 1, value: value($0.element), series: series) }
}

private let historyDomain = -(MonitorRoomModel.historyLength - 1)...0
private let placeholder = "–"

private func percent(_ fraction: Double, digits: Int = 0) -> String {
    fraction.formatted(.percent.precision(.fractionLength(digits)))
}

private let rateFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter
}()

private func memorySize(_ bytes: UInt64) -> String {
    Int64(clamping: bytes).formatted(.byteCount(style: .memory))
}

private struct CPUCard: View {
    @ObservedObject var model: MonitorRoomModel

    var body: some View {
        let cpu = model.cpu
        MonitorCard(title: String(localized: "Processor", table: "Monitor"), systemImage: "cpu", tint: .green) {
            HStack(alignment: .top) {
                RoomStat(value: cpu.map { percent($0.total) } ?? placeholder,
                             caption: String(localized: "Usage", table: "Monitor"), tint: .green)
                Spacer(minLength: 24)
                VStack(alignment: .leading, spacing: 4) {
                    LegendItem(color: .green, label: String(localized: "User", table: "Monitor"),
                               value: cpu.map { percent($0.user) } ?? placeholder)
                    LegendItem(color: .mint, label: String(localized: "System", table: "Monitor"),
                               value: cpu.map { percent($0.system) } ?? placeholder)
                }
                .frame(width: 170)
            }
            Chart {
                ForEach(historyPoints(model.cpuHistory.elements, series: "system", value: { $0.system * 100 })
                    + historyPoints(model.cpuHistory.elements, series: "user", value: { $0.user * 100 })) { point in
                    AreaMark(x: .value("t", point.x), y: .value("%", point.value))
                        .foregroundStyle(by: .value("s", point.series))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["system": Color.mint.opacity(0.85), "user": Color.green.opacity(0.75)])
            .chartLegend(.hidden)
            .chartXScale(domain: historyDomain)
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(verbatim: "\(value.as(Int.self) ?? 0) %") }
                }
            }
            .frame(height: 96)
            CoreBars(cores: model.cores, kinds: model.coreKinds)
            Divider()
            HStack {
                Text("Load average", tableName: "Monitor")
                    .foregroundStyle(.secondary)
                    .help(Text("Over 1, 5 and 15 minutes", tableName: "Monitor"))
                Spacer()
                Text(verbatim: model.loadAverage.isEmpty ? placeholder
                     : model.loadAverage.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: "   "))
                    .monospacedDigit()
            }
            .font(.callout)
        }
    }
}

private struct CoreBars: View {
    let cores: [CPUUsage]
    let kinds: [CoreKind]?

    private var groups: [(title: String, cores: [CPUUsage])] {
        guard let kinds, kinds.count == cores.count else {
            return [(String(localized: "Cores", table: "Monitor"), cores)]
        }
        let pairs = zip(kinds, cores)
        return [
            (String(localized: "Performance", table: "Monitor"), pairs.filter { $0.0 == .performance }.map(\.1)),
            (String(localized: "Efficiency", table: "Monitor"), pairs.filter { $0.0 == .efficiency }.map(\.1)),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(Array(group.cores.enumerated()), id: \.offset) { _, core in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(.quaternary)
                                .overlay(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(Color.green.gradient)
                                        .scaleEffect(x: 1, y: max(0.02, core.total), anchor: .bottom)
                                }
                                .frame(width: 10, height: 34)
                        }
                    }
                    Text(group.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: groups.map { "\($0.title) \(percent(CPUUsage.average($0.cores).total))" }.joined(separator: ", ")))
    }
}

private struct MemoryCard: View {
    @ObservedObject var model: MonitorRoomModel

    var body: some View {
        let memory = model.memory
        MonitorCard(title: String(localized: "Memory", table: "Monitor"), systemImage: "memorychip", tint: .blue) {
            PressureBadge(pressure: model.pressure)
        } content: {
            RoomStat(value: memory.map { memorySize($0.used) } ?? placeholder,
                         caption: String(localized: "used of \(memory.map { memorySize($0.total) } ?? placeholder)", table: "Monitor"),
                         tint: .blue)
            Chart(historyPoints(model.memoryHistory.elements, series: "used", value: { $0 * 100 })) { point in
                AreaMark(x: .value("t", point.x), y: .value("%", point.value))
                    .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.7), .blue.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", point.x), y: .value("%", point.value))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.monotone)
            }
            .chartXScale(domain: historyDomain)
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(verbatim: "\(value.as(Int.self) ?? 0) %") }
                }
            }
            .frame(height: 96)
            if let memory {
                StorageSegmentBar(segments: [
                    StorageSegment(id: "app", label: String(localized: "App memory", table: "Monitor"), bytes: Int64(memory.app), color: .blue),
                    StorageSegment(id: "wired", label: String(localized: "Wired", table: "Monitor"), bytes: Int64(memory.wired), color: .indigo),
                    StorageSegment(id: "compressed", label: String(localized: "Compressed", table: "Monitor"), bytes: Int64(memory.compressed), color: .cyan),
                    StorageSegment(id: "cached", label: String(localized: "Cached files", table: "Monitor"), bytes: Int64(memory.cached), color: .gray.opacity(0.5)),
                ], total: Int64(memory.total), height: 8, showsLegend: false)
                Grid(horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        LegendItem(color: .blue, label: String(localized: "App memory", table: "Monitor"), value: memorySize(memory.app))
                        LegendItem(color: .indigo, label: String(localized: "Wired", table: "Monitor"), value: memorySize(memory.wired))
                    }
                    GridRow {
                        LegendItem(color: .cyan, label: String(localized: "Compressed", table: "Monitor"), value: memorySize(memory.compressed))
                        LegendItem(color: .gray.opacity(0.5), label: String(localized: "Cached files", table: "Monitor"), value: memorySize(memory.cached))
                    }
                    GridRow {
                        LegendItem(color: .clear, label: String(localized: "Swap used", table: "Monitor"), value: memorySize(model.swapUsed))
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
    }
}

private struct PressureBadge: View {
    let pressure: MemoryPressure

    var body: some View {
        let (label, color): (String, Color) = switch pressure {
        case .normal: (String(localized: "Pressure: normal", table: "Monitor"), .green)
        case .warning: (String(localized: "Pressure: high", table: "Monitor"), .orange)
        case .critical: (String(localized: "Pressure: critical", table: "Monitor"), .red)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct ProcessesCard: View {
    @ObservedObject var model: MonitorRoomModel
    @AppStorage("VracMonitorSortsByMemory") private var byMemory = false

    var body: some View {
        let processes = byMemory ? model.topByMemory : model.topByCPU
        let tint: Color = byMemory ? .blue : .green
        let maximum = max(processes.map { value(of: $0) }.max() ?? 0, byMemory ? 1 : 10)
        MonitorCard(title: String(localized: "Processes", table: "Monitor"), systemImage: "square.stack.3d.up", tint: tint) {
            Picker(selection: $byMemory) {
                Text("CPU", tableName: "Monitor").tag(false)
                Text("Memory", tableName: "Monitor").tag(true)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            if processes.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 2) {
                    ForEach(processes) { process in
                        ProcessRow(model: model, process: process, value: byMemory ? memorySize(process.memory) : percent(process.cpuPercent / 100, digits: 1),
                                   fraction: value(of: process) / maximum, tint: tint)
                    }
                }
            }
        }
    }

    private func value(of process: ProcessSample) -> Double {
        byMemory ? Double(process.memory) : process.cpuPercent
    }
}

private struct ProcessRow: View {
    let model: MonitorRoomModel
    let process: ProcessSample
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        let app = model.application(for: process.pid)
        HStack(spacing: 10) {
            Image(nsImage: model.icon(of: process))
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(verbatim: model.displayName(of: process))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint.opacity(0.1))
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .contentShape(Rectangle())
        .help(Text("PID \(Int(process.pid))", tableName: "Monitor"))
        .contextMenu {
            if let url = model.revealURL(of: process) {
                Button(String(localized: "Reveal in Finder", table: "Monitor"), systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                Divider()
                Button(String(localized: "Quit", table: "Monitor"), systemImage: "xmark.circle") {
                    app.terminate()
                }
            }
        }
    }
}

private struct PortsCard: View {
    let ports: [ListeningPort]?

    var body: some View {
        let exposed = ports?.filter { $0.scope == .allInterfaces }.count ?? 0
        MonitorCard(title: String(localized: "Network ports", table: "Monitor"), systemImage: "network", tint: .orange) {
            if let ports {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    RoomStat(value: ports.count.formatted(), caption: String(localized: "Listening ports", table: "Monitor"))
                    if exposed > 0 {
                        Label(String(localized: "\(exposed) open to the network", table: "Monitor"), systemImage: "globe")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                if ports.isEmpty {
                    Text("No listening ports", tableName: "Monitor")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(ports) { PortRow(port: $0) }
                        }
                    }
                    .frame(maxHeight: 280)
                }
                Spacer(minLength: 0)
                Text("Only your own processes are listed.", tableName: "Monitor")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }
}

private struct PortRow: View {
    let port: ListeningPort

    var body: some View {
        let exposed = port.scope == .allInterfaces
        HStack(spacing: 10) {
            Text(verbatim: String(port.port))
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 52, alignment: .leading)
            Text(verbatim: port.proto.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(verbatim: port.processName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            scopeLabel
                .font(.caption)
                .foregroundStyle(exposed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(exposed ? Color.orange.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help(Text(verbatim: "PID \(port.pid) · " + port.addresses.joined(separator: ", ")))
    }

    @ViewBuilder
    private var scopeLabel: some View {
        switch port.scope {
        case .allInterfaces: Label(String(localized: "All interfaces", table: "Monitor"), systemImage: "globe")
        case .localhost: Label(String(localized: "This Mac only", table: "Monitor"), systemImage: "lock")
        case .specific: Label(port.addresses.joined(separator: ", "), systemImage: "point.3.connected.trianglepath.dotted")
        }
    }
}

private struct DiskCard: View {
    let history: [DiskRates]
    let volume: VolumeSpace?

    private func rate(_ value: Double?) -> String {
        guard let value else { return placeholder }
        return String(localized: "\(rateFormatter.string(fromByteCount: Int64(value)))/s", table: "Monitor")
    }

    var body: some View {
        let latest = history.last
        let peak = max(history.map { max($0.read, $0.write) }.max() ?? 0, 1_000_000)
        MonitorCard(title: String(localized: "Disk", table: "Monitor"), systemImage: "internaldrive", tint: .teal) {
            HStack(alignment: .top, spacing: 32) {
                RoomStat(value: rate(latest?.read), caption: String(localized: "Read", table: "Monitor"), tint: .teal)
                RoomStat(value: rate(latest?.write), caption: String(localized: "Write", table: "Monitor"), tint: .orange)
            }
            Chart {
                ForEach(historyPoints(history, series: "read", value: \.read)
                    + historyPoints(history, series: "write", value: \.write)) { point in
                    LineMark(x: .value("t", point.x), y: .value("B", point.value))
                        .foregroundStyle(by: .value("s", point.series))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["read": Color.teal, "write": Color.orange])
            .chartLegend(.hidden)
            .chartXScale(domain: historyDomain)
            .chartYScale(domain: 0...peak)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 64)
            if let volume {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(verbatim: volume.name).fontWeight(.medium)
                        Spacer()
                        Text("\(RadixFormatters.size(volume.available)) available of \(RadixFormatters.size(volume.total))", tableName: "Monitor")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                    StorageSegmentBar(segments: [
                        StorageSegment(id: "used", label: volume.name, bytes: volume.total - volume.available, color: .gray.opacity(0.55)),
                    ], total: volume.total, height: 8, showsLegend: false)
                }
            }
        }
    }
}

private struct BatteryCard: View {
    let battery: BatteryInfo

    private var tint: Color {
        battery.isCharging || battery.isPluggedIn ? .green : battery.percent <= 10 ? .red : battery.percent <= 20 ? .orange : .green
    }

    private var state: String {
        if battery.isCharging { return String(localized: "Charging", table: "Monitor") }
        if battery.isPluggedIn { return battery.isFullyCharged ? String(localized: "Charged", table: "Monitor")
            : String(localized: "Plugged in, not charging", table: "Monitor") }
        return String(localized: "On battery", table: "Monitor")
    }

    private var symbol: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        let level = [100, 75, 50, 25].first { battery.percent >= $0 - 12 } ?? 0
        return "battery.\(level)percent"
    }

    var body: some View {
        MonitorCard(title: String(localized: "Battery", table: "Monitor"), systemImage: symbol, tint: tint) {
            RoomStat(value: percent(Double(battery.percent) / 100), caption: state, tint: tint)
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(tint.gradient).frame(width: proxy.size.width * Double(battery.percent) / 100)
                    }
                }
                .frame(height: 8)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row(String(localized: "Power source", table: "Monitor"), powerSource)
                if let minutes = battery.minutesRemaining, !battery.isFullyCharged {
                    row(battery.isCharging ? String(localized: "Time to full", table: "Monitor") : String(localized: "Time remaining", table: "Monitor"),
                        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                }
                if let cycles = battery.cycleCount {
                    row(String(localized: "Cycle count", table: "Monitor"), cycles.formatted())
                }
                if let health = battery.health {
                    row(String(localized: "Maximum capacity", table: "Monitor"), percent(health))
                        .help(Text("Compared with its capacity when new.", tableName: "Monitor"))
                }
                if let temperature = battery.temperature {
                    row(String(localized: "Temperature", table: "Monitor"),
                        Measurement(value: temperature, unit: UnitTemperature.celsius)
                            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1)))))
                }
            }
            .font(.callout)
        }
    }

    private var powerSource: String {
        guard battery.isPluggedIn else { return String(localized: "Battery", table: "Monitor") }
        guard let watts = battery.adapterWatts else { return String(localized: "Power adapter", table: "Monitor") }
        return String(localized: "Power adapter, \(watts) W", table: "Monitor")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value).monospacedDigit().gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
