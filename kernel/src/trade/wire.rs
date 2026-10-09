//! Orders as OKX reads them: typed requests in, the exact REST path and body
//! out.
//!
//! Pure. The body built here is the body signed and the body sent, and the
//! same function hands the confirmation screen its text — so what a person
//! approves is what the exchange receives. Every rule about which field goes
//! where lives here and nowhere else:
//!
//! - `tdMode` is always stated, and never defaulted here. The CLI this
//!   replaced filled in `cross` for a perpetual that named none and `cash`
//!   for spot: the first is an order for a different position when the one
//!   held is isolated, and the second is refused outright on a
//!   multi-currency account (`51000 Parameter tdMode error`, demo account,
//!   2026-10-09). Which mode an order states is `margin`'s to decide — the
//!   strategy's regime for an order that opens, the position's own for one
//!   that acts on it — and an order that names none is refused.
//! - A leg's leverage is set per contract and margin mode, and per leg only
//!   where OKX keeps it per leg: isolated, in long/short mode.
//! - `reduceOnly` only where OKX reads it: perpetuals in net mode (its own
//!   words), options (deliberately — see `reduce_only_applies`), algo orders
//!   on a derivative. Never on spot.
//! - A stop and a target together are `oco`: as one `conditional` order OKX
//!   keeps the stop and silently drops the target.
//! - Booleans travel as the strings `"true"`, the encoding the CLI used on
//!   every order this app has placed.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use super::margin;
use super::route::Route;
use crate::strategy::InstrumentType;

// MARK: - Vocabulary

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Family {
    #[serde(rename = "SPOT")]
    Spot,
    #[serde(rename = "SWAP")]
    Swap,
    #[serde(rename = "OPTION")]
    Option,
    #[serde(rename = "STOCK")]
    Stock,
}

impl Family {
    /// A family with an algo book. Options have none: OKX refuses the listing
    /// for every order kind.
    pub fn has_algo_book(self) -> bool {
        matches!(self, Family::Spot | Family::Swap)
    }
    pub fn is_derivative(self) -> bool {
        matches!(self, Family::Swap | Family::Option)
    }

    /// A family whose positions OKX holds at a leverage of their own, set
    /// per contract and margin mode (`account/set-leverage`): a perpetual or
    /// a delivery future. A coin is paid for, and an option's leverage is in
    /// the contract.
    pub fn has_leverage(self) -> bool {
        matches!(self, Family::Swap)
    }

    /// The instrument type a strategy names this family by — where its
    /// margin regime is declared.
    pub fn instrument_type(self) -> InstrumentType {
        match self {
            Family::Spot => InstrumentType::Spot,
            Family::Swap => InstrumentType::Swap,
            Family::Option => InstrumentType::Option,
            Family::Stock => InstrumentType::Stock,
        }
    }

