import AppKit
import SwiftUI
import MayStockKit

/// Every account, one card each: OKX's two environments side by side — which
/// CLI profile reaches each, whether it does, and the switch between them —
/// and Schwab's, which for now is where its application stands. Plus the risk
/// limits and the cost model per venue that the engine and the backtester run
/// under — every trading-side setting the app has, on one page.
struct AccountPage: View {
    let appState: AppState
    @State private var feeSyncMessage: String?
    @State private var syncingFees = false
    @State private var costVenue: Venue = .okx

    private var prefs: TradingPrefs { appState.store.config.trading }
    private var portfolio: StrategyPortfolioPrefs { appState.store.config.strategy }

    var body: some View {
        pageBody
            // The picker offers the file's profiles; make sure it is the file
            // as it is now, not as it was at launch.
            .onAppear { appState.reloadProfilesIfChanged() }
    }

    private var pageBody: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                PageHeader(title: "账户与连接",
                           subtitle: "OKX 的 API Key 由官方 okx CLI 管理（okx config），MayStock 不接触、不存储任何密钥；嘉信 Trader API 审批中。回测只用公开行情，无需凭证。") {
                    Button {
                        appState.reloadProfiles()
                        Task {
                            await appState.detectTradeCLI()
                            await appState.verifyAllConnections()
                        }
                    } label: {
                        Label("重新检测并验证", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }

                cliCard

                HStack(alignment: .top, spacing: Theme.sectionSpacing) {
                    ForEach(TradingMode.allCases) { mode in
                        EnvironmentCard(appState: appState, mode: mode).frame(maxWidth: .infinity)
                    }
                }

                schwabCard

                HStack(alignment: .top, spacing: Theme.sectionSpacing) {
                    riskCard.frame(maxWidth: .infinity)
                    costCard.frame(maxWidth: .infinity)
                }

                panelCard
            }
            .padding(Theme.pagePadding)
        }
    }

    // MARK: CLI

    private var cliCard: some View {
        Card(title: "okx CLI", subtitle: "OKX 官方 Agent Trade Kit，所有账户读写都经它执行") {
            if appState.isDetectingCLI {
                ProgressView().controlSize(.small)
            } else {
                Button("重新检测") { Task { await appState.detectTradeCLI() } }.controlSize(.small)
            }
        } content: {
            HStack(alignment: .top, spacing: 14) {
                if let cli = appState.cliInfo {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.up).font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已检测到 · " + cli.version).font(Theme.Text.bodyMedium)
                        Text(cli.path).font(Theme.Text.mono).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未检测到 okx CLI").font(Theme.Text.bodyMedium)
                        Text("npm install -g @okx_ai/okx-trade-cli").font(Theme.Text.mono)
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("自定义路径（可选）").font(Theme.Text.caption).foregroundStyle(.secondary)
                    CommitTextField(placeholder: "/opt/homebrew/bin/okx", value: prefs.cliPath ?? "",
                                    width: 260, mono: true, alignment: .leading) { appState.setCLIPath($0) }
                }
            }
            HStack(spacing: 6) {
                StatusDot(color: appState.profileCatalog.fileExists ? Theme.up : Theme.warning, size: 6)
                Text(appState.profileCatalog.fileExists
                     ? "~/.okx/config.toml · \(appState.profileCatalog.profiles.count) 个 profile"
                        + (appState.profileCatalog.defaultProfile.map { " · 默认 \($0)" } ?? "")
                     : "未找到 ~/.okx/config.toml —— 运行 okx config 添加 API Key")
                    .font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Schwab

    /// Where the US-equity side stands. Honest about what exists: quotes flow
    /// from the interim source, the trading API is still being approved, and
    /// nothing here holds a key.
    private var schwabCard: some View {
        let feed = appState.hub.feedState(for: .schwab)
        let feedText: (String, Color) = switch feed {
        case .connected: ("已连接", Theme.up)
        case .degraded: ("读取失败，重试中", Theme.warning)
        case .connecting: ("连接中", .secondary)
        case .idle: ("自选里没有美股，未启动", .secondary)
        }
        return Card(title: "嘉信证券 · 美股",
                    subtitle: "Trader API – Individual 申请已提交，等待审批；审批通过后建 App 取 Key，再用 schwabctl 登录") {
            Button {
                NSWorkspace.shared.open(URL(string: "https://developer.schwab.com/dashboard")!)
            } label: {
                Label("开发者门户", systemImage: "arrow.up.right.square")
            }
            .controlSize(.small)
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                KeyValueRow(label: "美股行情", value: "\(Venue.schwab.marketDataSourceName) · \(feedText.0)", tint: feedText.1)
                KeyValueRow(label: "API 申请", value: "审批中 · Dashboard → Subscriptions 显示 Pending", tint: Theme.warning)
                KeyValueRow(label: "交易", value: "尚未接入：美股清单可以回测，不能下单")
            }
            .rowStyle()
            Text("审批通过后：Dashboard → Create App（回调 https://127.0.0.1:8182）→ 等 App 变为 Ready For Use → schwabctl login。"
                 + "密钥只在 schwabctl 进程里，MayStock 只拿 30 分钟有效的 access token；refresh token 每 7 天重新登录一次。")
                .font(Theme.Text.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Risk

    private var riskCard: some View {
        Card(title: "组合风控", subtitle: "对所有策略生效，每个 tick 检查") {
            EmptyView()
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    settingLabel("账户回撤熔断", help: "账户从最高点回撤到此比例后只允许减仓。留空关闭。")
                    HStack(spacing: 4) {
                        CommitTextField(placeholder: "关闭", value: portfolio.maxDrawdownPct.map { PriceFormatter.plain($0) } ?? "", width: 80) { text in
                            let cleaned = text.trimmingCharacters(in: .whitespaces)
                            appState.store.update { $0.strategy.maxDrawdownPct = cleaned.isEmpty ? nil : Double(cleaned).map { max($0, 0) } }
                        }
                        Text("%").font(Theme.Text.secondary).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    settingLabel("单笔名义额上限", help: "任何一笔订单的名义额都不得超过此数。防的是定量 bug，不是策略参数。留空只保留权益比例上限。")
                    HStack(spacing: 4) {
                        CommitTextField(placeholder: "不限", value: portfolio.maxOrderNotional.map { PriceFormatter.plain($0) } ?? "", width: 80) { text in
                            let cleaned = text.trimmingCharacters(in: .whitespaces)
                            appState.store.update { $0.strategy.maxOrderNotional = cleaned.isEmpty ? nil : Double(cleaned).map { max($0, 0) } }
                        }
                        Text(portfolio.quoteCurrency).font(Theme.Text.secondary).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    settingLabel("止损护栏", help: "一个回看窗口内被止损这么多次就暂停开新仓——策略可能完全按设计运行，却对当前市场判断错误。")
                    HStack(spacing: 4) {
                        CommitTextField(placeholder: "次", value: String(portfolio.stoplossGuard?.trades ?? 0), width: 50) { text in
                            guard let value = Int(text) else { return }
                            appState.store.update { config in
                                var guardConfig = config.strategy.stoplossGuard ?? StoplossGuard()
                                guardConfig.trades = max(value, 0)
                                config.strategy.stoplossGuard = guardConfig
                            }
                        }
                        Text("次 / ").font(Theme.Text.secondary).foregroundStyle(.secondary)
                        CommitTextField(placeholder: "分钟", value: String(portfolio.stoplossGuard?.lookbackMinutes ?? 0), width: 60) { text in
                            guard let value = Int(text) else { return }
                            appState.store.update { config in
                                var guardConfig = config.strategy.stoplossGuard ?? StoplossGuard()
                                guardConfig.lookbackMinutes = max(value, 0)
                                config.strategy.stoplossGuard = guardConfig
                            }
                        }
                        Text("分钟").font(Theme.Text.secondary).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    settingLabel("外部脚本策略", help: "声明式清单只做数组运算，永远安全；外部脚本等于在本机执行导入文件带来的任意代码。")
                    Toggle("允许", isOn: Binding(
                        get: { portfolio.allowScriptEngines },
                        set: { value in appState.store.update { $0.strategy.allowScriptEngines = value } }))
                    .toggleStyle(.switch).controlSize(.small)
                }
            }
            if let tripped = appState.runner.protectionTripped {
                InlineNotice(kind: .warning, title: "熔断生效中", message: tripped)
            }
            Text("当前账户回撤 " + PriceFormatter.percent(appState.runner.accountDrawdownPct, decimals: 2)
                 + " · 已持仓名义 " + PriceFormatter.money(appState.runner.committedNotional, decimals: 0) + " " + portfolio.quoteCurrency)
                .font(Theme.Text.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Costs

    private var costCard: some View {
        Card(title: "回测资金与成本", subtitle: "回测与寻优按每家交易所自己的费率计算；清单里自带 costs 的策略优先用自己的") {
            Picker("", selection: $costVenue) {
                ForEach(Venue.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    settingLabel("回测起始资金", help: "与实际分配无关，只决定回测的起点。按策略所在交易所的计价币计。")
                    HStack(spacing: 4) {
                        CommitTextField(placeholder: "10000", value: PriceFormatter.plain(portfolio.backtestCapital), width: 90) { text in
                            if let value = Double(text), value > 0 { appState.store.update { $0.strategy.backtestCapital = value } }
                        }
                        Text(costVenue.quoteCurrency).font(Theme.Text.secondary).foregroundStyle(.secondary)
                    }
                }
                switch costVenue {
                case .okx: okxCostRows
                case .schwab: schwabCostRows
                }
            }
            switch costVenue {
            case .okx: okxCostFooter
            case .schwab: schwabCostFooter
            }
        }
    }

    @ViewBuilder
    private var okxCostRows: some View {
        let schedule = portfolio.feeSchedules.okx
        GridRow {
            settingLabel("费率档位", help: "OKX 公布的档位表。新账户是普通 Lv1。")
                    Picker("", selection: Binding(
                        get: { schedule.tier },
                        set: { tier in appState.store.update { $0.strategy.feeSchedules.okx.tier = tier } })) {
                        ForEach(OKXFeeTier.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                    .disabled(schedule.syncedFromAccount)
                }
                GridRow {
                    settingLabel("成交方式", help: "按 maker 还是 taker 费率计费。市价单都是 taker。")
                    Picker("", selection: Binding(
                        get: { schedule.executionStyle },
                        set: { style in appState.store.update { $0.strategy.feeSchedules.okx.executionStyle = style } })) {
                        ForEach(FeeExecutionStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }
        GridRow {
            settingLabel("滑点假设", help: "每次成交在费率之外再假设的不利偏移。实测 BTC 永续不到 0.1 bps；用「实盘对照」里的实测值校准。")
            HStack(spacing: 4) {
                CommitTextField(placeholder: "1", value: PriceFormatter.plain(schedule.slippageBps), width: 60) { text in
                    if let value = Double(text), value >= 0 { appState.store.update { $0.strategy.feeSchedules.okx.slippageBps = value } }
                }
                Text("bps").font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var okxCostFooter: some View {
        let schedule = portfolio.feeSchedules.okx
        HStack(spacing: 8) {
            Text(schedule.summary).font(Theme.Text.caption).foregroundStyle(.secondary)
            Spacer()
            if schedule.syncedFromAccount {
                Button("改回档位表") { appState.store.update { $0.strategy.feeSchedules.okx.clearSync() } }.controlSize(.small)
            }
            if syncingFees {
                ProgressView().controlSize(.small)
            } else {
                Button("从账户同步实际费率") {
                    syncingFees = true
                    Task {
                        feeSyncMessage = await appState.syncFeeRates()
                        syncingFees = false
                    }
                }
                .controlSize(.small)
                .disabled(!appState.tradingReady)
                .help(appState.tradingBlocker ?? "读取 \(appState.tradingMode.displayName)账户的真实费率并覆盖档位表")
            }
        }
        if let feeSyncMessage {
            InlineNotice(kind: .warning, message: feeSyncMessage)
        }
    }

    /// Schwab's costs are two regulatory levies on sales plus an assumed
    /// slippage — numbers with a date on them, edited here when the SEC or
    /// FINRA restates them.
    @ViewBuilder
    private var schwabCostRows: some View {
        let schedule = portfolio.feeSchedules.schwab
        GridRow {
            settingLabel("佣金", help: "每笔订单的佣金，美元。嘉信上市股票与 ETF 为 0。")
            HStack(spacing: 4) {
                CommitTextField(placeholder: "0", value: PriceFormatter.plain(schedule.commissionPerOrder), width: 60) { text in
                    if let value = Double(text), value >= 0 { appState.store.update { $0.strategy.feeSchedules.schwab.commissionPerOrder = value } }
                }
                Text("USD / 笔").font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
        }
        GridRow {
            settingLabel("SEC §31", help: "只在卖出时按成交额收的监管费，每个财年重定。")
            HStack(spacing: 4) {
                CommitTextField(placeholder: "0.278", value: PriceFormatter.decimals(schedule.secFeeBpsOfSale, 3), width: 60) { text in
                    if let value = Double(text), value >= 0 { appState.store.update { $0.strategy.feeSchedules.schwab.secFeeBpsOfSale = value } }
                }
                Text("bps · 卖出").font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
        }
        GridRow {
            settingLabel("FINRA TAF", help: "只在卖出时按股数收的交易活动费，单笔有上限。")
            HStack(spacing: 4) {
                CommitTextField(placeholder: "0.000166", value: PriceFormatter.plain(schedule.tafPerShareSold), width: 80) { text in
                    if let value = Double(text), value >= 0 { appState.store.update { $0.strategy.feeSchedules.schwab.tafPerShareSold = value } }
                }
                Text("USD / 股，上限").font(Theme.Text.secondary).foregroundStyle(.secondary)
                CommitTextField(placeholder: "8.30", value: PriceFormatter.plain(schedule.tafCapPerOrder), width: 60) { text in
                    if let value = Double(text), value >= 0 { appState.store.update { $0.strategy.feeSchedules.schwab.tafCapPerOrder = value } }
                }
            }
        }
        GridRow {
            settingLabel("滑点假设", help: "每次成交在费率之外再假设的不利偏移。大盘股一美分价差约合 1 bps。")
            HStack(spacing: 4) {
                CommitTextField(placeholder: "2", value: PriceFormatter.plain(schedule.slippageBps), width: 60) { text in
                    if let value = Double(text), value >= 0 { appState.store.update { $0.strategy.feeSchedules.schwab.slippageBps = value } }
                }
                Text("bps").font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
        }
        GridRow {
            settingLabel("费率核对于", help: "上面两个监管费率最近一次对照官方公告的日期。改了费率就改这里。")
            CommitTextField(placeholder: "2025-05", value: schedule.ratesAsOf, width: 90, alignment: .leading) { text in
                let cleaned = text.trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty { appState.store.update { $0.strategy.feeSchedules.schwab.ratesAsOf = cleaned } }
            }
        }
    }

    @ViewBuilder
    private var schwabCostFooter: some View {
        Text(portfolio.feeSchedules.schwab.summary).font(Theme.Text.caption).foregroundStyle(.secondary)
    }

    // MARK: Panel

    private var panelCard: some View {
        Card(title: "悬浮面板") {
            EmptyView()
        } content: {
            Toggle(isOn: Binding(
                get: { prefs.enabled },
                set: { value in appState.store.update { $0.trading.enabled = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("在悬浮面板显示账户权益、收益与仓位").font(Theme.Text.body)
                    Text("关闭后面板只剩行情与告警。").font(Theme.Text.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
        }
    }

    private func settingLabel(_ text: String, help: String) -> some View {
        Text(text).font(Theme.Text.secondary).foregroundStyle(.secondary)
            .frame(width: 110, alignment: .leading)
            .help(help)
    }
}

// MARK: - Environment card

/// One account: its profile, its verdict, and the switch to it.
private struct EnvironmentCard: View {
    let appState: AppState
    let mode: TradingMode

    private var prefs: TradingPrefs { appState.store.config.trading }
    private var status: VenueConnectionStatus { appState.connectionStatus(for: mode) }
    private var isActive: Bool { appState.tradingMode == mode }
    private var catalog: OKXProfileCatalog { appState.profileCatalog }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ModeBadge(mode: mode, filled: isActive)
                    Text(mode.displayName).font(Theme.Text.heading)
                    if isActive {
                        Text("当前使用").font(Theme.Text.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ConnectionChip(appState: appState, mode: mode)
                }

                Text(mode.isDemo
                     ? "OKX 模拟交易环境：独立账户、虚拟资金，用模拟盘专用的 API Key。"
                     : "真实账户：策略发出的每一笔订单都会真实成交。")
                    .font(Theme.Text.secondary).foregroundStyle(.secondary)

                profileRow
                if let mismatch = appState.profileMismatch(for: mode) {
                    InlineNotice(kind: .warning, message: mismatch)
                }
                verdict

                if mode == .live { unlockRow }

                HStack(spacing: 8) {
                    Button {
                        Task { await appState.verifyConnection(mode) }
                    } label: {
                        Label("验证连接", systemImage: "checkmark.shield")
                    }
                    .controlSize(.small)
                    .disabled({ if case .checking = status { return true } else { return false } }())
                    Spacer()
                    if isActive {
                        Text("引擎正在这个账户上运行").font(Theme.Text.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            appState.requestModeSwitch(to: mode)
                        } label: {
                            Label("切换到\(mode.displayName)", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(ProminentButtonStyle(tint: Theme.mode(mode)))
                        .disabled(mode == .live && !appState.liveTradingUnlocked)
                        .help(mode == .live && !appState.liveTradingUnlocked ? "先解锁实盘" : "验证连接后确认切换；运行中的策略会先停止")
                    }
                }
            }
        }
    }

    private var profileRow: some View {
        HStack(spacing: 8) {
            Text("CLI profile").font(Theme.Text.secondary).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            if catalog.profiles.isEmpty {
                CommitTextField(placeholder: "默认 profile", value: prefs.profile(for: mode) ?? "",
                                width: 180, mono: true, alignment: .leading) { appState.setProfile($0, for: mode) }
            } else {
                Picker("", selection: Binding(
                    get: { prefs.profile(for: mode) ?? "" },
                    set: { appState.setProfile($0.isEmpty ? nil : $0, for: mode) })) {
                    Text(catalog.defaultProfile.map { "CLI 默认（\($0)）" } ?? "CLI 默认").tag("")
                    ForEach(catalog.profiles) { profile in
                        Text(profile.name + (profile.isDemo.map { $0 ? " · demo" : " · live" } ?? "")).tag(profile.name)
                    }
                    if let name = prefs.profile(for: mode), catalog.profile(named: name) == nil {
                        Text("\(name)（不存在）").tag(name)
                    }
                }
                .labelsHidden().frame(width: 220)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var verdict: some View {
        switch status {
        case .connected(let report):
            VStack(alignment: .leading, spacing: 4) {
                KeyValueRow(label: "账户权益", value: report.totalEquity.map { PriceFormatter.money($0) + " " + appState.runner.quoteCurrency } ?? "未报告")
                KeyValueRow(label: "持有币种", value: "\(report.balanceCount) 种")
                if let account = report.account {
                    KeyValueRow(label: "账户模式", value: account.accountLevelName, tint: account.supportsPerpetuals ? .primary : Theme.warning)
                    KeyValueRow(label: "持仓模式", value: account.positionModeName)
                    KeyValueRow(label: "Key 权限", value: account.permissions, tint: account.canTrade ? .primary : Theme.warning)
                    if !account.supportsPerpetuals {
                        InlineNotice(kind: .warning, message: "简单交易模式下 OKX 拒绝所有永续合约订单（51010）。到 OKX「交易 → 账户模式」切换后永续策略才能下单。")
                    }
                    if !account.canTrade {
                        InlineNotice(kind: .warning, message: "这个 API Key 只有读取权限，能看账户但不能下单。")
                    }
                }
                KeyValueRow(label: "验证时间", value: Format.clock(report.checkedAt))
            }
            .rowStyle()
        case .failed(let message, let hint, _):
            InlineNotice(kind: .danger, title: "连接失败", message: [message, hint].compactMap { $0 }.joined(separator: "\n"))
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在通过 okx CLI 读取账户…").font(Theme.Text.secondary).foregroundStyle(.secondary)
            }
        case .unknown:
            Text("尚未验证。验证只读取余额与账户配置，不会下单。")
                .font(Theme.Text.secondary).foregroundStyle(.tertiary)
        }
    }

    private var unlockRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { appState.liveTradingUnlocked },
                set: { appState.setLiveTradingUnlocked($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("解锁实盘交易").font(Theme.Text.bodyMedium)
                    Text("锁定时所有订单都走模拟盘（--demo），实盘不可切换。解锁后仍要逐个策略确认才会在实盘启动。")
                        .font(Theme.Text.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            if appState.liveTradingUnlocked {
                InlineNotice(kind: .danger, message: "实盘已解锁——切到实盘后，策略下的每一笔订单都会真实成交。")
            }
        }
        .rowStyle()
    }
}
