import Foundation

enum ChartType: String, Codable, CaseIterable, Sendable {
    case line
    case candlestick
    case depth
    case volume
}

enum TimeSpan: Codable, Equatable, Hashable, Sendable {
    case seconds(Int)
    case minutes(Int)
    case hours(Int)
    case days(Int)

    static let allPresets: [TimeSpan] = [
        .minutes(1), .minutes(5), .minutes(15),
        .hours(1), .hours(4),
        .days(1)
    ]

    var displayLabel: String {
        switch self {
        case .seconds(let v): return "\(v)s"
        case .minutes(let v): return "\(v)m"
        case .hours(let v): return "\(v)H"
        case .days(let v): return "\(v)D"
        }
    }

    var okxChannel: String {
        switch self {
        case .seconds(1): return "candle1s"
        case .seconds(5): return "candle5s"
        case .minutes(1): return "candle1m"
        case .minutes(5): return "candle5m"
        case .minutes(15): return "candle15m"
        case .hours(1): return "candle1H"
        case .hours(4): return "candle4H"
        case .days(1): return "candle1D"
        case .days(7): return "candle1W"
        default: return "candle1m"
        }
    }

    var intervalSeconds: TimeInterval {
        switch self {
        case .seconds(let v): return TimeInterval(v)
        case .minutes(let v): return TimeInterval(v * 60)
        case .hours(let v): return TimeInterval(v * 3600)
        case .days(let v): return TimeInterval(v * 86400)
        }
    }

    var timeAxisFormat: String {
        switch self {
        case .seconds: return "HH:mm:ss"
        case .minutes(let v) where v <= 5: return "HH:mm"
        case .minutes: return "HH:mm"
        case .hours(let v) where v <= 4: return "MM/dd HH:mm"
        case .hours: return "MM/dd"
        case .days: return "MM/dd"
        }
    }
}

enum ChartColorScheme: String, Codable, CaseIterable, Sendable {
    case standard
    case monochrome
    case custom
}

struct ChartConfig: Codable, Equatable, Sendable {
    var chartType: ChartType
    var timeSpan: TimeSpan
    var showVolume: Bool
    var colorScheme: ChartColorScheme

    static let `default` = ChartConfig(chartType: .candlestick, timeSpan: .minutes(5), showVolume: true, colorScheme: .standard)
}