    /// The family a strategy's instrument type trades as.
    pub fn of(inst_type: InstrumentType) -> Family {
        match inst_type {
            InstrumentType::Spot => Family::Spot,
            InstrumentType::Swap => Family::Swap,
            InstrumentType::Option => Family::Option,
            InstrumentType::Stock => Family::Stock,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    Buy,
    Sell,
}

impl Side {
    pub fn as_str(self) -> &'static str {
        match self {
            Side::Buy => "buy",
            Side::Sell => "sell",
        }
    }

    /// The side that closes a holding: a long is sold, a short bought back.
    pub fn closing(is_long: bool) -> Side {
        if is_long { Side::Sell } else { Side::Buy }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PosSide {
    Long,
    Short,
    Net,
}

impl PosSide {
    pub fn as_str(self) -> &'static str {
        match self {
            PosSide::Long => "long",
            PosSide::Short => "short",
            PosSide::Net => "net",
        }
    }

    /// The leg a venue's `posSide` names. Absent or empty is a one-way
    /// account's single leg, `net`; anything else is not a leg.
    pub fn from_venue(text: Option<&str>) -> Option<PosSide> {
        match text.unwrap_or("") {
            "long" => Some(PosSide::Long),
            "short" => Some(PosSide::Short),
            "net" | "" => Some(PosSide::Net),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderKind {
    Market,
    Limit,
    Ioc,
    PostOnly,
    Fok,
}

impl OrderKind {
    pub fn as_str(self) -> &'static str {
        match self {
            OrderKind::Market => "market",
            OrderKind::Limit => "limit",
            OrderKind::Ioc => "ioc",
            OrderKind::PostOnly => "post_only",
            OrderKind::Fok => "fok",
        }
    }
    pub fn is_priced(self) -> bool {
        self != OrderKind::Market
    }
}

/// A regular order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrderSpec {
    pub inst_id: String,
    pub inst_type: Family,
    pub side: Side,
    pub kind: OrderKind,
    /// Exchange units: contracts for derivatives, coins for spot — or the
    /// quote currency when `size_in_quote`.
    pub size: f64,
    /// Spot market orders only: `size` is an amount of the quote currency.
    #[serde(default)]
    pub size_in_quote: bool,
    #[serde(default)]
    pub price: Option<f64>,
    #[serde(default)]
    pub trade_mode: Option<String>,
    #[serde(default)]
    pub pos_side: Option<PosSide>,
    #[serde(default)]
    pub reduce_only: bool,
    #[serde(default)]
    pub client_id: Option<String>,
    /// Protection the exchange attaches once the order fills, filled at
    /// market when triggered.
    #[serde(default)]
    pub stop_trigger: Option<f64>,
    #[serde(default)]
    pub take_profit_trigger: Option<f64>,
}

/// An order the exchange works for us after it is placed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AlgoSpec {
    pub inst_id: String,
    pub inst_type: Family,
    pub side: Side,
    #[serde(default)]
    pub pos_side: Option<PosSide>,
    pub size: f64,
    #[serde(default)]
    pub trade_mode: Option<String>,
    #[serde(default)]
    pub reduce_only: bool,
    /// Cancelled by the exchange when the position is fully closed
    /// (`cxlOnClosePos`), so a stop left behind cannot fire into the next
    /// position on the instrument.
    #[serde(default)]
    pub cancel_with_position: bool,
    /// `algoClOrdId`: lets an order whose placement went unanswered be
    /// found on the algo book.
    #[serde(default)]
    pub client_id: Option<String>,
    pub kind: AlgoKind,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum AlgoKind {
    /// Post-only at the best price, re-priced every second, cancelled once the
    /// book has run `max_chase_ratio` (0.002 = 0.2%) from where it started.
    #[serde(rename_all = "camelCase")]
    Chase { max_chase_ratio: f64 },
    /// Filled at market once the last trade crosses a trigger.
    #[serde(rename_all = "camelCase")]
    Protection { take_profit: Option<f64>, stop_loss: Option<f64> },
}

/// Everything the kernel can ask OKX to do to an account. Closed: there is no
/// way to name an endpoint that is not here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum Action {
    Place { order: OrderSpec },
    PlaceAlgo { algo: AlgoSpec },
    #[serde(rename_all = "camelCase")]
    Cancel { inst_id: String, order_id: String },
    #[serde(rename_all = "camelCase")]
    CancelAlgo { inst_id: String, algo_id: String },
    /// Move an existing stop's trigger, filled at market as before.
    #[serde(rename_all = "camelCase")]
    AmendStop { inst_id: String, algo_id: String, stop: f64 },
    /// The exchange's own check of an order, without placing it. OKX offers
    /// it on multi-currency and portfolio margin accounts only.
    Precheck { order: OrderSpec },
    /// Hold one leg of a contract at `leverage`: the contract's, in one
    /// margin mode, on the leg named where OKX keeps one per leg. On a leg
    /// that holds an isolated position this moves margin in or out of it, so
    /// the runner only ever sends it to an empty leg (`leg`).
    #[serde(rename_all = "camelCase")]
    SetLeverage {
        inst_id: String,
        family: Family,
        margin_mode: String,
        #[serde(default)]
        pos_side: Option<PosSide>,
        leverage: f64,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Endpoint {
    PlaceOrder,
    PlaceAlgo,
    CancelOrder,
    CancelAlgos,
    AmendAlgos,
    OrderPrecheck,
    SetLeverage,
}

impl Endpoint {
    /// Every endpoint an action can become.
    pub const ALL: [Endpoint; 7] = [
        Endpoint::PlaceOrder,
        Endpoint::PlaceAlgo,
        Endpoint::CancelOrder,
        Endpoint::CancelAlgos,
        Endpoint::AmendAlgos,
        Endpoint::OrderPrecheck,
        Endpoint::SetLeverage,
    ];

    /// Where it goes, and at what rate — declared with every other route.
    pub fn route(self) -> Route {
        match self {
            Endpoint::PlaceOrder => Route::PlaceOrder,
            Endpoint::PlaceAlgo => Route::PlaceAlgo,
            Endpoint::CancelOrder => Route::CancelOrder,
            Endpoint::CancelAlgos => Route::CancelAlgos,
            Endpoint::AmendAlgos => Route::AmendAlgos,
            Endpoint::OrderPrecheck => Route::OrderPrecheck,
            Endpoint::SetLeverage => Route::SetLeverage,
        }
    }

    pub fn path(self) -> &'static str {
        self.route().path()
    }

    /// The field an accepted reply names the order by; none for a request
    /// that names no order.
    pub fn id_field(self) -> Option<&'static str> {
        match self {
            Endpoint::PlaceOrder | Endpoint::CancelOrder => Some("ordId"),
            Endpoint::PlaceAlgo | Endpoint::CancelAlgos | Endpoint::AmendAlgos => Some("algoId"),
            Endpoint::OrderPrecheck | Endpoint::SetLeverage => None,
        }
    }

    /// Whether the exchange may have acted on this request even when no
    /// reply came back — its route's to say.
    pub fn changes_state(self) -> bool {
        self.route().acts()
    }
}

/// One request, exactly as it will be signed and sent.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WireRequest {
    pub endpoint: Endpoint,
    pub method: &'static str,
    pub path: &'static str,
    pub body: String,
}

// MARK: - Building

pub fn build(action: &Action) -> Result<WireRequest, String> {
    let (endpoint, body) = match action {
        Action::Place { order } => (Endpoint::PlaceOrder, Value::Object(order_body(order)?)),
        Action::Precheck { order } => (Endpoint::OrderPrecheck, Value::Object(order_body(order)?)),
        Action::PlaceAlgo { algo } => (Endpoint::PlaceAlgo, Value::Object(algo_body(algo)?)),
        Action::Cancel { inst_id, order_id } => {
            require_id("instId", inst_id)?;
            require_id("ordId", order_id)?;
            (Endpoint::CancelOrder, json!({"instId": inst_id, "ordId": order_id}))
        }
        Action::CancelAlgo { inst_id, algo_id } => {
            require_id("instId", inst_id)?;
            require_id("algoId", algo_id)?;
            (Endpoint::CancelAlgos, json!([{"instId": inst_id, "algoId": algo_id}]))
        }
        Action::AmendStop { inst_id, algo_id, stop } => {
            require_id("instId", inst_id)?;
            require_id("algoId", algo_id)?;
            (
                Endpoint::AmendAlgos,
                json!({"instId": inst_id, "algoId": algo_id,
                       "newSlTriggerPx": price(*stop, "新止损价")?, "newSlOrdPx": "-1"}),
            )
        }
        Action::SetLeverage { inst_id, family, margin_mode, pos_side, leverage } => (
            Endpoint::SetLeverage,
            Value::Object(leverage_body(inst_id, *family, margin_mode, *pos_side, *leverage)?),
        ),
    };
    Ok(WireRequest { endpoint, method: "POST", path: endpoint.path(), body: body.to_string() })
}

fn require_id(field: &str, value: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        return Err(format!("{field} 不能为空"));
    }
    Ok(())
}

