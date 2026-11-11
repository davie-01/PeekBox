import CLibzip
import Foundation
import UniversalDetector

/// 压缩包中未标记编码的文件名（无 UTF-8 标志的 ZIP、tar 等）：以整个压缩包为单位统一判断编码，
/// 而不是逐个文件名猜——单个短文件名的字节太少，逐个猜会把 UTF-8 中文猜成 IBM866 等西文编码，
/// 或把 Shift-JIS / Big5 误认作 GB18030。
enum NameEncoding {
    static let gb18030 = encoding("GB18030")
    static let shiftJIS = encoding("Shift_JIS")
    static let big5 = encoding("Big5")
    static let eucKR = encoding("EUC-KR")
    static let cp437 = encoding("IBM437")

    /// 全部名称都是合法 UTF-8（含纯 ASCII）时为 UTF-8；否则用 UniversalDetector 对全部非 ASCII 名称合并识别。
    /// 名称多时识别可靠（实测 3 个中文名置信度 0.99）；只有一两个短名称时会猜成 KOI8-R、windows-1252 等
    /// 单字节编码——它们能"解开"任何字节，结果是乱码。所以只采用中日韩多字节编码或置信度 ≥ 0.9 的结果，
    /// 其余按系统首选语言决定优先尝试的编码；识别结果须能解开每一个名称
    static func detect(_ names: [Data]) -> String.Encoding {
        let nonASCII = names.filter { $0.contains { $0 >= 0x80 } }
        guard !nonASCII.isEmpty, !nonASCII.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) else { return .utf8 }

        var candidates: [String.Encoding] = []
        if let detector = UniversalDetector() {
            for name in nonASCII {
                detector.analyze(name)
                detector.analyze(Data("\n".utf8))
            }
            let detected = String.Encoding(rawValue: detector.encoding())
            if detected.rawValue != 0, multiByte.contains(detected) || detector.confidence() >= 0.9 {
                candidates.append(detected)
            }
        }
        candidates += preferredLegacyEncodings()
        return candidates.first { candidate in
            nonASCII.allSatisfy { String(data: $0, encoding: candidate) != nil }
        } ?? cp437
    }

    private static let multiByte: Set<String.Encoding> = [
        gb18030, shiftJIS, big5, eucKR, encoding("GBK"), encoding("GB2312"), encoding("EUC-JP"), encoding("Big5-HKSCS"),
    ]

    /// 识别不可靠时按系统首选语言决定先试哪种旧编码：简体中文 → GB18030，繁体 → Big5，日文 → Shift-JIS，
    /// 韩文 → EUC-KR，其他 → CP437（Windows 西文系统压缩的 ZIP）
    private static func preferredLegacyEncodings() -> [String.Encoding] {
        let language = Locale.preferredLanguages.first?.lowercased() ?? ""
        let first: String.Encoding
        if language.hasPrefix("zh-hant") || language.hasPrefix("zh-tw") || language.hasPrefix("zh-hk") {
            first = big5
        } else if language.hasPrefix("zh") {
            first = gb18030
        } else if language.hasPrefix("ja") {
            first = shiftJIS
        } else if language.hasPrefix("ko") {
            first = eucKR
        } else {
            first = cp437
        }
        return [first] + [gb18030, shiftJIS, big5, eucKR, cp437].filter { $0 != first }
    }

    static func decode(_ data: Data, as encoding: String.Encoding) -> String {
        let text = String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        return text.precomposedStringWithCanonicalMapping
    }

    /// 编码的 IANA 名称（XADMaster 按此名称解码）
    static func ianaName(_ encoding: String.Encoding) -> String {
        let cf = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        return (CFStringConvertEncodingToIANACharSetName(cf) as String?) ?? "UTF-8"
    }

    private static func encoding(_ iana: String) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(iana as CFString)))
    }
}

/// ZIP 条目名称。读取（ZipArchive）与修改（ZipEditor）必须用同一规则解码，路径才能对应。
enum ZipNameDecoder {
    /// 按索引排列的名称；带 UTF-8 标志的条目按 UTF-8，其余按整包识别出的编码。
    /// 分两遍读取以减少同时存活的中间数据：第一遍只保留需要识别编码的名称（含非 ASCII 且无 UTF-8 标志），
    /// 识别后第二遍从 libzip 重新取名称直接解码；纯 ASCII 名称不复制、不做 Unicode 规范化
    static func names(_ handle: OpaquePointer) -> [String?] {
        let count = Int(max(zip_get_num_entries(handle, 0), 0))
        var legacy: [Data] = []
        var flaggedUTF8 = [Bool](repeating: false, count: count)
        for index in 0..<count {
            guard let name = zip_get_name(handle, UInt64(index), zip_flags_t(ZIP_FL_ENC_RAW)) else { continue }
            let length = strlen(name)
            guard !isASCII(name, length: length) else { continue }
            // 按规范解码（无标志时视为 CP437 并转成 UTF-8）的结果与原始字节相同，说明带 UTF-8 标志
            if let strict = zip_get_name(handle, UInt64(index), zip_flags_t(ZIP_FL_ENC_STRICT)),
               strlen(strict) == length, memcmp(strict, name, length) == 0 {
                flaggedUTF8[index] = true
            } else {
                legacy.append(Data(bytes: name, count: length))
            }
        }
        let encoding = NameEncoding.detect(legacy)
        legacy = []

        var result = [String?](repeating: nil, count: count)
        for index in 0..<count {
            guard let name = zip_get_name(handle, UInt64(index), zip_flags_t(ZIP_FL_ENC_RAW)) else { continue }
            let length = strlen(name)
            if isASCII(name, length: length) {
                result[index] = String(cString: name)
            } else {
                result[index] = NameEncoding.decode(Data(bytes: name, count: length),
                                                    as: flaggedUTF8[index] ? .utf8 : encoding)
            }
        }
        return result
    }

    private static func isASCII(_ name: UnsafePointer<CChar>, length: Int) -> Bool {
        UnsafeRawBufferPointer(start: name, count: length).allSatisfy { $0 < 0x80 }
    }
}
