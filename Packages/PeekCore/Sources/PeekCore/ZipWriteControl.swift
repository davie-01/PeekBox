import Foundation

/// Broker 的进度面板与 libzip 回调共享；取消仅在原子提交之前生效。
/// 总进度按实测耗时比例分段（600 MB 导入：暂存约 7%、重写约 90%、校验约 3%）：
/// 暂存输入 0–8%（按字节）→ libzip 重写 8–95%（按工作量换算）→ 校验 95–98%（按字节）→ 提交。
public final class ZipWriteControl: @unchecked Sendable {
    private let state = Locked((cancelled: false, fraction: 0.0))
    /// libzip 依次处理的各条目的累计工作量（最后一项为总量）
    private let libzipWork = Locked<[Double]>([])

    public init() {}
    public var isCancelled: Bool { state.value.cancelled }
    public var fractionCompleted: Double { state.value.fraction }
    public func cancel() { state.withLock { $0.cancelled = true } }

    func update(_ fraction: Double) { state.withLock { $0.fraction = max($0.fraction, min(fraction, 1)) } }
    func checkCancellation() throws {
        if isCancelled { throw ZipEditor.EditError.cancelled }
    }

    /// 设置 libzip 重写时各条目的工作量（按 libzip 的处理顺序）
    func setLibzipWork(_ weights: [Double]) {
        var cumulative: [Double] = []
        var total = 0.0
        for weight in weights {
            total += weight
            cumulative.append(total)
        }
        libzipWork.value = cumulative
    }

    /// libzip 的进度把各条目平均分配（第 j 个条目占 [j/n, (j+1)/n)），条目内按已处理比例推进。
    /// 换算成按工作量计的进度：大文件不再挤在最后一小段里
    func libzipProgress(_ progress: Double) {
        let cumulative = libzipWork.value
        guard let total = cumulative.last, total > 0 else {
            update(0.08 + progress * 0.87)
            return
        }
        let position = min(max(progress, 0), 1) * Double(cumulative.count)
        let index = min(Int(position), cumulative.count - 1)
        let before = index == 0 ? 0 : cumulative[index - 1]
        let within = (cumulative[index] - before) * (position - Double(index))
        update(0.08 + (before + within) / total * 0.87)
    }
}