/// The `tdMode` an order states — its own, never a default: `margin`
/// decides it, and an order that skipped it is refused here.
fn trade_mode(family: Family, stated: Option<&str>) -> Result<String, String> {
    if family == Family::Stock {
        return Err("OKX 不交易股票".into());
    }
    let Some(mode) = stated.filter(|m| !m.is_empty()) else {
        return Err(format!(
            "{}单必须说明 tdMode：开仓按策略的保证金模式，作用于持仓的单按这笔仓位自己的模式，不能默认",
            family_label(family)));
    };
    if !margin::modes(family).contains(&mode) {
        return Err(format!("{}单不能用 tdMode {mode}", family_label(family)));
    }
    Ok(mode.to_string())
}

fn family_label(family: Family) -> &'static str {
    match family {
        Family::Spot => "现货",
        Family::Swap => "永续",
        Family::Option => "期权",
        Family::Stock => "股票",
    }
}

/// The body that holds one leg at a leverage. Cross leverage is the
/// contract's, shared by both legs, so naming one there is a mistake; an
/// isolated leg is named in long/short mode and is the whole contract in net
/// mode.
fn leverage_body(
    inst_id: &str, family: Family, margin_mode: &str, pos_side: Option<PosSide>, leverage: f64,
) -> Result<Map<String, Value>, String> {
    require_id("instId", inst_id)?;
    if !family.has_leverage() {
        return Err(format!("{}没有按仓位设的杠杆", family_label(family)));
    }
    if !matches!(margin_mode, "cross" | "isolated") {
        return Err(format!("杠杆只按全仓或逐仓设，不认识 {margin_mode}"));
    }
    if !crate::strategy::leverage_on_grid(leverage) {
        return Err(format!(
            "杠杆 {leverage} 不在 {} 的档位上：交易所会照单回执、却把它截短持有",
            crate::strategy::LEVERAGE_STEP));
    }
    let mut body = Map::new();
    body.insert("instId".into(), json!(inst_id));
    body.insert("lever".into(), json!(amount(leverage, "杠杆")?));
    body.insert("mgnMode".into(), json!(margin_mode));
    match (margin_mode, pos_side) {
        ("isolated", Some(leg @ (PosSide::Long | PosSide::Short))) => {
            body.insert("posSide".into(), json!(leg.as_str()));
        }
        ("cross", Some(PosSide::Long | PosSide::Short)) => {
            return Err("全仓杠杆按合约设、两条腿共用，不能只设一条腿".into());
        }
        _ => {}
    }
    Ok(body)
}

