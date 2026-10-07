//! Polymarket's prices for the events behind this market's macro inputs: the
//! week's scheduled data and the war that sets the oil price first, then the
//! longer threads (the next rate decisions, Hormuz, the ceasefire).
//!
//! What is watched is declared once, in `TOPICS`, by series or event — never
//! by market id. A series rolls forward on its own (the next CPI print, the
//! next week's Hormuz count, the next month's daily questions), so the card
//! does not go stale when one market settles.
//!
//! A price is only shown where the book makes one: Polymarket's own rule is
//! the midpoint while the spread is at most `MAX_SPREAD`, else the last trade.
//! A market nobody has traded quotes 0.01/0.89 and the API still reports the
//! 0.45 midpoint as its price; that is not a probability, and it is shown as
//! having none.

use chrono::NaiveDate;
use serde_json::Value;

pub const GAMMA: &str = "https://gamma-api.polymarket.com";

/// Widest spread whose midpoint Polymarket itself displays as the price.
pub const MAX_SPREAD: f64 = 0.10;

/// How far ahead counts as "the coming week": a market settling on a New
/// York day up to this many days after today's. Polymarket names its
/// deadlines by New York day, so the window is counted the same way — a
/// CPI print on the 14th settles at 23:59 ET that day, inside a window that
/// opened on the 7th.
pub const UPCOMING_DAYS: u64 = 7;

pub struct Topic {
    pub id: &'static str,
    pub label: &'static str,
    /// Why it matters to the coin under review, with the measurement behind it.
    pub meaning: &'static str,
    pub source: Source,
    pub layout: Layout,
}

pub enum Source {
    /// Every open event of a series, soonest first, up to this many.
    Series(&'static str, usize),
    /// One event.
    Event(&'static str),
}

pub enum Layout {
    /// Mutually exclusive outcomes of each event (a rate decision, a CPI
    /// print): one line per event, a cell per outcome.
    Outcomes,
    /// The same question at successive deadlines ("by October 31?"): one
    /// line for the topic, a cell per deadline, earliest first.
    Deadlines,
    /// The same question asked of each day ("on October 8?"): one line, one
    /// cell — the nearest day still ahead. The rest of the month says
    /// nothing the next day will not.
    Daily,
}

impl Layout {
    pub fn id(&self) -> &'static str {
        match self {
            Layout::Outcomes => "outcomes",
            Layout::Deadlines => "deadlines",
            Layout::Daily => "daily",
        }
    }
}

/// Chosen by May on 2026-10-07 from the events settling that week: the CPI
/// print, the oil route, and the fighting around it; then the four threads
/// the card started with. Daily questions come as one event per month, so
/// their series are read two deep to cross a month's end.
pub const TOPICS: [Topic; 13] = [
    Topic {
        id: "core-cpi",
        label: "美国核心 CPI 环比",
        meaning: "通胀超预期 → 加息预期 → 美债收益率 → 币价（2026-09 小时相关：10 年美债期货 +0.23）",
        source: Source::Series("core-cpi-mom", 1),
        layout: Layout::Outcomes,
    },
    Topic {
        id: "israel-iran",
        label: "以伊停火延续到",
        meaning: "停火破裂是油价跳涨的直接来源",
        source: Source::Event("israel-x-iran-ceasefire-continues-throughptptpt-20260716224448963"),
        layout: Layout::Deadlines,
    },
    Topic {
        id: "hormuz-deal",
        label: "美伊达成霍尔木兹协议",
        meaning: "协议意味着通航恢复、油价回落",
        source: Source::Event("us-iran-hormuz-agreement-byptptpt-20260803235957575"),
        layout: Layout::Deadlines,
    },
    Topic {
        id: "hormuz-ships",
        label: "霍尔木兹本周通航船数",
        meaning: "直接量油路：船越少，油价越高；油价涨 1%，ETH 平均跌约 0.2%（2026-09 小时回归）",
        source: Source::Series("ships-transit-the-strait-of-hormuz", 1),
        layout: Layout::Outcomes,
    },
    Topic {
        id: "hormuz-attacks",
        label: "霍尔木兹航运遇袭",
        meaning: "油轮遇袭当天油价跳涨",
        source: Source::Series("hormuz-shipping-targeted", 2),
        layout: Layout::Daily,
    },
    Topic {
        id: "houthi-saudi",
        label: "胡塞对沙特动武",
        meaning: "2026-10-07 胡塞打沙特吉赞的炼油设施，布伦特回到 102",
        source: Source::Series("houthi-military-action-against-saudi-arabia-on", 2),
        layout: Layout::Daily,
    },
    Topic {
        id: "saudi-yemen",
        label: "沙特对也门动武",
        meaning: "也门战事升级牵动红海航运与沙特产能",
        source: Source::Series("saudi-arabia-military-action-against-yemen-on", 2),
        layout: Layout::Daily,
    },
    Topic {
        id: "israel-lebanon",
        label: "以色列对黎巴嫩动武",
        meaning: "中东战线是否扩大",
        source: Source::Series("israel-military-action-against-lebanon", 2),
        layout: Layout::Daily,
    },
    Topic {
        id: "russia-kyiv",
        label: "俄罗斯打基辅",
        meaning: "俄乌战事烈度；与油价、币价的关系弱",
        source: Source::Series("russia-target-kyiv-on", 2),
        layout: Layout::Daily,
    },
    Topic {
        id: "fomc",
        label: "美联储议息",
        meaning: "加息预期经美债收益率传到币价（2026-09 小时相关：10 年美债期货 +0.23）",
        source: Source::Series("fomc", 2),
        layout: Layout::Outcomes,
    },
    Topic {
        id: "hormuz",
        label: "霍尔木兹恢复正常通航",
        meaning: "通航决定油价；油价涨 1%，ETH 平均跌约 0.2%（2026-09 小时回归）",
        source: Source::Series("hormuz-traffic-returns-to-normal", 6),
        layout: Layout::Deadlines,
    },
    Topic {
        id: "ceasefire",
        label: "美伊停火延续到",
        meaning: "停火破裂是油价跳涨的直接来源",
        source: Source::Series("us-iran-ceasefire-continues", 2),
        layout: Layout::Deadlines,
    },
    Topic {
        id: "deal",
        label: "美伊达成最终核协议",
        meaning: "协议意味着解除封锁、油价回落",
        source: Source::Event("us-iran-final-nuclear-deal-by-20260621201254412"),
        layout: Layout::Deadlines,
    },
];

pub fn topic(id: &str) -> Option<&'static Topic> {
    TOPICS.iter().find(|t| t.id == id)
}

