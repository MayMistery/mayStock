//! What one execution *is*, and how two records of the same account's trading
//! become one list.
//!
//! Two sources describe the same account and neither is complete. The venue's
//! own fill history knows every execution, whoever placed it, but only for a
//! rolling window — OKX returned exactly 2.98 days of it. The ledger this app
//! keeps knows only the fills it could attribute to a strategy through the
//! order tag, but it keeps them forever. A 「最近成交」 panel fed by either
//! one alone is wrong in a different direction, so they are unioned — and a
//! union needs a rule for when two records are the same execution.
//!
//! That rule is measured, not assumed. On the live OKX account (2026-09-20,
//! 63 fills in the window): `ordId` identified only **31** of them uniquely,
//! because one order fills in several pieces; `billId` and the pair
//! `(instId, tradeId)` each identified all **63**. An option's `tradeId` is a
//! per-instrument counter — the two live option fills are numbered `32` and
//! `50` — so a trade id without its instrument is not an identity at all, and
//! an earlier probe found 11 trade ids shared across two or three option
//! instruments.
//!
//! Hence: **a record is named by the strongest key its source stamped on it,
//! and two records name the same execution when any key they both carry
//! agrees.** Key overlap rather than id equality is what lets a row written
//! by an older build — which kept only a bare trade id — still be recognised
//! in the venue's re-reading of the same fill.
//!
//! Like everything else here this is a deterministic calculation over trading
//! data, and the answer must not depend on which side of the FFI asked.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

// MARK: - Vocabulary

/// Which of the two books a merged row came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FillSource {
    /// The app's own ledger: attributed to a strategy, with realised P&L this
    /// side computed.
    Ledger,
    /// The venue's fill history: everything on the account, attributed or not.
    Venue,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FillSide {
    Buy,
    Sell,
}

/// Which leg of a hedged position a fill touched. `Net` means the venue keeps
/// one net position for the instrument and does not say.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FillLeg {
    Long,
    Short,
    Net,
}

/// What a fill did to the leg it names.
///
/// Deliberately coarser than the ledger's open/add/close/flip: telling an
/// opener from an add needs a position book, and a fill read straight off the
/// venue has none. Grew or shrank is the whole of what the venue's own record
/// can honestly support, and it is enough to label a row and to decide
/// whether a stamped P&L means anything — an opener realises nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LegEffect {
    Increase,
    Decrease,
}

// MARK: - Records

/// One execution as one of the two books recorded it.
///
/// Every field but `instId` and `tsMs` is optional because the two books know
/// different things: the venue stamps a bill id, a trade id and a leg, the
/// ledger stores whatever it was given when the row was written. The rule
/// below asks for what is there rather than requiring a shape neither side
/// can always fill.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FillRecord {
    /// What the recording side called it.
    #[serde(default)]
    pub id: String,
    pub inst_id: String,
    #[serde(default)]
    pub trade_id: Option<String>,
    /// The venue's own ledger-line id, where it keeps one.
    #[serde(default)]
    pub bill_id: Option<String>,
    pub ts_ms: i64,
    #[serde(default)]
    pub side: Option<FillSide>,
    #[serde(default)]
    pub leg: Option<FillLeg>,
}

/// The two books, as the caller read them.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FillMergeRequest {
    #[serde(default)]
    pub ledger: Vec<FillRecord>,
    #[serde(default)]
    pub venue: Vec<FillRecord>,
}

/// One surviving row, pointing back at the record it came from so the caller
/// keeps its own presentation fields instead of shipping them across the FFI
/// and back.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MergedFill {
    pub source: FillSource,
    /// Index into `ledger` or `venue`, whichever `source` names.
    pub index: usize,
    /// The identity this execution is known by from here on.
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub leg_effect: Option<LegEffect>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FillMerge {
    /// Newest first.
    pub rows: Vec<MergedFill>,
    /// Venue rows dropped because the ledger already had them. Reported
    /// rather than discarded silently: it is the number that says how much of
    /// the venue's window this app had actually booked, and a zero on a busy
    /// account is the symptom that attribution is failing.
    pub matched: usize,
}

// MARK: - Identity

const KIND_BILL: &str = "bill";
const KIND_TRADE: &str = "trade";
const KINDS: [&str; 2] = [KIND_BILL, KIND_TRADE];

