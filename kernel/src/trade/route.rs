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
    pub fn path(self) -> &'static str {
        match self {
            Route::PlaceOrder | Route::Order => "/api/v5/trade/order",
            Route::PlaceAlgo => "/api/v5/trade/order-algo",
            Route::CancelOrder => "/api/v5/trade/cancel-order",
            Route::CancelAlgos => "/api/v5/trade/cancel-algos",
            Route::AmendAlgos => "/api/v5/trade/amend-algos",
            Route::OrderPrecheck => "/api/v5/trade/order-precheck",
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
        }
    }

    /// Whether a request on this route may change the account — and so
    /// whether an answer that says nothing definite leaves it unknown rather
    /// than simply failed. A precheck and every read change nothing.
    pub fn acts(self) -> bool {
        match self {
            Route::PlaceOrder | Route::PlaceAlgo | Route::CancelOrder | Route::CancelAlgos | Route::AmendAlgos => true,
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
            | Route::TradeFee => false,
        }
    }

    /// OKX's limit on this route. `PlaceOrder` and `Order` share a path but
    /// not a method, and OKX counts them apart.
    pub fn limit(self) -> Limit {
        match self {
            Route::PlaceOrder | Route::CancelOrder | Route::Order | Route::OrdersPending | Route::Fills => {
                Limit::per_two_seconds(60)
            }
            Route::PlaceAlgo | Route::CancelAlgos | Route::AmendAlgos | Route::AlgoOrdersPending => {
                Limit::per_two_seconds(20)
            }
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

    #[test]
    fn a_target_is_its_route_and_query() {
        assert_eq!(Target::bare(Route::AccountConfig).path_and_query(), "/api/v5/account/config");
        let listing = Target::new(Route::OrdersPending, "instType=SWAP&limit=100");
        assert_eq!(listing.path_and_query(), "/api/v5/trade/orders-pending?instType=SWAP&limit=100");
        assert_eq!(listing.and("after", "99").path_and_query(), "/api/v5/trade/orders-pending?instType=SWAP&limit=100&after=99");
        assert_eq!(Target::bare(Route::Positions).and("instType", "SWAP").path_and_query(), "/api/v5/account/positions?instType=SWAP");
    }
}
