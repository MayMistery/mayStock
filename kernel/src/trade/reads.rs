//! What the trading path reads back: the orders working on the account, one
//! order's fate, and the fees an order will pay. Signed GETs, each to a path
//! named here and nowhere else, parsed here.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::route::{Route, Target};
use super::wire::Family;

/// Everything the kernel reads for the trading path. Closed, like `Action`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "read", rename_all = "camelCase")]
pub enum Read {
    /// Working orders on both books, for the families given (all of them when
    /// empty), narrowed to one instrument when `inst_id` is set.
    #[serde(rename_all = "camelCase")]
    WorkingOrders {
        #[serde(default)]
        families: Vec<Family>,
        #[serde(default)]
        inst_id: Option<String>,
    },
    /// The stops and targets armed — `conditional` and `oco` orders, one
    /// listing: on one instrument for the runner's trailing stop, or on the
    /// whole account for the live layer.
    #[serde(rename_all = "camelCase")]
    Protection {
        #[serde(default)]
        family: Option<Family>,
        #[serde(default)]
        inst_id: Option<String>,
    },
    /// One order, by the client id it was sent with.
    #[serde(rename_all = "camelCase")]
    OrderStatus { inst_id: String, client_id: String },
    /// The account's open positions, as OKX's own document — for one family
    /// when named. Parsed by `live::okx::positions_in`, the one reader.
    #[serde(rename_all = "camelCase")]
    Positions {
        #[serde(default)]
        family: Option<Family>,
    },
    /// The trading account's balances, as OKX's own document — for one
    /// currency when named. What can be sold is its `availBal`.
    #[serde(rename_all = "camelCase")]
    Balance {
        #[serde(default)]
        ccy: Option<String>,
    },
    /// The whole account: the trading account, the funding account and the
    /// USD valuation, read together as `okx account balance-all
    /// --no-aggregate --valuationCcy USD` reads them.
    AccountSnapshot,
    /// The account's position mode and level (`posMode`, `acctLv`).
    AccountConfig,
    /// The last three days' fills on one family, newest first.
    #[serde(rename_all = "camelCase")]
    Fills {
        family: Family,
        #[serde(default)]
        inst_id: Option<String>,
    },
    /// Funding settled on perpetuals: bill type 8, asked for by type so a
    /// busy week of trades cannot push it off the page.
    FundingBills,
    /// The account's fee rates: for one instrument, or — without `inst_id` —
    /// the family's standard rates.
    #[serde(rename_all = "camelCase")]
    FeeRates {
        family: Family,
        #[serde(default)]
        inst_id: Option<String>,
        /// The instrument's fee group (`groupId` in its specification).
        #[serde(default)]
        group_id: Option<String>,
    },
}

/// The kinds of algo order OKX keeps, as its listing must be asked for them.
///
/// The listing takes one kind per request, with one documented exception:
/// `conditional,oco` together. Asking for a kind the list omits, or a pair
/// it does not accept, is refused (`51000 Parameter ordType error`, measured
/// 2026-09-25 for `conditional,oco,chase`) — so this list is the whole algo
/// book, and a kind OKX adds is invisible until it is added here.
pub const ALGO_LISTINGS: [&str; 6] = [PROTECTION_LISTING, "trigger", "move_order_stop", "chase", "iceberg", "twap"];

/// The algo kinds that protect a position: a stop, a target, or both.
pub const PROTECTION_LISTING: &str = "conditional,oco";

/// The families whose books are listed when none is named: every family
/// this app trades on OKX.
pub const LISTED_FAMILIES: [Family; 3] = [Family::Spot, Family::Swap, Family::Option];

/// The largest page each listing returns.
pub const PAGE: usize = 100;

/// One page request of the working-order listing.
#[derive(Debug, Clone, PartialEq)]
pub struct Listing {
    pub label: String,
    pub book: Book,
    /// The first page's request; later pages add the cursor.
    pub target: Target,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Book {
    Order,
    Algo,
}

impl Book {
    pub fn id_field(self) -> &'static str {
        match self {
            Book::Order => "ordId",
            Book::Algo => "algoId",
        }
    }
}