fn non_empty(value: &Option<String>) -> Option<&str> {
    value.as_deref().filter(|text| !text.is_empty())
}

/// True when `id` is already one of the keys below, rather than a raw id some
/// source handed us. A row named by this rule contributes the key it was
/// named by, instead of that key wrapped in another one.
fn is_key(id: &str) -> bool {
    KINDS.iter().any(|kind| {
        id.len() > kind.len() + 1 && id.starts_with(kind) && id.as_bytes()[kind.len()] == b':'
    })
}

/// Every key a record carries, strongest first.
///
/// The recorded id lands in the trade namespace because on every producer
/// here that is what it is — the venue's trade id, or a synthesised
/// `order-timestamp` when the venue gave none — and qualifying it with the
/// instrument turns a per-instrument counter into an identity.
///
/// There is deliberately no order-id key. `ordId` identified only 31 of the
/// 63 live fills because one order fills in several pieces, and those pieces
/// can share a millisecond, so an order key would merge distinct executions —
/// the one failure this whole rule exists to prevent. The ledger does not
/// record `ordId` either, so it would buy no cross-book matching in exchange.
pub fn keys(record: &FillRecord) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(3);
    if let Some(bill) = non_empty(&record.bill_id) {
        out.push(format!("{KIND_BILL}:{bill}"));
    }
    if let Some(trade) = non_empty(&record.trade_id) {
        out.push(format!("{KIND_TRADE}:{}|{}", record.inst_id, trade));
    }
    if !record.id.is_empty() {
        let key = if is_key(&record.id) {
            record.id.clone()
        } else {
            format!("{KIND_TRADE}:{}|{}", record.inst_id, record.id)
        };
        if !out.contains(&key) {
            // A row named by its bill id is stronger than the trade key it
            // also carries, so insertion order still has to put it first.
            let position = if key.starts_with(KIND_BILL) { 0 } else { out.len() };
            out.insert(position, key);
        }
    }
    if out.is_empty() {
        // Nothing to key on at all. Still deterministic, and still distinct
        // from another fill on the same instrument at another instant.
        out.push(format!("{KIND_TRADE}:{}|@{}", record.inst_id, record.ts_ms));
    }
    out
}

/// What this execution is called from here on: the strongest key it carries.
///
/// A book that keeps its own index of what it has booked must not use this to
/// test *membership* — see [`keys`]. Naming is one key; recognising is any.
pub fn identity(record: &FillRecord) -> String {
    keys(record).swap_remove(0)
}

/// What a fill did to the leg it names, or nil when the venue keeps one net
/// position and so cannot say.
pub fn leg_effect(side: Option<FillSide>, leg: Option<FillLeg>) -> Option<LegEffect> {
    match (side?, leg?) {
        (FillSide::Buy, FillLeg::Long) | (FillSide::Sell, FillLeg::Short) => Some(LegEffect::Increase),
        (FillSide::Sell, FillLeg::Long) | (FillSide::Buy, FillLeg::Short) => Some(LegEffect::Decrease),
        (_, FillLeg::Net) => None,
    }
}

// MARK: - Merge

/// Union the two books, newest first.
///
/// The ledger wins a tie. It is the side that attributed the fill to a
/// strategy and computed what the fill realised against its own position, and
/// the venue's copy of the same execution carries neither.
pub fn merge(request: &FillMergeRequest) -> FillMerge {
    let mut seen: HashSet<String> = HashSet::with_capacity(request.ledger.len() + request.venue.len());
    let mut rows: Vec<(i64, MergedFill)> = Vec::with_capacity(request.ledger.len() + request.venue.len());
    let mut matched = 0usize;

    for (source, records) in [
        (FillSource::Ledger, &request.ledger),
        (FillSource::Venue, &request.venue),
    ] {
        for (index, record) in records.iter().enumerate() {
            let record_keys = keys(record);
            if record_keys.iter().any(|key| seen.contains(key)) {
                if source == FillSource::Venue {
                    matched += 1;
                }
                continue;
            }
            let id = record_keys[0].clone();
            for key in record_keys {
                seen.insert(key);
            }
            rows.push((
                record.ts_ms,
                MergedFill {
                    source,
                    index,
                    id,
                    leg_effect: leg_effect(record.side, record.leg),
                },
            ));
        }
    }

    // Newest first, with the id breaking ties so the order does not depend on
    // which book happened to be read first.
    rows.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
    FillMerge {
        rows: rows.into_iter().map(|(_, row)| row).collect(),
        matched,
    }
}

