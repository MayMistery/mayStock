//! Closing a holding by hand: what someone asked for, turned into the one
//! order that does it — or the reason it cannot be done.
//!
//! Pure. The same holding, book and request always give the same plan, and
//! the plan carries the `Action` that is sent, the request body it becomes,
//! and every word of the confirmation, built from that one action. What the
//! person approves is what goes out.
//!
//! Prices come from the book the ticket shows (`live::book`), the way the
//! best exchanges offer them (Binance's `priceMatch`): the counterparty's Nth
//! level, which fills against that many levels at once, or the Nth level on
//! the order's own side, which joins the queue. Also the mid, the last trade,
//! or a typed price. OKX has no server-side price match, so the level is
//! resolved here, from the book as published, and the confirmation says which
//! book it was read from.

use serde::{Deserialize, Serialize};

use super::reads::{FeeRates, WorkingOrder};
use super::wire::{self, Action, AlgoKind, AlgoSpec, Family, OrderKind, OrderSpec, PosSide, Side, WireRequest};
use crate::live::book::{Px, Spec, PUBLISHED_DEPTH};

// MARK: - What can be done

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Venue {
    Okx,
    Schwab,
}

impl Venue {
    pub fn name(self) -> &'static str {
        match self {
            Venue::Okx => "OKX",
            Venue::Schwab => "嘉信",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Method {
    Market,
    Limit,
    Chase,
    Protect,
}

impl Method {
    pub const ALL: [Method; 4] = [Method::Limit, Method::Chase, Method::Market, Method::Protect];

    pub fn name(self) -> &'static str {
        match self {
            Method::Market => "市价",
            Method::Limit => "限价",
            Method::Chase => "追逐限价",
            Method::Protect => "止盈止损",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Availability {
    pub available: bool,
    /// Why not, shown on the control — never hidden.
    pub reason: Option<String>,
}

impl Availability {
    fn yes() -> Availability {
        Availability { available: true, reason: None }
    }
    fn no(reason: &str) -> Availability {
        Availability { available: false, reason: Some(reason.to_string()) }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SourceKind {
    Counterparty,
    Queue,
    Mid,
    Last,
    Fixed,
}

/// What one venue can do to close a holding of one family. Declared here,
/// once, for every venue — the ticket offers exactly this, and the planner
/// refuses anything else.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub market: Availability,
    pub limit: Availability,
    pub chase: Availability,
    pub take_profit: Availability,
    pub stop_loss: Availability,
    /// How a limit close may rest: good-till-cancelled, maker only, fill
    /// and kill, all or nothing.
    pub limit_kinds: Vec<OrderKind>,
    /// Where a limit price may come from.
    pub price_sources: Vec<SourceKind>,
    /// Levels of the book the venue shows; 1 is the touch alone.
    pub book_depth: usize,
}

impl Capabilities {
    fn none(reason: &str) -> Capabilities {
        Capabilities {
            market: Availability::no(reason),
            limit: Availability::no(reason),
            chase: Availability::no(reason),
            take_profit: Availability::no(reason),
            stop_loss: Availability::no(reason),
            limit_kinds: Vec::new(),
            price_sources: Vec::new(),
            book_depth: 0,
        }
    }

    pub fn of(&self, method: Method) -> Availability {
        match method {
            Method::Market => self.market.clone(),
            Method::Limit => self.limit.clone(),
            Method::Chase => self.chase.clone(),
            Method::Protect => {
                if self.take_profit.available || self.stop_loss.available {
                    Availability::yes()
                } else {
                    self.stop_loss.clone()
                }
            }
        }
    }
}

const ALL_SOURCES: [SourceKind; 5] = [SourceKind::Counterparty, SourceKind::Queue, SourceKind::Mid, SourceKind::Last, SourceKind::Fixed];

/// From each venue's own documentation (OKX 2026-09-24): a chase exists for
/// perpetuals and delivery futures only; options have no algo book at all;
/// an option market order is refused here by design, since a thin book fills
/// it at whatever the other side asks. Schwab's channel carries market,
/// limit and stop orders on shares, with a level-one quote.
pub fn capabilities(venue: Venue, family: Family) -> Capabilities {
    let okx_limits = vec![OrderKind::Limit, OrderKind::PostOnly, OrderKind::Ioc, OrderKind::Fok];
    match (venue, family) {
        (Venue::Okx, Family::Swap) => Capabilities {
            market: Availability::yes(),
            limit: Availability::yes(),
            chase: Availability::yes(),
            take_profit: Availability::yes(),
            stop_loss: Availability::yes(),
            limit_kinds: okx_limits,
            price_sources: ALL_SOURCES.to_vec(),
            book_depth: PUBLISHED_DEPTH,
        },
        (Venue::Okx, Family::Spot) => Capabilities {
            market: Availability::yes(),
            limit: Availability::yes(),
            chase: Availability::no("OKX 的追逐限价只支持永续和交割合约"),
            take_profit: Availability::yes(),
            stop_loss: Availability::yes(),
            limit_kinds: okx_limits,
            price_sources: ALL_SOURCES.to_vec(),
            book_depth: PUBLISHED_DEPTH,
        },
        (Venue::Okx, Family::Option) => {
            let no_algo = "OKX 期权没有策略委托簿，止盈止损和追逐限价都挂不了";
            Capabilities {
                market: Availability::no("期权盘口薄，市价单会按对手任意报价成交；请用限价"),
                limit: Availability::yes(),
                chase: Availability::no(no_algo),
                take_profit: Availability::no(no_algo),
                stop_loss: Availability::no(no_algo),
                limit_kinds: okx_limits,
                price_sources: ALL_SOURCES.to_vec(),
                book_depth: PUBLISHED_DEPTH,
            }
        }
        (Venue::Okx, Family::Stock) => Capabilities::none("OKX 不交易股票"),
        (Venue::Schwab, Family::Stock) => Capabilities {
            market: Availability::yes(),
            limit: Availability::yes(),
            chase: Availability::no("嘉信没有追逐限价单"),
            take_profit: Availability::no("嘉信通道只挂止损单；要在目标价卖出请用限价"),
            stop_loss: Availability::yes(),
            limit_kinds: vec![OrderKind::Limit],
            price_sources: ALL_SOURCES.to_vec(),
            book_depth: 1,
        },
        (Venue::Schwab, _) => Capabilities::none("嘉信只交易股票"),
    }
}

// MARK: - What is held, and what is asked

/// The holding as the exchange reports it now.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Holding {
    pub inst_id: String,
    pub family: Family,
    /// A coin is always long.
    pub is_long: bool,
    /// What can be closed, positive, in order units: contracts, coins, shares.
    pub quantity: f64,
    /// Those units for a person: `张`, `ETH`, `股`.
    pub unit: String,
    /// The leg an order names on a perpetual; none elsewhere.
    #[serde(default)]
    pub pos_side: Option<PosSide>,
    /// `cross` or `isolated` for a derivative position.
    #[serde(default)]
    pub margin_mode: Option<String>,
    #[serde(default)]
    pub average_price: Option<f64>,
    #[serde(default)]
    pub liquidation_price: Option<f64>,
}

impl Holding {
    /// The side that closes this: a long is sold, a short bought back.
    pub fn closing_side(&self) -> Side {
        if self.is_long { Side::Sell } else { Side::Buy }
    }

    pub fn action_label(&self) -> &'static str {
        match self.family {
            Family::Swap | Family::Option => if self.is_long { "卖出平多" } else { "买入平空" },
            Family::Spot | Family::Stock => if self.is_long { "卖出" } else { "买入平空" },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PriceSource {
    /// The Nth level on the other side: fills against the levels up to it.
    Counterparty { level: usize },
    /// The Nth level on the order's own side: joins that queue.
    Queue { level: usize },
    Mid,
    Last,
    Fixed { price: f64 },
}

impl PriceSource {
    fn kind(&self) -> SourceKind {
        match self {
            PriceSource::Counterparty { .. } => SourceKind::Counterparty,
            PriceSource::Queue { .. } => SourceKind::Queue,
            PriceSource::Mid => SourceKind::Mid,
            PriceSource::Last => SourceKind::Last,
            PriceSource::Fixed { .. } => SourceKind::Fixed,
        }
    }

    pub fn label(&self) -> String {
        match self {
            PriceSource::Counterparty { level } => format!("对手价第 {level} 档"),
            PriceSource::Queue { level } => format!("同向价第 {level} 档"),
            PriceSource::Mid => "中间价".into(),
            PriceSource::Last => "最新成交价".into(),
            PriceSource::Fixed { .. } => "自定义价格".into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SizeRequest {
    /// All of it, as held when the plan is made.
    All,
    Amount { amount: f64 },
}

/// What the person asked for.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ticket {
    pub method: Method,
    pub size: SizeRequest,
    /// For a limit close.
    #[serde(default = "touch")]
    pub price: PriceSource,
    #[serde(default = "gtc")]
    pub limit_kind: OrderKind,
    /// How far the book may run before a chase gives up, in percent.
    #[serde(default = "default_chase")]
    pub max_chase_pct: f64,
    #[serde(default)]
    pub take_profit: Option<f64>,
    #[serde(default)]
    pub stop_loss: Option<f64>,
}

fn touch() -> PriceSource {
    PriceSource::Counterparty { level: 1 }
}
fn gtc() -> OrderKind {
    OrderKind::Limit
}
fn default_chase() -> f64 {
    DEFAULT_MAX_CHASE_PCT
}

/// May's choice, 2026-09-24: give up once the book is 0.2% from where it
/// stood — about five dollars on ETH at 2,650, enough to follow jitter and
/// stop chasing a real move.
pub const DEFAULT_MAX_CHASE_PCT: f64 = 0.2;
/// A chase allowed further than this is a market order with extra steps.
pub const MAX_CHASE_PCT: f64 = 10.0;

/// The account's derivatives setup, where known.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    /// OKX `acctLv`.
    #[serde(default)]
    pub level: Option<u8>,
}

impl Account {
    /// OKX ties a stop to its position (`cxlOnClosePos`) in futures mode and
    /// multi-currency margin only — account levels 2 and 3.
    pub fn stops_follow_position(&self) -> bool {
        matches!(self.level, Some(2) | Some(3))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanInput {
    pub venue: Venue,
    /// `demo` or `live`.
    pub mode: String,
    pub holding: Holding,
    pub ticket: Ticket,
    /// Nil when it could not be read: a stop is then placed untied, and the
    /// review says so.
    #[serde(default)]
    pub account: Option<Account>,
    #[serde(default)]
    pub fees: Option<FeeRates>,
    /// The instrument's working orders; nil when they could not be read.
    #[serde(default)]
    pub working: Option<Vec<WorkingOrder>>,
    #[serde(default)]
    pub working_unread: Option<String>,
    /// The client id the order goes out with.
    #[serde(default)]
    pub client_id: Option<String>,
    /// For the book's age.
    pub now_ms: i64,
}

// MARK: - The book it closes into

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LevelText {
    pub px: String,
    pub sz: String,
    #[serde(default)]
    pub orders: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Stamped {
    pub px: String,
    pub ms: i64,
}

/// The book as `live::book` publishes it — or, for a venue with a quote
/// only, the same shape with one level a side.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookView {
    #[serde(default)]
    pub asks: Vec<LevelText>,
    #[serde(default)]
    pub bids: Vec<LevelText>,
    #[serde(default)]
    pub seq_id: Option<i64>,
    #[serde(default)]
    pub exchange_ms: Option<i64>,
    #[serde(default)]
    pub received_ms: Option<i64>,
    #[serde(default)]
    pub last: Option<Stamped>,
    #[serde(default)]
    pub spec: Option<Spec>,
    #[serde(default)]
    pub state: Option<String>,
    /// False for a quote without sizes: each price is then assumed to fill
    /// whatever is sent to it, and the confirmation says so.
    #[serde(default = "yes")]
    pub sizes_known: bool,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Lv {
    px: f64,
    exact: Px,
    size: f64,
}

/// The book, checked and parsed. A side out of order, a price that does not
/// parse, or sides that cross is a book that cannot be priced from.
struct Market {
    asks: Vec<Lv>,
    bids: Vec<Lv>,
    sizes_known: bool,
    last: Option<f64>,
    terms: Option<Terms>,
    seq: Option<i64>,
    exchange_ms: Option<i64>,
    received_ms: Option<i64>,
}

fn parse_levels(rows: &[LevelText], ascending: bool) -> Result<Vec<Lv>, CloseError> {
    let mut out: Vec<Lv> = Vec::with_capacity(rows.len());
    for row in rows {
        let exact = Px::parse(&row.px).filter(|p| p.as_f64() > 0.0).ok_or_else(|| CloseError::BadBook(format!("价格 {:?} 读不懂", row.px)))?;
        let size: f64 = row.sz.parse().ok().filter(|s: &f64| s.is_finite() && *s >= 0.0).ok_or_else(|| CloseError::BadBook(format!("数量 {:?} 读不懂", row.sz)))?;
        if let Some(previous) = out.last() {
            let ordered = if ascending { exact > previous.exact } else { exact < previous.exact };
            if !ordered {
                return Err(CloseError::BadBook("档位顺序不对".into()));
            }
        }
        out.push(Lv { px: exact.as_f64(), exact, size });
    }
    Ok(out)
}

impl Market {
    fn read(view: &BookView) -> Result<Market, CloseError> {
        let mut asks = parse_levels(&view.asks, true)?;
        let mut bids = parse_levels(&view.bids, false)?;
        if !view.sizes_known {
            for level in asks.iter_mut().chain(bids.iter_mut()) {
                level.size = f64::INFINITY;
            }
        }
        if let (Some(ask), Some(bid)) = (asks.first(), bids.first()) {
            if bid.exact >= ask.exact {
                return Err(CloseError::BadBook("买一不低于卖一".into()));
            }
        }
        let last = view.last.as_ref().and_then(|l| Px::parse(&l.px)).map(Px::as_f64).filter(|p| *p > 0.0);
        Ok(Market {
            asks,
            bids,
            sizes_known: view.sizes_known,
            last,
            terms: view.spec.as_ref().map(Terms::read).transpose()?,
            seq: view.seq_id,
            exchange_ms: view.exchange_ms,
            received_ms: view.received_ms,
        })
    }

    fn mid(&self) -> Option<f64> {
        Some((self.asks.first()?.px + self.bids.first()?.px) / 2.0)
    }

    /// The levels an order on `side` fills against.
    fn opposite(&self, side: Side) -> &[Lv] {
        match side {
            Side::Sell => &self.bids,
            Side::Buy => &self.asks,
        }
    }

    /// The levels an order on `side` joins.
    fn same(&self, side: Side) -> &[Lv] {
        match side {
            Side::Sell => &self.asks,
            Side::Buy => &self.bids,
        }
    }

    fn tick(&self) -> f64 {
        self.terms.as_ref().map_or(0.0, |t| t.tick)
    }

    fn format(&self, price: f64) -> String {
        format_price(price, self.terms.as_ref().map(|t| t.price_decimals))
    }
}

/// Contract terms as numbers.
#[derive(Debug, Clone, PartialEq)]
struct Terms {
    tick: f64,
    lot: f64,
    min: f64,
    price_decimals: usize,
    /// Base units per contract (`ctVal × ctMult`); 1 for spot and shares.
    contract_value: f64,
    ct_type: String,
    ct_val_ccy: String,
    settle_ccy: String,
    quote_ccy: String,
    inst_type: String,
}

fn decimals(text: &str) -> usize {
    text.split_once('.').map(|(_, f)| f.trim_end_matches('0').len()).unwrap_or(0)
}

fn positive(text: &str, what: &str) -> Result<f64, CloseError> {
    let value = Px::parse(text).map(Px::as_f64).filter(|v| *v > 0.0);
    value.ok_or_else(|| CloseError::BadBook(format!("合约规格的 {what} 不合法：{text:?}")))
}

impl Terms {
    fn read(spec: &Spec) -> Result<Terms, CloseError> {
        let ct_val = Px::parse(&spec.ct_val).map(Px::as_f64).filter(|v| *v > 0.0);
        let ct_mult = Px::parse(&spec.ct_mult).map(Px::as_f64).filter(|v| *v > 0.0).unwrap_or(1.0);
        Ok(Terms {
            tick: positive(&spec.tick_sz, "tickSz")?,
            lot: positive(&spec.lot_sz, "lotSz")?,
            min: positive(&spec.min_sz, "minSz")?,
            price_decimals: decimals(&spec.tick_sz),
            contract_value: ct_val.map_or(1.0, |v| v * ct_mult),
            ct_type: spec.ct_type.clone(),
            ct_val_ccy: spec.ct_val_ccy.clone(),
            settle_ccy: spec.settle_ccy.clone(),
            quote_ccy: spec.quote_ccy.clone(),
            inst_type: spec.inst_type.clone(),
        })
    }
}

// MARK: - The plan

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Money {
    pub amount: f64,
    pub ccy: String,
    /// As it reads, written once here (`money_text`) for every screen.
    #[serde(default)]
    pub text: String,
}

impl Money {
    pub fn of(amount: f64, ccy: impl Into<String>) -> Money {
        Money { amount, ccy: ccy.into(), text: String::new() }
    }

    fn written(mut self, with_sign: bool) -> Money {
        self.text = money_text(&self, with_sign);
        self
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fill {
    pub size: f64,
    pub average: f64,
    pub worst: f64,
    pub levels: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Resting {
    pub size: f64,
    pub price: f64,
}

/// A stop or target: where it fires and what it books.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Leg {
    pub label: String,
    pub trigger: f64,
    pub distance_pct: Option<f64>,
    pub pnl: Option<Money>,
}

/// What the close is expected to do against the book as published.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Estimate {
    pub mid: Option<f64>,
    pub spread_bps: Option<f64>,
    /// Filled on arrival, taking liquidity.
    pub taker: Option<Fill>,
    /// Left resting, making it.
    pub maker: Option<Resting>,
    /// Cancelled on arrival: what an IOC could not fill.
    pub cancelled: f64,
    /// A market order larger than the published book: this much fills
    /// beyond the levels shown, at prices not known here.
    pub beyond_book: f64,
    /// The taker fill's average against the mid; positive is a cost.
    pub slippage_bps: Option<f64>,
    pub fee: Option<Money>,
    pub fee_basis: Option<String>,
    /// What the expected fills are worth: proceeds of a sale, cost of a
    /// buy-back — in the quote, the settlement coin for an option, dollars
    /// for an inverse contract.
    pub notional: Option<Money>,
    /// Profit booked if everything expected fills, before fees.
    pub pnl: Option<Money>,
    /// The same, less the fee, where both are in one currency.
    pub net_pnl: Option<Money>,
    pub legs: Vec<Leg>,
}

impl Estimate {
    /// Every amount written as it reads, and the profit net of the fee.
    fn finish(&mut self) {
        self.net_pnl = match (&self.pnl, &self.fee) {
            (Some(pnl), Some(fee)) if pnl.ccy == fee.ccy => Some(Money::of(pnl.amount - fee.amount, pnl.ccy.clone())),
            _ => None,
        };
        for (money, with_sign) in [(&mut self.fee, false), (&mut self.notional, false), (&mut self.pnl, true), (&mut self.net_pnl, true)] {
            if let Some(amount) = money.take() {
                *money = Some(amount.written(with_sign));
            }
        }
        for leg in &mut self.legs {
            leg.pnl = leg.pnl.take().map(|p| p.written(true));
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedPrice {
    pub value: f64,
    pub text: String,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Review {
    /// "卖出平多 ETH-USDT-SWAP 187.75 张 · 限价 2,700.01（对手价第 1 档）"
    pub headline: String,
    pub lines: Vec<String>,
    /// Things to know before saying yes.
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClosePlan {
    pub action: Action,
    /// The exact request, where the venue is OKX.
    pub wire: Option<WireRequest>,
    pub side: Side,
    pub size: f64,
    /// Of the holding, 0–1.
    pub share: f64,
    /// Left behind: below one lot when all of it was asked for.
    pub remainder: f64,
    pub price: Option<ResolvedPrice>,
    pub estimate: Estimate,
    pub review: Review,
    pub book_seq: Option<i64>,
    pub book_exchange_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum CloseError {
    Unavailable(Method, String),
    NothingHeld,
    SizeNotPositive,
    SizeAboveHolding { size: f64, held: f64, unit: String },
    SizeBelowMinimum { minimum: f64, unit: String },
    PartialNeedsLot,
    UnknownMarginMode,
    BadBook(String),
    NoLevel { source: String, available: usize },
    NoPrice(String),
    LimitKindUnavailable(OrderKind),
    SourceUnavailable(String),
    PostOnlyWouldTake { price: String, touch: String },
    ChaseOutOfRange(f64),
    NoProtectionLeg,
    LegUnavailable(String),
    NoReferencePrice,
    TakeProfitWrongSide { price: String, reference: String, is_long: bool },
    StopLossWrongSide { price: String, reference: String, is_long: bool },
    StopLossBeyondLiquidation { price: String, liquidation: String, is_long: bool },
    Wire(String),
}

impl std::fmt::Display for CloseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CloseError::Unavailable(method, reason) => write!(f, "{}不可用：{reason}", method.name()),
            CloseError::NothingHeld => write!(f, "交易所上已经没有这笔持仓"),
            CloseError::SizeNotPositive => write!(f, "数量要大于 0"),
            CloseError::SizeAboveHolding { size, held, unit } => {
                write!(f, "数量 {} 超过持仓 {} {unit}", wire::number(*size), wire::number(*held))
            }
            CloseError::SizeBelowMinimum { minimum, unit } => write!(f, "低于交易所最小下单量 {} {unit}", wire::number(*minimum)),
            CloseError::PartialNeedsLot => write!(f, "读不到合约规格（最小变动单位），只能整笔平掉"),
            CloseError::UnknownMarginMode => write!(f, "读不到这笔仓位是逐仓还是全仓，平仓单必须和仓位同一种保证金模式，不能猜"),
            CloseError::BadBook(why) => write!(f, "盘口数据不可用：{why}"),
            CloseError::NoLevel { source, available } => write!(f, "{source}不存在：盘口这一侧只有 {available} 档"),
            CloseError::NoPrice(why) => write!(f, "{why}"),
            CloseError::LimitKindUnavailable(kind) => write!(f, "这个品种不支持 {} 单", kind_name(*kind)),
            CloseError::SourceUnavailable(source) => write!(f, "这个品种不能按{source}取价"),
            CloseError::PostOnlyWouldTake { price, touch } => {
                write!(f, "只做 Maker 的价格 {price} 已经碰到对手价 {touch}，交易所会直接撤单；换同向价或改成普通限价")
            }
            CloseError::ChaseOutOfRange(pct) => {
                write!(f, "最大追价距离 {}% 要大于 0、不超过 {}%；追得更远请用市价", wire::number(*pct), wire::number(MAX_CHASE_PCT))
            }
            CloseError::NoProtectionLeg => write!(f, "止盈价和止损价至少填一个"),
            CloseError::LegUnavailable(reason) => write!(f, "{reason}"),
            CloseError::NoReferencePrice => write!(f, "读不到最新成交价，无法核对止盈止损在现价的哪一边"),
            CloseError::TakeProfitWrongSide { price, reference, is_long } => write!(
                f, "止盈价 {price} 要{}最新价 {reference}，否则一挂上就触发", if *is_long { "高于" } else { "低于" }),
            CloseError::StopLossWrongSide { price, reference, is_long } => write!(
                f, "止损价 {price} 要{}最新价 {reference}，否则一挂上就触发", if *is_long { "低于" } else { "高于" }),
            CloseError::StopLossBeyondLiquidation { price, liquidation, is_long } => write!(
                f, "止损价 {price} 在强平价 {liquidation} {}，仓位会先被强平，这张止损永远等不到触发", if *is_long { "之下" } else { "之上" }),
            CloseError::Wire(why) => write!(f, "{why}"),
        }
    }
}

fn margin_name(mode: &str) -> &'static str {
    match mode {
        "cross" => "全仓",
        "isolated" => "逐仓",
        _ => "现金",
    }
}

fn kind_name(kind: OrderKind) -> &'static str {
    match kind {
        OrderKind::Market => "市价",
        OrderKind::Limit => "限价",
        OrderKind::PostOnly => "只做 Maker",
        OrderKind::Ioc => "IOC",
        OrderKind::Fok => "FOK",
    }
}

// MARK: - Planning

pub fn plan(input: &PlanInput, book: &BookView) -> Result<ClosePlan, CloseError> {
    let holding = &input.holding;
    let ticket = &input.ticket;
    let capabilities = capabilities(input.venue, holding.family);
    let availability = capabilities.of(ticket.method);
    if !availability.available {
        return Err(CloseError::Unavailable(ticket.method, availability.reason.unwrap_or_default()));
    }
    if !(holding.quantity > 0.0) || !holding.quantity.is_finite() {
        return Err(CloseError::NothingHeld);
    }
    let market = Market::read(book)?;
    let (size, remainder) = close_size(&ticket.size, holding, market.terms.as_ref())?;

    // An order acting on a position states that position's margin mode: a
    // default of `cross` on an isolated position is an order for a position
    // that does not exist.
    let trade_mode = match (holding.family, holding.margin_mode.as_deref()) {
        (Family::Swap, Some(mode @ ("cross" | "isolated"))) => Some(mode.to_string()),
        // An option bought outright on a simple account is held for cash.
        (Family::Option, Some(mode @ ("cross" | "isolated" | "cash"))) => Some(mode.to_string()),
        (Family::Swap | Family::Option, _) => return Err(CloseError::UnknownMarginMode),
        (Family::Spot, _) => Some("cash".to_string()),
        (Family::Stock, _) => None,
    };
    let side = holding.closing_side();
    let pos_side = if holding.family == Family::Swap { holding.pos_side } else { None };
    let reduce_only = holding.family != Family::Spot;
    let fees = input.fees.filter(|_| input.venue == Venue::Okx);

    let mut estimate = Estimate {
        mid: market.mid(),
        spread_bps: match (market.asks.first(), market.bids.first(), market.mid()) {
            (Some(a), Some(b), Some(mid)) if mid > 0.0 => Some((a.px - b.px) / mid * 1e4),
            _ => None,
        },
        ..Estimate::default()
    };
    let mut lines: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();
    let mut resolved: Option<ResolvedPrice> = None;

    let (action, how) = match ticket.method {
        Method::Market | Method::Limit => {
            let (kind, price) = if ticket.method == Method::Market {
                (OrderKind::Market, None)
            } else {
                if !capabilities.limit_kinds.contains(&ticket.limit_kind) || ticket.limit_kind == OrderKind::Market {
                    return Err(CloseError::LimitKindUnavailable(ticket.limit_kind));
                }
                let price = resolve_price(&ticket.price, side, &market, &capabilities)?;
                (ticket.limit_kind, Some(price))
            };
            if let Some(price) = price {
                resolved = Some(ResolvedPrice { value: price, text: market.format(price), source: ticket.price.label() });
            }
            estimate_order(&mut estimate, &mut lines, &mut warnings, kind, size, price, side, holding, &market, fees)?;
            let how = match price {
                None => "市价".to_string(),
                Some(p) => format!("{} {}（{}）", kind_name(kind), market.format(p), ticket.price.label()),
            };
            let order = OrderSpec {
                inst_id: holding.inst_id.clone(),
                inst_type: holding.family,
                side,
                kind,
                size,
                size_in_quote: false,
                price,
                trade_mode: trade_mode.clone(),
                pos_side,
                reduce_only,
                client_id: input.client_id.clone(),
                stop_trigger: None,
                take_profit_trigger: None,
            };
            (Action::Place { order }, how)
        }
        Method::Chase => {
            let pct = ticket.max_chase_pct;
            if !(pct > 0.0 && pct <= MAX_CHASE_PCT) || !pct.is_finite() {
                return Err(CloseError::ChaseOutOfRange(pct));
            }
            let start = market.same(side).first().map(|l| l.px);
            if let Some(start) = start {
                estimate.maker = Some(Resting { size, price: start });
                estimate.notional = value(holding, market.terms.as_ref(), size, start);
                estimate.pnl = pnl(holding, market.terms.as_ref(), size, start);
                if let Some(rates) = fees {
                    estimate.fee = fee(holding, market.terms.as_ref(), size, start, rates.maker);
                    estimate.fee_basis = Some(format!("maker {}", rate_text(rates.maker)));
                }
            }
            let touch = if side == Side::Sell { "卖一" } else { "买一" };
            lines.push(format!(
                "挂在{touch}{}只做 maker，每秒跟一次盘口；盘口离开下单时的价格超过 {}% 就撤单，已成交部分保留。",
                start.map(|p| format!(" {}", market.format(p))).unwrap_or_default(),
                wire::number(pct)));
            warnings.push("单边行情里追逐限价可能一直追不上而被撤；要确定出场请用市价。".into());
            let algo = AlgoSpec {
                inst_id: holding.inst_id.clone(),
                inst_type: holding.family,
                side,
                pos_side,
                size,
                trade_mode: trade_mode.clone(),
                reduce_only: true,
                cancel_with_position: false,
                client_id: input.client_id.clone(),
                kind: AlgoKind::Chase { max_chase_ratio: pct / 100.0 },
            };
            (Action::PlaceAlgo { algo }, format!("追逐限价（最大追价 {}%）", wire::number(pct)))
        }
        Method::Protect => {
            let take_profit = ticket.take_profit.filter(|p| *p > 0.0 && p.is_finite());
            let stop_loss = ticket.stop_loss.filter(|p| *p > 0.0 && p.is_finite());
            if take_profit.is_none() && stop_loss.is_none() {
                return Err(CloseError::NoProtectionLeg);
            }
            if take_profit.is_some() && !capabilities.take_profit.available {
                return Err(CloseError::LegUnavailable(format!("止盈不可用：{}", capabilities.take_profit.reason.clone().unwrap_or_default())));
            }
            if stop_loss.is_some() && !capabilities.stop_loss.available {
                return Err(CloseError::LegUnavailable(format!("止损不可用：{}", capabilities.stop_loss.reason.clone().unwrap_or_default())));
            }
            // Triggers fire on the last trade.
            let reference = market.last.or(market.mid()).ok_or(CloseError::NoReferencePrice)?;
            let is_long = holding.is_long;
            let tick = market.tick();
            // Each trigger snapped towards its own side of the market, so
            // snapping never moves one across the price.
            let target = take_profit.map(|p| snap(p, tick, is_long));
            let stop = stop_loss.map(|p| snap(p, tick, !is_long));
            if let Some(target) = target {
                if if is_long { target <= reference } else { target >= reference } {
                    return Err(CloseError::TakeProfitWrongSide { price: market.format(target), reference: market.format(reference), is_long });
                }
            }
            if let Some(stop) = stop {
                if if is_long { stop >= reference } else { stop <= reference } {
                    return Err(CloseError::StopLossWrongSide { price: market.format(stop), reference: market.format(reference), is_long });
                }
                if let Some(liquidation) = holding.liquidation_price.filter(|l| *l > 0.0) {
                    if if is_long { stop <= liquidation } else { stop >= liquidation } {
                        return Err(CloseError::StopLossBeyondLiquidation {
                            price: market.format(stop), liquidation: market.format(liquidation), is_long,
                        });
                    }
                }
            }
            for (label, trigger) in [("止盈", target), ("止损", stop)] {
                let Some(trigger) = trigger else { continue };
                estimate.legs.push(Leg {
                    label: label.into(),
                    trigger,
                    distance_pct: Some((trigger - reference) / reference * 100.0),
                    pnl: pnl(holding, market.terms.as_ref(), size, trigger),
                });
            }
            if let Some(rates) = fees {
                let at = stop.or(target).unwrap_or(reference);
                estimate.fee = fee(holding, market.terms.as_ref(), size, at, rates.taker);
                estimate.fee_basis = Some(format!("触发后按 taker {} 成交", rate_text(rates.taker)));
            }
            let tied = holding.family == Family::Swap && input.account.as_ref().is_some_and(Account::stops_follow_position);
            lines.push(format!(
                "按最新成交价触发（现 {}），触发后市价成交。{}",
                market.format(reference),
                if target.is_some() && stop.is_some() { "两边互斥：一边触发，另一边自动撤销。" } else { "" }));
            if tied {
                lines.push("仓位全部平掉时，交易所自动撤销这张单。".into());
            } else if holding.family == Family::Swap {
                warnings.push(if input.account.is_none() {
                    "读不到账户模式，这张单不会随仓位平掉而自动撤销；仓位平掉后请手动撤，否则它会打到下一笔同方向的仓位。".into()
                } else {
                    "这个账户模式下交易所不支持随仓撤销；仓位平掉后请手动撤，否则它会打到下一笔同方向的仓位。".into()
                });
            }
            let how = [target.map(|p| format!("止盈 {}", market.format(p))), stop.map(|p| format!("止损 {}", market.format(p)))]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" · ");
            let algo = AlgoSpec {
                inst_id: holding.inst_id.clone(),
                inst_type: holding.family,
                side,
                pos_side,
                size,
                trade_mode: trade_mode.clone(),
                reduce_only,
                cancel_with_position: tied,
                client_id: input.client_id.clone(),
                kind: AlgoKind::Protection { take_profit: target, stop_loss: stop },
            };
            (Action::PlaceAlgo { algo }, how)
        }
    };

    let wire = match input.venue {
        Venue::Okx => Some(wire::build(&action).map_err(CloseError::Wire)?),
        Venue::Schwab => None,
    };

    // What it is worth, what it costs, what it books.
    estimate.finish();
    for leg in &estimate.legs {
        lines.push(format!(
            "{}触发 {}{}{}",
            leg.label,
            market.format(leg.trigger),
            leg.distance_pct.map(|d| format!("（距现价 {}%）", signed(d, 2))).unwrap_or_default(),
            leg.pnl.as_ref().map(|p| format!(" → 盈亏约 {}（未计手续费）", p.text)).unwrap_or_default()));
    }
    if let Some(notional) = &estimate.notional {
        lines.push(format!("成交额约 {}", notional.text));
    }
    if let Some(fee) = &estimate.fee {
        lines.push(format!(
            "手续费约 {}{}",
            fee.text,
            estimate.fee_basis.as_ref().map(|b| format!("（{b}）")).unwrap_or_default()));
    }
    if let Some(profit) = &estimate.pnl {
        lines.push(format!(
            "实现盈亏约 {}（未计手续费）{}",
            profit.text,
            estimate.net_pnl.as_ref().map(|n| format!("，扣手续费后约 {}", n.text)).unwrap_or_default()));
    }

    // MARK: The confirmation's words
    let share = size / holding.quantity;
    let size_text = format!("{} {}", wire::number(size), holding.unit);
    let mut head = vec![format!(
        "数量 {size_text}，占持仓 {}%{}",
        grouped(share * 100.0, 0),
        if share >= 0.99999 { "（全部）" } else { "" })];
    if let Some(terms) = market.terms.as_ref().filter(|_| holding.family.is_derivative()) {
        if !terms.ct_val_ccy.is_empty() {
            head[0] += &format!("，约 {} {}", wire::number(size * terms.contract_value), terms.ct_val_ccy);
        }
    }
    let mut account_line = Vec::new();
    match (holding.family, &trade_mode) {
        (Family::Swap | Family::Option, Some(mode)) => account_line.push(format!("{}（tdMode={mode}）", margin_name(mode))),
        (Family::Spot, _) => account_line.push("现货（tdMode=cash）".to_string()),
        _ => {}
    }
    if let Some(leg) = pos_side {
        account_line.push(format!("持仓方向 {}", leg.as_str()));
    }
    if !account_line.is_empty() {
        head.push(account_line.join(" · "));
    }
    lines.splice(0..0, head);
    if remainder > 0.0 {
        let lot = market.terms.as_ref().map_or(0.0, |t| t.lot);
        lines.push(format!(
            "余下 {} {} 不足一个最小单位（{}），交易所不接受，留在账户里。",
            wire::number(remainder), holding.unit, wire::number(lot)));
    }
    if let Some(average) = holding.average_price.filter(|p| *p > 0.0) {
        lines.push(format!("持仓均价 {}", market.format(average)));
    }
    if let Some(liquidation) = holding.liquidation_price.filter(|p| *p > 0.0) {
        lines.push(format!("强平价 {}", market.format(liquidation)));
    }

    if let Some(received) = market.received_ms {
        let age = input.now_ms - received;
        if age > STALE_BOOK_MS && matches!(ticket.method, Method::Market | Method::Limit) {
            warnings.push(format!("盘口已经 {} 秒没有更新，上面的价格和预估可能已经过时。", age / 1000));
        }
    }
    let closing: Vec<&WorkingOrder> = input
        .working
        .iter()
        .flatten()
        .filter(|o| o.inst_id == holding.inst_id && o.side == side.as_str())
        .collect();
    if !closing.is_empty() {
        warnings.push(format!(
            "这个标的上已有 {} 笔同方向的挂单或条件单：{}。它们和这张单都可能成交。",
            closing.len(),
            closing.iter().map(|o| format!("{} {}", o.ord_type, order_size(o))).collect::<Vec<_>>().join("、")));
    }
    if input.working.is_none() {
        warnings.push(format!(
            "读不到这个标的的挂单（{}），无法确认有没有别的平仓单在挂着。",
            input.working_unread.as_deref().unwrap_or("原因未知")));
    }
    if input.mode == "live" {
        warnings.insert(0, format!("这是{}实盘，真实资金。", input.venue.name()));
    }

    Ok(ClosePlan {
        action,
        wire,
        side,
        size,
        share,
        remainder,
        price: resolved,
        estimate,
        review: Review { headline: format!("{} {} {size_text} · {how}", holding.action_label(), holding.inst_id), lines, warnings },
        book_seq: market.seq,
        book_exchange_ms: market.exchange_ms,
    })
}

/// A book older than this is flagged in the confirmation.
pub const STALE_BOOK_MS: i64 = 3_000;

fn order_size(order: &WorkingOrder) -> String {
    match (order.size, order.close_fraction) {
        (Some(size), _) => wire::number(size),
        (None, Some(f)) if f >= 1.0 => "全平".into(),
        (None, Some(f)) => format!("平 {}%", grouped(f * 100.0, 0)),
        _ => "—".into(),
    }
}

/// The size sent: floored to a whole lot, the whole holding included. A
/// position is always whole lots, so all of it is all of it; a coin balance
/// often is not (0.0408135 ETH against a 0.000001 lot, 2026-09-24), and OKX
/// refuses a size off the lot — so the remainder below one lot stays, and
/// is returned for the confirmation to say so.
fn close_size(request: &SizeRequest, holding: &Holding, terms: Option<&Terms>) -> Result<(f64, f64), CloseError> {
    let held = holding.quantity;
    let requested = match request {
        SizeRequest::All => held,
        SizeRequest::Amount { amount } => *amount,
    };
    if !(requested > 0.0) || !requested.is_finite() {
        return Err(CloseError::SizeNotPositive);
    }
    // A hair over the holding is the same request as all of it — a share
    // multiplied back out, a figure rounded for display. More is a request to
    // open, and refused.
    let tolerance = terms.map_or(0.0, |t| t.lot).max(held * 1e-9);
    if requested > held + tolerance {
        return Err(CloseError::SizeAboveHolding { size: requested, held, unit: holding.unit.clone() });
    }
    let whole = requested >= held - 1e-12;
    let Some(terms) = terms else {
        return if whole { Ok((held, 0.0)) } else { Err(CloseError::PartialNeedsLot) };
    };
    let mut size = floor_to_lot(if whole { held } else { requested }, terms.lot);
    // The nudge that keeps 0.29 / 0.01 from flooring to 28 lots could, on a
    // balance a hair under a lot boundary, round up past what is held. Never.
    if size > held {
        size = floor_to_lot(size - terms.lot, terms.lot);
    }
    if !(size > 0.0) || size < terms.min - terms.lot * 1e-9 {
        return Err(CloseError::SizeBelowMinimum { minimum: terms.min.max(terms.lot), unit: holding.unit.clone() });
    }
    let remainder = if whole { clean(held - size) } else { 0.0 };
    Ok((size, remainder.max(0.0)))
}

/// Floor to a whole number of lots, with the 1e-9-lot nudge every sizing
/// path uses: `29 × 0.01 / 0.01` is 28.999999999999996 in binary, and a plain
/// floor sends 28.
pub fn floor_to_lot(size: f64, lot: f64) -> f64 {
    if !(lot > 0.0) {
        return size;
    }
    clean(((size / lot) + 1e-9).floor() * lot)
}

/// Snap to the tick, towards the holder when `up` for a sale.
pub fn snap(price: f64, tick: f64, up: bool) -> f64 {
    if !(tick > 0.0) {
        return price;
    }
    let steps = price / tick;
    let snapped = if up { (steps - 1e-9).ceil() } else { (steps + 1e-9).floor() };
    clean(snapped * tick)
}

/// Binary noise off: ten decimals, as every number leaves for the exchange.
fn clean(value: f64) -> f64 {
    (value * 1e10).round() / 1e10
}

fn resolve_price(source: &PriceSource, side: Side, market: &Market, capabilities: &Capabilities) -> Result<f64, CloseError> {
    if !capabilities.price_sources.contains(&source.kind()) {
        return Err(CloseError::SourceUnavailable(source.label()));
    }
    let level = |levels: &[Lv], n: usize| -> Result<f64, CloseError> {
        if n == 0 || n > capabilities.book_depth {
            return Err(CloseError::NoLevel { source: source.label(), available: levels.len().min(capabilities.book_depth) });
        }
        levels.get(n - 1).map(|l| l.px).ok_or(CloseError::NoLevel { source: source.label(), available: levels.len() })
    };
    // Snapped towards the holder: a sale never goes out below the price
    // named, a buy-back never above it.
    let towards_holder = side == Side::Sell;
    let price = match source {
        PriceSource::Counterparty { level: n } => level(market.opposite(side), *n)?,
        PriceSource::Queue { level: n } => level(market.same(side), *n)?,
        PriceSource::Mid => snap(market.mid().ok_or_else(|| CloseError::NoPrice("盘口缺一边，没有中间价".into()))?, market.tick(), towards_holder),
        PriceSource::Last => market.last.ok_or_else(|| CloseError::NoPrice("还没有最新成交价".into()))?,
        PriceSource::Fixed { price } => {
            if !(*price > 0.0) || !price.is_finite() {
                return Err(CloseError::NoPrice("填一个大于 0 的限价".into()));
            }
            snap(*price, market.tick(), towards_holder)
        }
    };
    if !(price > 0.0) {
        return Err(CloseError::NoPrice("价格按最小变动单位取整后为 0".into()));
    }
    Ok(price)
}

/// Walk the levels an order fills against, up to its size and — for a
/// priced order — its price.
fn walk(levels: &[Lv], size: f64, limit: Option<f64>, side: Side) -> Option<Fill> {
    let limit = limit.and_then(|p| Px::parse(&wire::number(p)));
    let mut filled = 0.0;
    let mut notional = 0.0;
    let mut worst = 0.0;
    let mut touched = 0;
    for level in levels {
        if filled >= size - 1e-12 {
            break;
        }
        if let Some(limit) = limit {
            let reachable = match side {
                Side::Sell => level.exact >= limit,
                Side::Buy => level.exact <= limit,
            };
            if !reachable {
                break;
            }
        }
        let take = level.size.min(size - filled);
        if take <= 0.0 {
            continue;
        }
        filled += take;
        notional += take * level.px;
        worst = level.px;
        touched += 1;
    }
    (filled > 0.0).then(|| Fill { size: clean(filled), average: notional / filled, worst, levels: touched })
}

#[allow(clippy::too_many_arguments)]
fn estimate_order(
    estimate: &mut Estimate, lines: &mut Vec<String>, warnings: &mut Vec<String>,
    kind: OrderKind, size: f64, price: Option<f64>, side: Side,
    holding: &Holding, market: &Market, fees: Option<FeeRates>,
) -> Result<(), CloseError> {
    let taker = walk(market.opposite(side), size, price, side);
    let filled = taker.as_ref().map_or(0.0, |f| f.size);
    let rest = clean(size - filled).max(0.0);
    let touch = market.opposite(side).first().map(|l| l.px);
    let unit = &holding.unit;

    match kind {
        OrderKind::PostOnly => {
            if filled > 0.0 {
                return Err(CloseError::PostOnlyWouldTake {
                    price: market.format(price.unwrap_or(0.0)),
                    touch: touch.map(|t| market.format(t)).unwrap_or_default(),
                });
            }
            estimate.maker = price.map(|p| Resting { size, price: p });
        }
        OrderKind::Ioc => {
            estimate.taker = taker.clone();
            estimate.cancelled = rest;
        }
        OrderKind::Fok => {
            if rest > 0.0 {
                warnings.push(format!(
                    "按当前盘口，这个价以内只有 {} {unit} 可成交，不够 {}：FOK 会整单撤销，一张不成交。",
                    wire::number(filled), wire::number(size)));
                estimate.cancelled = size;
            } else {
                estimate.taker = taker.clone();
            }
        }
        OrderKind::Limit => {
            estimate.taker = taker.clone();
            if rest > 0.0 {
                estimate.maker = price.map(|p| Resting { size: rest, price: p });
            }
        }
        OrderKind::Market => {
            estimate.taker = taker.clone();
            estimate.beyond_book = rest;
        }
    }

    if let (Some(fill), Some(mid)) = (&estimate.taker, estimate.mid.filter(|m| *m > 0.0)) {
        let direction = if side == Side::Sell { 1.0 } else { -1.0 };
        estimate.slippage_bps = Some((mid - fill.average) / mid * 1e4 * direction);
    }
    let terms = market.terms.as_ref();
    let taker_pnl = estimate.taker.as_ref().and_then(|f| pnl(holding, terms, f.size, f.average));
    let maker_pnl = estimate.maker.as_ref().and_then(|r| pnl(holding, terms, r.size, r.price));
    estimate.pnl = sum_money(estimate.taker.as_ref().map(|_| taker_pnl.clone()), estimate.maker.as_ref().map(|_| maker_pnl.clone()));
    estimate.notional = sum_money(
        estimate.taker.as_ref().map(|f| value(holding, terms, f.size, f.average)),
        estimate.maker.as_ref().map(|r| value(holding, terms, r.size, r.price)),
    );
    if let Some(rates) = fees {
        let taker_fee = estimate.taker.as_ref().map(|f| fee(holding, terms, f.size, f.average, rates.taker));
        let maker_fee = estimate.maker.as_ref().map(|r| fee(holding, terms, r.size, r.price, rates.maker));
        estimate.fee = sum_money(taker_fee, maker_fee);
        estimate.fee_basis = Some(match (&estimate.taker, &estimate.maker) {
            (Some(_), Some(_)) => format!("taker {} · maker {}", rate_text(rates.taker), rate_text(rates.maker)),
            (None, Some(_)) => format!("maker {}", rate_text(rates.maker)),
            _ => format!("taker {}", rate_text(rates.taker)),
        });
    }

    // Words.
    if !market.sizes_known && estimate.taker.is_some() {
        lines.push("报价不含挂单量：按对手价全部成交估算，实际可能分几笔、以更差的价格成交。".into());
    }
    if let Some(fill) = &estimate.taker {
        lines.push(format!(
            "立即成交 {} {unit}，均价 {}，吃 {} 档，最差 {}",
            wire::number(fill.size), market.format(fill.average), fill.levels, market.format(fill.worst)));
        if let (Some(slip), Some(mid)) = (estimate.slippage_bps, estimate.mid) {
            lines.push(format!("相对中间价 {} 滑点 {} bp", market.format(mid), grouped(slip, 1)));
            if fill.levels > 3 || slip > 20.0 {
                warnings.push(format!("这张单会立刻吃掉 {} 档，均价比中间价差 {} bp。", fill.levels, grouped(slip, 1)));
            }
        }
    }
    if let Some(resting) = &estimate.maker {
        lines.push(format!(
            "{} {} {unit} 挂在 {}，成交前一直挂着，需要时在下方撤单。",
            if kind == OrderKind::PostOnly { "只做 Maker：" } else { "余下" },
            wire::number(resting.size), market.format(resting.price)));
    }
    if kind == OrderKind::Ioc && estimate.cancelled > 0.0 {
        lines.push(format!("其余 {} {unit} 在这个价以内没有对手，立即撤销。", wire::number(estimate.cancelled)));
    }
    if estimate.beyond_book > 0.0 {
        warnings.push(format!(
            "可见的 {} 档不够：剩余 {} {unit} 会以比 {} 更差的价格成交。",
            market.opposite(side).len(), wire::number(estimate.beyond_book),
            market.opposite(side).last().map(|l| market.format(l.px)).unwrap_or_default()));
    }
    if kind == OrderKind::Market {
        warnings.push("市价单按对手盘逐档成交，盘口薄或行情急时成交价会比现价差。".into());
        if estimate.taker.is_none() {
            warnings.push("盘口这一侧是空的，读不到市价单会以什么价成交。".into());
        }
    }
    Ok(())
}

fn sum_money(a: Option<Option<Money>>, b: Option<Option<Money>>) -> Option<Money> {
    // Every part that exists must be known, and in one currency.
    let parts: Vec<Option<Money>> = [a, b].into_iter().flatten().collect();
    if parts.is_empty() {
        return None;
    }
    let mut total: Option<Money> = None;
    for part in parts {
        let part = part?;
        total = Some(match total {
            None => part,
            Some(t) if t.ccy == part.ccy => Money::of(t.amount + part.amount, t.ccy),
            Some(_) => return None,
        });
    }
    total
}

fn rate_text(rate: f64) -> String {
    format!("{}%", wire::number((rate * 100.0 * 1e6).round() / 1e6))
}

/// Profit booked by closing `size` at `exit`, before fees — where the
/// arithmetic is exact: linear and inverse perpetuals from their terms,
/// options on their premium, shares. A coin balance has no cost here.
fn pnl(holding: &Holding, terms: Option<&Terms>, size: f64, exit: f64) -> Option<Money> {
    let average = holding.average_price.filter(|p| *p > 0.0)?;
    if !(exit > 0.0) {
        return None;
    }
    let direction = if holding.is_long { 1.0 } else { -1.0 };
    match holding.family {
        Family::Swap => {
            let terms = terms?;
            let amount = match terms.ct_type.as_str() {
                // Settled in the quote: the move times the base covered.
                "linear" => (exit - average) * size * terms.contract_value,
                // Settled in the coin: contracts are worth a fixed number of
                // dollars, and profit is the change in coins those buy.
                "inverse" => (1.0 / average - 1.0 / exit) * size * terms.contract_value,
                _ => return None,
            };
            Some(Money::of(amount * direction, terms.settle_ccy.clone())).filter(|m| !m.ccy.is_empty())
        }
        // Quoted in the settlement coin per unit of the underlying.
        Family::Option => {
            let terms = terms?;
            Some(Money::of((exit - average) * size * terms.contract_value * direction, terms.settle_ccy.clone()))
                .filter(|m| !m.ccy.is_empty())
        }
        Family::Stock => Some(Money::of((exit - average) * size * direction, "USD")),
        Family::Spot => None,
    }
}

/// The fee on `size` filled at `price`, in the currency it is charged in.
fn fee(holding: &Holding, terms: Option<&Terms>, size: f64, price: f64, rate: f64) -> Option<Money> {
    let terms = terms?;
    if !(price > 0.0) {
        return None;
    }
    match holding.family {
        Family::Swap => match terms.ct_type.as_str() {
            "linear" => Some(Money::of(rate * size * terms.contract_value * price, terms.settle_ccy.clone())),
            "inverse" => Some(Money::of(rate * size * terms.contract_value / price, terms.settle_ccy.clone())),
            _ => None,
        },
        // OKX charges an option the lesser of the rate on the underlying
        // covered and 12.5% of the premium.
        Family::Option => {
            let underlying = rate * size * terms.contract_value;
            let cap = 0.125 * price * size * terms.contract_value;
            Some(Money::of(underlying.min(cap), terms.settle_ccy.clone()))
        }
        // A sale is charged in what it receives: the quote.
        Family::Spot => (!terms.quote_ccy.is_empty() && holding.closing_side() == Side::Sell)
            .then(|| Money::of(rate * size * price, terms.quote_ccy.clone())),
        Family::Stock => None,
    }
    .filter(|m| !m.ccy.is_empty() && m.amount.is_finite())
}

/// What `size` filled at `price` is worth, in the currency it settles in.
fn value(holding: &Holding, terms: Option<&Terms>, size: f64, price: f64) -> Option<Money> {
    if !(price > 0.0) {
        return None;
    }
    match holding.family {
        Family::Swap => {
            let terms = terms?;
            match terms.ct_type.as_str() {
                "linear" => Some(Money::of(size * terms.contract_value * price, terms.settle_ccy.clone())),
                // A contract is a fixed number of dollars, whatever the price.
                "inverse" => Some(Money::of(size * terms.contract_value, terms.ct_val_ccy.clone())),
                _ => None,
            }
        }
        Family::Option => {
            let terms = terms?;
            Some(Money::of(size * terms.contract_value * price, terms.settle_ccy.clone()))
        }
        Family::Spot => {
            let terms = terms?;
            Some(Money::of(size * price, terms.quote_ccy.clone()))
        }
        Family::Stock => Some(Money::of(size * price, "USD")),
    }
    .filter(|m| !m.ccy.is_empty() && m.amount.is_finite())
}

// MARK: - Text

/// Money as it reads: cents for dollars and stablecoins (four places below
/// one, so a fee of a third of a cent is not shown as nothing), six places
/// for a coin.
pub fn money_text(money: &Money, with_sign: bool) -> String {
    let dollars = ["USDT", "USDC", "USD"].contains(&money.ccy.to_ascii_uppercase().as_str());
    let places = if dollars { if money.amount.abs() >= 1.0 { 2 } else { 4 } } else { 6 };
    let body = if with_sign { signed(money.amount, places) } else { grouped(money.amount, places) };
    format!("{body} {}", money.ccy)
}

/// A number with its sign always shown: `+1.20`, `-0.35`.
fn signed(value: f64, places: usize) -> String {
    let text = grouped(value, places);
    if text.starts_with('-') || text.chars().all(|c| !c.is_ascii_digit() || c == '0' || c == '.' || c == ',') {
        text
    } else {
        format!("+{text}")
    }
}

/// A price to the instrument's tick, grouped: `2,682.45`.
pub fn format_price(value: f64, decimals: Option<usize>) -> String {
    match decimals {
        Some(d) => grouped(value, d),
        None => {
            // No tick known: as the number reads, up to ten decimals.
            let text = wire::number(value);
            let d = decimals_of(&text);
            grouped(value, d)
        }
    }
}

fn decimals_of(text: &str) -> usize {
    text.split_once('.').map_or(0, |(_, f)| f.len())
}

/// Thousands separators and a fixed number of decimals.
pub fn grouped(value: f64, decimals: usize) -> String {
    if !value.is_finite() {
        return "—".into();
    }
    let text = format!("{:.*}", decimals, value.abs());
    let (whole, fraction) = text.split_once('.').map_or((text.as_str(), None), |(w, f)| (w, Some(f)));
    let mut out = String::new();
    for (i, ch) in whole.chars().enumerate() {
        if i > 0 && (whole.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    if let Some(fraction) = fraction {
        out.push('.');
        out.push_str(fraction);
    }
    let negative = value < 0.0 && out.chars().any(|c| c.is_ascii_digit() && c != '0');
    if negative { format!("-{out}") } else { out }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn spec(inst_type: &str) -> Spec {
        match inst_type {
            "SWAP" => Spec {
                inst_type: "SWAP".into(), tick_sz: "0.01".into(), lot_sz: "0.01".into(), min_sz: "0.01".into(),
                ct_val: "0.1".into(), ct_mult: "1".into(), ct_type: "linear".into(), ct_val_ccy: "ETH".into(),
                settle_ccy: "USDT".into(), group_id: "4".into(), state: "live".into(), ..Spec::default()
            },
            "INVERSE" => Spec {
                inst_type: "SWAP".into(), tick_sz: "0.1".into(), lot_sz: "0.1".into(), min_sz: "0.1".into(),
                ct_val: "100".into(), ct_mult: "1".into(), ct_type: "inverse".into(), ct_val_ccy: "USD".into(),
                settle_ccy: "BTC".into(), ..Spec::default()
            },
            "SPOT" => Spec {
                inst_type: "SPOT".into(), tick_sz: "0.01".into(), lot_sz: "0.000001".into(), min_sz: "0.0001".into(),
                base_ccy: "ETH".into(), quote_ccy: "USDT".into(), ..Spec::default()
            },
            "OPTION" => Spec {
                inst_type: "OPTION".into(), tick_sz: "0.0001".into(), lot_sz: "1".into(), min_sz: "1".into(),
                ct_val: "1".into(), ct_mult: "0.1".into(), ct_type: "inverse".into(), ct_val_ccy: "ETH".into(),
                settle_ccy: "ETH".into(), ..Spec::default()
            },
            "STOCK" => Spec { inst_type: "STOCK".into(), tick_sz: "0.01".into(), lot_sz: "1".into(), min_sz: "1".into(), ..Spec::default() },
            _ => unreachable!(),
        }
    }

    fn book(asks: &[(&str, &str)], bids: &[(&str, &str)], spec: Spec) -> BookView {
        let rows = |levels: &[(&str, &str)]| levels.iter().map(|(p, s)| LevelText { px: p.to_string(), sz: s.to_string(), orders: 1 }).collect();
        BookView {
            asks: rows(asks), bids: rows(bids), seq_id: Some(100), exchange_ms: Some(1_000), received_ms: Some(1_000),
            last: Some(Stamped { px: "2682.44".into(), ms: 1_000 }), spec: Some(spec), state: Some("live".into()),
            sizes_known: true,
        }
    }

    fn eth_book() -> BookView {
        book(
            &[("2682.45", "10"), ("2682.50", "5"), ("2682.60", "7"), ("2682.70", "20")],
            &[("2682.44", "8"), ("2682.40", "4"), ("2682.30", "2"), ("2682.00", "50")],
            spec("SWAP"),
        )
    }

    fn long_swap(quantity: f64) -> Holding {
        Holding {
            inst_id: "ETH-USDT-SWAP".into(), family: Family::Swap, is_long: true, quantity, unit: "张".into(),
            pos_side: Some(PosSide::Long), margin_mode: Some("isolated".into()), average_price: Some(2600.0),
            liquidation_price: Some(2400.0),
        }
    }

    fn input(holding: Holding, ticket: Ticket) -> PlanInput {
        PlanInput {
            venue: Venue::Okx, mode: "demo".into(), holding, ticket, account: Some(Account { level: Some(2) }),
            fees: Some(FeeRates { maker: 0.00016, taker: 0.00045 }), working: Some(Vec::new()), working_unread: None,
            client_id: Some("msmanual".into()), now_ms: 1_500,
        }
    }

    fn limit(source: PriceSource, kind: OrderKind, size: SizeRequest) -> Ticket {
        Ticket { method: Method::Limit, size, price: source, limit_kind: kind, max_chase_pct: 0.2, take_profit: None, stop_loss: None }
    }

    fn body(plan: &ClosePlan) -> Value {
        serde_json::from_str(&plan.wire.as_ref().unwrap().body).unwrap()
    }

    #[test]
    fn counterparty_and_queue_levels_are_read_from_the_side_they_name() {
        let cases = [
            (PriceSource::Counterparty { level: 1 }, "2682.44"),
            (PriceSource::Counterparty { level: 3 }, "2682.3"),
            (PriceSource::Queue { level: 1 }, "2682.45"),
            (PriceSource::Queue { level: 2 }, "2682.5"),
            (PriceSource::Mid, "2682.45"),
            (PriceSource::Last, "2682.44"),
            (PriceSource::Fixed { price: 2690.001 }, "2690.01"),
        ];
        for (source, expected) in cases {
            let plan = plan(&input(long_swap(10.0), limit(source.clone(), OrderKind::Limit, SizeRequest::All)), &eth_book()).unwrap();
            assert_eq!(body(&plan)["px"], expected, "{source:?}");
            assert_eq!(body(&plan)["side"], "sell");
        }
        // A buy-back reads the other sides.
        let mut short = long_swap(10.0);
        short.is_long = false;
        short.pos_side = Some(PosSide::Short);
        short.liquidation_price = Some(2900.0);
        for (source, expected) in [(PriceSource::Counterparty { level: 2 }, "2682.5"), (PriceSource::Queue { level: 2 }, "2682.4"), (PriceSource::Mid, "2682.44"), (PriceSource::Fixed { price: 2600.009 }, "2600")] {
            let plan = plan(&input(short.clone(), limit(source.clone(), OrderKind::Limit, SizeRequest::All)), &eth_book()).unwrap();
            assert_eq!(body(&plan)["px"], expected, "{source:?}");
            assert_eq!(body(&plan)["side"], "buy");
        }
    }

    #[test]
    fn a_level_the_book_does_not_have_is_refused() {
        let error = plan(&input(long_swap(10.0), limit(PriceSource::Counterparty { level: 5 }, OrderKind::Limit, SizeRequest::All)), &eth_book()).unwrap_err();
        assert!(matches!(error, CloseError::NoLevel { available: 4, .. }), "{error:?}");
        assert!(plan(&input(long_swap(10.0), limit(PriceSource::Queue { level: 0 }, OrderKind::Limit, SizeRequest::All)), &eth_book()).is_err());
        assert!(plan(&input(long_swap(10.0), limit(PriceSource::Queue { level: 51 }, OrderKind::Limit, SizeRequest::All)), &eth_book()).is_err());
    }

    #[test]
    fn a_limit_walks_the_levels_it_reaches_and_rests_the_rest() {
        // Selling 14 at the third bid: 8 + 4 + 2 fill at once.
        let plan = plan(&input(long_swap(14.0), limit(PriceSource::Counterparty { level: 3 }, OrderKind::Limit, SizeRequest::All)), &eth_book()).unwrap();
        let fill = plan.estimate.taker.clone().unwrap();
        assert_eq!((fill.size, fill.levels, fill.worst), (14.0, 3, 2682.30));
        assert!((fill.average - (8.0 * 2682.44 + 4.0 * 2682.40 + 2.0 * 2682.30) / 14.0).abs() < 1e-9);
        assert!(plan.estimate.maker.is_none());
        // Selling 20 there: 14 fill, 6 rest at the limit.
        let plan = super::plan(&input(long_swap(20.0), limit(PriceSource::Counterparty { level: 3 }, OrderKind::Limit, SizeRequest::All)), &eth_book()).unwrap();
        assert_eq!(plan.estimate.maker, Some(Resting { size: 6.0, price: 2682.30 }));
        // The fee: taker on what fills, maker on what rests.
        let fee = plan.estimate.fee.unwrap();
        let expected = 0.00045 * 14.0 * 0.1 * plan.estimate.taker.unwrap().average + 0.00016 * 6.0 * 0.1 * 2682.30;
        assert!((fee.amount - expected).abs() < 1e-9 && fee.ccy == "USDT");
        // Proceeds: every contract's 0.1 ETH at its own price.
        let notional = plan.estimate.notional.clone().unwrap();
        let expected = (8.0 * 2682.44 + 4.0 * 2682.40 + 2.0 * 2682.30 + 6.0 * 2682.30) * 0.1;
        assert!((notional.amount - expected).abs() < 1e-6 && notional.ccy == "USDT");
        assert!(plan.review.lines.iter().any(|l| l.starts_with("成交额约 ")), "{:?}", plan.review.lines);
        assert!(plan.review.lines.iter().any(|l| l.starts_with("手续费约 ") && l.contains("taker 0.045% · maker 0.016%")));
        assert!(plan.review.lines.iter().any(|l| l.starts_with("实现盈亏约 +")));
        // Profit: (price − 2600) × size × 0.1 ETH, summed over both parts.
        let pnl = plan.estimate.pnl.unwrap();
        let expected = (8.0 * 2682.44 + 4.0 * 2682.40 + 2.0 * 2682.30 + 6.0 * 2682.30 - 20.0 * 2600.0) * 0.1;
        assert!((pnl.amount - expected).abs() < 1e-6, "{} vs {expected}", pnl.amount);
    }

    #[test]
    fn time_in_force_changes_what_happens_to_the_rest() {
        let ioc = plan(&input(long_swap(20.0), limit(PriceSource::Counterparty { level: 2 }, OrderKind::Ioc, SizeRequest::All)), &eth_book()).unwrap();
        assert_eq!(body(&ioc)["ordType"], "ioc");
        assert_eq!(ioc.estimate.taker.as_ref().unwrap().size, 12.0);
        assert_eq!(ioc.estimate.cancelled, 8.0);
        assert!(ioc.estimate.maker.is_none());
        let fok = plan(&input(long_swap(20.0), limit(PriceSource::Counterparty { level: 2 }, OrderKind::Fok, SizeRequest::All)), &eth_book()).unwrap();
        assert!(fok.estimate.taker.is_none() && fok.estimate.cancelled == 20.0);
        assert!(fok.review.warnings.iter().any(|w| w.contains("FOK 会整单撤销")));
        let maker = plan(&input(long_swap(20.0), limit(PriceSource::Queue { level: 1 }, OrderKind::PostOnly, SizeRequest::All)), &eth_book()).unwrap();
        assert_eq!(body(&maker)["ordType"], "post_only");
        assert_eq!(maker.estimate.maker, Some(Resting { size: 20.0, price: 2682.45 }));
        let crossing = plan(&input(long_swap(20.0), limit(PriceSource::Counterparty { level: 1 }, OrderKind::PostOnly, SizeRequest::All)), &eth_book());
        assert!(matches!(crossing, Err(CloseError::PostOnlyWouldTake { .. })), "a maker-only order that would take is cancelled by the exchange");
    }

    #[test]
    fn a_market_order_larger_than_the_book_says_so() {
        let mut ticket = limit(PriceSource::Counterparty { level: 1 }, OrderKind::Limit, SizeRequest::All);
        ticket.method = Method::Market;
        let plan = plan(&input(long_swap(100.0), ticket), &eth_book()).unwrap();
        assert_eq!(body(&plan)["ordType"], "market");
        assert!(body(&plan).get("px").is_none());
        assert_eq!(plan.estimate.taker.as_ref().unwrap().size, 64.0);
        assert_eq!(plan.estimate.beyond_book, 36.0);
        assert!(plan.estimate.slippage_bps.unwrap() > 0.0, "selling below the mid is a cost");
        assert!(plan.review.warnings.iter().any(|w| w.contains("可见的 4 档不够")));
    }

    #[test]
    fn the_whole_holding_is_floored_to_the_lot_and_the_rest_named() {
        let coin = Holding {
            inst_id: "ETH-USDT".into(), family: Family::Spot, is_long: true, quantity: 0.0408135, unit: "ETH".into(),
            pos_side: None, margin_mode: None, average_price: None, liquidation_price: None,
        };
        let spot = book(&[("2682.45", "10")], &[("2682.44", "8")], spec("SPOT"));
        let plan = plan(&input(coin.clone(), limit(PriceSource::Counterparty { level: 1 }, OrderKind::Limit, SizeRequest::All)), &spot).unwrap();
        assert_eq!(body(&plan)["sz"], "0.040813");
        assert_eq!(body(&plan)["tdMode"], "cash");
        assert!(body(&plan).get("reduceOnly").is_none(), "never on spot");
        assert!((plan.remainder - 0.0000005).abs() < 1e-12);
        assert!(plan.review.lines.iter().any(|l| l.contains("余下 0.0000005 ETH 不足一个最小单位")));
        // A sale is charged in the quote.
        assert_eq!(plan.estimate.fee.as_ref().unwrap().ccy, "USDT");
        assert!(plan.estimate.pnl.is_none(), "a coin balance has no cost here");
        // More than held is a request to open.
        let too_much = super::plan(&input(coin.clone(), limit(PriceSource::Counterparty { level: 1 }, OrderKind::Limit, SizeRequest::Amount { amount: 0.05 })), &spot);
        assert!(matches!(too_much, Err(CloseError::SizeAboveHolding { .. })));
        let tiny = super::plan(&input(coin, limit(PriceSource::Counterparty { level: 1 }, OrderKind::Limit, SizeRequest::Amount { amount: 0.00005 })), &spot);
        assert!(matches!(tiny, Err(CloseError::SizeBelowMinimum { .. })));
    }

    #[test]
    fn an_order_on_a_position_repeats_its_margin_mode() {
        let plan = plan(&input(long_swap(10.0), limit(PriceSource::Counterparty { level: 1 }, OrderKind::Limit, SizeRequest::All)), &eth_book()).unwrap();
        let b = body(&plan);
        assert_eq!(b["tdMode"], "isolated");
        assert_eq!(b["posSide"], "long");
        assert!(b.get("reduceOnly").is_none(), "a long/short leg carries none (51205)");
        assert_eq!(b["clOrdId"], "msmanual");
        let mut cash = long_swap(10.0);
        cash.margin_mode = Some("cash".into());
        assert_eq!(super::plan(&input(cash, limit(PriceSource::Counterparty { level: 1 }, OrderKind::Limit, SizeRequest::All)), &eth_book()).unwrap_err(), CloseError::UnknownMarginMode, "a perpetual is never held for cash");
        let mut unknown = long_swap(10.0);
        unknown.margin_mode = None;
        assert_eq!(super::plan(&input(unknown, limit(PriceSource::Counterparty { level: 1 }, OrderKind::Limit, SizeRequest::All)), &eth_book()).unwrap_err(), CloseError::UnknownMarginMode);
    }

    #[test]
    fn protection_is_checked_against_the_last_trade_and_liquidation() {
        let protect = |tp: Option<f64>, sl: Option<f64>| Ticket {
            method: Method::Protect, size: SizeRequest::All, price: touch(), limit_kind: OrderKind::Limit,
            max_chase_pct: 0.2, take_profit: tp, stop_loss: sl,
        };
        let plan = plan(&input(long_swap(10.0), protect(Some(2800.004), Some(2500.009))), &eth_book()).unwrap();
        let b = body(&plan);
        assert_eq!(b["ordType"], "oco");
        assert_eq!(b["tpTriggerPx"], "2800.01", "a long's target rounds up, away from the price");
        assert_eq!(b["slTriggerPx"], "2500", "its stop rounds down");
        assert_eq!(b["cxlOnClosePos"], "true", "account level 2 ties it to the position");
        assert_eq!(b["algoClOrdId"], "msmanual");
        assert_eq!(plan.estimate.legs.len(), 2);
        assert!(plan.review.lines.iter().any(|l| l.starts_with("止盈触发 2,800.01（距现价 +") && l.contains("盈亏约 +")), "{:?}", plan.review.lines);
        assert!(plan.review.lines.iter().any(|l| l.starts_with("止损触发 2,500.00（距现价 -") && l.contains("盈亏约 -")));
        let wrong = |tp, sl| super::plan(&input(long_swap(10.0), protect(tp, sl)), &eth_book()).unwrap_err();
        assert!(matches!(wrong(Some(2682.0), None), CloseError::TakeProfitWrongSide { .. }));
        assert!(matches!(wrong(None, Some(2690.0)), CloseError::StopLossWrongSide { .. }));
        assert!(matches!(wrong(None, Some(2300.0)), CloseError::StopLossBeyondLiquidation { .. }));
        assert_eq!(wrong(None, None), CloseError::NoProtectionLeg);
        // Unknown account level: untied, and the review says so.
        let mut untied = input(long_swap(10.0), protect(None, Some(2500.0)));
        untied.account = None;
        let plan = super::plan(&untied, &eth_book()).unwrap();
        assert!(body(&plan).get("cxlOnClosePos").is_none());
        assert!(plan.review.warnings.iter().any(|w| w.contains("不会随仓位平掉而自动撤销")));
    }

    #[test]
    fn a_chase_starts_at_the_queue_and_is_bounded() {
        let chase = |pct: f64| Ticket {
            method: Method::Chase, size: SizeRequest::All, price: touch(), limit_kind: OrderKind::Limit,
            max_chase_pct: pct, take_profit: None, stop_loss: None,
        };
        let plan = plan(&input(long_swap(10.0), chase(0.2)), &eth_book()).unwrap();
        assert_eq!(body(&plan)["ordType"], "chase");
        assert_eq!(body(&plan)["maxChaseVal"], "0.002");
        assert_eq!(plan.estimate.maker, Some(Resting { size: 10.0, price: 2682.45 }));
        for bad in [0.0, -1.0, 10.5, f64::NAN] {
            assert!(matches!(super::plan(&input(long_swap(10.0), chase(bad)), &eth_book()), Err(CloseError::ChaseOutOfRange(_))), "{bad}");
        }
    }

    #[test]
    fn inverse_and_option_arithmetic() {
        let holding = Holding {
            inst_id: "BTC-USD-SWAP".into(), family: Family::Swap, is_long: true, quantity: 10.0, unit: "张".into(),
            pos_side: Some(PosSide::Long), margin_mode: Some("cross".into()), average_price: Some(80_000.0), liquidation_price: None,
        };
        let terms = Terms::read(&spec("INVERSE")).unwrap();
        let profit = pnl(&holding, Some(&terms), 10.0, 84_000.0).unwrap();
        // 10 contracts of $100: $1,000, bought at 80k and sold at 84k.
        assert!((profit.amount - 1_000.0 * (1.0 / 80_000.0 - 1.0 / 84_000.0)).abs() < 1e-12 && profit.ccy == "BTC");
        let paid = fee(&holding, Some(&terms), 10.0, 84_000.0, 0.0005).unwrap();
        assert!((paid.amount - 0.0005 * 1_000.0 / 84_000.0).abs() < 1e-15);

        let option = Holding {
            inst_id: "ETH-USD-261009-2750-P".into(), family: Family::Option, is_long: true, quantity: 5.0, unit: "张".into(),
            pos_side: None, margin_mode: Some("cross".into()), average_price: Some(0.05), liquidation_price: None,
        };
        let terms = Terms::read(&spec("OPTION")).unwrap();
        let profit = pnl(&option, Some(&terms), 5.0, 0.06).unwrap();
        assert!((profit.amount - 0.01 * 5.0 * 0.1).abs() < 1e-12 && profit.ccy == "ETH");
        // The fee is the lesser of the rate on 0.5 ETH covered and 12.5% of
        // the premium.
        let cheap = fee(&option, Some(&terms), 5.0, 0.001, 0.0003).unwrap();
        assert!((cheap.amount - 0.125 * 0.001 * 0.5).abs() < 1e-15);
        let dear = fee(&option, Some(&terms), 5.0, 0.06, 0.0003).unwrap();
        assert!((dear.amount - 0.0003 * 0.5).abs() < 1e-15);
    }

    #[test]
    fn an_option_close_has_no_market_order_and_no_algo() {
        let option = Holding {
            inst_id: "ETH-USD-261009-2750-P".into(), family: Family::Option, is_long: true, quantity: 5.0, unit: "张".into(),
            pos_side: None, margin_mode: Some("cross".into()), average_price: Some(0.05), liquidation_price: None,
        };
        let book = book(&[("0.051", "5079")], &[("0.05", "1135")], spec("OPTION"));
        let mut ticket = limit(PriceSource::Counterparty { level: 1 }, OrderKind::Limit, SizeRequest::All);
        let plan = plan(&input(option.clone(), ticket.clone()), &book).unwrap();
        let b = body(&plan);
        assert_eq!(b["reduceOnly"], "true", "kept on options, deliberately");
        assert!(b.get("posSide").is_none());
        for method in [Method::Market, Method::Chase, Method::Protect] {
            ticket.method = method;
            assert!(matches!(super::plan(&input(option.clone(), ticket.clone()), &book), Err(CloseError::Unavailable(..))), "{method:?}");
        }
    }

    #[test]
    fn a_book_that_cannot_be_priced_from_is_refused() {
        let crossed = book(&[("2682.40", "1")], &[("2682.44", "1")], spec("SWAP"));
        assert!(matches!(plan(&input(long_swap(1.0), limit(touch(), OrderKind::Limit, SizeRequest::All)), &crossed), Err(CloseError::BadBook(_))));
        let unordered = book(&[("2682.50", "1"), ("2682.45", "1")], &[("2682.44", "1")], spec("SWAP"));
        assert!(matches!(plan(&input(long_swap(1.0), limit(touch(), OrderKind::Limit, SizeRequest::All)), &unordered), Err(CloseError::BadBook(_))));
    }

    #[test]
    fn schwab_plans_a_share_order_with_no_okx_request() {
        let shares = Holding {
            inst_id: "MU".into(), family: Family::Stock, is_long: true, quantity: 30.0, unit: "股".into(),
            pos_side: None, margin_mode: None, average_price: Some(100.0), liquidation_price: None,
        };
        let mut quote = book(&[("120.10", "0")], &[("120.00", "0")], spec("STOCK"));
        quote.sizes_known = false;
        let mut request = input(shares, limit(PriceSource::Counterparty { level: 1 }, OrderKind::Limit, SizeRequest::All));
        request.venue = Venue::Schwab;
        let plan = plan(&request, &quote).unwrap();
        assert!(plan.wire.is_none());
        assert!(plan.estimate.fee.is_none(), "no fee rates on this venue");
        assert_eq!(plan.estimate.taker.as_ref().map(|f| f.size), Some(30.0), "a quote without sizes is assumed to fill");
        assert!(plan.review.lines.iter().any(|l| l.contains("报价不含挂单量")));
        let pnl = plan.estimate.pnl.clone().unwrap();
        assert_eq!((pnl.amount, pnl.ccy.as_str(), pnl.text.as_str()), (600.0, "USD", "+600.00 USD"));
        let deeper = { let mut r = request.clone(); r.ticket.price = PriceSource::Counterparty { level: 2 }; r };
        assert!(matches!(super::plan(&deeper, &quote), Err(CloseError::NoLevel { .. })), "one level is all a quote has");
        request.ticket.limit_kind = OrderKind::Ioc;
        assert!(matches!(super::plan(&request, &quote), Err(CloseError::LimitKindUnavailable(_))));
    }

    #[test]
    fn the_review_names_live_money_and_other_closing_orders() {
        let mut request = input(long_swap(10.0), limit(touch(), OrderKind::Limit, SizeRequest::All));
        request.mode = "live".into();
        request.working = Some(vec![WorkingOrder {
            id: "1".into(), book: super::super::reads::Book::Algo, inst_id: "ETH-USDT-SWAP".into(), inst_type: "SWAP".into(),
            ord_type: "conditional".into(), side: "sell".into(), pos_side: Some("long".into()), price: None,
            trigger_price: Some(2500.0), stop_trigger_price: Some(2500.0), take_profit_trigger_price: None,
            size: None, close_fraction: Some(1.0), filled_size: 0.0, state: "live".into(), reduce_only: true,
            client_id: None, created_ms: None,
        }]);
        request.now_ms = 10_000;
        let plan = plan(&request, &eth_book()).unwrap();
        assert!(plan.review.warnings[0].contains("OKX实盘"));
        assert!(plan.review.warnings.iter().any(|w| w.contains("conditional 全平")));
        assert!(plan.review.warnings.iter().any(|w| w.contains("盘口已经 9 秒没有更新")));
        assert!(plan.review.headline.starts_with("卖出平多 ETH-USDT-SWAP 10 张 · 限价 2,682.44（对手价第 1 档）"), "{}", plan.review.headline);
        request.working = None;
        request.working_unread = Some("超时".into());
        assert!(super::plan(&request, &eth_book()).unwrap().review.warnings.iter().any(|w| w.contains("读不到这个标的的挂单（超时）")));
    }

    #[test]
    fn money_reads_in_its_own_currency() {
        let m = |amount: f64, ccy: &str| Money::of(amount, ccy);
        assert_eq!(money_text(&m(1234.5, "USDT"), false), "1,234.50 USDT");
        assert_eq!(money_text(&m(0.0038, "USDT"), false), "0.0038 USDT", "a small fee is not shown as nothing");
        assert_eq!(money_text(&m(0.0000123, "BTC"), true), "+0.000012 BTC");
        assert_eq!(money_text(&m(-2.08, "USDT"), true), "-2.08 USDT");
        assert_eq!(money_text(&m(0.0, "USDT"), true), "0.0000 USDT");
    }

    #[test]
    fn prices_read_as_the_instrument_quotes_them() {
        assert_eq!(format_price(83606.1, Some(2)), "83,606.10");
        assert_eq!(format_price(0.0215, Some(4)), "0.0215");
        assert_eq!(format_price(2682.4, None), "2,682.4");
        assert_eq!(grouped(-1234.5, 1), "-1,234.5");
        assert_eq!(grouped(-0.004, 2), "0.00");
        assert_eq!(grouped(999.0, 0), "999");
        assert_eq!(grouped(1000.0, 0), "1,000");
    }

    /// Random holdings, books and requests: whatever the planner sends is a
    /// close — the right side, never more than held, whole lots, a price on
    /// the tick that never gives away more than the source named.
    #[test]
    fn every_plan_is_a_valid_close() {
        let mut seed: u64 = 0x9E3779B97F4A7C15;
        let mut next = move |bound: u64| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed % bound.max(1)
        };
        let mut planned = 0;
        let mut refusals = std::collections::BTreeMap::<String, usize>::new();
        for _ in 0..20_000 {
            let is_long = next(2) == 0;
            let lots = 1 + next(5_000);
            let quantity = clean(lots as f64 * 0.01);
            let mut holding = long_swap(quantity);
            holding.is_long = is_long;
            holding.pos_side = Some(if next(4) == 0 { PosSide::Net } else if is_long { PosSide::Long } else { PosSide::Short });
            holding.margin_mode = Some(if next(2) == 0 { "cross" } else { "isolated" }.into());
            holding.liquidation_price = None;
            let bid_ticks = 200_000 + next(100_000) as i64;
            let spread = 1 + next(5) as i64;
            let depth = next(30) as usize;
            let text = |ticks: i64| format!("{}.{:02}", ticks / 100, ticks % 100);
            // Strictly ordered sides with random gaps between levels.
            let mut ask = bid_ticks + spread;
            let mut asks: Vec<(String, String)> = Vec::new();
            for _ in 0..depth {
                asks.push((text(ask), format!("{}", 1 + next(50))));
                ask += 1 + next(3) as i64;
            }
            let mut bid = bid_ticks;
            let mut bids: Vec<(String, String)> = Vec::new();
            for _ in 0..depth {
                bids.push((text(bid), format!("{}", 1 + next(50))));
                bid -= 1 + next(3) as i64;
            }
            fn as_ref(rows: &[(String, String)]) -> Vec<(&str, &str)> {
                rows.iter().map(|(p, s)| (p.as_str(), s.as_str())).collect()
            }
            let view = book(&as_ref(&asks), &as_ref(&bids), spec("SWAP"));
            let source = match next(5) {
                0 => PriceSource::Counterparty { level: 1 + next(8) as usize },
                1 => PriceSource::Queue { level: 1 + next(8) as usize },
                2 => PriceSource::Mid,
                3 => PriceSource::Last,
                _ => PriceSource::Fixed { price: (bid_ticks as f64 + next(2_000) as f64 - 1_000.0) / 100.0 + next(1_000) as f64 * 1e-5 },
            };
            let size = if next(3) == 0 { SizeRequest::All } else { SizeRequest::Amount { amount: quantity * (next(1_200) as f64 / 1_000.0) } };
            let kind = [OrderKind::Limit, OrderKind::PostOnly, OrderKind::Ioc, OrderKind::Fok][next(4) as usize];
            let method = [Method::Limit, Method::Market, Method::Chase][next(3) as usize];
            let mut ticket = limit(source.clone(), kind, size.clone());
            ticket.method = method;
            let request = input(holding.clone(), ticket);
            let plan = match plan(&request, &view) {
                Ok(plan) => plan,
                Err(error) => {
                    *refusals.entry(format!("{error:?}").split(['(', ' ', '{']).next().unwrap_or("").to_string()).or_insert(0) += 1;
                    continue;
                }
            };
            planned += 1;
            let b = body(&plan);
            assert_eq!(b["side"], if is_long { "sell" } else { "buy" });
            assert_eq!(b["tdMode"], holding.margin_mode.clone().unwrap());
            let sent: f64 = b["sz"].as_str().unwrap().parse().unwrap();
            assert!(sent > 0.0 && sent <= quantity + 1e-12, "sent {sent} of {quantity}");
            let lots_sent = sent / 0.01;
            assert!((lots_sent - lots_sent.round()).abs() < 1e-6, "whole lots: {sent}");
            assert_eq!(b.get("reduceOnly").is_some(), holding.pos_side == Some(PosSide::Net) || method == Method::Chase);
            if method == Method::Limit {
                let px: f64 = b["px"].as_str().unwrap().parse().unwrap();
                let ticks = px / 0.01;
                assert!((ticks - ticks.round()).abs() < 1e-6, "on the tick: {px}");
                if let PriceSource::Fixed { price } = source {
                    // Never worse for the holder than the price typed.
                    if is_long { assert!(px >= price - 1e-9, "{px} < {price}") } else { assert!(px <= price + 1e-9, "{px} > {price}") }
                    assert!((px - price).abs() < 0.01 + 1e-9);
                }
                if kind == OrderKind::PostOnly {
                    let touch = if is_long { bids.first() } else { asks.first() };
                    if let Some((touch, _)) = touch {
                        let touch: f64 = touch.parse().unwrap();
                        assert!(if is_long { px > touch } else { px < touch }, "a maker-only price never meets the other side");
                    }
                }
                let estimated = plan.estimate.taker.as_ref().map_or(0.0, |f| f.size)
                    + plan.estimate.maker.as_ref().map_or(0.0, |r| r.size) + plan.estimate.cancelled;
                assert!((estimated - sent).abs() < 1e-9, "the estimate accounts for every contract: {estimated} vs {sent}");
            }
            // What Swift sends back to be placed is the action planned.
            let document = serde_json::to_value(&plan).unwrap();
            let back: Action = serde_json::from_value(document["action"].clone()).unwrap();
            assert_eq!(back, plan.action);
            assert_eq!(wire::build(&back).unwrap().body, plan.wire.as_ref().unwrap().body);
        }
        assert!(planned > 5_000, "the random cases mostly plan: {planned}, refused {refusals:?}");
    }
}
