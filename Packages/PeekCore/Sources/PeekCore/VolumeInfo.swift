import Foundation

/// 按文件名识别分卷压缩包。只看名字，不读文件（沙盒内也可能读不到其他卷）。
public enum VolumeInfo: Equatable {
    case first
    case part(number: Int, firstName: String)

    public static func detect(_ url: URL) -> VolumeInfo? {
        // 列举大目录时每个文件都会调用：先按扩展名排除绝大多数文件，Swift 正则单次匹配约十几微秒，10 万项累计数秒
        guard mayBeVolume(extension: url.pathExtension) else { return nil }
        let name = url.lastPathComponent
        let lower = name.lowercased()

        // name.7z.001 / name.zip.001 / name.tar.001
        if let match = lower.firstMatch(of: /^(.+)\.(\d{3})$/), let number = Int(match.2) {
            let base = String(name.dropLast(4))
            return number == 1 ? .first : .part(number: number, firstName: base + ".001")
        }
        // name.part1.rar / name.part01.rar
        if let match = lower.firstMatch(of: /^(.+)\.part(\d+)\.rar$/), let number = Int(match.2) {
            let digits = match.2.count
            let prefix = String(name.dropLast(".part\(match.2).rar".count))
            let first = prefix + ".part" + String(repeating: "0", count: digits - 1) + "1.rar"
            return number == 1 ? .first : .part(number: number, firstName: first)
        }
        // 旧式 RAR 分卷 name.r00 …（首卷为 name.rar）
        if let match = lower.firstMatch(of: /^(.+)\.r(\d{2})$/), let number = Int(match.2) {
            return .part(number: number + 2, firstName: String(name.dropLast(4)) + ".rar")
        }
        // 分卷 ZIP name.z01 …（末卷 name.zip 是打开入口）
        if let match = lower.firstMatch(of: /^(.+)\.z(\d{2})$/), let number = Int(match.2) {
            return .part(number: number, firstName: String(name.dropLast(4)) + ".zip")
        }
        return nil
    }

    /// 分卷包第二卷的位置（据此判断能否读到其他卷）：name.001 → name.002，name.part01.rar → name.part02.rar，
    /// 分卷 ZIP 的入口 name.zip → name.z01。不是可识别的分卷首卷时返回 nil
    public static func secondVolume(of url: URL) -> URL? {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        let directory = url.deletingLastPathComponent()
        if lower.hasSuffix(".zip") {
            return directory.appendingPathComponent(String(name.dropLast(4)) + ".z01")
        }
        guard detect(url) == .first else { return nil }
        if lower.firstMatch(of: /^(.+)\.(\d{3})$/) != nil {
            return directory.appendingPathComponent(String(name.dropLast(3)) + "002")
        }
        if let match = lower.firstMatch(of: /^(.+)\.part(\d+)\.rar$/) {
            let digits = match.2.count
            let prefix = String(name.dropLast(".part\(match.2).rar".count))
            return directory.appendingPathComponent(prefix + ".part" + String(repeating: "0", count: digits - 1) + "2.rar")
        }
        return nil
    }

    /// 扩展名是 3 位数字、rar、r 加 2 位数字、z 加 2 位数字之一
    private static func mayBeVolume(extension ext: String) -> Bool {
        let chars = Array(ext.lowercased().utf8)
        let isDigit = { (c: UInt8) in c >= 0x30 && c <= 0x39 }
        switch chars.count {
        case 3:
            if chars.allSatisfy(isDigit) { return true }
            if chars == Array("rar".utf8) { return true }
            return (chars[0] == UInt8(ascii: "r") || chars[0] == UInt8(ascii: "z")) && isDigit(chars[1]) && isDigit(chars[2])
        default:
            return false
        }
    }
}