/// The identity of every record, in the order given and with nothing dropped.
///
/// The merge answers "which of these are new"; this answers "what is each one
/// called". A book that keeps its own index of what it has already booked
/// needs the second question, and must not spell the key itself — two
/// spellings of one rule is one spelling too many.
///
/// Callers that must recognise a record rather than name it want [`keys`]:
/// naming picks one key, recognising accepts any.
pub fn identities(records: &[FillRecord]) -> Vec<String> {
    records.iter().map(identity).collect()
}

/// Every record's key set, one entry per record in the order given.
///
/// What a book that has to answer "have I already booked this?" actually
/// needs. Union the sets and test membership: an execution written by an older
/// build under its trade id is still recognised in a listing that now also
/// carries the bill id, which naming alone would miss.
pub fn key_sets(records: &[FillRecord]) -> Vec<Vec<String>> {
    records.iter().map(keys).collect()
}

/// How many distinct executions a set of records describes. Used by tests and
/// by callers measuring whether a candidate key is an identity at all.
pub fn distinct(records: &[FillRecord]) -> usize {
    let mut seen: HashSet<String> = HashSet::with_capacity(records.len());
    let mut groups = 0usize;
    for record in records {
        let record_keys = keys(record);
        // Two records are the same execution when any key agrees, so a new
        // group is one whose keys are entirely unseen — the same rule `merge`
        // applies, asked as a count instead of as a list.
        if record_keys.iter().any(|key| seen.contains(key)) {
            continue;
        }
        for key in record_keys {
            seen.insert(key);
        }
        groups += 1;
    }
    groups
}

#[cfg(test)]
mod tests {
    use super::*;

    fn venue_fill(inst: &str, trade: &str, bill: &str, ts: i64) -> FillRecord {
        FillRecord {
            id: trade.to_string(),
            inst_id: inst.to_string(),
            trade_id: Some(trade.to_string()),
            bill_id: Some(bill.to_string()),
            ts_ms: ts,
            side: Some(FillSide::Buy),
            leg: Some(FillLeg::Short),
        }
    }

    /// The old ledger rows on disk: a bare trade id and nothing else.
    fn legacy_ledger_fill(inst: &str, id: &str, ts: i64) -> FillRecord {
        FillRecord {
            id: id.to_string(),
            inst_id: inst.to_string(),
            ts_ms: ts,
            ..FillRecord::default()
        }
    }

    #[test]
    fn a_bare_trade_id_matches_the_venues_own_record_of_it() {
        let request = FillMergeRequest {
            ledger: vec![legacy_ledger_fill("ETH-USDT-SWAP", "4319032649", 10)],
            venue: vec![venue_fill("ETH-USDT-SWAP", "4319032649", "b1", 10)],
        };
        let merged = merge(&request);
        assert_eq!(merged.rows.len(), 1, "the same execution counted twice");
        assert_eq!(merged.matched, 1);
        assert_eq!(merged.rows[0].source, FillSource::Ledger);
    }

    #[test]
    fn a_row_named_by_this_rule_is_recognised_next_time() {
        // What the ledger stores once it has been through here: the key, not
        // a raw id. It must still match the venue's record of the same fill.
        let named = FillRecord {
            id: "bill:b1".to_string(),
            inst_id: "ETH-USDT-SWAP".to_string(),
            ts_ms: 10,
            ..FillRecord::default()
        };
        let request = FillMergeRequest {
            ledger: vec![named],
            venue: vec![venue_fill("ETH-USDT-SWAP", "4319032649", "b1", 10)],
        };
        assert_eq!(merge(&request).rows.len(), 1);
    }

    #[test]
    fn a_trade_id_is_not_an_identity_without_its_instrument() {
        // Two live option fills really are numbered 32 and 50 on different
        // instruments; a counter shared across instruments must not collapse.
        let records = vec![
            legacy_ledger_fill("ETH-USD-260919-2610-C", "32", 10),
            legacy_ledger_fill("ETH-USD-260919-2625-C", "32", 20),
        ];
        assert_eq!(distinct(&records), 2);
    }

