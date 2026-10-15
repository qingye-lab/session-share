import SwiftUI

// Shared native colors and motion keep the menu bar panel at home on macOS.
enum Brand {
    static let accent = Color.indigo
    static let gradient = LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let avatarColors: [Color] = [.indigo, .teal, .orange, .blue, .pink, .purple]
    static let panelWidth: CGFloat = 400
    static let spring = Animation.spring(response: 0.32, dampingFraction: 1)
}

private let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.unitsStyle = .full
    return f
}()

private func ago(_ date: Date) -> String { relative.localizedString(for: date, relativeTo: Date()) }

private func shortDate(_ ms: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}

private struct Surface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(scheme == .dark ? 0.65 : 0.9))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.07))
            }
    }
}

private struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? Brand.accent : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.055))
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : Brand.spring, value: configuration.isPressed)
    }
}

// MARK: - Panel

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var refreshOnAppear = true

    var body: some View {
        VStack(spacing: 0) {
            Header()
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 16) {
                    StatusCard()
                    if let snapshot = model.snapshot {
                        AccountsSection(snapshot: snapshot)
                        ProjectsSection(snapshot: snapshot)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: max(240, min(600, (NSScreen.main?.visibleFrame.height ?? 800) - (model.confirming ? 270 : 180))))
            .fixedSize(horizontal: false, vertical: true)

            Footer()
        }
        .frame(width: Brand.panelWidth)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .tint(Brand.accent)
        .animation(reduceMotion ? nil : Brand.spring, value: model.phase)
        .onAppear { if refreshOnAppear { model.panelOpened() } }
    }
}

struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Brand.gradient)
            .overlay {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Header

private struct Header: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("会话合并")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.3)
                HStack(spacing: 5) {
                    Circle().fill(model.claudeRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 5, height: 5)
                    Text(model.claudeRunning ? "Claude 正在运行" : "Claude 未运行")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { Task { await model.refresh() } } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(model.loading ? 0 : 1)
                    if model.loading { ProgressView().controlSize(.mini) }
                }
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.loading || model.interactionLocked)
            .help("重新读取会话 · ⌘R")
            .accessibilityLabel(model.loading ? "正在读取会话" : "重新读取会话")
            .keyboardShortcut("r")

            Menu {
                Button("撤销上次合并…") { model.undoTapped() }
                    .disabled(model.snapshot?.lastRun == nil || model.interactionLocked)
                if let last = model.snapshot?.lastRun {
                    Text("上次合并\(ago(last.date)) · 改动 \(last.changes) 处")
                }
                Button("打开备份文件夹") { model.revealBackups() }
                Divider()
                Toggle("登录时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Divider()
                Button("退出会话合并") { NSApp.terminate(nil) }.keyboardShortcut("q")
                    .disabled(model.busy || model.saving)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .medium))
                    .frame(width: 24, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .accessibilityLabel("更多选项")
            .help("备份、撤销与设置")
        }
    }
}

// MARK: - Status

private struct StatusCard: View {
    @EnvironmentObject var model: AppModel
    @State private var showDetails = false

    private var notes: [String] {
        guard let snapshot = model.snapshot else { return [] }
        var result = snapshot.warnings
        if snapshot.missing > 0 { result.insert("\(snapshot.missing) 个会话找不到对话文件，可能无法打开。", at: 0) }
        if let error = model.loadError { result.insert("重新读取失败：\(error)", at: 0) }
        return result
    }

