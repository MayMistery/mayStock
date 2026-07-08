import SwiftUI

struct PopoverView: View {
    let marketData: MarketDataProvider
    let cpuMonitor: CPUMonitor
    let memoryMonitor: MemoryMonitor
    let networkMonitor: NetworkMonitor
    let configService: ConfigurationService

    var body: some View {
        VStack(spacing: 12) {
            Text("BTC/USDT")
                .font(.headline)
            Text(marketData.formattedPrice)
                .font(.system(.largeTitle, design: .monospaced))
        }
        .frame(width: 400, height: 300)
        .padding()
    }
}
