import AppKit
import Foundation

struct ScreenshotSpec {
    let filename: String
    let sourceFilename: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let chips: [String]
    let accent: NSColor
}

guard CommandLine.arguments.count == 4 else {
    fputs("用法：generate_app_store_promotional_screenshots.swift <背景图> <真实界面截图目录> <输出目录>\n", stderr)
    exit(2)
}

let backgroundPath = CommandLine.arguments[1]
let screenshotDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)

guard let background = NSImage(contentsOfFile: backgroundPath) else {
    fputs("无法读取背景图。\n", stderr)
    exit(2)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let specs = [
    ScreenshotSpec(
        filename: "01-unified-api-1440x900.jpg",
        sourceFilename: "overview.png",
        eyebrow: "MODELHUB · 原生 macOS 多模型网关",
        title: "一个本机入口\n连接所有 AI 模型",
        subtitle: "把多家供应商统一为稳定的本机入口，现有客户端只需配置一次。",
        chips: ["本机统一 API", "11 种语言", "Universal"],
        accent: NSColor(calibratedRed: 0.20, green: 0.72, blue: 1.00, alpha: 1)
    ),
    ScreenshotSpec(
        filename: "02-safe-model-catalog-1440x900.jpg",
        sourceFilename: "providers.png",
        eyebrow: "严格可用性边界",
        title: "只把可用模型\n交给外部客户端",
        subtitle: "按需热更新名录并导入 CSV；新模型先隔离，完成真实验证后才参与调用。",
        chips: ["模型热更新", "CSV 导入", "隔离原因"],
        accent: NSColor(calibratedRed: 0.26, green: 0.91, blue: 0.59, alpha: 1)
    ),
    ScreenshotSpec(
        filename: "03-smart-routing-1440x900.jpg",
        sourceFilename: "routes.png",
        eyebrow: "智能模型路由",
        title: "一个稳定别名\n智能选择模型",
        subtitle: "价格、速度、官方三项内置规则互斥生效，并在可用目标之间完成故障转移。",
        chips: ["同模型价格优先", "同模型速度优先", "同模型官方优先"],
        accent: NSColor(calibratedRed: 0.72, green: 0.40, blue: 1.00, alpha: 1)
    ),
    ScreenshotSpec(
        filename: "04-local-privacy-1440x900.jpg",
        sourceFilename: "governance.png",
        eyebrow: "本机优先的隐私设计",
        title: "凭证留在\nmacOS 钥匙串",
        subtitle: "凭证存入钥匙串；工作区与虚拟密钥为不同客户端划定模型、预算和权限。",
        chips: ["Keychain", "工作区策略", "虚拟密钥"],
        accent: NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.94, alpha: 1)
    ),
    ScreenshotSpec(
        filename: "05-usage-insights-1440x900.jpg",
        sourceFilename: "analytics.png",
        eyebrow: "清晰的运行洞察",
        title: "从请求到成本\n都能看得见",
        subtitle: "同步供应商机器可读价格，按计划更新，并用 8 种币种查看费用与预算。",
        chips: ["官方价格同步", "8 种展示币种", "预算与用量"],
        accent: NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.30, alpha: 1)
    ),
    ScreenshotSpec(
        filename: "06-background-widget-1440x900.jpg",
        sourceFilename: "operations.png",
        eyebrow: "安静常驻，随时可用",
        title: "后台运行\n不占用程序坞",
        subtitle: "限流、并发、熔断、预算、内存缓存与 Agent 协议都能在本机集中控制。",
        chips: ["韧性控制", "MCP 与 Agent", "后台与小组件"],
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
    let screenshotURL = screenshotDirectory.appendingPathComponent(spec.sourceFilename)
    guard let screenshot = NSImage(contentsOf: screenshotURL) else {
        fputs("无法读取真实界面截图：\(screenshotURL.path)\n", stderr)
        exit(2)
    }
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
