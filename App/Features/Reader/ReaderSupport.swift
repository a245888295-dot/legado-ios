import CoreText
import SwiftUI
import UIKit

struct ReaderInteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.enableInteractivePopIfAvailable()
    }

    static func dismantleUIViewController(_ uiViewController: Controller, coordinator: Void) {
        uiViewController.restoreInteractivePopDelegate()
    }

    final class Controller: UIViewController {
        private weak var popGesture: UIGestureRecognizer?
        private var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var releasedDelegate = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableInteractivePopIfAvailable()
        }

        func enableInteractivePopIfAvailable() {
            guard let navigationController,
                  navigationController.viewControllers.count > 1,
                  let gesture = navigationController.interactivePopGestureRecognizer else { return }
            if gesture.delegate != nil {
                previousDelegate = gesture.delegate
                gesture.delegate = nil
                releasedDelegate = true
            }
            gesture.isEnabled = true
            popGesture = gesture
        }

        func restoreInteractivePopDelegate() {
            guard releasedDelegate, let popGesture, popGesture.delegate == nil else { return }
            popGesture.delegate = previousDelegate
            previousDelegate = nil
            releasedDelegate = false
        }

    }
}

struct ReaderMenuDismissShape: Shape {
    var leadingExclusion: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: min(max(leadingExclusion, 0), rect.width),
            y: 0,
            width: max(rect.width - leadingExclusion, 0),
            height: rect.height
        ))
    }
}

@MainActor enum ReaderScreenOrientation {
    static private(set) var supportedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    static func apply(_ value: String) {
        let mask: UIInterfaceOrientationMask = switch value {
        case "1": .portrait
        case "2": .landscape
        case "3": .all
        case "4": .portraitUpsideDown
        case "5": .landscapeLeft
        default: .allButUpsideDown
        }
        supportedOrientations = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    static func restoreApplicationDefault() { apply("0") }
}

extension NSAttributedString.Key {
    /// 标记这一段正文需要自绘下划线。值存 underlineMode（1 实线 / 2 点线）。
    /// 不交给 TextKit 画：它紧贴字底、颜色跟正文一样、行末还会提前截断。
    static let readerUnderline = NSAttributedString.Key("LegadoReaderUnderline")
    /// 标记章节标题。分页时用它避免「标题落在页脚、正文翻到下一页」。
    static let readerHeading = NSAttributedString.Key("LegadoReaderHeading")
}

enum ReaderUnderlinePainter {
    /// 下划线到字底的空隙。这里从 em 框底算，汉字墨迹底比 em 底高约 0.1 em，
    /// 所以取 0.10 → 视觉上离字底约 0.2 个字高（微信读书实测 0.18–0.2）。
    static func gap(pointSize: CGFloat) -> CGFloat {
        max(2.0, pointSize * 0.10)
    }

    /// 线本身要细而有存在感：约 0.045 个字高，实机上就是 1pt 上下。
    static func lineWidth(pointSize: CGFloat) -> CGFloat {
        max(0.9, min(1.1, pointSize * 0.045))
    }

    /// 短横虚线，实线段与空白约 1:2.2（微信读书 4px 线 + 8px 空，比例一致），
    /// 随字号缩放，所以改字号后观感不变。
    static func dashPattern(pointSize: CGFloat) -> [NSNumber] {
        let dash = max(1.6, pointSize * 0.10)
        let space = max(3.0, pointSize * 0.22)
        return [NSNumber(value: Double(dash)), NSNumber(value: Double(space))]
    }

    /// 比正文浅一档；正文纯黑时约 38% 不透明度。
    static func strokeColor(_ foreground: UIColor) -> UIColor {
        foreground.withAlphaComponent(0.38)
    }
}

// MARK: - 排版模型
//
// 这一层是排版的唯一真源。所有间距都由「基准字号 × 倍数」算出来，
// 不再存任何一个绝对 pt —— 以前字号一放大，行距/段距/边距全被稀释，
// 用户看到的就是「28 号字满屏留白」。

/// 是否把断行权从 TextKit 手里接管过来（中文避头尾真正生效的前提）。
///
/// 默认关闭：接管靠重写 `NSTextContainer.lineFragmentRect`，这是我们代码里
/// 唯一一处跟系统布局器「抢方向盘」的地方 —— 一旦某本书出现极端行宽，
/// 系统的 usedRect 断言会把进程直接带走。所以它作为实验特性单独立开关，
/// 稳了再默认打开。
enum ReaderLineBreakTakeover {
    static let defaultsKey = "readerTakeoverLineBreakV1"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
    static func setEnabled(_ value: Bool) { UserDefaults.standard.set(value, forKey: defaultsKey) }
}

/// 新版排版引擎的开关。
/// 一旦有未捕获异常（多半来自 TextKit 布局断言），启动时会自动置为 true，
/// 退回「只调参数、不接管断行」的旧路径，让用户还能正常读书。
enum ReaderEngineSwitch {
    static let defaultsKey = "readerEngineDisabledV1"
    static var isDisabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
    static func setDisabled(_ value: Bool) { UserDefaults.standard.set(value, forKey: defaultsKey) }
}

@MainActor
struct ReaderTypography {
    let fontSize: CGFloat
    let lineHeightMultiple: CGFloat
    let paraSpacingMultiple: CGFloat
    let indentString: String
    let letterSpacing: CGFloat
    let justified: Bool
    let fontWeight: Int
    let fontPath: String
    let titleMode: Int
    let titleSize: CGFloat
    let titleTopSpacing: CGFloat
    let titleBottomSpacing: CGFloat
    let underlineMode: Int
    let availableHeight: CGFloat