    var body: some View {
        let c = content
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.tint.opacity(0.1))
                    if c.spinner {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: c.icon).font(.system(size: 19, weight: .medium)).foregroundStyle(c.tint)
                    }
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(c.title).font(.system(size: 18, weight: .semibold)).tracking(-0.5)
                    Text(c.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            if !notes.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 5)
                } label: {
                    Label("\(notes.count) 项需要留意", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Surface())
        .accessibilityElement(children: .contain)
    }

    struct Content {
        var icon = "arrow.triangle.merge"
        var tint = Brand.accent
        var title: String
        var detail: String
        var spinner = false
    }

    private var content: Content {
        switch model.phase {
        case .working(let text):
            return Content(title: text, detail: "完成后会自动打开 Claude。", spinner: true)
        case .done(let text):
            return Content(icon: "checkmark.circle.fill", tint: .green, title: "操作已完成", detail: text)
        case .failed(let text):
            return Content(icon: "exclamationmark.circle", tint: .red, title: "操作未完成", detail: text)
        default: break
        }
        guard let s = model.snapshot else {
            if let error = model.loadError {
                return Content(icon: "exclamationmark.circle", tint: .red, title: "无法读取会话", detail: error)
            }
            return Content(title: "正在读取会话", detail: "查找本机账号与项目…", spinner: true)
        }
        if model.saving { return Content(title: "正在更新同步范围", detail: "正在保存选择并重新计算改动。", spinner: true) }
        if s.accounts.isEmpty { return Content(icon: "person.crop.circle.badge.plus", title: "先登录一个账号", detail: "在 Claude 桌面版中登录并创建 Code 会话，再回来刷新。") }
        if s.changes > 0 {
            let title = s.behind.isEmpty ? "有会话等待更新" : "\(s.behind.count) 个账号待同步"
            var detail = "\(s.accounts.count) 个账号 · \(s.sessions) 个会话"
            if s.imports > 0 { detail += "，含 \(s.imports) 个终端导入" }
            return Content(title: title, detail: detail + " · 合并后跨账号共享")
        }
        var detail = "\(s.accounts.count) 个账号的会话列表已同步。"
        if let last = s.lastRun { detail += "上次合并\(ago(last.date))。" }
        return Content(icon: "checkmark.circle.fill", tint: .green, title: "会话已是最新", detail: detail)
    }
}

// MARK: - Accounts

private struct SectionHeading: View {
    var title: String
    var detail: String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

private struct AccountsSection: View {
    var snapshot: Snapshot

    var body: some View {
        VStack(spacing: 8) {
            SectionHeading(title: "共享账号", detail: "\(snapshot.accounts.count) 个账号")
            if snapshot.accounts.isEmpty {
                Text("登录过的桌面账号会显示在这里。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(16).modifier(Surface())
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.accounts.enumerated()), id: \.element.key) { i, account in
                            AccountRow(account: account, color: Brand.avatarColors[i % Brand.avatarColors.count])
                            if i < snapshot.accounts.count - 1 {
                                Divider().padding(.leading, 54).padding(.trailing, 12)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(snapshot.accounts.count) * 53, 159))
                .modifier(Surface())
            }
        }
    }
}

private struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    var account: Snapshot.Account
    var color: Color
    @State private var hover = false
    @State private var editing = false

    var body: some View {
        HStack(spacing: 10) {
            Avatar(account: account, color: color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(account.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if account.signedIn {
                        Text("当前").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Brand.accent)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Brand.accent.opacity(0.09), in: Capsule())
                    }
                }
                Text(secondary).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 2)
            if !account.gateway {
                Button { editing = true } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hover || editing ? 1 : 0.35)
                .disabled(model.interactionLocked)
                .help("编辑\(account.name)的备注")
                .accessibilityLabel("编辑\(account.name)的备注")
                .popover(isPresented: $editing, arrowEdge: .trailing) {
                    RemarkEditor(account: account) { editing = false }
                }
            }
            CountBadge(account: account).frame(minWidth: 46, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(Color.primary.opacity(hover ? 0.035 : 0))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var secondary: String {
        if account.gateway { return "第三方网关" }
        if !account.email.isEmpty { return account.email }
        return "ID \(account.shortID)"
    }
}

private struct Avatar: View {
    var account: Snapshot.Account
    var color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12))
            if account.gateway {
                Image(systemName: "network").font(.system(size: 15, weight: .medium))
            } else if let initial {
                Text(initial).font(.system(size: 14, weight: .semibold))
            } else {
                Image(systemName: "person.fill").font(.system(size: 13))
            }
        }
        .foregroundStyle(color)
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    private var initial: String? {
        let known = !account.remark.isEmpty || !account.email.isEmpty || !account.name.hasPrefix("账号 ")
        guard known, let first = account.name.first else { return nil }
        return String(first).uppercased()
    }
}

private struct CountBadge: View {
    var account: Snapshot.Account