pub fn url(source: &Source) -> String {
    match source {
        Source::Series(slug, limit) => {
            format!("{GAMMA}/events?series_slug={slug}&closed=false&order=endDate&ascending=true&limit={limit}")
        }
        Source::Event(slug) => format!("{GAMMA}/events?slug={slug}"),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub title: String,
    /// When the event resolves, in ms.
    pub end_ms: i64,
    pub volume_24h: f64,
    pub liquidity: f64,
    /// Open markets only, in the order the event lists them.
    pub markets: Vec<Market>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Market {
    /// The event's name for this market ("25 bps increase", "October 31");
    /// empty for an event with a single market.
    pub label: String,
    pub end_ms: i64,
    /// The first outcome's price by Polymarket's display rule; none when
    /// the book is too wide and nothing has traded.
    pub probability: Option<f64>,
    /// The price is the last trade because the book is wider than
    /// `MAX_SPREAD`.
    pub from_last_trade: bool,
    /// The book and the tape as gamma reports them, for the first outcome;
    /// none where that side is empty.
    pub bid: Option<f64>,
    pub ask: Option<f64>,
    pub last_trade: Option<f64>,
    /// Price changes over the last hour, day and week, in price units
    /// (0.03 is three points); none where gamma omits them.
    pub change_1h: Option<f64>,
    pub change_1d: Option<f64>,
    pub change_1w: Option<f64>,
    pub volume_24h: f64,
}

/// Gamma's `/events` body. Closed markets are dropped; an event left with
/// none is dropped with them.
pub fn events(body: &str) -> Result<Vec<Event>, String> {
    let value: Value = serde_json::from_str(body).map_err(|e| format!("Polymarket 返回的不是 JSON：{e}"))?;
    let list = value.as_array().ok_or("Polymarket 返回的不是事件列表")?;
    let mut events = Vec::new();
    for event in list {
        if event.get("closed").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let markets: Vec<Market> = event
            .get("markets")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|m| m.get("closed").and_then(Value::as_bool) != Some(true))
            .filter_map(market)
            .collect();
        if markets.is_empty() {
            continue;
        }
        events.push(Event {
            title: text(event, "title").unwrap_or_default(),
            end_ms: time(event, "endDate").ok_or("Polymarket 事件没有 endDate")?,
            volume_24h: number(event, "volume24hr").unwrap_or(0.0),
            liquidity: number(event, "liquidity").unwrap_or(0.0),
            markets,
        });
    }
    Ok(events)
}

fn market(value: &Value) -> Option<Market> {
    let bid = number(value, "bestBid");
    let ask = number(value, "bestAsk");
    let last = number(value, "lastTradePrice").filter(|p| *p > 0.0);
    // An empty side prices at its bound: no bid is a bid of 0, no ask 1.
    let (floor, ceiling) = (bid.unwrap_or(0.0), ask.unwrap_or(1.0));
    let (probability, from_last_trade) = if ceiling - floor <= MAX_SPREAD + 1e-9 {
        (Some((floor + ceiling) / 2.0), false)
    } else {
        (last, last.is_some())
    };
    Some(Market {
        label: text(value, "groupItemTitle").unwrap_or_default(),
        end_ms: time(value, "endDate")?,
        probability,
        from_last_trade,
        bid,
        ask,
        last_trade: last,
        change_1h: number(value, "oneHourPriceChange"),
        change_1d: number(value, "oneDayPriceChange"),
        change_1w: number(value, "oneWeekPriceChange"),
        volume_24h: number(value, "volume24hr").unwrap_or(0.0),
    })
}

fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_string)
}