    /// 实际行高（pt）。已经按页面高度对齐成整数行。
    let lineHeight: CGFloat
    /// 首行缩进宽度（pt）。
    let indentWidth: CGFloat

    let bodyAttributes: [NSAttributedString.Key: Any]
    let headingAttributes: [NSAttributedString.Key: Any]

    /// 大字自动收紧行距：22 号及以下不动，往上每大一号收 3.3%，最低 0.72 倍。
    /// 这是真排版规则（大字视觉重量足，同样的比例会显得散），不是补丁。
    static func tighteningScale(for fontSize: CGFloat) -> CGFloat {
        fontSize > 22 ? max(0.72, 1.0 - 0.033 * (fontSize - 22)) : 1.0
    }

    /// 理想行高 = 字号 × 档位 × 收紧系数。
    static func idealLineHeight(fontSize: CGFloat, multiple: CGFloat) -> CGFloat {
        fontSize * min(2.6, max(1.22, multiple * tighteningScale(for: fontSize)))
    }

    init(configuration c: ReaderTextView, availableHeight: CGFloat = 0) {
        let size = CGFloat(max(5, c.fontSize))
        fontSize = size
        lineHeightMultiple = CGFloat(c.lineHeightMultiple)
        paraSpacingMultiple = CGFloat(c.paraSpacingMultiple)
        indentString = c.paragraphIndent
        letterSpacing = CGFloat(c.letterSpacing) * size
        justified = c.fullJustify
        fontWeight = c.fontWeight
        fontPath = c.fontPath
        titleMode = c.titleMode
        titleSize = CGFloat(c.titleSize)
        titleTopSpacing = CGFloat(c.titleTopSpacing)
        titleBottomSpacing = CGFloat(c.titleBottomSpacing)
        underlineMode = c.underlineMode
        self.availableHeight = availableHeight

        let weight: UIFont.Weight = switch c.fontWeight {
        case 1: .bold
        case 2: .light
        default: .regular
        }
        let resolved = ReaderFontStore.font(at: c.fontPath, size: size, weight: c.fontWeight)
            ?? (c.fontWeight == 0
                ? (UIFont(name: "STSongti-SC-Regular", size: size) ?? UIFont.systemFont(ofSize: size))
                : UIFont.systemFont(ofSize: size, weight: weight))

        // 行高对齐：把理想行高微调成「页面高度 ÷ 整数行」。
        // 这样一页正好装下 n 行，页脚不会剩下半行高的空白 —— 之前的底部留白主要来自这里。
        let ideal = Self.idealLineHeight(fontSize: size, multiple: CGFloat(c.lineHeightMultiple))
        var height = ideal
        if !ReaderEngineSwitch.isDisabled, availableHeight > ideal * 2.5 {
            let lines = max(1, floor(availableHeight / ideal))
            let snapped = availableHeight / lines
            if snapped <= ideal * 1.08 { height = snapped }
        }
        lineHeight = height

        let indent = c.paragraphIndent.isEmpty
            ? 0
            : (c.paragraphIndent as NSString).size(withAttributes: [
                .font: resolved, .kern: letterSpacing
            ]).width
        indentWidth = indent

        let paragraph = NSMutableParagraphStyle()
        // 只用 lineSpacing 加间距，不用 minimumLineHeight/maximumLineHeight。
        //
        // 这是这一版最重要的一处回退：固定行高（把 minimum 和 maximum 设成同一个值）
        // 确实能让每页精确排满，但它是在跟 NSLayoutManager 的行片段计算较劲 ——
        // 一旦某行的高度算不拢，系统内部断言直接把进程带走，表现就是打开 TXT 闪退。
        //
        // 系统行高对同一字体字号是常数（font.lineHeight），所以「目标行高 - 字体行高」
        // 得到额外间距，行高依然是精确值，整页对齐的效果一点没丢，但没有越权改系统行为。
        paragraph.lineSpacing = max(0, height - resolved.lineHeight)
        paragraph.paragraphSpacing = max(0, size * CGFloat(c.paraSpacingMultiple))
        paragraph.firstLineHeadIndent = indent
        paragraph.alignment = c.fullJustify ? .justified : .natural
        // pushOut 让行首标点被推回上一行，代价是允许行宽溢出容器。
        // iOS 15 的 TextKit 1 对中文标点覆盖不全，溢出后 usedRect 会超出
        // 行片段宽度，直接触发 NSLayoutManager 的断言 —— 中文小说里几乎每段都有标点，
        // 所以这条最容易被踩响。熔断时一并关掉。
        if !ReaderEngineSwitch.isDisabled {
            paragraph.lineBreakStrategy = .pushOut
        }
        paragraph.hyphenationFactor = 0

        var body: [NSAttributedString.Key: Any] = [
            .font: resolved,
            .kern: letterSpacing,
            .foregroundColor: c.foregroundColor,
            .paragraphStyle: paragraph
        ]
        if c.underlineMode != 0 {
            body[.readerUnderline] = c.underlineMode
        }
        bodyAttributes = body

        let headingSize = CGFloat(max(5, size + CGFloat(c.titleSize)))
        let headingFont = ReaderFontStore.font(at: c.fontPath, size: headingSize, weight: c.fontWeight)
            ?? UIFont.systemFont(ofSize: headingSize, weight: weight)
        let headingParagraph = NSMutableParagraphStyle()
        let headingHeight = max(height, headingSize * 1.25)
        headingParagraph.lineSpacing = max(0, headingHeight - headingFont.lineHeight)
        headingParagraph.alignment = c.titleMode == 1 ? .center : .left
        headingParagraph.paragraphSpacingBefore = CGFloat(c.titleTopSpacing)
        headingParagraph.paragraphSpacing = CGFloat(c.titleBottomSpacing)
        if !ReaderEngineSwitch.isDisabled {
            headingParagraph.lineBreakStrategy = .pushOut
        }
        headingAttributes = [
            .font: headingFont,
            .foregroundColor: c.foregroundColor,
            .paragraphStyle: headingParagraph,
            .readerHeading: true
        ]
    }
}

// MARK: - 中文断行禁则

/// 中文排版的避头尾规则。纯字符判断，和具体小说、具体字号都无关，
/// 所以换任何一本书行为完全一致 —— 这就是「通用性」的落点。
enum ReaderLineBreaker {
    /// 不能出现在一行开头的字符（会跟着上一行走）。
    private static let noLineStart: Set<unichar> = {
        var set = Set<unichar>()
        let text = "，。、；：？！）〕〉》」』】｝〗〙〛”’…—～·%,.;:?!)]}"
        for scalar in text.unicodeScalars where scalar.value <= 0xFFFF {
            set.insert(unichar(scalar.value))
        }
        return set
    }()