    #[test]
    fn a_key_set_carries_every_name_a_record_is_known_by() {
        // The ledger's dedupe reads these: a row written by an older build
        // knows only the trade id, and today's listing of the same execution
        // carries the bill id too. Naming alone would miss it; overlap does
        // not, and the strongest key still comes first.
        let sets = key_sets(&[venue_fill("ETH-USDT-SWAP", "4294122652", "3931253135398440960", 10)]);
        assert_eq!(
            sets[0],
            vec![
                "bill:3931253135398440960".to_string(),
                "trade:ETH-USDT-SWAP|4294122652".to_string(),
            ]
        );
        let legacy = key_sets(&[legacy_ledger_fill("ETH-USDT-SWAP", "4294122652", 10)]);
        assert!(sets[0].iter().any(|key| legacy[0].contains(key)));
    }

    #[test]
    fn distinct_counts_by_overlap_not_by_name() {
        // Same execution, two spellings of it: one row names it by bill id,
        // the other only by trade id. One execution, so one group.
        let records = vec![
            venue_fill("ETH-USDT-SWAP", "4294122652", "b1", 10),
            legacy_ledger_fill("ETH-USDT-SWAP", "4294122652", 10),
        ];
        assert_eq!(distinct(&records), 1);
        assert_eq!(identity(&records[0]), "bill:b1");
        assert_eq!(identity(&records[1]), "trade:ETH-USDT-SWAP|4294122652");
    }

    #[test]
    fn one_order_filling_in_pieces_stays_several_fills() {
        // `ordId` identified only 31 of 63 live fills; the pieces differ by
        // trade id, and that is what must decide.
        let request = FillMergeRequest {
            ledger: vec![],
            venue: vec![
                venue_fill("BTC-USDT-SWAP", "1", "b1", 10),
                venue_fill("BTC-USDT-SWAP", "2", "b2", 10),
            ],
        };
        assert_eq!(merge(&request).rows.len(), 2);
    }

    #[test]
    fn the_union_is_newest_first_and_keeps_what_neither_book_has_alone() {
        let request = FillMergeRequest {
            ledger: vec![legacy_ledger_fill("BTC-USDT", "old", 1_000)],
            venue: vec![venue_fill("BTC-USDT-SWAP", "new", "b9", 9_000)],
        };
        let merged = merge(&request);
        assert_eq!(merged.matched, 0);
        assert_eq!(merged.rows.len(), 2);
        assert_eq!(merged.rows[0].source, FillSource::Venue);
        assert_eq!(merged.rows[1].source, FillSource::Ledger);
    }

    #[test]
    fn a_leg_says_whether_the_fill_grew_or_shrank_it() {
        use FillLeg::*;
        use FillSide::*;
        assert_eq!(leg_effect(Some(Buy), Some(Long)), Some(LegEffect::Increase));
        assert_eq!(leg_effect(Some(Sell), Some(Short)), Some(LegEffect::Increase));
        assert_eq!(leg_effect(Some(Sell), Some(Long)), Some(LegEffect::Decrease));
        assert_eq!(leg_effect(Some(Buy), Some(Short)), Some(LegEffect::Decrease));
        assert_eq!(leg_effect(Some(Buy), Some(Net)), None);
        assert_eq!(leg_effect(None, Some(Long)), None);
    }

    #[test]
    fn identities_are_returned_one_per_record_in_order() {
        let records = vec![
            legacy_ledger_fill("A", "1", 1),
            legacy_ledger_fill("A", "1", 1),
            legacy_ledger_fill("B", "1", 1),
        ];
        let ids = identities(&records);
        assert_eq!(ids.len(), 3, "nothing may be dropped here");
        assert_eq!(ids[0], ids[1]);
        assert_ne!(ids[0], ids[2]);
    }