/// Gamma writes numbers both as numbers and as strings.
fn number(value: &Value, key: &str) -> Option<f64> {
    match value.get(key)? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
    .filter(|v: &f64| v.is_finite())
}

fn time(value: &Value, key: &str) -> Option<i64> {
    let text = value.get(key)?.as_str()?;
    chrono::DateTime::parse_from_rfc3339(text).ok().map(|t| t.timestamp_millis())
}

/// The calendar day a deadline names. Polymarket's deadlines are New York
/// days: "by September 30" ends 23:59 ET, which gamma writes either as
/// `…-09-30T23:59:00Z` or as `…-10-01T03:59:00Z`. Both are September 30 in
/// New York; read in UTC the second one would be a day late.
pub fn deadline_day(end_ms: i64) -> Option<String> {
    new_york_day(end_ms).map(|day| day.format("%Y-%m-%d").to_string())
}

fn new_york_day(ms: i64) -> Option<NaiveDate> {
    use chrono::TimeZone;
    let utc = chrono::DateTime::from_timestamp_millis(ms)?;
    // A deadline written as 23:59 UTC is 19:59 ET the same day; as 03:59 or
    // 04:59 UTC the next day, 23:59 ET — both land on the intended day.
    Some(chrono_tz::America::New_York.from_utc_datetime(&utc.naive_utc()).date_naive())
}

