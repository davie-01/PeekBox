import Foundation

/// 界面语言切换：设置了语言时，从资源包里取对应的 .lproj 子包查文案；跟随系统时直接用资源包本身。
/// String(localized:bundle:) 传入 .lproj 子包即可按指定语言查找（含单复数 .stringsdict）。
public enum Localization {
    private static let cache = Locked<[String: Bundle]>([:])

    public static func bundle(_ base: Bundle) -> Bundle {
        // 跟随系统时也自行按系统首选语言选取：系统为非主包选语言时会跟随当前进程主包的语言，
        // 后台服务这类没有语言资源的包会把外层主应用的文案表也带成英文
        guard let language = PeekPreferences.language ?? systemLanguage(for: base) else { return base }
        let key = base.bundlePath + "|" + language
        if let cached = cache.value[key] { return cached }
        guard let path = base.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return base }
        cache.withLock { $0[key] = bundle }
        return bundle
    }

    private static func systemLanguage(for base: Bundle) -> String? {
        let available = base.localizations.filter { $0 != "Base" }
        return Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages).first
    }

    /// 文件大小（如"31 字节" / "31 bytes"）随界面语言
    public static func fileSize(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// 日期、数字等格式也随界面语言
    public static var locale: Locale {
        PeekPreferences.language.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }
}
