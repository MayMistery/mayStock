import SwiftUI
import MayStockKit

/// 模拟盘 | 实盘. Tinted by the mode's colour, locked until live is unlocked,
/// and never switching by itself: a tap hands off to `requestModeSwitch`,
/// which verifies the target account and asks before acting.
struct TradingModeSwitch: View {
    let appState: AppState
    var size: CGFloat = 11

    var body: some View {
        PillSegments(
            segments: TradingMode.allCases.map { mode in
                PillSegments<TradingMode>.Segment(
                    value: mode,
                    title: mode.displayName,
                    tint: Theme.mode(mode),
                    icon: mode == .live && !appState.liveTradingUnlocked ? "lock.fill" : nil,
                    help: help(for: mode),
                    enabled: true)
            },
            selection: appState.tradingMode,
            size: size,
            onSelect: { appState.requestModeSwitch(to: $0) })
    }

    private func help(for mode: TradingMode) -> String {
        if mode == appState.tradingMode { return "当前环境：\(mode.displayName)" }
        if mode == .live && !appState.liveTradingUnlocked {
            return "实盘已锁定——在「账户与连接」页解锁后才能切换"
        }
        return "切换到\(mode.displayName)：先验证连接，再确认；运行中的策略会先停止"
    }
}

/// One mode's connection verdict, as a chip: dot, words, and the full story
/// on hover. Clicking an unverified or failed chip re-checks.
struct ConnectionChip: View {
    let appState: AppState
    let mode: TradingMode
    var showsMode = false

    private var status: VenueConnectionStatus { appState.connectionStatus(for: mode) }

    var body: some View {
        Button {
            Task { await appState.verifyConnection(mode) }
        } label: {
            HStack(spacing: 5) {
                if showsMode { ModeBadge(mode: mode, size: .small) }
                switch status {
                case .checking:
                    ProgressView().controlSize(.mini)
                    Text("验证中…")
                default:
                    StatusDot(color: color, size: 6)
                    Text(text).lineLimit(1)
                }
            }
            .font(Theme.Text.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .disabled({ if case .checking = status { return true } else { return false } }())
    }

    private var color: Color {
        switch status {
        case .unknown: return .secondary
        case .checking: return Theme.accent
        case .connected: return Theme.up
        case .failed: return Theme.down
        }
    }

    private var text: String {
        switch status {
        case .unknown: return "未验证连接"
        case .checking: return "验证中…"
        case .connected(let report):
            var parts = ["已连接"]
            if let equity = report.totalEquity {
                parts.append(PriceFormatter.money(equity, decimals: 0) + " " + StrategyRunner.quoteCurrency)
            }
            return parts.joined(separator: " · ")
        case .failed: return "连接失败"
        }
    }

    private var helpText: String {
        switch status {
        case .unknown: return "还没有验证过\(mode.displayName)的连接，点击验证（只读）"
        case .checking: return "正在用 okx CLI 读取账户…"
        case .connected(let report):
            var lines = ["\(mode.displayName) · " + (report.profile.map { "profile \($0)" } ?? "CLI 默认 profile")]
            if let account = report.account {
                lines.append("\(account.accountLevelName) · \(account.positionModeName) · 权限 \(account.permissions)")
            }
            lines.append("验证于 " + Format.clock(report.checkedAt) + "，点击重新验证")
            return lines.joined(separator: "\n")
        case .failed(let message, let hint, let at):
            return [message, hint, "失败于 " + Format.clock(at) + "，点击重试"].compactMap { $0 }.joined(separator: "\n")
        }
    }
}