    /// The rule against the account it was written for.
    ///
    /// Every fill the live OKX account returned on 2026-09-21 — 52 of them
    /// across four instruments, including two option contracts whose trade ids
    /// are a per-instrument counter. Three properties, all of which the old
    /// rules failed:
    ///
    /// - every fill is a distinct execution (an order key collapsed them);
    /// - no two fills share an identity (an unqualified trade id collapsed the
    ///   two option contracts' counters);
    /// - a listing re-read by a book that already booked all of it — under the
    ///   ids an older build stored — matches every row and adds nothing.
    #[test]
    fn the_live_accounts_fills_are_each_their_own_execution() {
        // (instId, tradeId, billId, side, tsMs, leg) as the venue returned them.
        let raw: [(&str, &str, &str, &str, &str, &str); 52] = [
            ("ETH-USDT-SWAP", "4295969335", "3933126824075235329", "sell", "1789718713602", "short"),
            ("ETH-USDT-SWAP", "4296228156", "3933252612225273856", "buy", "1789722462381", "short"),
            ("ETH-USDT-SWAP", "4296238938", "3933254297865719810", "buy", "1789722512617", "long"),
            ("ETH-USDT-SWAP", "4296238937", "3933254297865719809", "buy", "1789722512617", "long"),
            ("ETH-USDT-SWAP", "4296238941", "3933254297899274242", "buy", "1789722512618", "long"),
            ("ETH-USDT-SWAP", "4296238940", "3933254297899274241", "buy", "1789722512618", "long"),
            ("ETH-USDT-SWAP", "4296238939", "3933254297899274240", "buy", "1789722512618", "long"),
            ("ETH-USDT-SWAP", "4296238943", "3933254297966383105", "buy", "1789722512620", "long"),
            ("ETH-USDT-SWAP", "4296238942", "3933254297966383104", "buy", "1789722512620", "long"),
            ("ETH-USDT-SWAP", "4296238944", "3933254298469699584", "buy", "1789722512635", "long"),
            ("ETH-USDT-SWAP", "4296238946", "3933254299140788225", "buy", "1789722512655", "long"),
            ("ETH-USDT-SWAP", "4296238945", "3933254299140788224", "buy", "1789722512655", "long"),
            ("ETH-USDT-SWAP", "4296238947", "3933254299174342656", "buy", "1789722512656", "long"),
            ("ETH-USDT-SWAP", "4296247028", "3933256596277202944", "sell", "1789722581115", "long"),
            ("ETH-USDT-SWAP", "4297669717", "3933841727220125707", "buy", "1789740019376", "long"),
            ("ETH-USDT-SWAP", "4298259836", "3933931577633968128", "sell", "1789742697127", "long"),
            ("ETH-USDT-SWAP", "4298259837", "3933931577969512448", "sell", "1789742697137", "long"),
            ("ETH-USDT-SWAP", "4298259856", "3933931589512237056", "sell", "1789742697481", "long"),
            ("ETH-USDT-SWAP", "4298259857", "3933931590216880128", "sell", "1789742697502", "long"),
            ("ETH-USDT-SWAP", "4298259867", "3933931593471660032", "sell", "1789742697599", "long"),
            ("ETH-USDT-SWAP", "4298259868", "3933931595350708224", "sell", "1789742697655", "long"),
            ("ETH-USDT-SWAP", "4298259950", "3933931629509120000", "sell", "1789742698673", "long"),
            ("ETH-USDT-SWAP", "4298259951", "3933931632059256832", "sell", "1789742698749", "long"),
            ("ETH-USDT-SWAP", "4298259952", "3933931634307403776", "sell", "1789742698816", "long"),
            ("ETH-USDT-SWAP", "4299210558", "3934181317499981825", "sell", "1789750139955", "short"),
            ("ETH-USDT", "876928769", "3934387344061272068", "buy", "1789756280025", "net"),
            ("ETH-USDT-SWAP", "4299642554", "3934393250681491456", "sell", "1789756456056", "short"),
            ("ETH-USDT-SWAP", "4299652254", "3934394498235273216", "sell", "1789756493236", "short"),
            ("ETH-USD-260919-2625-C", "50", "3934413639361007618", "buy", "1789757063686", "net"),
            ("ETH-USDT", "876948562", "3934449497707417601", "buy", "1789758132348", "net"),
            ("ETH-USD-260919-2610-C", "32", "3934449531798720515", "buy", "1789758133364", "net"),
            ("ETH-USDT-SWAP", "4301471892", "3936052559119159296", "sell", "1789805907301", "short"),
            ("ETH-USDT-SWAP", "4301471893", "3936052565259620352", "sell", "1789805907484", "short"),
            ("ETH-USDT-SWAP", "4301471897", "3936052595727044608", "sell", "1789805908392", "short"),
            ("ETH-USDT-SWAP", "4301572122", "3936059071296212993", "sell", "1789806101379", "short"),
            ("ETH-USDT-SWAP", "4301572123", "3936059071329767424", "sell", "1789806101380", "short"),
            ("ETH-USDT-SWAP", "4302250029", "3936826413978521601", "buy", "1789828969973", "long"),
            ("ETH-USDT-SWAP", "4302250036", "3936826418005053440", "buy", "1789828970093", "long"),
            ("ETH-USDT-SWAP", "4302250340", "3936826738382770176", "buy", "1789828979641", "long"),
            ("ETH-USDT-SWAP", "4302355349", "3936951745050087424", "sell", "1789832705130", "long"),
            ("ETH-USDT-SWAP", "4302399543", "3936992977138782210", "buy", "1789833933942", "long"),
            ("ETH-USDT-SWAP", "4302399542", "3936992977138782209", "buy", "1789833933942", "long"),
            ("ETH-USDT-SWAP", "4302425830", "3937014697593704448", "sell", "1789834581262", "long"),
            ("ETH-USDT-SWAP", "4302425832", "3937014715981533184", "sell", "1789834581810", "long"),
            ("ETH-USDT-SWAP", "4302425833", "3937014728094683136", "sell", "1789834582171", "long"),
            ("ETH-USDT-SWAP", "4302570896", "3937142130112237568", "sell", "1789838379047", "short"),
            ("ETH-USDT-SWAP", "4302591097", "3937149204695126019", "buy", "1789838589886", "short"),
            ("ETH-USDT-SWAP", "4302591098", "3937149204728680448", "buy", "1789838589887", "short"),
            ("ETH-USDT-SWAP", "4303443700", "3938278136177790977", "buy", "1789872234666", "short"),
            ("ETH-USDT-SWAP", "4303807040", "3938342352851079170", "buy", "1789874148472", "short"),
            ("ETH-USDT-SWAP", "4303807039", "3938342352851079169", "buy", "1789874148472", "short"),
            ("ETH-USDT-SWAP", "4304838684", "3939532730283364352", "buy", "1789909624484", "short"),
        ];
        let venue: Vec<FillRecord> = raw
            .iter()
            .map(|(inst, trade, bill, side, ts, leg)| FillRecord {
                id: trade.to_string(),
                inst_id: inst.to_string(),
                trade_id: Some(trade.to_string()),
                bill_id: Some(bill.to_string()),
                ts_ms: ts.parse().unwrap(),
                side: Some(if *side == "buy" { FillSide::Buy } else { FillSide::Sell }),
                leg: Some(match *leg {
                    "long" => FillLeg::Long,
                    "short" => FillLeg::Short,
                    _ => FillLeg::Net,
                }),
            })
            .collect();

        assert_eq!(venue.len(), 52, "the fixture is the whole listing");
        assert_eq!(distinct(&venue), venue.len(), "every fill is its own execution");
        let named = identities(&venue);
        assert_eq!(
            named.iter().collect::<HashSet<_>>().len(),
            venue.len(),
            "no two fills share an identity"
        );

        // The same listing booked by a build that kept only trade ids — what
        // the ledger on disk holds before this rule existed.
        let legacy: Vec<FillRecord> = venue
            .iter()
            .map(|r| FillRecord {
                id: r.trade_id.clone().unwrap(),
                inst_id: r.inst_id.clone(),
                trade_id: r.trade_id.clone(),
                bill_id: None,
                ..FillRecord::default()
            })
            .collect();
        let merged = merge(&FillMergeRequest {
            ledger: legacy,
            venue: venue.clone(),
        });
        assert_eq!(merged.matched, venue.len(), "every venue row is recognised");
        assert_eq!(merged.rows.len(), venue.len(), "and none is dropped or doubled");
    }

    #[test]
    fn a_record_with_no_ids_at_all_still_gets_one() {
        let bare = FillRecord {
            inst_id: "BTC-USDT".to_string(),
            ts_ms: 77,
            ..FillRecord::default()
        };
        assert_eq!(identity(&bare), "trade:BTC-USDT|@77");
    }
}