    /// 不能出现在一行结尾的字符（会跟着下一行走）。
    private static let noLineEnd: Set<unichar> = {
        var set = Set<unichar>()
        let text = "（〔〈《「『【｛〖〘〚“‘([{"
        for scalar in text.unicodeScalars where scalar.value <= 0xFFFF {
            set.insert(unichar(scalar.value))
        }
        return set
    }()

    /// 把断点往前挪，直到不违反禁则。`breakIndex` 是「下一行从哪个字符开始」。
    /// 最多回退 3 个字，避免极端文本（比如整段都是省略号）把一行挤没。
    static func adjust(breakIndex: Int, in text: NSString, lowerBound: Int) -> Int {
        var index = breakIndex
        var steps = 0
        while steps < 3 {
            guard index > lowerBound, index < text.length else { break }
            let head = text.character(at: index)
            let tail = text.character(at: index - 1)
            if noLineStart.contains(head) || noLineEnd.contains(tail) {
                index -= 1
                steps += 1
            } else {
                break
            }
        }
        return index
    }
}

// MARK: - 断行测量

/// 给 NSTextContainer 用的测量器：算出「这一行该在哪里断」。
/// 只做测量，不碰绘制，所以可以在 TextKit 询问时同步调用。
final class ReaderLineMetrics {
    weak var storage: NSTextStorage?
    var indentWidth: CGFloat = 0
    var enabled = true

    private var cache: [Int: CGFloat] = [:]

    func invalidate() { cache.removeAll(keepingCapacity: true) }

