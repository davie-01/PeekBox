// 由浅色 / 深色两张 1024 母图生成 App/AppIcon.icon（Icon Composer 格式，随系统外观切换）。
//
// 用法：swift Scripts/make-app-icon.swift <浅色母图.png> <深色母图.png> [底板边距比例，默认 0.05]
//
// 母图自带圆角底板且四周留有透明边距时，不能原样放进 .icon：系统会再套一层规范圆角，
// 出现"圆角里套圆角"的双层边框（传统光栅图标则会被缩小放进系统底板）。
// 这里只裁取底板范围、铺满画布，底板颜色作为图层背景填充补满角落，外形交给系统按规范裁切；
// 并关闭系统给图层加的玻璃、高光与阴影，保持原画。
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("用法：swift Scripts/make-app-icon.swift <浅色母图.png> <深色母图.png> [边距比例]\n".utf8))
    exit(1)
}
let inset = arguments.count >= 4 ? Double(arguments[3]) ?? 0.05 : 0.05
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let icon = root.appendingPathComponent("App/AppIcon.icon")
let assets = icon.appendingPathComponent("Assets")
let side = 1024

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("无法读取 \(path)\n".utf8))
        exit(1)
    }
    return image
}

/// 裁出底板范围并缩放到 1024，返回图层图片与底板颜色（取底板上沿中部，避开边缘高光）
func process(_ path: String, name: String) -> String {
    let image = load(path)
    let margin = Int((Double(image.width) * inset).rounded())
    let crop = CGRect(x: margin, y: margin, width: image.width - margin * 2, height: image.height - margin * 2)
    guard let plate = image.cropping(to: crop),
          let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    context.interpolationQuality = .high
    context.draw(plate, in: CGRect(x: 0, y: 0, width: side, height: side))
    let output = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: output)
    try! rep.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent(name))

    let sample = NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: margin + image.height / 50)!
        .usingColorSpace(.sRGB)!
    return String(format: "srgb:%.5f,%.5f,%.5f,1.00000", sample.redComponent, sample.greenComponent, sample.blueComponent)
}

try? FileManager.default.removeItem(at: icon)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
let lightFill = process(arguments[1], name: "peekbox-light.png")
let darkFill = process(arguments[2], name: "peekbox-dark.png")

let json: [String: Any] = [
    "fill-specializations": [
        ["value": ["solid": lightFill]],
        ["appearance": "dark", "value": ["solid": darkFill]],
    ],
    "groups": [[
        "layers": [[
            "glass": false,
            "image-name-specializations": [
                ["value": "peekbox-light.png"],
                ["appearance": "dark", "value": "peekbox-dark.png"],
            ],
            "name": "PeekBox",
        ]],
        "shadow": ["kind": "none", "opacity": 0],
        "specular": false,
        "translucency": ["enabled": false, "value": 0],
    ]],
    "supported-platforms": ["squares": ["macOS"]],
]
let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: icon.appendingPathComponent("icon.json"))
print("已生成 \(icon.path)\n浅色背景 \(lightFill)\n深色背景 \(darkFill)")