fn family_name(family: Family) -> &'static str {
    match family {
        Family::Spot => "现货",
        Family::Swap => "永续",
        Family::Option => "期权",
        Family::Stock => "股票",
    }
}

fn family_code(family: Family) -> &'static str {
    match family {
        Family::Spot => "SPOT",
        Family::Swap => "SWAP",
        Family::Option => "OPTION",
        Family::Stock => "STOCK",
    }
}

/// Every request the listing makes. A family without an algo book is not
/// asked for one: there is nothing there to miss.
pub fn listings(families: &[Family], inst_id: Option<&str>) -> Result<Vec<Listing>, String> {
    let families: Vec<Family> = if families.is_empty() { LISTED_FAMILIES.to_vec() } else { families.to_vec() };
    let scope = inst_id.filter(|i| !i.is_empty()).map(|i| format!("&instId={i}")).unwrap_or_default();
    let mut out = Vec::new();
    for family in families {
        if family == Family::Stock {
            return Err("OKX 不交易股票".into());
        }
        let code = family_code(family);
        out.push(Listing {
            label: format!("{}普通委托", family_name(family)),
            book: Book::Order,
            target: Target::new(Route::OrdersPending, format!("instType={code}{scope}&limit={PAGE}")),
        });
        if family.has_algo_book() {
            for kind in ALGO_LISTINGS {
                out.push(Listing {
                    label: format!("{}{}", family_name(family), algo_name(kind)),
                    book: Book::Algo,
                    target: Target::new(Route::AlgoOrdersPending, format!("ordType={kind}&instType={code}{scope}&limit={PAGE}")),
                });
            }
        }
    }
    Ok(out)
}

/// The one listing that holds a position's stops and targets.
/// The one listing that holds stops and targets: for a family, an
/// instrument, or — naming neither — the whole account.
pub fn protection_listing(family: Option<Family>, inst_id: Option<&str>) -> Result<Listing, String> {
    let mut query = format!("ordType={PROTECTION_LISTING}");
    if let Some(family) = family {
        if !family.has_algo_book() {
            return Err(format!("{}没有策略委托簿", family_name(family)));
        }
        query += &format!("&instType={}", family_code(family));
    }
    if let Some(inst_id) = inst_id {
        if inst_id.trim().is_empty() {
            return Err("instId 是空的".into());
        }
        query += &format!("&instId={inst_id}");
    }
    Ok(Listing {
        label: format!("{}{}", family.map(family_name).unwrap_or(""), algo_name(PROTECTION_LISTING)),
        book: Book::Algo,
        target: Target::new(Route::AlgoOrdersPending, format!("{query}&limit={PAGE}")),
    })
}

fn algo_name(kind: &str) -> &'static str {
    match kind {
        "conditional,oco" => "止盈止损与 OCO",
        "trigger" => "计划委托",
        "move_order_stop" => "移动止损",
        "chase" => "追单",
        "iceberg" => "冰山",
        "twap" => "TWAP",
        _ => "策略委托",
    }
}

/// An order on the account, whoever placed it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkingOrder {
    /// `ordId`, or `algoId` on the algo book.
    pub id: String,
    pub book: Book,
    pub inst_id: String,
    #[serde(default)]
    pub inst_type: String,
    pub ord_type: String,
    pub side: String,
    #[serde(default)]
    pub pos_side: Option<String>,
    /// The price it rests at, or fills at once triggered. None is market.
    #[serde(default)]
    pub price: Option<f64>,
    /// The level an algo order waits for: its own trigger, or its single
    /// leg's when it has just one.
    #[serde(default)]
    pub trigger_price: Option<f64>,
    #[serde(default)]
    pub stop_trigger_price: Option<f64>,
    #[serde(default)]
    pub take_profit_trigger_price: Option<f64>,
    /// None when sized as a share of the position instead.
    #[serde(default)]
    pub size: Option<f64>,
    #[serde(default)]
    pub close_fraction: Option<f64>,
    #[serde(default)]
    pub filled_size: f64,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub reduce_only: bool,
    #[serde(default)]
    pub client_id: Option<String>,
    #[serde(default)]
    pub created_ms: Option<i64>,
}

