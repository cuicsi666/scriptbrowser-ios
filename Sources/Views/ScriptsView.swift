import SwiftUI
import UniformTypeIdentifiers

struct ScriptsView: View {
    var embedded: Bool = false
    @ObservedObject private var store = Store.shared
    @State private var showImport = false
    @State private var path: [String] = []

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack(path: $path) { content }
        }
    }

    private var content: some View {
        List {
            Section {
                HStack {
                    statCard("已安装", "\(store.scripts.count)", "curlybraces")
                    statCard("已启用", "\(store.scripts.filter(\.enabled).count)", "bolt.fill")
                    statCard("全部网站", "\(store.scripts.filter { $0.matches.isEmpty }.count)", "globe")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }

            if store.scripts.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "curlybraces.square")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("还没有用户脚本").font(.headline)
                        Text("点右上角 + 从网址安装，或直接粘贴 .user.js 源码；也可以通过本地 API 端口 POST /api/userscripts 自动安装。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            } else {
                Section("脚本") {
                    ForEach(store.scripts) { script in
                        NavigationLink {
                            ScriptDetailView(scriptID: script.id)
                        } label: {
                            ScriptRow(script: script)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { store.removeScript(id: store.scripts[i].id) }
                        BrowserModel.shared.rebuildUserScripts()
                    }
                }
            }
        }
        .navigationTitle("用户脚本")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImport = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImport) {
            ScriptImportSheet()
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(white: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ScriptRow: View {
    let script: UserScript
    @ObservedObject private var store = Store.shared

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(script.enabled ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(script.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text("v\(script.version)").font(.caption2).foregroundStyle(.secondary)
                }
                Text(script.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { script.enabled },
                set: { _ in
                    store.toggleScript(id: script.id)
                    BrowserModel.shared.rebuildUserScripts()
                }
            ))
            .labelsHidden()
            .scaleEffect(0.8)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 脚本详情

struct ScriptDetailView: View {
    let scriptID: String
    @ObservedObject private var store = Store.shared
    @Environment(\.dismiss) private var dismiss

    private var script: UserScript? { store.scripts.first { $0.id == scriptID } }

    var body: some View {
        Group {
            if let s = script {
                List {
                    Section("信息") {
                        LabeledContent("名称", value: s.name)
                        LabeledContent("版本", value: s.version)
                        LabeledContent("命名空间", value: s.namespace.isEmpty ? "—" : s.namespace)
                        LabeledContent("运行时机", value: s.runAt)
                        LabeledContent("匹配", value: s.matches.isEmpty ? "<all urls>" : s.matches.joined(separator: "\n"))
                        if !s.excludes.isEmpty {
                            LabeledContent("排除", value: s.excludes.joined(separator: "\n"))
                        }
                        if !s.desc.isEmpty {
                            LabeledContent("说明", value: s.desc)
                        }
                        Toggle("启用", isOn: Binding(
                            get: { s.enabled },
                            set: { _ in
                                store.toggleScript(id: s.id)
                                BrowserModel.shared.rebuildUserScripts()
                            }
                        ))
                    }

                    Section("源码（\(s.source.count) 字符）") {
                        Text(s.source)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Section {
                        Button(role: .destructive) {
                            store.removeScript(id: s.id)
                            BrowserModel.shared.rebuildUserScripts()
                            dismiss()
                        } label: {
                            Label("卸载脚本", systemImage: "trash")
                        }
                    }
                }
            } else {
                Text("脚本已删除").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(script?.name ?? "脚本")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 安装

struct ScriptImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var urlText = ""
    @State private var source = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showFile = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("方式", selection: $mode) {
                    Text("粘贴源码").tag(0)
                    Text("从网址").tag(1)
                    Text("从文件").tag(2)
                }
                .pickerStyle(.segmented)

                if mode == 0 {
                    Section("脚本源码") {
                        TextEditor(text: $source)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 260)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } else if mode == 1 {
                    Section("脚本地址") {
                        TextField("https://example.com/foo.user.js", text: $urlText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section {
                        Text("支持 http / https，直接下载 .user.js 并解析元数据安装。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Button {
                            showFile = true
                        } label: {
                            Label("选择 .user.js 文件", systemImage: "doc.badge.plus")
                        }
                    }
                    Section {
                        Text("也可以把脚本文件放进「文件」App → 我的 iPhone → 脚本浏览器/ScriptBrowser 目录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let message {
                    Section { Text(message).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("安装用户脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("安装") { install() }
                            .disabled(mode == 0 ? source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     : mode == 1 ? urlText.isEmpty : true)
                    }
                }
            }
            .fileImporter(isPresented: $showFile, allowedContentTypes: [.javascript, .plainText, .text, .data]) { result in
                switch result {
                case .success(let url):
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        finish(Store.shared.install(source: text))
                    } else {
                        message = "文件读取失败（不是 UTF-8 文本？）"
                    }
                case .failure(let e):
                    message = e.localizedDescription
                }
            }
        }
    }

    private func install() {
        if mode == 0 {
            finish(Store.shared.install(source: source))
            return
        }
        guard let u = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "网址不合法"
            return
        }
        busy = true
        message = nil
        Task {
            do {
                var req = URLRequest(url: u)
                req.timeoutInterval = 20
                req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: req)
                let text = String(data: data, encoding: .utf8) ?? ""
                busy = false
                finish(Store.shared.install(source: text))
            } catch {
                busy = false
                message = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    private func finish(_ script: UserScript?) {
        guard let s = script else {
            message = "解析失败：需要 // ==UserScript== 元数据块并带 @name"
            return
        }
        BrowserModel.shared.rebuildUserScripts()
        dismiss()
        _ = s
    }
}