    var body: some View {
        HStack(spacing: 4) {
            if account.add > 0 || account.remove > 0 {
                Text("\(account.have)").foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                Text("\(account.after)").foregroundStyle(Brand.accent).fontWeight(.semibold)
            } else {
                Text("\(account.have)").foregroundStyle(.secondary)
                Image(systemName: account.update > 0 ? "arrow.triangle.2.circlepath" : "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(account.update > 0 ? Brand.accent : Color.green)
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("现在 \(account.have) 个会话，合并后 \(account.after) 个，更新 \(account.update) 个")
        .help("现在 \(account.have) 个 · 合并后 \(account.after) 个 · 更新 \(account.update) 个")
    }
}

private struct RemarkEditor: View {
    @EnvironmentObject var model: AppModel
    var account: Snapshot.Account
    var close: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("账号备注").font(.system(size: 14, weight: .semibold))
            TextField("邮箱、用途，或容易记住的名字", text: $draft)
                .textFieldStyle(.roundedBorder).focused($focused)
                .frame(width: 270).onSubmit(save)
                .accessibilityLabel("账号备注")
            Text("ID \(account.uuid)").font(.system(size: 10).monospaced())
                .foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                if !account.remark.isEmpty {
                    Button("清除") { model.setRemark(account.uuid, ""); close() }.buttonStyle(.link)
                }
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .onAppear { draft = account.remark; focused = true }
    }

    private func save() { model.setRemark(account.uuid, draft); close() }
}

// MARK: - Projects

private struct ProjectsSection: View {
    @EnvironmentObject var model: AppModel
    var snapshot: Snapshot
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "同步范围", detail: "已选 \(rows.filter(\.on).count) / \(rows.count) 个项目")
            Picker("会话来源", selection: $model.tab) {
                Text("桌面会话 · \(snapshot.projects.count)").tag(AppModel.Tab.desktop)
                Text("终端导入 · \(snapshot.terminal.count)").tag(AppModel.Tab.terminal)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.regular)

            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("搜索项目或路径", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .focused($searchFocused).accessibilityLabel("搜索项目或路径")
                    if !query.isEmpty {
                        Button { query = ""; searchFocused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 12).frame(height: 36)
                Divider().padding(.horizontal, 12)
                if filteredRows.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: query.isEmpty ? "folder" : "magnifyingglass")
                            .font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
                        Text(query.isEmpty ? (model.tab == .desktop ? "还没有桌面会话" : "没有可导入的终端会话") : "没有匹配的项目")
                            .font(.system(size: 12, weight: .medium))
                        Text(query.isEmpty ? "刷新后，这里的项目会自动更新。" : "试试其他名称，或清除搜索。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).frame(height: 112)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredRows, id: \.path) { row in
                                ProjectRow(row: row)
                            }
                        }
                    }
                    .frame(height: 160)
                    .clipped()
                    .scrollIndicators(.automatic)
                }
            }
            .modifier(Surface())
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: model.tab == .desktop ? "info.circle" : "terminal")
                    .font(.system(size: 10)).padding(.top, 2)
                Text(model.tab == .desktop
                     ? "所选项目共享到所有账号。关闭开关后，已共享的会话仍会保留。"
                     : "按需导入终端会话。所选项目会出现在所有账号的侧边栏。")
                    .font(.system(size: 11)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .onChange(of: model.tab) { _, _ in query = "" }
    }

    private var rows: [ProjectRow.Model] {
        switch model.tab {
        case .desktop:
            return snapshot.projects.map { p in
                let from = p.from.map { $0.name }.joined(separator: "、")
                return .init(path: p.path, name: p.name, detail: "\(p.count) 个会话" + (from.isEmpty ? "" : " · \(from)"),
                             on: p.on, terminal: false)
            }
        case .terminal:
            return snapshot.terminal.map { t in
                .init(path: t.path, name: t.name, detail: "\(t.count) 个会话 · \(shortDate(t.latest))活跃", on: t.on, terminal: true)
            }
        }
    }

    private var filteredRows: [ProjectRow.Model] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? rows : rows.filter { $0.name.localizedStandardContains(text) || $0.path.localizedStandardContains(text) }
    }
}

private struct ProjectRow: View {
    struct Model {
        var path: String
        var name: String
        var detail: String
        var on: Bool
        var terminal: Bool
    }

