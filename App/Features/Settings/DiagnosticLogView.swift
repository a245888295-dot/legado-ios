import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DiagnosticLogView: View {
    @State private var entries: [DiagnosticLogEntry] = []
    @State private var query = ""
    @State private var level = "all"
    @State private var confirmsClear = false
    @State private var exportsLog = false
    @State private var exportText = ""
    @State private var copiedHint = false
    @State private var errorMessage: String?
    @State private var crashText: String?
    @State private var metricKitText: String?
    @State private var traceText: String?

    private var filtered: [DiagnosticLogEntry] {
        entries.filter {
            (level == "all" || $0.level.rawValue == level)
                && (query.isEmpty || "\($0.category) \($0.message)".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    copyToPasteboard(fullReport)
                } label: {
                    Label(copiedHint ? "已复制到剪贴板" : "复制完整诊断报告", systemImage: copiedHint ? "checkmark.circle.fill" : "doc.on.doc")
                }
                Button {
                    exportText = fullReport
                    exportsLog = true
                } label: {
                    Label("存成文件", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("诊断报告")
            } footer: {
                Text("一份文件装下版本号、崩溃记录和运行日志，直接发给开发者就能定位，不用截图。")
            }
            if let crashText {
                Section {
                    ScrollView {
                        Text(crashText)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    Button {
                        copyToPasteboard(ReaderCrashReport.fullText ?? crashText)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    Button("清除崩溃记录", role: .destructive) {
                        ReaderCrashReport.clear()
                        self.crashText = nil
                    }
                } header: {
                    Text("上次崩溃（排版引擎已自动回退）")
                } footer: {
                    Text("把这段内容发出去就能定位问题。清除后不会影响阅读。")
                }
            }
            if let traceText {
                Section {
                    ScrollView {
                        Text(traceText)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    Button {
                        copyToPasteboard(traceText)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("上次进入阅读页的足迹")
                } footer: {
                    Text("按时间记录阅读页走过的每一步，最后一行就是崩溃前停下的位置。")
                }
            }
            if let metricKitText {
                Section {
                    ScrollView {
                        Text(metricKitText)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    Button {
                        copyToPasteboard(metricKitText)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    Button("清除系统报告", role: .destructive) {
                        ReaderCrashReport.clearMetricKit()
                        self.metricKitText = nil
                    }
                } header: {
                    Text("系统崩溃报告（iOS 自动上报）")
                } footer: {
                    Text("含崩溃线程的完整调用栈，能定位到具体函数。连这个一起发出来。")
                }
            }
            Section {
                Picker("级别", selection: $level) {
                    Text("全部").tag("all")
                    Text("信息").tag("info")
                    Text("警告").tag("warning")
                    Text("错误").tag("error")
                }.pickerStyle(.segmented)
                Text("\(entries.count) 条日志 · 下拉刷新")
                    .font(.footnote).foregroundStyle(.secondary)
            } footer: {
                Text("在“其他设置”开启记录后，会保存网络请求、JS 输出和运行错误。崩溃诊断由 iOS 延迟提供，可搜索“系统诊断”查看。")
            }
            if filtered.isEmpty {
                ReadingUnavailableView(query.isEmpty ? "暂无日志" : "没有匹配的日志", systemImage: "doc.text.magnifyingglass")
            } else {
                ForEach(filtered) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.category).font(.caption.weight(.semibold))
                            Text(levelTitle(entry.level)).font(.caption)
                                .foregroundStyle(entry.level == .error ? .red : .secondary)
                            Spacer()
                            Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(entry.message).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }.padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("日志与诊断")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索内容或分类")
        .task { reload() }
        .refreshable { reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("日志操作", systemImage: "ellipsis") {
                    Button("刷新", systemImage: "arrow.clockwise") { reload() }
                    Button("导出全部日志", systemImage: "square.and.arrow.up") {
                        exportText = DiagnosticLog.shared.export()
                        exportsLog = true
                    }.disabled(entries.isEmpty)
                    Button("清空日志", systemImage: "trash", role: .destructive) { confirmsClear = true }
                        .disabled(entries.isEmpty)
                }
            }
        }
        .confirmationDialog("清空全部日志？", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("清空日志", role: .destructive) {
                do { try DiagnosticLog.shared.clear(); reload() }
                catch { errorMessage = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exportsLog, document: DiagnosticLogDocument(text: exportText), contentType: .plainText, defaultFilename: "阅读诊断日志") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("日志操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    /// 版本号从 Info.plist 取，跟启动日志一致，方便确认装的是哪一版。
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var fullReport: String {
        var parts = ["# 小浣熊阅读诊断报告", "版本：\(versionText)",
                     "设备：\(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)"]
        if let crashText {
            parts.append("\n== 未捕获异常 ==\n" + crashText)
        }
        if let metricKitText {
            parts.append("\n== 系统崩溃报告（MetricKit 原始 JSON）==\n" + metricKitText)
        }
        if let traceText {
            parts.append("\n== 阅读页足迹 ==\n" + traceText)
        }
        let log = DiagnosticLog.shared.export()
        parts.append("\n== 运行日志（\(entries.count) 条）==\n" + (log.isEmpty ? "（无）" : log))
        return parts.joined(separator: "\n")
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
        copiedHint = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copiedHint = false
        }
    }

    private func reload() {
        entries = DiagnosticLog.shared.snapshot()
        crashText = ReaderCrashReport.text
        metricKitText = ReaderCrashReport.metricKitText
        traceText = ReaderTrace.text
    }
    private func levelTitle(_ level: DiagnosticLogEntry.Level) -> String {
        switch level { case .info: "信息"; case .warning: "警告"; case .error: "错误" }
    }
}

private struct DiagnosticLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: Data(text.utf8)) }
}
