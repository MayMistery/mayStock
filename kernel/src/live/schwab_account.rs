//! Schwab's account document — `schwabctl account`, which is
//! `GET /trader/v1/accounts/{hash}?fields=positions` — read once, here.
//!
//! The app's trading path and the live layer both read it through this
//! module (`ffi::ms_schwab_account_document`, `State::ingest`), so a holding
//! cannot be a share to one and nothing to the other. Until 2026-10-09 the
//! app read it in Swift and filed every option under "untracked", a list
//! nothing displayed: a call bought by hand was in the equity and nowhere
//! else — not on the positions page, not in the checkup.
//!
//! Field names are the Trader API schema's (cross-checked with schwab-go's
//! `Position` and `AccountInstrument`, 2026-10-09): a position carries
//! `longQuantity`/`shortQuantity`, `averagePrice`, `marketValue`, the open
//! and day profit, and its maintenance requirement; an option's instrument
//! adds `putCall`, `underlyingSymbol` and `optionMultiplier` but not the
//! strike or the expiry, which come from its OCC symbol (`us_options`).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::trade::wire::Family;
use crate::us_options::{UsOption, STANDARD_MULTIPLIER};

/// Schwab's asset types this app reads, and as which family. Anything else —
/// a bond, a mutual fund, a money-market sweep — is named in `unrecognised`
/// rather than folded into a count or dropped.
pub const FAMILIES: [(&str, Family); 4] =
    [("EQUITY", Family::Stock), ("ETF", Family::Stock), ("COLLECTIVE_INVESTMENT", Family::Stock), ("OPTION", Family::Option)];

pub fn family_of(asset_type: &str) -> Option<Family> {
    FAMILIES.iter().find(|(name, _)| name.eq_ignore_ascii_case(asset_type)).map(|(_, family)| *family)
}

/// One account, as every reader gets it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchwabAccount {
    pub account_number: String,
    /// `MARGIN` or `CASH`.
    #[serde(rename = "type")]
    pub kind: String,
    pub cash: f64,
    /// Schwab's own liquidation value: what the account is worth now.
    pub equity: Option<f64>,
    pub available_funds: Option<f64>,
    pub buying_power: Option<f64>,
    pub maintenance_requirement: Option<f64>,
    pub positions: Vec<SchwabHolding>,
    /// Holdings of a family this app does not read, as `SYMBOL（ASSET_TYPE）`.
    pub unrecognised: Vec<String>,
}

/// One holding: shares, or contracts of one option.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchwabHolding {
    /// As Schwab spells it — the OCC symbol, padding kept, for an option.
    pub symbol: String,
    /// Schwab's own word for the family.
    pub asset_type: String,
    pub family: Family,
    /// Long minus short: shares, or contracts.
    pub quantity: f64,
    /// A share's price, or an option's premium a share.
    pub average_price: f64,
    /// Schwab's valuation, in dollars; negative for a short.
    pub market_value: f64,
    pub day_profit_loss: Option<f64>,
    /// Schwab's open profit on the holding, long and short legs together.
    pub open_profit_loss: Option<f64>,
    pub maintenance_requirement: Option<f64>,
    pub option: Option<OptionTerms>,
    /// What about this row is not as read — said, never silent.
    pub note: Option<String>,
}

/// What an option holding is a contract on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OptionTerms {
    pub underlying: String,
    pub call: bool,
    pub strike: f64,
    /// `2026-11-20`, the date in the symbol.
    pub expiry_day: String,
    /// When it stops trading (`UsOption::expiry_ms`).
    pub expiry_ms: i64,
    /// Shares one contract delivers.
    pub multiplier: f64,
    pub description: Option<String>,
    /// What one contract delivers, where that is not `multiplier` shares of
    /// the underlying — an adjusted contract after a split or a merger
    /// (`33 ETHA` on ETHA1, 2026-10-09). None for a standard contract.
    pub nonstandard: Option<String>,
}

impl SchwabHolding {
    /// The contract this holding is, when it is an option.
    pub fn contract(&self) -> Option<UsOption> {
        self.option.as_ref().and_then(|_| UsOption::parse(&self.symbol).ok())
    }

    /// Shares the holding moves with: its own count, or its contracts'.
    pub fn units(&self) -> f64 {
        self.quantity * self.option.as_ref().map_or(1.0, |o| o.multiplier)
    }

    /// The underlying a holding is exposed to: its own symbol for shares.
    pub fn underlying(&self) -> &str {
        self.option.as_ref().map_or(self.symbol.as_str(), |o| o.underlying.as_str())
    }
}

fn number(object: &Value, key: &str) -> Option<f64> {
    match object.get(key)? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
    .filter(|v: &f64| v.is_finite())
}