/// States in which an order is still working. The pending listings return
/// nothing else, but a finished order must never be shown as armed, so it
/// is checked rather than assumed.
pub const OPEN_STATES: [&str; 5] = ["live", "partially_filled", "effective", "partially_effective", "pause"];

fn num(row: &Value, key: &str) -> Option<f64> {
    match row.get(key)? {
        Value::String(text) if !text.is_empty() => text.parse::<f64>().ok().filter(|v| v.is_finite()),
        Value::Number(number) => number.as_f64(),
        _ => None,
    }
}

fn text(row: &Value, key: &str) -> Option<String> {
    row.get(key).and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string)
}

fn flag(row: &Value, key: &str) -> bool {
    match row.get(key) {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(t)) => t == "true",
        _ => false,
    }
}

/// The rows of one listing page, and the id of the last row for paging.
pub fn parse_page(body: &str, book: Book) -> Result<(Vec<WorkingOrder>, usize, Option<String>), String> {
    let value = envelope(body)?;
    let rows = value.get("data").and_then(Value::as_array).cloned().unwrap_or_default();
    let count = rows.len();
    let last_id = rows.last().and_then(|r| text(r, book.id_field()));
    let mut out = Vec::new();
    for row in &rows {
        let (Some(id), Some(inst_id), Some(side)) = (text(row, book.id_field()), text(row, "instId"), text(row, "side")) else {
            continue;
        };
        if side != "buy" && side != "sell" {
            continue;
        }
        let state = text(row, "state").unwrap_or_default();
        if !state.is_empty() && !OPEN_STATES.contains(&state.as_str()) {
            continue;
        }
        let stop = num(row, "slTriggerPx");
        let target = num(row, "tpTriggerPx");
        // A leg priced at -1 fills at market; only a real level is a price.
        let leg_price = [num(row, "tpOrdPx"), num(row, "slOrdPx")].into_iter().flatten().find(|p| *p > 0.0);
        let price = num(row, "px").filter(|p| *p > 0.0).or(num(row, "orderPx").filter(|p| *p > 0.0)).or(leg_price);
        let trigger = num(row, "triggerPx")
            .or(num(row, "moveTriggerPx"))
            .or(if stop.is_some() && target.is_some() { None } else { stop.or(target) });
        out.push(WorkingOrder {
            id,
            book,
            inst_id,
            inst_type: text(row, "instType").unwrap_or_default(),
            ord_type: text(row, "ordType").unwrap_or_default(),
            side,
            pos_side: text(row, "posSide"),
            price,
            trigger_price: trigger,
            stop_trigger_price: stop,
            take_profit_trigger_price: target,
            size: num(row, "sz").filter(|s| *s > 0.0),
            close_fraction: num(row, "closeFraction").filter(|f| *f > 0.0),
            filled_size: num(row, "accFillSz").or(num(row, "fillSz")).or(num(row, "actualSz")).unwrap_or(0.0),
            state,
            reduce_only: flag(row, "reduceOnly"),
            client_id: text(row, "clOrdId").or(text(row, "algoClOrdId")),
            created_ms: num(row, "cTime").map(|v| v as i64),
        });
    }
    Ok((out, count, last_id))
}

/// What the account's working orders could and could not be read as.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkingOrders {
    pub orders: Vec<WorkingOrder>,
    /// Listings that could not be read, so an empty list is never mistaken
    /// for "nothing armed" on a book that could not be asked.
    pub unavailable: Vec<String>,
}

impl WorkingOrders {
    /// Newest first, each order once.
    pub fn finish(mut self) -> WorkingOrders {
        let mut seen = std::collections::HashSet::new();
        self.orders.retain(|o| seen.insert((o.book, o.id.clone())));
        self.orders.sort_by(|a, b| b.created_ms.cmp(&a.created_ms).then_with(|| a.id.cmp(&b.id)));
        self.unavailable.sort();
        self
    }
}

/// An order's fate, as the runner needs it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum OrderStatus {
    /// The exchange has no such order: it never arrived, so resending is safe.
    Unknown,
    Live,
    Canceled,
    #[serde(rename_all = "camelCase")]
    Filled { filled_size: f64, average_price: f64 },
}

/// OKX's answer for an order that does not exist.
pub const ORDER_DOES_NOT_EXIST: &str = "51603";

