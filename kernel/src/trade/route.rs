//! Every OKX REST route the trading client calls, and the rate OKX allows on
//! each — declared once, here, and enforced for every request.
//!
//! A request can only be addressed through a `Target`, which can only be made
//! from a `Route`; `Route::limit` matches every route with no default arm. So
//! a new route cannot be called before its limit is written down.
//!
//! The limits are OKX's published ones, per account, as ccxt's OKX definition
//! (`ts/src/okx.ts`, a cost of 1 = 20 requests per 2 seconds) states them —
//! checked 2026-09-25 against it and against the official okx CLI, whose own
//! throttle uses the same routes. Where OKX counts per instrument as well,
//! pacing per account is stricter than it has to be and never looser.
//!
//! Why it exists (measured 2026-09-25): one working-order read asks twelve
//! algo listings at once, and OKX allows twenty such requests per two
//! seconds per account. The app polling the same account at the same moment
//! as the close-doctor took four of them over the limit — `50011 Too Many
//! Requests`.
//!
//! The two leverage routes and `max-size` were checked 2026-10-09 against
//! OKX's own documentation — twenty per two seconds per user ID, each — and
//! ccxt's table (cost 1).

use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Route {
    // Acting on the account.
    PlaceOrder,
    PlaceAlgo,
    CancelOrder,
    CancelAlgos,
    AmendAlgos,
    OrderPrecheck,
    /// The leverage one leg of a contract is held at.
    SetLeverage,
    // Reading it.
    OrdersPending,
    AlgoOrdersPending,
    Order,
    Positions,
    Balance,
    AssetBalances,
    AssetValuation,
    AccountConfig,
    Fills,
    Bills,
    TradeFee,
    LeverageInfo,
    MaxSize,
}

/// At most `requests` in any `window`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limit {
    pub requests: usize,
    pub window: Duration,
}

impl Limit {
    const fn per_two_seconds(requests: usize) -> Limit {
        Limit { requests, window: Duration::from_secs(2) }
    }
    const fn per_second(requests: usize) -> Limit {
        Limit { requests, window: Duration::from_secs(1) }
    }
}

impl Route {
    /// Every route, for the checks that must hold of each one.
    pub const ALL: [Route; 20] = [
        Route::PlaceOrder,
        Route::PlaceAlgo,
        Route::CancelOrder,
        Route::CancelAlgos,
        Route::AmendAlgos,
        Route::OrderPrecheck,
        Route::SetLeverage,
        Route::OrdersPending,
        Route::AlgoOrdersPending,
        Route::Order,
        Route::Positions,
        Route::Balance,
        Route::AssetBalances,
        Route::AssetValuation,
        Route::AccountConfig,
        Route::Fills,
        Route::Bills,
        Route::TradeFee,
        Route::LeverageInfo,
        Route::MaxSize,
    ];

    pub fn path(self) -> &'static str {
        match self {
            Route::PlaceOrder | Route::Order => "/api/v5/trade/order",
            Route::PlaceAlgo => "/api/v5/trade/order-algo",
            Route::CancelOrder => "/api/v5/trade/cancel-order",
            Route::CancelAlgos => "/api/v5/trade/cancel-algos",
            Route::AmendAlgos => "/api/v5/trade/amend-algos",
            Route::OrderPrecheck => "/api/v5/trade/order-precheck",
            Route::SetLeverage => "/api/v5/account/set-leverage",
            Route::OrdersPending => "/api/v5/trade/orders-pending",
            Route::AlgoOrdersPending => "/api/v5/trade/orders-algo-pending",
            Route::Positions => "/api/v5/account/positions",
            Route::Balance => "/api/v5/account/balance",
            Route::AssetBalances => "/api/v5/asset/balances",
            Route::AssetValuation => "/api/v5/asset/asset-valuation",
            Route::AccountConfig => "/api/v5/account/config",
            Route::Fills => "/api/v5/trade/fills",
            Route::Bills => "/api/v5/account/bills",
            Route::TradeFee => "/api/v5/account/trade-fee",
            Route::LeverageInfo => "/api/v5/account/leverage-info",
            Route::MaxSize => "/api/v5/account/max-size",
        }
    }

    /// Whether a request on this route may change the account — and so
    /// whether an answer that says nothing definite leaves it unknown rather
    /// than simply failed. A precheck and every read change nothing.
    pub fn acts(self) -> bool {
        match self {
            Route::PlaceOrder
            | Route::PlaceAlgo
            | Route::CancelOrder
            | Route::CancelAlgos
            | Route::AmendAlgos
            | Route::SetLeverage => true,
            Route::OrderPrecheck
            | Route::OrdersPending
            | Route::AlgoOrdersPending
            | Route::Order
            | Route::Positions
            | Route::Balance
            | Route::AssetBalances
            | Route::AssetValuation
            | Route::AccountConfig
            | Route::Fills
            | Route::Bills
            | Route::TradeFee
            | Route::LeverageInfo
            | Route::MaxSize => false,
        }
    }

    /// OKX's limit on this route. `PlaceOrder` and `Order` share a path but
    /// not a method, and OKX counts them apart.
    pub fn limit(self) -> Limit {
        match self {
            Route::PlaceOrder | Route::CancelOrder | Route::Order | Route::OrdersPending | Route::Fills => {
                Limit::per_two_seconds(60)
            }
            Route::PlaceAlgo
            | Route::CancelAlgos
            | Route::AmendAlgos
            | Route::AlgoOrdersPending
            | Route::SetLeverage
            | Route::LeverageInfo
            | Route::MaxSize => Limit::per_two_seconds(20),
            Route::Positions | Route::Balance | Route::Bills => Limit::per_two_seconds(10),
            Route::OrderPrecheck | Route::AccountConfig | Route::TradeFee => Limit::per_two_seconds(5),
            Route::AssetBalances => Limit::per_second(6),
            Route::AssetValuation => Limit::per_second(1),
        }
    }
}

