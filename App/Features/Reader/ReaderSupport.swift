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
}

enum ReaderUnderlinePainter {
    /// 下划线到字底的空隙：微信读书实测约 0.18–0.2 个字高（20pt 字离 3.5pt），
    /// 取 0.22 留一点余量，随字号缩放。
    static func gap(pointSize: CGFloat) -> CGFloat {
        max(2.5, pointSize * 0.22)
    }

    /// 线本身要细而有存在感：约 0.045 个字高，实机上就是 1pt 上下。
    static func lineWidth(pointSize: CGFloat) -> CGFloat {
        max(0.9, min(1.6, pointSize * 0.045))
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