/// Whether a market settling at `end_ms` is still ahead and settles within
/// the coming week (`UPCOMING_DAYS`), both counted in New York days.
pub fn is_upcoming(end_ms: i64, now: i64) -> bool {
    match (new_york_day(end_ms), new_york_day(now)) {
        (Some(end), Some(today)) => end_ms > now && end <= today + chrono::Days::new(UPCOMING_DAYS),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Trimmed from `events?series_slug=us-iran-ceasefire-continues` on
    /// 2026-09-30: two settled deadlines, four traded ones, and one nobody
    /// has traded (0.01/0.89, reported price 0.45).
    const CEASEFIRE: &str = r#"[{"title":"US-Iran ceasefire continues through...?","endDate":"2026-10-31T12:00:00Z","closed":false,"volume24hr":253563.0,"liquidity":364065.1,"markets":[
        {"groupItemTitle":"September 25","closed":true,"bestBid":0.999,"bestAsk":1,"lastTradePrice":0.999,"endDate":"2026-09-25T23:59:00Z"},
        {"groupItemTitle":"September 30","closed":false,"bestBid":0.979,"bestAsk":0.983,"lastTradePrice":0.982,"oneDayPriceChange":0.0095,"endDate":"2026-09-30T23:59:00Z"},
        {"groupItemTitle":"October 31","closed":false,"bestBid":0.6,"bestAsk":0.61,"lastTradePrice":0.61,"oneDayPriceChange":0.03,"endDate":"2026-10-31T23:59:00Z"},
        {"groupItemTitle":"October 7","closed":false,"bestBid":0.01,"bestAsk":0.89,"lastTradePrice":null,"outcomePrices":"[\"0.45\", \"0.55\"]","endDate":"2026-10-08T03:59:00Z"}]}]"#;

    #[test]
    fn a_book_nobody_trades_has_no_probability() {
        let events = events(CEASEFIRE).unwrap();
        let markets = &events[0].markets;
        assert_eq!(markets.iter().map(|m| m.label.as_str()).collect::<Vec<_>>(), ["September 30", "October 31", "October 7"], "settled deadlines are dropped");
        assert!((markets[0].probability.unwrap() - 0.981).abs() < 1e-9);
        assert!((markets[1].probability.unwrap() - 0.605).abs() < 1e-9);
        assert_eq!((markets[1].bid, markets[1].ask, markets[1].last_trade), (Some(0.6), Some(0.61), Some(0.61)));
        assert_eq!((markets[1].change_1d, markets[1].change_1h), (Some(0.03), None), "an omitted change stays unknown, not zero");
        assert_eq!(markets[2].probability, None, "a 0.01/0.89 book with no trade is not 45%");
    }

    #[test]
    fn a_wide_book_that_has_traded_shows_its_last_trade() {
        let body = r#"[{"title":"t","endDate":"2026-10-01T03:59:00Z","markets":[{"bestBid":0.2,"bestAsk":0.5,"lastTradePrice":0.31,"endDate":"2026-10-01T03:59:00Z"}]}]"#;
        let market = &events(body).unwrap()[0].markets[0];
        assert_eq!(market.probability, Some(0.31));
        assert!(market.from_last_trade);
    }

    #[test]
    fn a_one_sided_book_is_priced_against_the_empty_side() {
        // Hormuz by September 30 on 2026-09-30: no bid, ask 0.001, reported 0.0005.
        let body = r#"[{"title":"Strait of Hormuz traffic returns to normal by September 30?","endDate":"2026-10-01T03:59:00Z","markets":[{"groupItemTitle":null,"bestAsk":"0.001","endDate":"2026-10-01T03:59:00Z"}]}]"#;
        let market = &events(body).unwrap()[0].markets[0];
        assert!((market.probability.unwrap() - 0.0005).abs() < 1e-12);
        assert_eq!((market.bid, market.ask), (None, Some(0.001)), "the empty side is reported empty");
        assert_eq!(market.label, "");
    }

    #[test]
    fn deadlines_are_new_york_days_whichever_way_gamma_writes_them() {
        let day = |text: &str| deadline_day(chrono::DateTime::parse_from_rfc3339(text).unwrap().timestamp_millis()).unwrap();
        assert_eq!(day("2026-09-30T23:59:00Z"), "2026-09-30");
        assert_eq!(day("2026-10-01T03:59:00Z"), "2026-09-30", "EDT");
        assert_eq!(day("2026-12-01T04:59:00Z"), "2026-11-30", "EST");
        assert_eq!(day("2026-10-29T03:59:00Z"), "2026-10-28", "the October FOMC decides on the 28th");
    }

    #[test]
    fn the_coming_week_is_counted_in_new_york_days() {
        let at = |text: &str| chrono::DateTime::parse_from_rfc3339(text).unwrap().timestamp_millis();
        // 23:30 CST on 2026-10-07 is 11:30 ET the same day.
        let now = at("2026-10-07T15:30:00Z");
        assert_eq!(UPCOMING_DAYS, 7, "the dates below are written for a seven-day window");
        assert!(is_upcoming(at("2026-10-15T03:59:00Z"), now), "a CPI print settling 23:59 ET on the 14th is inside");
        assert!(!is_upcoming(at("2026-10-16T03:59:00Z"), now), "the 15th is a day past the window");
        assert!(!is_upcoming(at("2026-10-07T15:00:00Z"), now), "a deadline already past is not ahead");
        assert!(is_upcoming(at("2026-10-08T03:59:00Z"), now), "tonight 23:59 ET is");
    }

    #[test]
    fn every_topic_is_declared_once_and_asks_gamma() {
        for (index, topic) in TOPICS.iter().enumerate() {
            assert!(TOPICS[..index].iter().all(|t| t.id != topic.id), "{} declared twice", topic.id);
            assert!(url(&topic.source).starts_with(GAMMA));
            assert!(!topic.label.is_empty() && !topic.meaning.is_empty());
        }
    }
}
