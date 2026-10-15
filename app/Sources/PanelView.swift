import SwiftUI

enum Brand {
    static let accent = Color(red: 0.38, green: 0.40, blue: 0.96)
    static let gradient = LinearGradient(
        colors: [Color(red: 0.58, green: 0.42, blue: 0.98), Color(red: 0.27, green: 0.52, blue: 0.98)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let avatarColors: [Color] = [
        Color(red: 0.95, green: 0.55, blue: 0.25), Color(red: 0.22, green: 0.68, blue: 0.55),
        Color(red: 0.86, green: 0.36, blue: 0.48), Color(red: 0.30, green: 0.56, blue: 0.95),
        Color(red: 0.62, green: 0.45, blue: 0.92), Color(red: 0.85, green: 0.65, blue: 0.20),
    ]
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

// MARK: - panel

struct PanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            StatusCard()
                .padding(.horizontal, 12)
            if let snap = model.snapshot {
                AccountsSection(snapshot: snap)
                    .padding(.top, 16)
                ProjectsSection(snapshot: snap)
                    .padding(.top, 14)
            }
            Footer()
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 12)
        }
        .frame(width: 360)
        .tint(Brand.accent)
        .onAppear { model.panelOpened() }
    }
}

struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Brand.gradient)
            .overlay(
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: Brand.accent.opacity(0.35), radius: 3, y: 1)
    }
}

// MARK: - header

private struct Header: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("会话合并").font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.loading {
                ProgressView().controlSize(.small).frame(width: 22, height: 22)
            } else {
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("重新读取")
                .disabled(model.busy)
            }
            Menu {
                Button("撤销上次合并…") { model.undoTapped() }
                    .disabled(model.snapshot?.lastRun == nil || model.busy)
                if let last = model.snapshot?.lastRun {
                    Text("上次合并：\(ago(last.date))，改动 \(last.changes) 处")
                }
                Button("打开备份文件夹") { model.revealBackups() }
                Divider()
                Toggle("登录时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Divider()
                Button("退出会话合并") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 14, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        guard let s = model.snapshot else { return model.loadError == nil ? "正在读取…" : "读取失败" }
        let claude = model.claudeRunning ? "Claude 运行中" : "Claude 未运行"
        return "\(s.accounts.count) 个账号 · \(s.sessions) 个会话 · \(claude)"
    }
}

// MARK: - status

