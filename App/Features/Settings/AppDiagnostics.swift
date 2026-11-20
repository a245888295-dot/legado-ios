import Foundation
import MetricKit

/// 上次启动时没接住的异常。
/// 单独落盘、不受「记录运行日志」开关影响：崩溃当下最需要的就是这份东西。
enum ReaderCrashReport {
    private static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var fileURL: URL { directory.appendingPathComponent("last-crash.txt") }

    static var text: String? {
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        return value.isEmpty ? nil : value
    }

    static func write(_ message: String) {
        try? message.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// MetricKit 的原始诊断包。它比 uncaughtException 覆盖得广：
    /// 卡死、看门狗、栈溢出这类抓不到 ObjC 异常的崩溃，只有它有记录。
    private static var metricKitURL: URL { directory.appendingPathComponent("metrickit-crash.json") }

    static var metricKitText: String? {
        guard let value = try? String(contentsOf: metricKitURL, encoding: .utf8) else { return nil }
        return value.isEmpty ? nil : value
    }

    static func writeMetricKit(_ json: String) {
        try? (json + "\n").write(to: metricKitURL, atomically: true, encoding: .utf8)
    }

    static func clearMetricKit() {
        try? FileManager.default.removeItem(at: metricKitURL)
    }

    /// 两份记录拼在一起，给「复制」按钮用。
    static var fullText: String? {
        var parts: [String] = []
        if let text { parts.append("== 未捕获异常 ==\n" + text) }
        if let json = metricKitText { parts.append("== 系统崩溃报告 ==\n" + json) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

final class AppDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = AppDiagnostics()

    func start() {
        MXMetricManager.shared.add(self)
        // TextKit 的布局断言都属于未捕获的 ObjC 异常，进程会被直接带走。
        // 这里先把名字、原因和调用栈落到文件里，再把新版排版引擎熔断，
        // 保证用户下一次启动还能正常读书 —— 崩溃只需要发生一次。
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(28).joined(separator: "\n")
            ReaderCrashReport.write(
                "\(Date())\n\(exception.name.rawValue)\n\(exception.reason ?? "")\n\n\(stack)"
            )
            UserDefaults.standard.set(true, forKey: ReaderEngineSwitch.defaultsKey)
        }
        // 上次是不是死在阅读页里（卡死、fatalError 这类抓不到异常的情况也能兜住）。
        if UserDefaults.standard.bool(forKey: "readerEnginePendingOpen") {
            UserDefaults.standard.set(false, forKey: "readerEnginePendingOpen")
            UserDefaults.standard.set(true, forKey: ReaderEngineSwitch.defaultsKey)
            if ReaderCrashReport.text == nil {
                ReaderCrashReport.write("上次进入阅读页时进程被中断（多半是排版布局死循环或断言），已自动回退排版引擎。\n")
            }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        DiagnosticLog.shared.record(category: "应用", message: "启动 \(version) (\(build))")
    }

    /// 把 MetricKit 报告压成一行：崩溃类型、信号、终止原因、系统版本。
    /// 这几个字段决定了「是断言、是栈溢出、还是被系统杀掉」，比栈本身更先有用。
    private static func summary(of data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "系统上报了一次崩溃（报告解析失败）"
        }
        let meta = object["diagnosticMetaData"] as? [String: Any] ?? [:]
        var parts: [String] = ["系统上报了一次崩溃"]
        if let type = object["exceptionType"] as? Int { parts.append("类型=\(type)") }
        if let code = object["exceptionCode"] as? Int { parts.append("代码=\(code)") }
        if let signal = object["signal"] as? Int { parts.append("信号=\(signal)") }
        if let reason = object["terminationReason"] as? String { parts.append("终止=\(reason)") }
        if let version = meta["appVersion"] as? String { parts.append("版本=\(version)") }
        if let os = meta["osVersion"] as? String { parts.append("系统=\(os)") }
        if let region = object["virtualMemoryRegionInfo"] as? String { parts.append("内存=\(region)") }
        return parts.joined(separator: " · ") + "\n完整报告见诊断页「系统崩溃报告」"
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                // 完整落盘，不走日志（日志单条有长度上限，栈会被截断在半路）。
                let data = crash.jsonRepresentation()
                let json = String(decoding: data, as: UTF8.self)
                ReaderCrashReport.writeMetricKit(json)
                // 关键字段直接写进日志：用户只要导出发我，不用再去点那个区块。
                DiagnosticLog.shared.record(.error, category: "系统诊断",
                                            message: Self.summary(of: data))
            }
            for hang in payload.hangDiagnostics ?? [] {
                DiagnosticLog.shared.record(.warning, category: "系统诊断", message: "卡顿诊断：\(String(decoding: hang.jsonRepresentation(), as: UTF8.self))")
            }
        }
    }
}