pub fn parse_order_status(body: &str, client_id: &str) -> Result<OrderStatus, String> {
    let value: Value = serde_json::from_str(body).map_err(|_| format!("订单查询回复不是 JSON：{}", head(body)))?;
    let code = value.get("code").and_then(Value::as_str).unwrap_or("");
    if code == ORDER_DOES_NOT_EXIST {
        return Ok(OrderStatus::Unknown);
    }
    if code != "0" {
        return Err(refusal(&value, body));
    }
    let Some(row) = value.get("data").and_then(Value::as_array).and_then(|rows| {
        rows.iter().find(|r| r.get("clOrdId").and_then(Value::as_str) == Some(client_id))
    }) else {
        return Ok(OrderStatus::Unknown);
    };
    let filled = num(row, "accFillSz").or(num(row, "fillSz")).unwrap_or(0.0);
    let average = num(row, "avgPx").or(num(row, "fillPx")).unwrap_or(0.0);
    Ok(match text(row, "state").as_deref().unwrap_or("") {
        "filled" | "partially_filled" => OrderStatus::Filled { filled_size: filled, average_price: average },
        // A cancel after a partial fill still left something held.
        "canceled" | "mmp_canceled" if filled > 0.0 => OrderStatus::Filled { filled_size: filled, average_price: average },
        "canceled" | "mmp_canceled" => OrderStatus::Canceled,
        "live" => OrderStatus::Live,
        _ if filled > 0.0 => OrderStatus::Filled { filled_size: filled, average_price: average },
        _ => OrderStatus::Live,
    })
}

pub fn positions_target(family: Option<Family>) -> Result<Target, String> {
    match family {
        None => Ok(Target::bare(Route::Positions)),
        Some(Family::Stock) => Err("OKX 不交易股票".into()),
        Some(Family::Spot) => Err("现货没有持仓，只有余额".into()),
        Some(family) => Ok(Target::new(Route::Positions, format!("instType={}", family_code(family)))),
    }
}

pub fn balance_target(ccy: Option<&str>) -> Result<Target, String> {
    match ccy.map(str::trim).filter(|c| !c.is_empty()) {
        None => Ok(Target::bare(Route::Balance)),
        Some(ccy) if ccy.bytes().all(|b| b.is_ascii_alphanumeric()) => Ok(Target::new(Route::Balance, format!("ccy={}", ccy.to_ascii_uppercase()))),
        Some(ccy) => Err(format!("币种 {ccy:?} 不合法")),
    }
}

pub fn account_config_target() -> Target {
    Target::bare(Route::AccountConfig)
}

/// The account snapshot's three sections: trading balance, funding balance,
/// and the whole account valued in USD.
pub fn snapshot_targets() -> [Target; 3] {
    [Target::bare(Route::Balance), Target::bare(Route::AssetBalances), Target::new(Route::AssetValuation, "ccy=USD")]
}

/// Funding payments are asked for by their bill type, not filtered from a
/// page of every bill.
pub fn funding_bills_target() -> Target {
    Target::new(Route::Bills, "instType=SWAP&type=8&limit=100")
}

pub fn fills_target(family: Family, inst_id: Option<&str>) -> Result<Target, String> {
    if family == Family::Stock {
        return Err("OKX 不交易股票".into());
    }
    let scope = inst_id.filter(|i| !i.is_empty()).map(|i| format!("&instId={i}")).unwrap_or_default();
    Ok(Target::new(Route::Fills, format!("instType={}{scope}&limit={PAGE}", family_code(family))))
}

/// One section of the account snapshot: the rows read, or why not.
pub enum Section {
    Read(Value),
    Failed(String),
}