private struct StatusCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let c = content
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if c.spinner {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: c.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(c.tint)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(.system(size: 13, weight: .semibold))
                    if !c.detail.isEmpty {
                        Text(c.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            if !c.actions.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(c.actions.indices, id: \.self) { i in
                        let a = c.actions[i]
                        if a.primary {
                            Button(a.title, action: a.run).buttonStyle(.borderedProminent).tint(c.tint)
                                .keyboardShortcut(.defaultAction)
                        } else {
                            Button(a.title, action: a.run).buttonStyle(.bordered)
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                }
                .controlSize(.regular)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(c.tint.opacity(0.20)))
        .animation(.easeOut(duration: 0.18), value: c.title)
    }

    struct Action {
        var title: String
        var primary = false
        var run: () -> Void
    }

    struct Content {
        var icon = ""
        var tint = Brand.accent
        var title: String
        var detail = ""
        var spinner = false
        var actions: [Action] = []
    }

    private var content: Content {
        switch model.phase {
        case .working(let text):
            return Content(title: text, detail: "请稍等，完成后会自动打开 Claude。", spinner: true)
        case .confirmMerge:
            return Content(
                icon: "exclamationmark.triangle.fill", tint: .orange, title: "需要先关闭 Claude",
                detail: "正在运行的 Code 会话会被中断。合并完成后会自动重新打开 Claude。",
                actions: [Action(title: "取消") { model.cancel() },
                          Action(title: "关闭并合并", primary: true) { Task { await model.merge() } }])
        case .confirmUndo:
            var detail = "会话列表会回到上次合并之前，之后新建或改动过的会话不受影响。"
            if let last = model.snapshot?.lastRun { detail = "上次合并在\(ago(last.date))。" + detail }
            if model.claudeRunning { detail += "Claude 会先关闭，完成后重新打开。" }
            return Content(
                icon: "arrow.uturn.backward.circle.fill", tint: .orange, title: "撤销上次合并？", detail: detail,
                actions: [Action(title: "取消") { model.cancel() },
                          Action(title: "撤销", primary: true) { Task { await model.undo() } }])
        case .done(let text):
            return Content(icon: "checkmark.circle.fill", tint: .green, title: "完成", detail: text)
        case .failed(let text):
            return Content(icon: "xmark.octagon.fill", tint: .red, title: "出了点问题", detail: text,
                           actions: [Action(title: "知道了") { model.cancel() }])
        case .idle:
            break
        }
        guard let s = model.snapshot else {
            if let err = model.loadError {
                return Content(icon: "xmark.octagon.fill", tint: .red, title: "读取会话失败", detail: err,
                               actions: [Action(title: "重试", primary: true) { Task { await model.refresh() } }])
            }
            return Content(title: "正在读取会话…", spinner: true)
        }
        var notes: [String] = []
        if s.missing > 0 { notes.append("\(s.missing) 个会话找不到对话文件，会显示但可能打不开。") }
        notes += s.warnings
        if s.changes > 0 {
            var detail = "合并后，每个账号的侧边栏都能看到 \(s.sessions) 个会话"
            detail += s.imports > 0 ? "（其中 \(s.imports) 个从终端导入）。" : "。"
            return Content(icon: "arrow.triangle.merge", title: "\(s.behind.count) 个账号还没同步",
                           detail: ([detail] + notes).joined(separator: "\n"))
        }
        var detail = "每个账号都能看到 \(s.sessions) 个会话"
        if let last = s.lastRun { detail += " · 上次合并\(ago(last.date))" }
        return Content(icon: "checkmark.circle.fill", tint: .green, title: "所有账号都已同步",
                       detail: ([detail] + notes).joined(separator: "\n"))
    }
}

// MARK: - accounts

private struct SectionLabel: View {
    var title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private struct AccountsSection: View {
    var snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "账号").padding(.horizontal, 16)
            VStack(spacing: 1) {
                ForEach(Array(snapshot.accounts.enumerated()), id: \.element.key) { i, a in
                    AccountRow(account: a, color: Brand.avatarColors[i % Brand.avatarColors.count])
                }
            }
            .padding(.horizontal, 8)
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if account.signedIn { Tag(text: "当前登录") }
                }
                Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if !account.gateway && (hover || editing) {
                Button { editing = true } label: {
                    Image(systemName: "pencil").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("设置备注")
            }
            CountBadge(account: account)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            RemarkEditor(account: account) { editing = false }
        }
    }

    private var secondary: String {
        if account.gateway { return "第三方网关模式" }
        if !account.email.isEmpty { return account.email }
        return account.remark.isEmpty ? "读不到名字和邮箱，可以加个备注" : "ID \(account.shortID)"
    }
}

private struct Avatar: View {
    var account: Snapshot.Account
    var color: Color

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
            if account.gateway {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 12, weight: .semibold))
            } else if let initial {
                Text(initial).font(.system(size: 13, weight: .semibold))
            } else {
                Image(systemName: "person.fill").font(.system(size: 12, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
    }

    /// The first letter of a real name; none for an account known only by its ID.
    private var initial: String? {
        let known = !account.remark.isEmpty || !account.email.isEmpty || !account.name.hasPrefix("账号 ")
        guard known, let first = account.name.first else { return nil }
        return String(first).uppercased()
    }
}

private struct Tag: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Brand.accent.opacity(0.14)))
            .foregroundStyle(Brand.accent)
    }
}

private struct CountBadge: View {
    var account: Snapshot.Account