/// Where one request goes: a declared route and its query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub route: Route,
    /// Without the leading `?`; empty for none.
    pub query: String,
}

impl Target {
    pub fn new(route: Route, query: impl Into<String>) -> Target {
        Target { route, query: query.into() }
    }

    pub fn bare(route: Route) -> Target {
        Target::new(route, "")
    }

    /// The same request with one more parameter — the paging cursor.
    pub fn and(&self, key: &str, value: &str) -> Target {
        let pair = format!("{key}={value}");
        Target::new(self.route, if self.query.is_empty() { pair } else { format!("{}&{pair}", self.query) })
    }

    /// What is signed and requested.
    pub fn path_and_query(&self) -> String {
        if self.query.is_empty() {
            self.route.path().to_string()
        } else {
            format!("{}?{}", self.route.path(), self.query)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `Route::ALL` names every route once: the match below stops compiling
    /// when a route is added, and an ordinal past the list fails.
    #[test]
    fn every_route_is_listed_once() {
        fn ordinal(route: Route) -> usize {
            match route {
                Route::PlaceOrder => 0,
                Route::PlaceAlgo => 1,
                Route::CancelOrder => 2,
                Route::CancelAlgos => 3,
                Route::AmendAlgos => 4,
                Route::OrderPrecheck => 5,
                Route::SetLeverage => 6,
                Route::OrdersPending => 7,
                Route::AlgoOrdersPending => 8,
                Route::Order => 9,
                Route::Positions => 10,
                Route::Balance => 11,
                Route::AssetBalances => 12,
                Route::AssetValuation => 13,
                Route::AccountConfig => 14,
                Route::Fills => 15,
                Route::Bills => 16,
                Route::TradeFee => 17,
                Route::LeverageInfo => 18,
                Route::MaxSize => 19,
            }
        }
        let mut seen = [false; Route::ALL.len()];
        for route in Route::ALL {
            assert!(!std::mem::replace(&mut seen[ordinal(route)], true), "{route:?} twice");
        }
        assert!(seen.iter().all(|s| *s));
    }

    /// Whatever acts on the account is an order or an account setting.
    /// Nothing under the funding account's paths — where transfers and
    /// withdrawals live — acts, so no route here can move money out.
    #[test]
    fn nothing_here_can_move_funds() {
        for route in Route::ALL {
            let path = route.path();
            assert!(path.starts_with("/api/v5/"), "{route:?}");
            if route.acts() {
                assert!(path.starts_with("/api/v5/trade/") || path.starts_with("/api/v5/account/set-"), "{route:?} {path}");
            }
            if path.starts_with("/api/v5/asset/") {
                assert!(!route.acts(), "{route:?}");
            }
            let limit = route.limit();
            assert!(limit.requests > 0 && limit.window > Duration::ZERO, "{route:?}");
        }
    }

    #[test]
    fn a_target_is_its_route_and_query() {
        assert_eq!(Target::bare(Route::AccountConfig).path_and_query(), "/api/v5/account/config");
        let listing = Target::new(Route::OrdersPending, "instType=SWAP&limit=100");
        assert_eq!(listing.path_and_query(), "/api/v5/trade/orders-pending?instType=SWAP&limit=100");
        assert_eq!(listing.and("after", "99").path_and_query(), "/api/v5/trade/orders-pending?instType=SWAP&limit=100&after=99");
        assert_eq!(Target::bare(Route::Positions).and("instType", "SWAP").path_and_query(), "/api/v5/account/positions?instType=SWAP");
    }
}