/// Where `reduceOnly` goes on a regular order.
///
/// OKX documents it for "MARGIN orders, and FUTURES/SWAP orders in net mode"
/// only (2026-09-24), and has a refusal for it being sent where it is not
/// available (51205). So a perpetual on a long/short leg goes without it — the
/// leg already makes a sale of the long a close, and no such order can open
/// the other side.
///
/// Options keep it, against the letter of that line, because the risk is
/// lopsided: on an option it is the only thing between an oversized sale and a
/// naked short, while a refusal is an error on screen. Not verified against
/// the exchange either way; if OKX ever answers 51205 here, that is the
/// answer.
pub fn reduce_only_applies(family: Family, pos_side: Option<PosSide>) -> bool {
    match family {
        Family::Swap => matches!(pos_side, None | Some(PosSide::Net)),
        Family::Option => true,
        Family::Spot | Family::Stock => false,
    }
}

fn order_body(order: &OrderSpec) -> Result<Map<String, Value>, String> {
    require_id("instId", &order.inst_id)?;
    let mode = trade_mode(order.inst_type, order.trade_mode.as_deref())?;
    let mut body = Map::new();
    body.insert("instId".into(), json!(order.inst_id));
    body.insert("tdMode".into(), json!(mode));
    body.insert("side".into(), json!(order.side.as_str()));
    body.insert("ordType".into(), json!(order.kind.as_str()));
    body.insert("sz".into(), json!(amount(order.size, "数量")?));
    match (order.kind.is_priced(), order.price) {
        (true, Some(px)) => {
            body.insert("px".into(), json!(price(px, "价格")?));
        }
        (true, None) => return Err(format!("{} 单必须带价格", order.kind.as_str())),
        (false, Some(_)) => return Err("市价单不能带价格".into()),
        (false, None) => {}
    }
    if order.size_in_quote && !(order.inst_type == Family::Spot && order.kind == OrderKind::Market) {
        return Err("按计价币数量下单只适用于现货市价单".into());
    }
    if order.inst_type == Family::Spot && order.kind == OrderKind::Market {
        body.insert("tgtCcy".into(), json!(if order.size_in_quote { "quote_ccy" } else { "base_ccy" }));
    }
    if let Some(leg) = order.pos_side {
        if order.inst_type == Family::Swap {
            body.insert("posSide".into(), json!(leg.as_str()));
        }
    }
    if order.reduce_only && reduce_only_applies(order.inst_type, order.pos_side) {
        body.insert("reduceOnly".into(), json!("true"));
    }
    if let Some(id) = order.client_id.as_deref().filter(|id| !id.is_empty()) {
        body.insert("clOrdId".into(), json!(id));
    }
    let mut attached = Map::new();
    if let Some(target) = order.take_profit_trigger.filter(|p| *p > 0.0) {
        attached.insert("tpTriggerPx".into(), json!(price(target, "止盈价")?));
        attached.insert("tpOrdPx".into(), json!("-1"));
    }
    if let Some(stop) = order.stop_trigger.filter(|p| *p > 0.0) {
        attached.insert("slTriggerPx".into(), json!(price(stop, "止损价")?));
        attached.insert("slOrdPx".into(), json!("-1"));
    }
    if !attached.is_empty() {
        body.insert("attachAlgoOrds".into(), json!([Value::Object(attached)]));
    }
    Ok(body)
}