/// The account as the CLI's `balance-all` lays it out — trading, funding and
/// valuation side by side — so the one reader of those fields
/// (`live::okx::balances_in`, `total_equity_in`) reads it unchanged. A
/// section that failed is marked unavailable with why; both balance
/// sections failing is a failed read, as it is there.
pub fn account_snapshot(trading: Section, funding: Section, valuation: Section) -> Result<Value, String> {
    let error = |why: &str| serde_json::json!({"available": false, "error": {"msg": why}});
    if let (Section::Failed(a), Section::Failed(b)) = (&trading, &funding) {
        return Err(format!("交易账户与资金账户都读不到：{a}；{b}"));
    }
    let first = |data: &Value| data.get("data").and_then(Value::as_array).and_then(|rows| rows.first()).cloned();
    let rows = |data: &Value| data.get("data").cloned().unwrap_or(Value::Array(Vec::new()));
    let trading = match trading {
        Section::Read(document) => {
            let mut section = first(&document).unwrap_or_else(|| serde_json::json!({}));
            if let Some(object) = section.as_object_mut() {
                object.insert("available".into(), Value::Bool(true));
            }
            section
        }
        Section::Failed(why) => error(&why),
    };
    let funding = match funding {
        Section::Read(document) => serde_json::json!({"available": true, "details": rows(&document)}),
        Section::Failed(why) => error(&why),
    };
    let valuation = match valuation {
        Section::Read(document) => serde_json::json!({
            "available": true, "valuationCcy": "USD",
            "totalBal": first(&document).and_then(|row| row.get("totalBal").cloned()).unwrap_or(Value::String("0".into())),
            "details": rows(&document),
        }),
        Section::Failed(why) => error(&why),
    };
    Ok(serde_json::json!({"trading": trading, "funding": funding, "valuation": valuation}))
}

/// A document read whole, its envelope checked.
pub fn document(body: &str) -> Result<Value, String> {
    envelope(body)
}

pub fn order_status_target(inst_id: &str, client_id: &str) -> Result<Target, String> {
    if inst_id.trim().is_empty() || client_id.trim().is_empty() {
        return Err("查单需要 instId 和 clOrdId".into());
    }
    Ok(Target::new(Route::Order, format!("instId={inst_id}&clOrdId={client_id}")))
}

/// Fee rates as fractions of notional, positive when charged and negative
/// when rebated — the opposite of OKX's own sign.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeeRates {
    pub maker: f64,
    pub taker: f64,
}

pub fn fee_target(family: Family, inst_id: Option<&str>) -> Result<Target, String> {
    let base = Target::new(Route::TradeFee, format!("instType={}", family_code(family)));
    let Some(inst_id) = inst_id.filter(|i| !i.is_empty()) else {
        return match family {
            Family::Stock => Err("OKX 不交易股票".into()),
            _ => Ok(base),
        };
    };
    match family {
        Family::Spot => Ok(base.and("instId", inst_id)),
        Family::Swap | Family::Option => {
            let parts: Vec<&str> = inst_id.split('-').collect();
            let family_id = parts.get(..2).map(|p| p.join("-")).ok_or_else(|| format!("{inst_id} 读不出品种族"))?;
            Ok(base.and("instFamily", &family_id))
        }
        Family::Stock => Err("OKX 不交易股票".into()),
    }
}

/// Read the account's rates.
///
/// Fees are charged by group, and spot groups differ tenfold (measured
/// 2026-09-25 on the live account: 0.08% taker in group 1, 0.32% in group
/// 5). So an instrument is charged its own group's rates — named from its
/// specification, or the only group listed — and a group that is named but
/// not listed is an error, never a guess. Without an instrument, the
/// family's standard rates are the top-level fields (`maker`/`taker`, or
/// `makerU`/`takerU` for USDT-margined contracts).
pub fn parse_fee_rates(body: &str, group_id: Option<&str>) -> Result<FeeRates, String> {
    let value = envelope(body)?;
    let row = value.get("data").and_then(Value::as_array).and_then(|r| r.first()).ok_or("手续费率回复是空的")?;
    let groups = row.get("feeGroup").and_then(Value::as_array).cloned().unwrap_or_default();
    let pair = |source: &Value, maker: &str, taker: &str| Some((num(source, maker)?, num(source, taker)?));
    let (maker, taker) = match group_id.filter(|g| !g.is_empty()) {
        Some(id) => groups
            .iter()
            .find(|g| g.get("groupId").and_then(Value::as_str) == Some(id))
            .and_then(|g| pair(g, "maker", "taker"))
            .ok_or_else(|| format!("手续费率回复里没有第 {id} 组"))?,
        None if groups.len() == 1 => pair(&groups[0], "maker", "taker").ok_or("手续费率回复里没有费率")?,
        None => pair(row, "maker", "taker")
            .or_else(|| pair(row, "makerU", "takerU"))
            .ok_or("手续费率回复里没有费率")?,
    };
    Ok(FeeRates { maker: -maker, taker: -taker })
}