fn text(object: &Value, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

/// The document as `schwabctl account` prints it: the object
/// `GET /accounts/{hash}` returns, or the array `GET /accounts` returns.
pub fn read(document: &str) -> Result<SchwabAccount, String> {
    let value: Value = serde_json::from_str(document).map_err(|_| "嘉信账户文档不是 JSON".to_string())?;
    let wrapper = match &value {
        Value::Object(_) => &value,
        Value::Array(list) => list.first().ok_or("嘉信账户文档是空列表")?,
        _ => return Err("嘉信账户文档既不是对象也不是列表".into()),
    };
    let account = wrapper.get("securitiesAccount").ok_or("嘉信账户文档没有 securitiesAccount")?;
    let balances = account.get("currentBalances").cloned().unwrap_or(Value::Null);
    let aggregated = wrapper.get("aggregatedBalance").cloned().unwrap_or(Value::Null);
    let mut positions = Vec::new();
    let mut unrecognised = Vec::new();
    for row in account.get("positions").and_then(Value::as_array).into_iter().flatten() {
        match holding(row) {
            Ok(Some(holding)) => positions.push(holding),
            Ok(None) => {}
            Err(named) => unrecognised.push(named),
        }
    }
    Ok(SchwabAccount {
        account_number: text(account, "accountNumber").unwrap_or_default(),
        kind: text(account, "type").unwrap_or_default(),
        cash: number(&balances, "cashBalance").unwrap_or(0.0),
        equity: number(&balances, "liquidationValue").or_else(|| number(&aggregated, "liquidationValue")),
        available_funds: number(&balances, "availableFunds").or_else(|| number(&balances, "cashAvailableForTrading")),
        buying_power: number(&balances, "buyingPower"),
        maintenance_requirement: number(&balances, "maintenanceRequirement"),
        positions,
        unrecognised,
    })
}

/// One position row: a holding, nothing (a flat row), or — for a family this
/// app does not read, or an option whose symbol does not parse — its name.
fn holding(row: &Value) -> Result<Option<SchwabHolding>, String> {
    let instrument = row.get("instrument").cloned().unwrap_or(Value::Null);
    let symbol = instrument.get("symbol").and_then(Value::as_str).unwrap_or("?").to_string();
    let asset_type = text(&instrument, "assetType").unwrap_or_else(|| "?".into());
    let long = number(row, "longQuantity").unwrap_or(0.0);
    let short = number(row, "shortQuantity").unwrap_or(0.0);
    let quantity = long - short;
    let Some(family) = family_of(&asset_type) else {
        return Err(format!("{}（{asset_type}）", symbol.trim()));
    };
    if quantity == 0.0 {
        return Ok(None);
    }
    let market_value = number(row, "marketValue").unwrap_or(0.0);
    // Schwab states the open profit per side; a row holds one side.
    let open = match (number(row, "longOpenProfitLoss"), number(row, "shortOpenProfitLoss")) {
        (None, None) => None,
        (l, s) => Some(l.unwrap_or(0.0) + s.unwrap_or(0.0)),
    };
    let stated_average = number(row, "averagePrice").unwrap_or(0.0);
    let mut note = None;
    let (average_price, option) = match family {
        Family::Option => {
            let contract = UsOption::parse(&symbol).map_err(|why| format!("{}（{asset_type}，{why}）", symbol.trim()))?;
            let multiplier = number(&instrument, "optionMultiplier")
                .or_else(|| {
                    instrument
                        .get("optionDeliverables")
                        .and_then(Value::as_array)
                        .and_then(|list| list.first())
                        .and_then(|d| number(d, "deliverableUnits"))
                })
                .filter(|m| *m > 0.0)
                .unwrap_or(STANDARD_MULTIPLIER);
            if let Some(side) = text(&instrument, "putCall") {
                if side.eq_ignore_ascii_case("CALL") != contract.call {
                    note = Some(format!("嘉信标的是 {side}，期权代码写的是 {}，按代码读", if contract.call { "CALL" } else { "PUT" }));
                }
            }
            let (average, unit_note) = option_average(stated_average, quantity, multiplier, market_value, open);
            note = note.or(unit_note);
            let underlying = text(&instrument, "underlyingSymbol").unwrap_or_else(|| contract.underlying.clone());
            let deliverables = instrument.get("optionDeliverables").and_then(Value::as_array).cloned().unwrap_or_default();
            let nonstandard = nonstandard(&deliverables, &underlying, multiplier);
            let terms = OptionTerms {
                underlying,
                call: contract.call,
                strike: contract.strike,
                expiry_day: contract.expiry_day(),
                expiry_ms: contract.expiry_ms(),
                multiplier,
                description: text(&instrument, "description"),
                nonstandard,
            };
            (average, Some(terms))
        }
        _ => (stated_average, None),
    };
    Ok(Some(SchwabHolding {
        symbol,
        asset_type,
        family,
        quantity,
        average_price,
        market_value,
        day_profit_loss: number(row, "currentDayProfitLoss"),
        open_profit_loss: open,
        maintenance_requirement: number(row, "maintenanceRequirement"),
        option,
        note,
    }))
}

/// What a contract delivers, in words, when it is not `multiplier` shares of
/// `underlying`; None for a standard contract or one that does not say.
pub fn nonstandard(deliverables: &[Value], underlying: &str, multiplier: f64) -> Option<String> {
    let parts: Vec<(String, f64)> = deliverables
        .iter()
        .filter_map(|d| Some((text(d, "symbol")?, number(d, "deliverableUnits")?)))
        .collect();
    match parts.as_slice() {
        [] => None,
        [(symbol, units)] if symbol == underlying && (units - multiplier).abs() < 1e-9 => None,
        _ => Some(parts.iter().map(|(symbol, units)| format!("{} {symbol}", crate::trade::wire::number(*units))).collect::<Vec<_>>().join(" + ")),
    }
}

/// An option's average as premium a share, checked against Schwab's own
/// arithmetic: the cost the open profit implies — market value less the
/// profit, either sign convention for a short — is the average times the
/// contracts times the multiplier. The API documentation does not say which
/// unit `averagePrice` is in for an option, and no option has been held on
/// the account to read one from, so the document is made to say it: a
/// figure that matches per contract is divided down, and one that matches
/// neither is kept as a share's premium and said.
fn option_average(stated: f64, quantity: f64, multiplier: f64, market_value: f64, open: Option<f64>) -> (f64, Option<String>) {
    let Some(open) = open else { return (stated, None) };
    let contracts = quantity.abs();
    let costs = [(market_value - open).abs(), market_value.abs() + open];
    let matches = |cost: f64| costs.iter().any(|c| (c - cost).abs() <= 0.01 + 1e-6 * cost.abs());
    if matches(stated * contracts * multiplier) {
        (stated, None)
    } else if matches(stated * contracts) {
        (stated / multiplier, Some(format!("嘉信的 averagePrice {stated} 是每张的价格，已按 {multiplier} 股/张折成每股权利金")))
    } else {
        (stated, Some(format!(
            "均价 {stated} 与嘉信自己的持仓盈亏对不上（市值 {market_value}、浮动盈亏 {open}），按每股权利金读，浮动盈亏以嘉信为准"
        )))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Cash, two share rows, a long call and a short put, a bond and a flat
    /// row — in the shape `schwabctl account` prints.
    pub(crate) const DOCUMENT: &str = r#"{
      "securitiesAccount": {
        "type": "MARGIN", "accountNumber": "42324703",
        "currentBalances": {"cashBalance": 12000.5, "liquidationValue": 13839.25, "availableFunds": 11000, "buyingPower": 22000, "maintenanceRequirement": 3100},
        "positions": [
          {"longQuantity": 10, "shortQuantity": 0, "averagePrice": 400.0, "marketValue": 4101.0, "currentDayProfitLoss": 20.5, "longOpenProfitLoss": 101.0,
           "instrument": {"assetType": "EQUITY", "symbol": "TSLA"}},
          {"longQuantity": 0, "shortQuantity": 5, "averagePrice": 520.0, "marketValue": -2610.0, "shortOpenProfitLoss": -10.0,
           "instrument": {"assetType": "ETF", "symbol": "QQQ"}},
          {"longQuantity": 2, "shortQuantity": 0, "averagePrice": 60.5, "marketValue": 13625.0, "longOpenProfitLoss": 1525.0, "maintenanceRequirement": 0,
           "instrument": {"assetType": "OPTION", "symbol": "MU    261120C01040000", "putCall": "CALL", "underlyingSymbol": "MU", "optionMultiplier": 100,
                          "description": "MICRON TECHNOLOGY INC 11/20/2026 $1040 Call"}},
          {"longQuantity": 0, "shortQuantity": 1, "averagePrice": 31.0, "marketValue": -2810.0, "shortOpenProfitLoss": 290.0, "maintenanceRequirement": 20500,
           "instrument": {"assetType": "OPTION", "symbol": "MU    261120P01000000", "putCall": "PUT", "underlyingSymbol": "MU"}},
          {"longQuantity": 1000, "shortQuantity": 0, "averagePrice": 99.1, "marketValue": 990.0,
           "instrument": {"assetType": "FIXED_INCOME", "symbol": "912797KX4"}},
          {"longQuantity": 0, "shortQuantity": 0, "averagePrice": 0, "marketValue": 0,
           "instrument": {"assetType": "EQUITY", "symbol": "NVDA"}}
        ]
      },
      "aggregatedBalance": {"liquidationValue": 13839.25}
    }"#;

    #[test]
    fn every_holding_is_read_as_its_family_and_the_rest_is_named() {
        let account = read(DOCUMENT).unwrap();
        assert_eq!((account.kind.as_str(), account.cash, account.equity), ("MARGIN", 12000.5, Some(13839.25)));
        let symbols: Vec<&str> = account.positions.iter().map(|p| p.symbol.as_str()).collect();
        assert_eq!(symbols, vec!["TSLA", "QQQ", "MU    261120C01040000", "MU    261120P01000000"], "a flat row is not a holding");
        assert_eq!(account.unrecognised, vec!["912797KX4（FIXED_INCOME）"]);
        let qqq = &account.positions[1];
        assert_eq!((qqq.family, qqq.quantity, qqq.units()), (Family::Stock, -5.0, -5.0));
        let call = &account.positions[2];
        assert_eq!((call.family, call.quantity, call.average_price), (Family::Option, 2.0, 60.5));
        let terms = call.option.as_ref().unwrap();
        assert_eq!((terms.underlying.as_str(), terms.call, terms.strike, terms.expiry_day.as_str(), terms.multiplier), ("MU", true, 1040.0, "2026-11-20", 100.0));
        assert_eq!(call.units(), 200.0);
        assert_eq!(call.underlying(), "MU");
        assert!(call.note.is_none(), "the average squares with Schwab's own profit: {:?}", call.note);
        let put = &account.positions[3];
        assert_eq!((put.quantity, put.average_price, put.maintenance_requirement), (-1.0, 31.0, Some(20500.0)));
        assert_eq!(put.option.as_ref().map(|o| o.multiplier), Some(100.0), "no multiplier stated: the standard contract");
        assert!(put.note.is_none(), "a short's cost reads either sign convention: {:?}", put.note);
    }

    #[test]
    fn an_adjusted_contract_says_what_it_delivers() {
        let standard = serde_json::json!([{"symbol": "MU", "deliverableUnits": 100.0, "assetType": "STOCK"}]);
        assert_eq!(nonstandard(standard.as_array().unwrap(), "MU", 100.0), None);
        // ETHA1, read from Schwab's chain on 2026-10-09.
        let adjusted = serde_json::json!([{"symbol": "ETHA", "deliverableUnits": 33.0, "assetType": "STOCK"}]);
        assert_eq!(nonstandard(adjusted.as_array().unwrap(), "ETHA", 100.0).as_deref(), Some("33 ETHA"));
        assert_eq!(nonstandard(&[], "MU", 100.0), None, "a row that does not say is read as standard");
    }

    #[test]
    fn an_average_stated_per_contract_is_divided_down_and_said() {
        // 2 contracts bought at 60.50 a share — 6,050 a contract.
        let (average, note) = option_average(6050.0, 2.0, 100.0, 13625.0, Some(1525.0));
        assert_eq!(average, 60.5);
        assert!(note.unwrap().contains("每张"));
        let (average, note) = option_average(61.0, 2.0, 100.0, 13625.0, Some(1525.0));
        assert_eq!(average, 61.0);
        assert!(note.unwrap().contains("对不上"));
        assert_eq!(option_average(61.0, 2.0, 100.0, 13625.0, None), (61.0, None), "nothing to check against");
    }

    #[test]
    fn an_option_whose_symbol_does_not_read_is_named_not_dropped() {
        let document = r#"{"securitiesAccount":{"type":"CASH","currentBalances":{"cashBalance":1},"positions":[
            {"longQuantity":1,"shortQuantity":0,"averagePrice":1,"marketValue":100,"instrument":{"assetType":"OPTION","symbol":"WEIRD"}}]}}"#;
        let account = read(document).unwrap();
        assert!(account.positions.is_empty());
        assert_eq!(account.unrecognised.len(), 1);
        assert!(account.unrecognised[0].starts_with("WEIRD（OPTION，"), "{:?}", account.unrecognised);
        assert!(read("[]").is_err());
        assert!(read("not json").is_err());
        assert!(read(r#"{"aggregatedBalance":{}}"#).is_err());
    }

    #[test]
    fn the_array_form_reads_its_first_account() {
        let array = format!("[{DOCUMENT}]");
        assert_eq!(read(&array).unwrap(), read(DOCUMENT).unwrap());
    }

    /// The account a cash-only Schwab login read on 2026-10-09.
    #[test]
    fn a_cash_account_reads_as_cash() {
        let document = r#"{"aggregatedBalance":{"liquidationValue":1456.72},"securitiesAccount":{"accountNumber":"42324703","currentBalances":{"availableFunds":1456.72,"buyingPower":1456.72,"cashBalance":1456.72,"liquidationValue":1456.72,"maintenanceRequirement":0.0},"type":"MARGIN"}}"#;
        let account = read(document).unwrap();
        assert_eq!((account.cash, account.equity, account.positions.len()), (1456.72, Some(1456.72), 0));
    }
}