fn algo_body(algo: &AlgoSpec) -> Result<Map<String, Value>, String> {
    require_id("instId", &algo.inst_id)?;
    if !algo.inst_type.has_algo_book() {
        return Err(match algo.inst_type {
            Family::Option => "OKX 期权没有策略委托簿".into(),
            _ => "OKX 不交易股票".into(),
        });
    }
    let mode = trade_mode(algo.inst_type, algo.trade_mode.as_deref())?;
    let ord_type = match &algo.kind {
        AlgoKind::Chase { .. } => {
            if algo.inst_type != Family::Swap {
                return Err("OKX 的追逐限价只支持永续和交割合约".into());
            }
            "chase"
        }
        AlgoKind::Protection { take_profit, stop_loss } => match (take_profit, stop_loss) {
            (Some(_), Some(_)) => "oco",
            (None, None) => return Err("止盈价和止损价至少要有一个".into()),
            _ => "conditional",
        },
    };
    let mut body = Map::new();
    body.insert("instId".into(), json!(algo.inst_id));
    body.insert("tdMode".into(), json!(mode));
    body.insert("side".into(), json!(algo.side.as_str()));
    body.insert("ordType".into(), json!(ord_type));
    body.insert("sz".into(), json!(amount(algo.size, "数量")?));
    if let Some(leg) = algo.pos_side {
        if algo.inst_type == Family::Swap {
            body.insert("posSide".into(), json!(leg.as_str()));
        }
    }
    // Algo orders read `reduceOnly` on every derivative leg — tying a stop to
    // its position requires it — and it means nothing on spot.
    if algo.reduce_only && algo.inst_type.is_derivative() {
        body.insert("reduceOnly".into(), json!("true"));
    }
    if let Some(id) = algo.client_id.as_deref().filter(|id| !id.is_empty()) {
        body.insert("algoClOrdId".into(), json!(id));
    }
    match &algo.kind {
        AlgoKind::Chase { max_chase_ratio } => {
            if !(*max_chase_ratio > 0.0 && *max_chase_ratio <= 0.1) {
                return Err(format!("最大追价比例 {max_chase_ratio} 要在 0 到 0.1 之间"));
            }
            // Sit at the best price (distance 0) and give up once the book has
            // run the ratio from where it started.
            body.insert("chaseType".into(), json!("distance"));
            body.insert("chaseVal".into(), json!("0"));
            body.insert("maxChaseType".into(), json!("ratio"));
            body.insert("maxChaseVal".into(), json!(number(*max_chase_ratio)));
        }
        AlgoKind::Protection { take_profit, stop_loss } => {
            // Market once triggered, on the last trade — stated rather than
            // left to a default, so the confirmation can say which price fires.
            if let Some(target) = take_profit {
                body.insert("tpTriggerPx".into(), json!(price(*target, "止盈价")?));
                body.insert("tpOrdPx".into(), json!("-1"));
                body.insert("tpTriggerPxType".into(), json!("last"));
            }
            if let Some(stop) = stop_loss {
                body.insert("slTriggerPx".into(), json!(price(*stop, "止损价")?));
                body.insert("slOrdPx".into(), json!("-1"));
                body.insert("slTriggerPxType".into(), json!("last"));
            }
            if algo.cancel_with_position && algo.inst_type == Family::Swap {
                if !algo.reduce_only {
                    return Err("随仓撤销的止盈止损必须只减仓".into());
                }
                body.insert("cxlOnClosePos".into(), json!("true"));
            }
        }
    }
    Ok(body)
}

// MARK: - Numbers

/// A number as the exchange must read it: at most ten decimals, trailing
/// zeros and binary noise gone — `0.30000000000000004` leaves as `"0.3"`.
/// Never rounded to fewer places: a size already floored to the lot must not
/// be rounded back up past it.
pub fn number(value: f64) -> String {
    if value == value.trunc() && value.abs() < 1e15 {
        return format!("{}", value as i64);
    }
    let text = format!("{value:.10}");
    let trimmed = text.trim_end_matches('0').trim_end_matches('.');
    if trimmed == "-0" { "0".into() } else { trimmed.to_string() }
}

fn amount(value: f64, what: &str) -> Result<String, String> {
    let text = number(value);
    if !value.is_finite() || value <= 0.0 || text == "0" {
        return Err(format!("{what}必须大于 0"));
    }
    Ok(text)
}