    var body: some View {
        Group {
            if account.add > 0 || account.remove > 0 {
                HStack(spacing: 3) {
                    Text("\(account.have)").foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Text("\(account.after)").foregroundStyle(Brand.accent).fontWeight(.semibold)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Brand.accent.opacity(0.10)))
                .help("现在 \(account.have) 个，合并后 \(account.after) 个")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                    Text("\(account.have)").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .help("已经有全部 \(account.have) 个会话")
            }
        }
        .font(.system(size: 12).monospacedDigit())
    }
}

private struct RemarkEditor: View {
    @EnvironmentObject var model: AppModel
    var account: Snapshot.Account
    var close: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("账号备注").font(.system(size: 13, weight: .semibold))
            TextField("比如邮箱或用途", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit(save)
            VStack(alignment: .leading, spacing: 2) {
                Text("ID \(account.uuid)").font(.system(size: 10).monospaced()).textSelection(.enabled)
                Text("账号邮箱可以在 Claude 的设置里看到。").font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            HStack {
                if !account.remark.isEmpty {
                    Button("清除备注") {
                        model.setRemark(account.uuid, "")
                        close()
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { draft = account.remark }
    }

    private func save() {
        model.setRemark(account.uuid, draft)
        close()
    }
}

// MARK: - projects

private struct ProjectsSection: View {
    @EnvironmentObject var model: AppModel
    var snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "项目")
                Spacer()
                Picker("", selection: $model.tab) {
                    Text("桌面会话 \(snapshot.projects.count)").tag(AppModel.Tab.desktop)
                    Text("终端会话 \(snapshot.terminal.count)").tag(AppModel.Tab.terminal)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 16)

            let rows = self.rows
            if rows.isEmpty {
                Text(model.tab == .desktop ? "还没有桌面版的 Code 会话。" : "没有只在终端里用过的会话。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows, id: \.path) { ProjectRow(row: $0) }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: min(CGFloat(rows.count) * 42, 210))
            }

            Text(model.tab == .desktop
                 ? "打开的项目会补到所有账号。关掉后不再补，已经同步过去的会保留。"
                 : "打开后，这个项目里只在终端用过的会话会出现在所有账号的侧边栏。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
        }
    }

    private var rows: [ProjectRow.Model] {
        switch model.tab {
        case .desktop:
            return snapshot.projects.map { p in
                let from = p.from.map { "\($0.name) \($0.count)" }.joined(separator: " · ")
                return .init(path: p.path, name: p.name, detail: "\(p.count) 个会话" + (from.isEmpty ? "" : " · 来自 \(from)"),
                             on: p.on, terminal: false)
            }
        case .terminal:
            return snapshot.terminal.map { t in
                .init(path: t.path, name: t.name, detail: "\(t.count) 个会话 · 最近 \(shortDate(t.latest))", on: t.on, terminal: true)
            }
        }
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
        HStack(spacing: 10) {
            Image(systemName: row.terminal ? "terminal" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(row.on ? Brand.accent : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { row.on },
                set: { on in row.terminal ? model.setTerminal(row.path, on: on) : model.setProject(row.path, on: on) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(model.busy)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .onHover { hover = $0 }
        .help(row.path)
    }
}

// MARK: - footer

private struct Footer: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.phase {
        case .confirmMerge, .confirmUndo:
            EmptyView()
        default:
            Button(action: action) {
                Label(title, systemImage: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(disabled)
        }
    }

    private var pending: Bool { model.pending }

    private var title: String {
        if model.busy { return "处理中…" }
        if pending { return model.claudeRunning ? "合并并重启 Claude" : "合并并打开 Claude" }
        return model.claudeRunning ? "已是最新" : "打开 Claude"
    }

    private var icon: String {
        if pending { return "arrow.triangle.merge" }
        return model.claudeRunning ? "checkmark" : "arrow.up.forward.app"
    }

    private var disabled: Bool {
        model.busy || model.snapshot == nil || (!pending && model.claudeRunning)
    }

    private func action() {
        if pending { model.mergeTapped() } else { model.openClaude() }
    }
}
