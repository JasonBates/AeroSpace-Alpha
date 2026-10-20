import Common

private let adaptiveLayoutParser: [String: any ParserProtocol<AdaptiveLayoutConfig>] = [
    "enabled": Parser(\.enabled, parseAdaptiveLayoutEnabled),
    "one-column-width-percent": Parser(\.oneColumnWidthPercent, parseAdaptiveLayoutPercent),
    "two-column-width-percent": Parser(\.twoColumnWidthPercent, parseAdaptiveLayoutPercent),
    "single-row-height-percent": Parser(\.singleRowHeightPercent, parseAdaptiveLayoutPercent),
]

private func parseAdaptiveLayoutEnabled(
    _ raw: OrderedJson,
    _ backtrace: ConfigBacktrace,
    _ c: inout ConfigParserContext,
) -> DynamicConfigValue<Bool> {
    parseDynamicValue(raw, ofType: Bool.self, false, backtrace, &c)
}

private func parseAdaptiveLayoutPercent(
    _ raw: OrderedJson,
    _ backtrace: ConfigBacktrace,
) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace).filter(.init(backtrace, "Expected an integer from 1 to 100")) {
        (1 ... 100).contains($0)
    }
}

func parseAdaptiveLayout(
    _ raw: OrderedJson,
    _ backtrace: ConfigBacktrace,
    _ c: inout ConfigParserContext,
) -> AdaptiveLayoutConfig {
    let result = parseTable(raw, .default, adaptiveLayoutParser, backtrace, &c)
    if result.oneColumnWidthPercent > result.twoColumnWidthPercent {
        c.errors.append(.init(
            backtrace + .key("one-column-width-percent"),
            "Must be less than or equal to 'two-column-width-percent'",
        ))
    }
    return result
}
