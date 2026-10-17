import SwiftUI
import UniformTypeIdentifiers

struct PasswordsView: View {
    @ObservedObject private var store = Store.shared
    @State private var query = ""
    @State private var showPaste = false
    @State private var showFile = false
    @State private var message: String?
    @State private var revealed: Set<String> = []

    private var filtered: [Credential] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.credentials }
        return store.credentials.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
                || $0.username.lowercased().contains(q) || $0.domain.contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.credentials.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "key.slash").font(.system(size: 40)).foregroundStyle(.tertiary)
                            Text("还没有密码").font(.headline)
                            Text("导入 Chrome 导出的 passwords.csv：Chrome → 设置 → 密码 → 导出密码。\n导出的 CSV 只有 4 列：name,url,username,password。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                    }
                } else {
                    Section("\(filtered.count) 条") {
                        ForEach(filtered) { c in
                            CredentialRow(credential: c, revealed: $revealed)
                        }
                        .onDelete { offsets in
                            for i in offsets { store.credentials.removeAll { $0.id == filtered[i].id } }
                        }
                    }
                }

                if let message {
                    Section { Text(message).font(.caption).foregroundStyle(.orange) }
                }
            }
            .searchable(text: $query, prompt: "搜索网站 / 用户名")
            .navigationTitle("密码")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showFile = true } label: { Label("导入 CSV 文件", systemImage: "doc.badge.plus") }
                        Button { showPaste = true } label: { Label("粘贴 CSV 文本", systemImage: "doc.on.clipboard") }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(isPresented: $showFile, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        let r = store.importCSV(text)
                        message = "导入完成：新增 \(r.added) 条，跳过 \(r.skipped) 条（重复或缺少字段）"
                    } else {
                        message = "读取失败：请确认是 UTF-8 编码的 CSV"
                    }
                case .failure(let e):
                    message = e.localizedDescription
                }
            }
            .sheet(isPresented: $showPaste) {
                PasteCSVSheet { text in
                    let r = store.importCSV(text)
                    message = "导入完成：新增 \(r.added) 条，跳过 \(r.skipped) 条"
                }
            }
        }
    }
}

struct CredentialRow: View {
    let credential: Credential
    @Binding var revealed: Set<String>

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.2))
                    .frame(width: 34, height: 34)
                Text(String((credential.title.isEmpty ? credential.domain : credential.title).prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.title.isEmpty ? credential.domain : credential.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(credential.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if revealed.contains(credential.id) {
                    Text(credential.password)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button {
                if revealed.contains(credential.id) { revealed.remove(credential.id) }
                else { revealed.insert(credential.id) }
            } label: {
                Image(systemName: revealed.contains(credential.id) ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                UIPasteboard.general.string = credential.password
            } label: {
                Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }
}

struct PasteCSVSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let onImport: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
            }
            .navigationTitle("粘贴 CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        onImport(text)
                        dismiss()
                    }.disabled(text.isEmpty)
                }
            }
        }
    }
}