fn price(value: f64, what: &str) -> Result<String, String> {
    amount(value, what)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn order(family: Family, kind: OrderKind) -> OrderSpec {
        OrderSpec {
            inst_id: match family {
                Family::Swap => "ETH-USDT-SWAP".into(),
                Family::Spot => "ETH-USDT".into(),
                Family::Option => "ETH-USD-260925-2600-C".into(),
                Family::Stock => "MU".into(),
            },
            inst_type: family,
            side: Side::Sell,
            kind,
            size: 187.75,
            size_in_quote: false,
            price: kind.is_priced().then_some(2653.2),
            trade_mode: margin::modes(family).first().map(|m| m.to_string()),
            pos_side: None,
            reduce_only: false,
            client_id: None,
            stop_trigger: None,
            take_profit_trigger: None,
        }
    }

    fn body(action: &Action) -> Value {
        serde_json::from_str(&build(action).unwrap().body).unwrap()
    }

    #[test]
    fn numbers_never_round_past_the_lot() {
        assert_eq!(number(0.30000000000000004), "0.3");
        assert_eq!(number(0.0408135), "0.0408135");
        assert_eq!(number(187.75), "187.75");
        assert_eq!(number(100.0), "100");
        assert_eq!(number(0.00497246), "0.00497246");
        assert_eq!(number(83518.27), "83518.27");
        // Ten decimals and no more: a size is never rounded up.
        assert_eq!(number(0.01234567891234), "0.0123456789");
    }

    const FAMILIES: [Family; 4] = [Family::Spot, Family::Swap, Family::Option, Family::Stock];

    /// No family has a default: an order that names no mode is refused
    /// before the network, on the order book and the algo book alike, and a
    /// stated mode is sent exactly when the family may state it.
    #[test]
    fn every_order_states_its_margin_mode_and_none_is_defaulted() {
        for family in FAMILIES {
            let mut bare = order(family, OrderKind::Limit);
            bare.trade_mode = None;
            assert!(build(&Action::Place { order: bare.clone() }).is_err(), "{family:?}: no default");
            assert!(build(&Action::Precheck { order: bare }).is_err(), "{family:?}: no default");
            for mode in ["cash", "cross", "isolated", "margin"] {
                let mut stated = order(family, OrderKind::Limit);
                stated.trade_mode = Some(mode.into());
                match build(&Action::Place { order: stated }) {
                    Ok(wire) => {
                        assert!(margin::modes(family).contains(&mode), "{family:?} {mode}");
                        let sent: Value = serde_json::from_str(&wire.body).unwrap();
                        assert_eq!(sent["tdMode"], mode, "{family:?}");
                    }
                    Err(_) => assert!(!margin::modes(family).contains(&mode), "{family:?} {mode}"),
                }
            }
            if family.has_algo_book() {
                let algo = AlgoSpec {
                    inst_id: "ETH-USDT-SWAP".into(), inst_type: family, side: Side::Sell, pos_side: None,
                    size: 1.0, trade_mode: None, reduce_only: family.is_derivative(), cancel_with_position: false,
                    client_id: None, kind: AlgoKind::Protection { take_profit: None, stop_loss: Some(2500.0) },
                };
                assert!(build(&Action::PlaceAlgo { algo }).is_err(), "{family:?}: an algo order states its mode too");
            }
        }
    }

    /// The vocabulary is one: every instrument type a strategy can name is a
    /// family the trading path knows, and back.
    #[test]
    fn every_instrument_type_is_a_family_and_back() {
        for inst_type in InstrumentType::ALL {
            assert_eq!(Family::of(inst_type).instrument_type(), inst_type);
            // Spelled the same on both sides of the boundary.
            assert_eq!(serde_json::to_value(Family::of(inst_type)).unwrap(), serde_json::to_value(inst_type).unwrap());
        }
        for family in FAMILIES {
            assert_eq!(Family::of(family.instrument_type()), family);
        }
    }

    /// OKX holds a leverage per position exactly where the backtest models
    /// one: an isolated regime, margin `notional / leverage`. A family that
    /// had one without the other would trade at a leverage nobody tested.
    #[test]
    fn leverage_is_held_where_the_regime_is_isolated() {
        for inst_type in InstrumentType::ALL {
            let family = Family::of(inst_type);
            assert_eq!(
                family.has_leverage(),
                inst_type.margin_regime() == crate::strategy::MarginRegime::Isolated,
                "{inst_type:?}");
        }
    }

    #[test]
    fn a_leg_is_named_only_where_okx_keeps_a_leverage_per_leg() {
        let set = |family: Family, mode: &str, leg: Option<PosSide>| Action::SetLeverage {
            inst_id: "ETH-USDT-SWAP".into(), family, margin_mode: mode.into(), pos_side: leg, leverage: 10.0,
        };
        for family in FAMILIES {
            for mode in ["cross", "isolated", "cash"] {
                for leg in [None, Some(PosSide::Net), Some(PosSide::Long), Some(PosSide::Short)] {
                    let built = build(&set(family, mode, leg));
                    let allowed = family.has_leverage()
                        && matches!(mode, "cross" | "isolated")
                        && !(mode == "cross" && matches!(leg, Some(PosSide::Long | PosSide::Short)));
                    assert_eq!(built.is_ok(), allowed, "{family:?} {mode} {leg:?}: {built:?}");
                    let Ok(wire) = built else { continue };
                    assert_eq!(wire.path, "/api/v5/account/set-leverage");
                    let sent: Value = serde_json::from_str(&wire.body).unwrap();
                    assert_eq!(sent["lever"], "10");
                    assert_eq!(sent["mgnMode"], mode);
                    // Isolated in long/short mode is per leg; everything else
                    // is the whole contract.
                    let named = mode == "isolated" && matches!(leg, Some(PosSide::Long | PosSide::Short));
                    assert_eq!(sent.get("posSide").is_some(), named, "{family:?} {mode} {leg:?}");
                }
            }
        }
        let fractional = Action::SetLeverage {
            inst_id: "ETH-USDT-SWAP".into(), family: Family::Swap, margin_mode: "isolated".into(),
            pos_side: Some(PosSide::Short), leverage: 2.5,
        };
        assert_eq!(body(&fractional)["lever"], "2.5");
        // Off the grid OKX echoes the value and holds a truncated one.
        for bad in [0.0, -3.0, f64::NAN, f64::INFINITY, 2.336, 2.005] {
            let mut action = fractional.clone();
            if let Action::SetLeverage { leverage, .. } = &mut action { *leverage = bad; }
            assert!(build(&action).is_err(), "{bad}");
        }
    }

    #[test]
    fn reduce_only_goes_where_okx_reads_it() {
        let cases = [
            (Family::Swap, Some(PosSide::Long), false),
            (Family::Swap, Some(PosSide::Short), false),
            (Family::Swap, Some(PosSide::Net), true),
            (Family::Swap, None, true),
            (Family::Option, None, true),
            (Family::Spot, None, false),
        ];
        for (family, leg, sent) in cases {
            let mut spec = order(family, OrderKind::Limit);
            spec.pos_side = leg;
            spec.reduce_only = true;
            let b = body(&Action::Place { order: spec });
            assert_eq!(b.get("reduceOnly").is_some(), sent, "{family:?} {leg:?}");
            if sent {
                assert_eq!(b["reduceOnly"], "true", "a string, as the CLI sent it");
            }
            // The leg is named on perpetuals only.
            assert_eq!(b.get("posSide").is_some(), family == Family::Swap && leg.is_some());
        }
    }

    #[test]
    fn prices_belong_to_priced_kinds_only() {
        assert_eq!(body(&Action::Place { order: order(Family::Swap, OrderKind::Limit) })["px"], "2653.2");
        let mut unpriced = order(Family::Swap, OrderKind::Limit);
        unpriced.price = None;
        assert!(build(&Action::Place { order: unpriced }).is_err());
        let mut priced_market = order(Family::Swap, OrderKind::Market);
        priced_market.price = Some(1.0);
        assert!(build(&Action::Place { order: priced_market }).is_err());
        for bad in [0.0, -1.0, f64::NAN, f64::INFINITY, 1e-12] {
            let mut spec = order(Family::Swap, OrderKind::Market);
            spec.size = bad;
            assert!(build(&Action::Place { order: spec }).is_err(), "size {bad}");
        }
    }

    #[test]
    fn spot_market_orders_say_which_currency_the_size_is_in() {
        let b = body(&Action::Place { order: order(Family::Spot, OrderKind::Market) });
        assert_eq!(b["tgtCcy"], "base_ccy");
        let mut quote = order(Family::Spot, OrderKind::Market);
        quote.size_in_quote = true;
        quote.side = Side::Buy;
        assert_eq!(body(&Action::Place { order: quote })["tgtCcy"], "quote_ccy");
        let mut swap_quote = order(Family::Swap, OrderKind::Market);
        swap_quote.size_in_quote = true;
        assert!(build(&Action::Place { order: swap_quote }).is_err());
        assert!(body(&Action::Place { order: order(Family::Spot, OrderKind::Limit) }).get("tgtCcy").is_none());
    }

    #[test]
    fn attached_protection_rides_in_attach_algo_ords() {
        let mut spec = order(Family::Swap, OrderKind::Market);
        spec.stop_trigger = Some(2500.0);
        spec.take_profit_trigger = Some(2900.0);
        let b = body(&Action::Place { order: spec });
        let attached = &b["attachAlgoOrds"][0];
        assert_eq!(attached["slTriggerPx"], "2500");
        assert_eq!(attached["slOrdPx"], "-1");
        assert_eq!(attached["tpTriggerPx"], "2900");
        assert_eq!(attached["tpOrdPx"], "-1");
        assert!(b.get("slTriggerPx").is_none(), "never flat on the order itself");
    }

    #[test]
    fn a_stop_and_a_target_together_are_oco() {
        let algo = |tp: Option<f64>, sl: Option<f64>| AlgoSpec {
            inst_id: "ETH-USDT-SWAP".into(), inst_type: Family::Swap, side: Side::Sell,
            pos_side: Some(PosSide::Long), size: 10.0, trade_mode: Some("isolated".into()),
            reduce_only: true, cancel_with_position: true, client_id: None,
            kind: AlgoKind::Protection { take_profit: tp, stop_loss: sl },
        };
        let both = body(&Action::PlaceAlgo { algo: algo(Some(2750.0), Some(2600.0)) });
        assert_eq!(both["ordType"], "oco");
        assert_eq!(both["tpOrdPx"], "-1");
        assert_eq!(both["slOrdPx"], "-1");
        assert_eq!(both["slTriggerPxType"], "last");
        assert_eq!(both["cxlOnClosePos"], "true");
        assert_eq!(both["reduceOnly"], "true", "cxlOnClosePos requires it");
        assert_eq!(both["posSide"], "long");
        assert_eq!(body(&Action::PlaceAlgo { algo: algo(None, Some(2600.0)) })["ordType"], "conditional");
        assert!(build(&Action::PlaceAlgo { algo: algo(None, None) }).is_err());
        let mut untied = algo(None, Some(2600.0));
        untied.reduce_only = false;
        assert!(build(&Action::PlaceAlgo { algo: untied }).is_err(), "tied to a position means reduce-only");
    }

    #[test]
    fn chase_is_a_perpetual_order_bounded_by_its_ratio() {
        let chase = |family: Family, ratio: f64| AlgoSpec {
            inst_id: "ETH-USDT-SWAP".into(), inst_type: family, side: Side::Sell,
            pos_side: Some(PosSide::Long), size: 10.0, trade_mode: Some("cross".into()),
            reduce_only: true, cancel_with_position: false, client_id: Some("ms1".into()),
            kind: AlgoKind::Chase { max_chase_ratio: ratio },
        };
        let b = body(&Action::PlaceAlgo { algo: chase(Family::Swap, 0.002) });
        assert_eq!(b["ordType"], "chase");
        assert_eq!(b["maxChaseType"], "ratio");
        assert_eq!(b["maxChaseVal"], "0.002");
        assert_eq!(b["chaseVal"], "0");
        assert_eq!(b["algoClOrdId"], "ms1");
        for bad in [0.0, -0.1, 0.11] {
            assert!(build(&Action::PlaceAlgo { algo: chase(Family::Swap, bad) }).is_err(), "{bad}");
        }
        assert!(build(&Action::PlaceAlgo { algo: chase(Family::Spot, 0.002) }).is_err());
        assert!(build(&Action::PlaceAlgo { algo: chase(Family::Option, 0.002) }).is_err());
    }

    #[test]
    fn cancels_and_amends_name_their_order() {
        let cancel = build(&Action::Cancel { inst_id: "ETH-USDT-SWAP".into(), order_id: "123".into() }).unwrap();
        assert_eq!(cancel.path, "/api/v5/trade/cancel-order");
        let algos = body(&Action::CancelAlgo { inst_id: "ETH-USDT-SWAP".into(), algo_id: "9".into() });
        assert_eq!(algos, json!([{"instId": "ETH-USDT-SWAP", "algoId": "9"}]), "an array, as the endpoint takes it");
        let amend = body(&Action::AmendStop { inst_id: "ETH-USDT-SWAP".into(), algo_id: "9".into(), stop: 2610.5 });
        assert_eq!(amend["newSlTriggerPx"], "2610.5");
        assert_eq!(amend["newSlOrdPx"], "-1");
        assert!(build(&Action::Cancel { inst_id: "ETH-USDT-SWAP".into(), order_id: " ".into() }).is_err());
    }

    /// `Endpoint::ALL` names every endpoint once: the match below stops
    /// compiling when one is added, and an ordinal past the list fails.
    #[test]
    fn every_endpoint_is_listed_once() {
        fn ordinal(endpoint: Endpoint) -> usize {
            match endpoint {
                Endpoint::PlaceOrder => 0,
                Endpoint::PlaceAlgo => 1,
                Endpoint::CancelOrder => 2,
                Endpoint::CancelAlgos => 3,
                Endpoint::AmendAlgos => 4,
                Endpoint::OrderPrecheck => 5,
                Endpoint::SetLeverage => 6,
            }
        }
        let mut seen = [false; Endpoint::ALL.len()];
        for endpoint in Endpoint::ALL {
            assert!(!std::mem::replace(&mut seen[ordinal(endpoint)], true), "{endpoint:?} twice");
        }
        assert!(seen.iter().all(|s| *s));
    }

    #[test]
    fn every_endpoint_acts_but_the_exchanges_own_check() {
        for endpoint in Endpoint::ALL {
            assert_eq!(endpoint.path(), endpoint.route().path());
            assert_eq!(endpoint.changes_state(), endpoint != Endpoint::OrderPrecheck, "{endpoint:?}");
        }
    }

    #[test]
    fn actions_round_trip_through_json() {
        let action = Action::PlaceAlgo { algo: AlgoSpec {
            inst_id: "ETH-USDT-SWAP".into(), inst_type: Family::Swap, side: Side::Buy,
            pos_side: Some(PosSide::Short), size: 0.01, trade_mode: Some("cross".into()),
            reduce_only: true, cancel_with_position: true, client_id: Some("ms2".into()),
            kind: AlgoKind::Protection { take_profit: Some(81096.85), stop_loss: Some(86113.15) },
        }};
        let text = serde_json::to_string(&action).unwrap();
        assert_eq!(serde_json::from_str::<Action>(&text).unwrap(), action);
    }
}
