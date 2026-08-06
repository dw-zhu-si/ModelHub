import AppKit
import Foundation

struct ScreenshotSpec {
    let filename: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let chips: [String]
    let accent: NSColor
}

guard CommandLine.arguments.count == 4 else {
    fputs("用法：generate_app_store_promotional_screenshots.swift <背景图> <真实界面截图> <输出目录>\n", stderr)
    exit(2)
}

let backgroundPath = CommandLine.arguments[1]
let screenshotPath = CommandLine.arguments[2]
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)

guard let background = NSImage(contentsOfFile: backgroundPath),
      let screenshot = NSImage(contentsOfFile: screenshotPath)
else {
    fputs("无法读取背景或真实界面截图。\n", stderr)
    exit(2)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let specs = [
    ScreenshotSpec(
        filename: "01-unified-api-1440x900.jpg",
        eyebrow: "MODELHUB · 原生 macOS 多模型网关",
        title: "一个本机入口\n连接所有 AI 模型",
        subtitle: "把多家供应商统一为稳定的通用兼容地址，现有客户端只需配置一次。",
        chips: ["统一 Base URL", "11 种语言", "Universal"],
        accent: NSColor(calibratedRed: 0.20, green: 0.72, blue: 1.00, alpha: 1)
    ),
    ScreenshotSpec(
        filename: "02-safe-model-catalog-1440x900.jpg",
        eyebrow: "严格可用性边界",
        title: "只把可用模型\n交给外部客户端",
        subtitle: "未验证、配置异常或检测失败的模型自动隔离，不进入目录、直连或路由。",
        chips: ["明确健康状态", "自动隔离", "按需重新测试"],
        accent: NSColor(calibratedRed: 0.26, green: 0.91, blue: 0.59, alpha: 1)
    ),
    ScreenshotSpec(
        filename: "03-smart-routing-1440x900.jpg",
        eyebrow: "智能模型路由",
        title: "一个稳定别名\n智能选择模型",
        subtitle: "使用优先级故障转移、轮询或权重随机策略，在可用目标之间灵活调度。",
        chips: ["优先级故障转移", "轮询", "权重随机"],
        accent: NSColor(calibratedRed: 0.72, green: 0.40, blue: 1.00, alpha: 1)
    ),
    ScreenshotSpec(
        filename: "04-local-privacy-1440x900.jpg",
        eyebrow: "本机优先的隐私设计",
        title: "凭证留在\nmacOS 钥匙串",
        subtitle: "API Key 与访问令牌不写入项目文件；网关默认只监听 127.0.0.1。",
        chips: ["Keychain", "仅回环监听", "无密钥备份"],
        accent: NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.94, alpha: 1)
    ),
    ScreenshotSpec(
        filename: "05-usage-insights-1440x900.jpg",
        eyebrow: "清晰的运行洞察",
        title: "从请求到成本\n都能看得见",
        subtitle: "集中查看用量、请求日志、延迟、错误与预算，让多模型调用更容易管理。",
        chips: ["用量分析", "请求日志", "调用预算"],
        accent: NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.30, alpha: 1)
    ),
    ScreenshotSpec(
        filename: "06-background-widget-1440x900.jpg",
        eyebrow: "安静常驻，随时可用",
        title: "后台运行\n不占用程序坞",
        subtitle: "支持登录时启动与桌面小组件，保持本机 API 状态随时可见。",
        chips: ["登录时启动", "菜单栏后台", "WidgetKit"],
        accent: NSColor(calibratedRed: 0.45, green: 0.64, blue: 1.00, alpha: 1)
    )
]

let canvasSize = NSSize(width: 1440, height: 900)
let paragraph = NSMutableParagraphStyle()
paragraph.lineBreakMode = .byWordWrapping

func drawAspectFill(_ image: NSImage, in rect: NSRect) {
    let imageAspect = image.size.width / image.size.height
    let rectAspect = rect.width / rect.height
    var source = NSRect(origin: .zero, size: image.size)
    if imageAspect > rectAspect {
        let width = image.size.height * rectAspect
        source.origin.x = (image.size.width - width) / 2
        source.size.width = width
    } else {
        let height = image.size.width / rectAspect
        source.origin.y = (image.size.height - height) / 2
        source.size.height = height
    }
    image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
}

func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, lineHeight: CGFloat? = nil) {
    let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
    if let lineHeight {
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
    }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style
    ]
    NSAttributedString(string: text, attributes: attributes).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
}

func roundedPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

for spec in specs {
    let canvas = NSImage(size: canvasSize)
    canvas.lockFocus()
    NSGraphicsContext.saveGraphicsState()

    drawAspectFill(background, in: NSRect(origin: .zero, size: canvasSize))
    let shade = NSGradient(colors: [
        NSColor(calibratedWhite: 0.01, alpha: 0.24),
        NSColor(calibratedWhite: 0.01, alpha: 0.56)
    ])!
    shade.draw(in: NSRect(origin: .zero, size: canvasSize), angle: 0)

    drawText(spec.eyebrow, in: NSRect(x: 72, y: 735, width: 390, height: 28), font: .systemFont(ofSize: 16, weight: .semibold), color: spec.accent)
    drawText(spec.title, in: NSRect(x: 72, y: 555, width: 390, height: 165), font: .systemFont(ofSize: 47, weight: .bold), color: .white, lineHeight: 58)
    drawText(spec.subtitle, in: NSRect(x: 72, y: 445, width: 380, height: 100), font: .systemFont(ofSize: 20, weight: .regular), color: NSColor(calibratedWhite: 0.93, alpha: 0.92), lineHeight: 31)

    var chipY: CGFloat = 384
    for chip in spec.chips {
        let chipRect = NSRect(x: 72, y: chipY, width: 230, height: 42)
        spec.accent.withAlphaComponent(0.17).setFill()
        roundedPath(chipRect, radius: 21).fill()
        spec.accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: 89, y: chipY + 16, width: 10, height: 10)).fill()
        drawText(chip, in: NSRect(x: 112, y: chipY + 9, width: 175, height: 25), font: .systemFont(ofSize: 16, weight: .medium), color: .white)
        chipY -= 54
    }

    let panelRect = NSRect(x: 500, y: 113, width: 872, height: 636)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor.white.withAlphaComponent(0.96).setFill()
    roundedPath(panelRect, radius: 24).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()

    roundedPath(panelRect, radius: 24).addClip()
    drawAspectFill(screenshot, in: panelRect)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()

    spec.accent.withAlphaComponent(0.55).setStroke()
    let border = roundedPath(panelRect, radius: 24)
    border.lineWidth = 1.5
    border.stroke()

    NSGraphicsContext.restoreGraphicsState()
    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.94])
    else { continue }
    try jpeg.write(to: outputDirectory.appendingPathComponent(spec.filename), options: .atomic)
    print(outputDirectory.appendingPathComponent(spec.filename).path)
}