    /// 只保留字体和字距，去掉段落样式。
    /// 中途截出来的一段如果还带着 firstLineHeadIndent/alignment，CoreText 会二次计算缩进，
    /// 量出来的宽度就偏大，收缩也就不生效了。
    private static func measuringSlice(
        _ storage: NSTextStorage, location: Int, length: Int
    ) -> NSAttributedString {
        guard length > 0 else { return NSAttributedString(string: "") }
        let slice = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: NSRange(location: location, length: length))
        )
        let full = NSRange(location: 0, length: slice.length)
        slice.removeAttribute(.paragraphStyle, range: full)
        slice.removeAttribute(.readerUnderline, range: full)
        slice.removeAttribute(.readerHeading, range: full)
        return slice
    }

    /// 返回需要收缩到的行宽；nil 表示不用改，按原宽度断行。
    func narrowedWidth(lineStart: Int, available: CGFloat) -> CGFloat? {
        guard enabled, let storage, storage.length > 0,
              available > 16, lineStart >= 0, lineStart < storage.length else { return nil }
        let key = lineStart &* 100_003 &+ Int(available)
        if let cached = cache[key] { return cached > 0 ? cached : nil }

        let text = storage.string as NSString
        let isFirstLine = lineStart == 0 || text.character(at: lineStart - 1) == 10
        let indent = isFirstLine ? indentWidth : 0
        let measureWidth = available - indent
        guard measureWidth > 16 else { return nil }

        let limit = min(storage.length, lineStart + 480)
        let slice = Self.measuringSlice(storage, location: lineStart, length: limit - lineStart)
        guard slice.length > 0 else { return nil }
        let typesetter = CTTypesetterCreateWithAttributedString(slice as CFAttributedString)
        var count = CTTypesetterSuggestLineBreak(typesetter, 0, Double(measureWidth))
        if count <= 0 { count = 1 }

        let fixed = ReaderLineBreaker.adjust(
            breakIndex: lineStart + count,
            in: text,
            lowerBound: lineStart
        )
        guard fixed != lineStart + count else {
            cache[key] = 0
            return nil
        }

        // 至少要能放下两个字，否则说明这次收缩不合理（多半是超长英文单词或极端字号），
        // 交回系统处理，免得排出一字一行。
        guard fixed - lineStart >= 2 else {
            cache[key] = 0
            return nil
        }
        // 收缩幅度设上限：缩完还不到原行宽的 55%，说明这一行几乎是整行标点，
        // 硬缩会让 TextKit 的 usedRect 超出 fragmentRect 而抛断言 —— 宁可这行不避。
        guard fixed - lineStart >= count * 55 / 100 else {
            cache[key] = 0
            return nil
        }

        let sub = Self.measuringSlice(storage, location: lineStart, length: fixed - lineStart)
        let line = CTLineCreateWithAttributedString(sub as CFAttributedString)
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + indent
        // 加 0.5 是留给字宽取整的余量：实测宽度比真实字形窄一点点时，
        // TextKit 会算出行宽超过行片段宽度，直接抛异常。多给半磅不会多塞进一个字。
        width = min(available, max(width + 0.5, available * 0.3))
        cache[key] = width
        return width
    }
}

/// 正文容器。
///
/// 这里原本重写了 `lineFragmentRect`，想在系统断行时把标点顶回上一行（避头尾）。
/// 但它是在系统布局计算的中途把自己的结果塞回去 —— 等于在布局过程里修改布局输入，
/// 容器初始宽度为 0 的那一瞬间系统会反复询问同一个字符位置，一层层叠上去就是栈溢出。
/// 崩溃报告里同一地址出现四层、与系统帧交替，正是这个形状。
///
/// 断行接管已整体摘除：避头尾交给系统自带的 pushOut，稳定性优先。
final class ReaderTextContainer: NSTextContainer {
    /// 预留给将来用 CoreText 自绘时的测量器，目前不再参与布局。
    var metrics: ReaderLineMetrics?
}

// MARK: - 阅读页足迹
//
// 崩溃现场最难拿到的不是栈，是「死在哪一步」。这里在关键路径打点，
// 每次都覆盖写同一个文件，崩溃后重进就能看到最后停在哪里。
// 只要崩溃栈没有符号，足迹就是唯一能定位的手段。

enum ReaderTrace {
    private static let queue = DispatchQueue(label: "com.legado.reader.trace", qos: .utility)
    /// 只在主线程读写（mark 全部从 UI 更新、布局回调里调用），
    /// 所以这里明确豁免并发检查，不用锁也不用 actor —— 上锁反而会给每次布局加开销。
    nonisolated(unsafe) private static var lastMarked: [String: TimeInterval] = [:]
    private static let maxBytes = 96 * 1024

    private static var fileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("reader-trace.log")
    }

    /// 只在主线程调用。同一步骤 0.5 秒内只记一次，避免布局回调把文件刷爆。
    static func mark(_ step: String) {
        let now = Date().timeIntervalSince1970
        if let last = lastMarked[step], now - last < 0.5 { return }
        lastMarked[step] = now
        queue.async {
            let url = fileURL
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int) ?? 0
            if size > maxBytes {
                try? FileManager.default.removeItem(at: url)
            }
            let line = String(format: "%.3f  %@\n", now, step)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    static var text: String? {
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        return value.isEmpty ? nil : value
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }
}
