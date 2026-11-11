extension Sequence where Element == Int64 {
    /// 求和，溢出时封顶为 Int64.max（畸形压缩包可声明接近上限的大小，直接相加会使进程崩溃）
    public var saturatingSum: Int64 {
        reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? (value > 0 ? .max : .min) : sum
        }
    }
}
