import Foundation
import Testing
@testable import MayStockKit

@Suite("Orders are priced from the environment they are filled in")
struct MarketEnvironmentTests {
    @Test("模拟盘客户端在每个请求上带环境头，真实市场客户端不带")
    func theSimulatedClientCarriesTheHeader() throws {
        let demo = try OKXRESTClient(simulated: true)
            .request(path: "api/v5/market/ticker", query: ["instId": "BTC-USD-261225-100000-C"])
        #expect(demo.value(forHTTPHeaderField: "x-simulated-trading") == "1")
        #expect(demo.url?.query == "instId=BTC-USD-261225-100000-C")

        let real = try OKXRESTClient()
            .request(path: "api/v5/market/ticker", query: ["instId": "BTC-USD-261225-100000-C"])
        #expect(real.value(forHTTPHeaderField: "x-simulated-trading") == nil)
    }

    @Test("venue 按交易模式挑行情环境：模拟盘读模拟盘，实盘读真实市场")
    func theVenueReadsTheEnvironmentItTradesIn() {
        let venue = OKXVenue(bridge: TradeBridge())
        for mode in TradingMode.allCases {
            #expect(venue.market(mode).simulated == mode.isDemo, "\(mode)")
        }
    }
}