fn envelope(body: &str) -> Result<Value, String> {
    let value: Value = serde_json::from_str(body).map_err(|_| format!("回复不是 JSON：{}", head(body)))?;
    if value.get("code").and_then(Value::as_str) != Some("0") {
        return Err(refusal(&value, body));
    }
    Ok(value)
}

fn refusal(value: &Value, body: &str) -> String {
    let code = value.get("code").and_then(Value::as_str).unwrap_or("?");
    let message = value.get("msg").and_then(Value::as_str).filter(|m| !m.is_empty()).map(str::to_string).unwrap_or_else(|| head(body));
    format!("OKX {code}：{message}")
}

fn head(body: &str) -> String {
    body.chars().take(200).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_listing_asks_every_book_of_every_family() {
        let all = listings(&[], None).unwrap();
        // Three order books, and six algo listings on each family that has
        // an algo book.
        assert_eq!(all.len(), 3 + 6 * 2);
        assert!(all.iter().all(|l| l.target.path_and_query().starts_with("/api/v5/trade/")));
        assert!(!all.iter().any(|l| l.target.query.contains("instType=OPTION") && l.book == Book::Algo), "options have no algo book");
        let one = listings(&[Family::Swap], Some("ETH-USDT-SWAP")).unwrap();
        assert!(one.iter().all(|l| l.target.query.contains("&instId=ETH-USDT-SWAP") && l.target.query.contains("instType=SWAP")));
        assert!(one.iter().any(|l| l.target.query.contains("ordType=conditional,oco")));
        assert!(listings(&[Family::Stock], None).is_err());
        let protection = protection_listing(Some(Family::Swap), Some("ETH-USDT-SWAP")).unwrap();
        assert_eq!(protection.target.path_and_query(), "/api/v5/trade/orders-algo-pending?ordType=conditional,oco&instType=SWAP&instId=ETH-USDT-SWAP&limit=100");
        assert!(all.iter().any(|l| l.target.path_and_query() == protection.target.path_and_query().replace("&instId=ETH-USDT-SWAP", "")), "the same listing the full read asks");
        assert!(protection_listing(Some(Family::Option), Some("ETH-USD-261009-2750-P")).is_err());
        assert_eq!(protection_listing(None, None).unwrap().target.path_and_query(),
                   "/api/v5/trade/orders-algo-pending?ordType=conditional,oco&limit=100", "the whole account's");
        assert!(protection_listing(Some(Family::Swap), Some(" ")).is_err());
    }

    #[test]
    fn reads_working_orders_on_both_books() {
        let orders = r#"{"code":"0","msg":"","data":[
            {"ordId":"11","clOrdId":"ms1","instId":"ETH-USDT-SWAP","instType":"SWAP","ordType":"limit","side":"sell","posSide":"long","px":"2700.5","sz":"10","accFillSz":"2","state":"partially_filled","reduceOnly":"false","cTime":"1790000000000"},
            {"ordId":"12","instId":"ETH-USDT-SWAP","ordType":"limit","side":"sell","px":"2701","sz":"1","state":"filled"}]}"#;
        let (rows, count, last) = parse_page(orders, Book::Order).unwrap();
        assert_eq!(count, 2, "the page's size counts every row, for paging");
        assert_eq!(last.as_deref(), Some("12"));
        assert_eq!(rows.len(), 1, "a finished order is never listed as working");
        let order = &rows[0];
        assert_eq!((order.id.as_str(), order.price, order.size, order.filled_size), ("11", Some(2700.5), Some(10.0), 2.0));
        assert_eq!(order.client_id.as_deref(), Some("ms1"));
        assert_eq!(order.pos_side.as_deref(), Some("long"));

        let algos = r#"{"code":"0","data":[
            {"algoId":"9","instId":"ETH-USDT-SWAP","ordType":"oco","side":"sell","posSide":"long","sz":"10","tpTriggerPx":"2800","tpOrdPx":"-1","slTriggerPx":"2600","slOrdPx":"-1","state":"live","reduceOnly":"true"},
            {"algoId":"10","instId":"ETH-USDT-SWAP","ordType":"conditional","side":"sell","sz":"","closeFraction":"1","slTriggerPx":"2600","slOrdPx":"-1","state":"live"}]}"#;
        let (rows, _, _) = parse_page(algos, Book::Algo).unwrap();
        assert_eq!(rows[0].price, None, "a leg at -1 fills at market");
        assert_eq!(rows[0].trigger_price, None, "two legs have no single trigger");
        assert_eq!((rows[0].stop_trigger_price, rows[0].take_profit_trigger_price), (Some(2600.0), Some(2800.0)));
        assert!(rows[0].reduce_only);
        assert_eq!((rows[1].size, rows[1].close_fraction, rows[1].trigger_price), (None, Some(1.0), Some(2600.0)));
        assert!(parse_page(r#"{"code":"51000","msg":"Parameter ordType error","data":[]}"#, Book::Algo).is_err());
    }

    #[test]
    fn account_documents_are_read_from_their_own_paths() {
        assert_eq!(positions_target(None).unwrap().path_and_query(), "/api/v5/account/positions");
        assert_eq!(positions_target(Some(Family::Option)).unwrap().path_and_query(), "/api/v5/account/positions?instType=OPTION");
        assert!(positions_target(Some(Family::Spot)).is_err());
        assert_eq!(balance_target(Some("eth")).unwrap().path_and_query(), "/api/v5/account/balance?ccy=ETH");
        assert_eq!(balance_target(Some(" ")).unwrap().path_and_query(), "/api/v5/account/balance");
        assert!(balance_target(Some("ETH&x=1")).is_err(), "nothing but a currency reaches the query");
        assert!(document(r#"{"code":"50113","msg":"Invalid Sign","data":[]}"#).is_err());
    }

    #[test]
    fn the_account_snapshot_is_laid_out_as_the_cli_lays_it_out() {
        let trading = Section::Read(serde_json::json!({"code":"0","data":[{"totalEq":"6500.5","adjEq":"6400","details":[{"ccy":"USDT","availBal":"100","cashBal":"100"}]}]}));
        let funding = Section::Read(serde_json::json!({"code":"0","data":[{"ccy":"ETH","availBal":"0.5","bal":"0.5"}]}));
        let valuation = Section::Failed("OKX 50011：Too Many Requests".into());
        let document = account_snapshot(trading, funding, valuation).unwrap();
        assert_eq!(document["trading"]["totalEq"], "6500.5");
        assert_eq!(document["trading"]["available"], true);
        assert_eq!(document["trading"]["details"][0]["ccy"], "USDT");
        assert_eq!(document["funding"]["details"][0]["ccy"], "ETH");
        assert_eq!(document["valuation"]["available"], false, "a failed section is named, not dropped");
        // The one reader reads it: equity from the trading account, both
        // accounts' coins.
        assert_eq!(crate::live::okx_total_equity_in(&document), Some(6500.5));
        let coins: Vec<String> = crate::live::okx_balances_in(&document).into_iter().map(|b| b.ccy).collect();
        assert!(coins.contains(&"USDT".to_string()) && coins.contains(&"ETH".to_string()), "{coins:?}");
        assert!(account_snapshot(Section::Failed("a".into()), Section::Failed("b".into()), Section::Failed("c".into())).is_err());
        assert_eq!(fills_target(Family::Swap, Some("ETH-USDT-SWAP")).unwrap().path_and_query(), "/api/v5/trade/fills?instType=SWAP&instId=ETH-USDT-SWAP&limit=100");
        assert_eq!(funding_bills_target().path_and_query(), "/api/v5/account/bills?instType=SWAP&type=8&limit=100");
    }

    #[test]
    fn an_order_the_exchange_never_saw_is_unknown() {
        assert_eq!(parse_order_status(r#"{"code":"51603","msg":"Order does not exist","data":[]}"#, "ms1").unwrap(), OrderStatus::Unknown);
        let row = |state: &str, filled: &str| format!(r#"{{"code":"0","data":[{{"clOrdId":"ms1","state":"{state}","accFillSz":"{filled}","avgPx":"2700"}}]}}"#);
        assert_eq!(parse_order_status(&row("live", "0"), "ms1").unwrap(), OrderStatus::Live);
        assert_eq!(parse_order_status(&row("canceled", "0"), "ms1").unwrap(), OrderStatus::Canceled);
        assert_eq!(parse_order_status(&row("canceled", "3"), "ms1").unwrap(), OrderStatus::Filled { filled_size: 3.0, average_price: 2700.0 });
        assert_eq!(parse_order_status(&row("filled", "10"), "ms1").unwrap(), OrderStatus::Filled { filled_size: 10.0, average_price: 2700.0 });
        assert_eq!(parse_order_status(&row("filled", "10"), "ms2").unwrap(), OrderStatus::Unknown, "someone else's order is not this one");
        assert!(parse_order_status(r#"{"code":"50113","msg":"Invalid Sign","data":[]}"#, "ms1").is_err(), "a refusal to answer is not an answer");
    }

    #[test]
    fn fee_rates_come_from_the_instruments_group() {
        // Recorded from the live account, 2026-09-25.
        let swap = r#"{"code":"0","data":[{"feeGroup":[{"groupId":"4","maker":"-0.00016","taker":"-0.00045"}],"instType":"SWAP","level":"VIP1","maker":"","makerU":"-0.00016","taker":"","takerU":"-0.00045"}],"msg":""}"#;
        assert_eq!(parse_fee_rates(swap, Some("4")).unwrap(), FeeRates { maker: 0.00016, taker: 0.00045 });
        assert_eq!(parse_fee_rates(swap, None).unwrap(), FeeRates { maker: 0.00016, taker: 0.00045 }, "the only group");
        let two_groups = r#"{"code":"0","data":[{"feeGroup":[{"groupId":"1","maker":"-0.0002","taker":"-0.0005"},{"groupId":"2","maker":"0.00005","taker":"-0.0004"}],"maker":"","taker":""}]}"#;
        assert_eq!(parse_fee_rates(two_groups, Some("2")).unwrap(), FeeRates { maker: -0.00005, taker: 0.0004 }, "a rebate reads negative");
        assert!(parse_fee_rates(two_groups, None).is_err(), "two groups, none named, no family rates: no guess");
        assert!(parse_fee_rates(two_groups, Some("9")).is_err(), "a named group that is not listed: no guess");
        // A family read: the standard rates are top-level, beside the groups.
        let family = r#"{"code":"0","data":[{"feeGroup":[{"groupId":"1","maker":"-0.000675","taker":"-0.0008"},{"groupId":"5","maker":"-0.0007","taker":"-0.0032"}],"maker":"-0.000675","taker":"-0.0008","makerU":"","takerU":""}]}"#;
        assert_eq!(parse_fee_rates(family, None).unwrap(), FeeRates { maker: 0.000675, taker: 0.0008 });
        assert_eq!(parse_fee_rates(family, Some("5")).unwrap(), FeeRates { maker: 0.0007, taker: 0.0032 });
        let legacy = r#"{"code":"0","data":[{"maker":"-0.0008","taker":"-0.001"}]}"#;
        assert_eq!(parse_fee_rates(legacy, None).unwrap(), FeeRates { maker: 0.0008, taker: 0.001 });
        assert_eq!(fee_target(Family::Swap, Some("ETH-USDT-SWAP")).unwrap().path_and_query(), "/api/v5/account/trade-fee?instType=SWAP&instFamily=ETH-USDT");
        assert_eq!(fee_target(Family::Option, Some("ETH-USD-261009-2750-P")).unwrap().path_and_query(), "/api/v5/account/trade-fee?instType=OPTION&instFamily=ETH-USD");
        assert_eq!(fee_target(Family::Spot, Some("ETH-USDT")).unwrap().path_and_query(), "/api/v5/account/trade-fee?instType=SPOT&instId=ETH-USDT");
        assert_eq!(fee_target(Family::Spot, None).unwrap().path_and_query(), "/api/v5/account/trade-fee?instType=SPOT");
        assert!(fee_target(Family::Stock, None).is_err());
    }
}