    @EnvironmentObject var model: AppModel
    var row: Model
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button { set(!row.on) } label: {
                HStack(spacing: 10) {
                    Image(systemName: row.terminal ? "terminal" : "folder.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(row.on ? Brand.accent : Color.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(row.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.on ? "停止共享" : "共享")\(row.name)")
            .disabled(selectionLocked)

            Toggle("共享\(row.name)", isOn: Binding(get: { row.on }, set: set))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(selectionLocked)
                .accessibilityValue(row.on ? "已选择" : "未选择")
        }
        .padding(.horizontal, 12)
        .background(Color.primary.opacity(hover ? 0.04 : 0))
        .onHover { hover = $0 }
        .help(row.path)
    }

    private var selectionLocked: Bool { model.busy || model.confirming }

    private func set(_ on: Bool) {
        row.terminal ? model.setTerminal(row.path, on: on) : model.setProject(row.path, on: on)
    }
}

// MARK: - Action area

private struct Footer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .confirmMerge:
                confirmation(title: "关闭 Claude 并合并？", detail: "正在运行的 Code 会话会中断。合并前自动备份，完成后重新打开 Claude。", action: "关闭并合并") {
                    Task { await model.merge() }
                }
            case .confirmUndo:
                confirmation(title: "撤销上次合并？", detail: "恢复上次合并前的列表，跳过之后改动的文件。\(model.claudeRunning ? "Claude 将先关闭，再重新打开。" : "完成后会打开 Claude。")", action: "撤销合并") {
                    Task { await model.undo() }
                }
            default:
                Button(action: action) {
                    HStack(spacing: 7) {
                        if model.busy || model.saving {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                        }
                        Text(title).font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(PressStyle(prominent: !upToDate))
                .disabled(disabled)
                .opacity(disabled && !upToDate ? 0.55 : 1)
                .keyboardShortcut(.defaultAction)
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield").font(.system(size: 10))
                    Text(model.saving ? "正在保存选择…" : "仅在本机处理 · 合并前自动备份")
                        .font(.system(size: 10))
                    Spacer()
                    if case .failed = model.phase {
                        Button("重试") { model.cancel(); Task { await model.refresh() } }
                            .buttonStyle(.link).font(.system(size: 10))
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16)
        .background {
            Group {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                else { Rectangle().fill(.bar) }
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.primary.opacity(0.045), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 8).allowsHitTesting(false)
            }
        }
    }

    private func confirmation(title: String, detail: String, action: String, run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button { model.cancel() } label: {
                    Text("取消").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 36)
                }
                .buttonStyle(PressStyle()).keyboardShortcut(.cancelAction)
                Button(action: run) {
                    Text(action).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 36)
                }
                .buttonStyle(PressStyle(prominent: true))
            }
        }
        .transition(.opacity)
    }

    private var noAccounts: Bool { model.snapshot?.accounts.isEmpty == true }
    private var upToDate: Bool { !model.pending && model.claudeRunning && model.snapshot != nil && model.loadError == nil && !noAccounts && !model.saving && !model.busy }
    private var title: String {
        if model.busy { return "正在处理…" }
        if model.saving { return "正在保存选择…" }
        if model.loadError != nil { return "重新读取会话" }
        if model.snapshot == nil { return "正在读取…" }
        if noAccounts { return "打开 Claude 登录账号" }
        if model.pending { return model.claudeRunning ? "合并并重启 Claude" : "合并并打开 Claude" }
        return model.claudeRunning ? "所有会话已同步" : "打开 Claude"
    }
    private var icon: String {
        if model.snapshot == nil || model.loadError != nil { return "arrow.clockwise" }
        if noAccounts { return "arrow.up.forward.app" }
        if model.pending { return "arrow.triangle.merge" }
        return model.claudeRunning ? "checkmark" : "arrow.up.forward.app"
    }
    private var disabled: Bool {
        model.busy || model.saving || upToDate || (model.snapshot == nil && model.loadError == nil)
    }
    private func action() {
        if model.snapshot == nil || model.loadError != nil { Task { await model.refresh() } }
        else if model.pending { model.mergeTapped() }
        else { model.openClaude() }
    }
}
