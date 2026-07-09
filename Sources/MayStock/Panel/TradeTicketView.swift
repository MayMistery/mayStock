import SwiftUI
import MayStockKit

/// Compact order ticket inside the hover panel.
///
/// Safety ladder: trading disabled → hidden; okx CLI missing → install hint;
/// live not unlocked → forced demo; every order requires an in-place
/// confirmation tap before anything is executed.
struct TradeTicketView: View {
    let appState: AppState
    let instId: String
    let referencePrice: Double?
    var onClose: () -> Void

    @State private var side: SpotOrderRequest.Side = .buy
    @State private var kind: SpotOrderRequest.Kind = .market
    @State private var sizeText: String = ""
    @State private var priceText: String = ""
    @State private var confirming = false
    @State private var placing = false
    @State private var resultText: String? = nil
    @State private var resultOK = false

    private var demo: Bool { !appState.store.config.trading.liveTradingUnlocked }

    var body: some View {
        VStack(spacing: 8) {
            if appState.cliInfo == nil {
                cliMissing
            } else {
                ticket
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            sizeText = PriceFormatter.plain(appState.store.config.trading.defaultQuoteSize)
            if let referencePrice {
                priceText = PriceFormatter.plain(referencePrice)
            }
        }
    }

    private var cliMissing: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("未检测到官方 okx CLI", systemImage: "terminal")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("关闭") { onClose() }.controlSize(.mini)
            }
            Text("npm install -g @okx_ai/okx-trade-cli")
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("安装并配置 API Key 后即可在此下单")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Button("重新检测") { Task { await appState.detectTradeCLI() } }
                    .controlSize(.mini)
            }
        }
    }

    private var ticket: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $side) {
                    Text("买入").tag(SpotOrderRequest.Side.buy)
                    Text("卖出").tag(SpotOrderRequest.Side.sell)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 110)

                Picker("", selection: $kind) {
                    Text("市价").tag(SpotOrderRequest.Kind.market)
                    Text("限价").tag(SpotOrderRequest.Kind.limit)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 96)

                Spacer()

                Text(demo ? "DEMO" : "LIVE")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background((demo ? Color.orange : Color.red).opacity(0.18), in: Capsule())
                    .foregroundStyle(demo ? .orange : .red)

                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                TextField(kind == .market ? "数量 (USDT)" : "数量 (币)", text: $sizeText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11).monospacedDigit())
                if kind == .limit {
                    TextField("价格", text: $priceText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11).monospacedDigit())
                }
                placeButton
            }

            if let resultText {
                Text(resultText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(resultOK ? ChartStyle.up : ChartStyle.down)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var placeButton: some View {
        if placing {
            ProgressView().controlSize(.small).frame(width: 84)
        } else if confirming {
            Button(role: .destructive) {
                Task { await place() }
            } label: {
                Text("确认\(side == .buy ? "买入" : "卖出")")
                    .font(.system(size: 11, weight: .bold)).frame(width: 72)
            }
            .tint(side == .buy ? ChartStyle.up : ChartStyle.down)
            .controlSize(.small)
        } else {
            Button {
                confirming = true
                resultText = nil
                Task { // auto-cancel confirmation after 4s
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    confirming = false
                }
            } label: {
                Text(side == .buy ? "买入" : "卖出")
                    .font(.system(size: 11, weight: .semibold)).frame(width: 72)
            }
            .controlSize(.small)
            .disabled(Double(sizeText) == nil || (kind == .limit && Double(priceText) == nil))
        }
    }

    private func place() async {
        confirming = false
        placing = true
        defer { placing = false }
        guard let size = Double(sizeText), size > 0 else { return }

        let order = SpotOrderRequest(
            instId: instId,
            side: side,
            kind: kind,
            size: size,
            sizeUnit: kind == .market ? .quote : .base,
            limitPrice: kind == .limit ? Double(priceText) : nil)

        do {
            let result = try await appState.placeOrder(order)
            resultOK = true
            resultText = "✓ 已提交 · 订单号 \(result.ordId)\(demo ? "（demo）" : "")"
            appState.notifications.post(
                title: "\(instId) \(side == .buy ? "买入" : "卖出")已提交",
                body: "\(kind == .market ? "市价" : "限价") \(sizeText) · ordId \(result.ordId)",
                sound: true)
        } catch {
            resultOK = false
            resultText = "✗ \(error)"
        }
    }
}
