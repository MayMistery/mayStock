//! What each outcome on the prediction card has meant for ETH.
//!
//! The measurements are made by `Scripts/event-reactions.py` and embedded
//! from `kernel/data/event_reactions.json`; this module only applies them to
//! the live book. Two kinds:
//!
//! - **surprise**: ETH's move regressed on how far an outcome landed from
//!   what the market expected just before it was known. An outcome's
//!   surprise is read against today's expectation — the probability-weighted
//!   value of the outcomes on the card — so a 0.3% CPI print counts as
//!   hawkish only when the market expects less.
//! - **oil-chain**: for events with no settled history, Brent's excess move
//!   on the 2026 days of the same kind of event, times ETH's beta to Brent.
//!   An estimate, and published as one.
//!
//! Only the event's own effect is applied — the slope, never the intercept,
//! which is the sample's drift (2023–25 ETH mostly rose) and not something
//! the event says. A window whose slope is under `significance` standard
//! errors shows no probability: "no relation" is a finding, and a number
//! built on noise would read as one.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

use crate::options::normal_cdf;

const DOCUMENT: &str = include_str!("../../data/event_reactions.json");

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    pub measured: String,
    pub significance: f64,
    pub oil: Oil,
    pub topics: BTreeMap<String, Model>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Model {
    #[serde(rename_all = "camelCase")]
    Surprise { unit: Unit, source: String, event: Side, why: String, windows: Vec<Window> },
    #[serde(rename_all = "camelCase")]
    OilChain { analog: String, event: Side },
}

/// What an outcome's value is measured in.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Unit {
    /// Percentage points: "0.3%", "≤0.0%", "0.6%+".
    Pp,
    /// Basis points of a rate change: "25 bps increase", "No change".
    Bp,
    /// A count bracket's midpoint: "<20", "20-24", "40+".
    Ships,
    /// A yes/no question: the outcome is 1 or 0.
    Probability,
}

/// Which side of a question is the event.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    /// Each outcome of a bracketed question.
    Outcome,
    /// The question resolving yes ("a strike today", "a deal by …").
    Yes,
    /// The question resolving no ("the ceasefire continues" failing).
    No,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub label: String,
    pub n: usize,
    /// The smallest and largest surprise in the history.
    pub x_min: f64,
    pub x_max: f64,
    pub slope: f64,
    pub slope_se: f64,
    pub sigma: f64,
    pub significant: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Oil {
    pub source: String,
    pub since: String,
    /// ETH on Brent over the analog span (the day before an event and its
    /// own), on spans that do not overlap.
    pub beta_event: Window,
    pub analogs: BTreeMap<String, Analog>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Analog {
    pub label: String,
    pub n: usize,
    pub oil_excess: Option<f64>,
    pub oil_excess_se: Option<f64>,
    /// Judged by the script against the shared critical value; absent where
    /// there were too few days to judge.
    #[serde(default)]
    pub significant: bool,
}

/// Fewer analog days than this and the chain is not drawn.
pub const MIN_ANALOGS: usize = 3;

pub fn document() -> &'static Document {
    static PARSED: OnceLock<Document> = OnceLock::new();
    PARSED.get_or_init(|| serde_json::from_str(DOCUMENT).expect("kernel/data/event_reactions.json is the script's own output"))
}

impl Unit {
    /// An outcome label's value, or none for a label this unit cannot read.
    pub fn value(self, label: &str) -> Option<f64> {
        let text: String = label.chars().filter(|c| !c.is_whitespace()).collect();
        let lower = text.to_lowercase();
        match self {
            Unit::Pp => lower.trim_start_matches(['≤', '<', '≥', '>']).trim_end_matches('+').trim_end_matches('%').trim_end_matches('+').parse().ok(),
            Unit::Bp => {
                if lower.contains("nochange") || lower.contains("maintain") || lower == "hold" {
                    return Some(0.0);
                }
                let digits: String = lower.chars().take_while(|c| c.is_ascii_digit()).collect();
                let size: f64 = digits.parse().ok()?;
                if lower.contains("decrease") || lower.contains("cut") {
                    Some(-size)
                } else if lower.contains("increase") || lower.contains("hike") {
                    Some(size)
                } else {
                    None
                }
            }
            // The same midpoints `Scripts/event-reactions.py` measured with
            // (`bracket_value`); `the_ship_brackets_read_as_the_script_measured_them`
            // holds the two to the examples the script writes.
            Unit::Ships => {
                if let Some(rest) = text.strip_prefix('<') {
                    return rest.parse::<f64>().ok().map(|v| v - 2.5);
                }
                if let Some(rest) = text.strip_suffix('+') {
                    return rest.parse::<f64>().ok().map(|v| v + 2.0);
                }
                let (low, high) = text.split_once('-')?;
                Some((low.parse::<f64>().ok()? + high.parse::<f64>().ok()?) / 2.0)
            }
            Unit::Probability => None,
        }
    }

    /// The step a slope is shown per, and how to say it.
    pub fn step(self) -> (f64, &'static str) {
        match self {
            Unit::Pp => (0.1, "0.1 个百分点"),
            Unit::Bp => (25.0, "25 个基点"),
            Unit::Ships => (5.0, "5 艘"),
            Unit::Probability => (1.0, "完全出乎意料"),
        }
    }
}

/// One window's reading for one outcome.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CellReaction {
    /// ETH's expected move over the window if this outcome happens, in
    /// percent; none where there is no relation to apply.
    pub median: Option<f64>,
    /// The probability ETH ends the window higher.
    pub up: Option<f64>,
    /// The outcome's surprise lies beyond any in the history: the line is
    /// carried past the data it was fitted on.
    pub extrapolated: bool,
}

/// How a topic's outcomes map to ETH, for its header and its columns.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TopicReaction {
    /// `surprise` or `oil-chain`.
    pub kind: &'static str,
    /// "若是这一档", "若当天发生", "若破裂", "若达成".
    pub event_label: &'static str,
    pub windows: Vec<WindowView>,
    /// Where the history comes from.
    pub source: String,
    /// Why the sample is what it is.
    pub why: Option<String>,
    /// Oil chain only: the analog events and their measured oil move.
    pub analog: Option<AnalogView>,
    pub measured: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowView {
    pub label: String,
    pub n: usize,
    /// ETH's move per `step_label` of surprise, in percent.
    pub per_step: f64,
    pub per_step_se: f64,
    pub step_label: &'static str,
    pub significant: bool,
    /// The critical |t| it was judged against.
    pub significance: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalogView {
    pub label: String,
    pub n: usize,
    /// Brent beyond an ordinary span of the same length, percent.
    pub oil_excess: Option<f64>,
    pub oil_excess_se: Option<f64>,
    pub oil_significant: bool,
    /// ETH per 1% of Brent over the span.
    pub beta: f64,
    pub beta_se: f64,
    pub beta_significant: bool,
    pub span_label: String,
    pub since: String,
    /// The critical |t| every relation here was judged against.
    pub significance: f64,
}

/// A topic's mapping, or none for a topic the measurement does not cover.
pub fn topic(id: &str, event_label_for: impl Fn(Side) -> &'static str) -> Option<(TopicReaction, Applier)> {
    let doc = document();
    match doc.topics.get(id)? {
        Model::Surprise { unit, source, event, why, windows } => {
            let (step, step_label) = unit.step();
            Some((
                TopicReaction {
                    kind: "surprise",
                    event_label: event_label_for(*event),
                    windows: windows
                        .iter()
                        .map(|w| WindowView {
                            label: w.label.clone(),
                            n: w.n,
                            per_step: w.slope * step,
                            per_step_se: w.slope_se * step,
                            step_label,
                            significant: w.significant,
                            significance: doc.significance,
                        })
                        .collect(),
                    source: source.clone(),
                    why: Some(why.clone()),
                    analog: None,
                    measured: doc.measured.clone(),
                },
                Applier::Surprise { unit: *unit, side: *event, windows: windows.clone() },
            ))
        }
        Model::OilChain { analog, event } => {
            let found = doc.oil.analogs.get(analog)?;
            let beta = &doc.oil.beta_event;
            let usable = found.n >= MIN_ANALOGS && beta.significant && found.significant;
            Some((
                TopicReaction {
                    kind: "oil-chain",
                    event_label: event_label_for(*event),
                    windows: vec![WindowView {
                        label: beta.label.clone(),
                        n: found.n,
                        per_step: found.oil_excess.unwrap_or(0.0) * beta.slope,
                        per_step_se: 0.0,
                        step_label: "",
                        significant: usable,
                        significance: doc.significance,
                    }],
                    source: doc.oil.source.clone(),
                    why: None,
                    analog: Some(AnalogView {
                        label: found.label.clone(),
                        n: found.n,
                        oil_excess: found.oil_excess,
                        oil_excess_se: found.oil_excess_se,
                        oil_significant: found.significant,
                        beta: beta.slope,
                        beta_se: beta.slope_se,
                        beta_significant: beta.significant,
                        span_label: beta.label.clone(),
                        since: doc.oil.since.clone(),
                        significance: doc.significance,
                    }),
                    measured: doc.measured.clone(),
                },
                Applier::OilChain {
                    side: *event,
                    effect: if usable { found.oil_excess.map(|x| x * beta.slope) } else { None },
                    sigma: beta.sigma,
                },
            ))
        }
    }
}

/// Turns one line's outcomes into ETH readings.
pub enum Applier {
    Surprise { unit: Unit, side: Side, windows: Vec<Window> },
    OilChain { side: Side, effect: Option<f64>, sigma: f64 },
}

impl Applier {
    /// One reading per window for each outcome, given each outcome's label
    /// and probability. A bracketed question's expectation is the
    /// probability-weighted value of its priced outcomes.
    pub fn apply(&self, outcomes: &[(&str, Option<f64>)]) -> Vec<Vec<CellReaction>> {
        match self {
            Applier::Surprise { unit, side, windows } => {
                let surprises: Vec<Option<f64>> = match side {
                    Side::Outcome => {
                        let priced: Vec<(f64, f64)> =
                            outcomes.iter().filter_map(|(label, p)| Some((unit.value(label)?, (*p)?))).collect();
                        let total: f64 = priced.iter().map(|(_, p)| p).sum();
                        let expected = (priced.len() >= 2 && total > 0.0).then(|| priced.iter().map(|(v, p)| v * p).sum::<f64>() / total);
                        outcomes.iter().map(|(label, _)| Some(unit.value(label)? - expected?)).collect()
                    }
                    Side::Yes => outcomes.iter().map(|(_, p)| p.map(|p| 1.0 - p)).collect(),
                    // The question resolving no: its value 0 against a yes price of p.
                    Side::No => outcomes.iter().map(|(_, p)| p.map(|p| -p)).collect(),
                };
                surprises
                    .into_iter()
                    .map(|surprise| {
                        windows
                            .iter()
                            .map(|w| {
                                let applied = surprise.filter(|_| w.significant);
                                CellReaction {
                                    extrapolated: applied.is_some_and(|s| s < w.x_min || s > w.x_max),
                                    ..reading(applied.map(|s| w.slope * s), w.sigma)
                                }
                            })
                            .collect()
                    })
                    .collect()
            }
            Applier::OilChain { side, effect, sigma } => outcomes
                .iter()
                .map(|(_, p)| {
                    // The analogs were surprises when they happened; an event
                    // the market already prices moves less.
                    let unexpected = p.map(|p| match side {
                        Side::No => p,
                        _ => 1.0 - p,
                    });
                    vec![reading(effect.zip(unexpected).map(|(e, u)| e * u), *sigma)]
                })
                .collect(),
        }
    }
}

fn reading(median: Option<f64>, sigma: f64) -> CellReaction {
    CellReaction { median, up: median.filter(|_| sigma > 0.0).map(|m| normal_cdf(m / sigma)), extrapolated: false }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::live::polymarket;

    #[test]
    fn every_declared_topic_has_a_measurement() {
        for topic_decl in polymarket::TOPICS.iter() {
            assert!(
                topic(topic_decl.id, |_| "").is_some(),
                "{} is on the card but `Scripts/event-reactions.py` does not measure it",
                topic_decl.id
            );
        }
    }

    #[test]
    fn outcome_labels_read_as_values() {
        assert_eq!(Unit::Pp.value("≤0.0%"), Some(0.0));
        assert_eq!(Unit::Pp.value("0.3%"), Some(0.3));
        assert_eq!(Unit::Pp.value("0.6%+"), Some(0.6));
        assert_eq!(Unit::Bp.value("50+ bps decrease"), Some(-50.0));
        assert_eq!(Unit::Bp.value("25 bps increase"), Some(25.0));
        assert_eq!(Unit::Bp.value("No change"), Some(0.0));
        assert_eq!(Unit::Bp.value("Fed maintains rate"), Some(0.0));
    }

    #[test]
    fn the_ship_brackets_read_as_the_script_measured_them() {
        // `bracket_value` in Scripts/event-reactions.py.
        for (label, value) in [("<20", 17.5), ("20-24", 22.0), ("25-29", 27.0), ("40+", 42.0)] {
            assert_eq!(Unit::Ships.value(label), Some(value), "{label}");
        }
    }

    #[test]
    fn a_hawkish_bracket_reads_down_and_a_dovish_one_up_against_todays_expectation() {
        let window = Window { label: "1 小时".into(), n: 41, x_min: -0.23, x_max: 0.13, slope: -9.7, slope_se: 2.9, sigma: 1.4, significant: true };
        let applier = Applier::Surprise { unit: Unit::Pp, side: Side::Outcome, windows: vec![window] };
        // The 2026-10-07 book for September's core CPI.
        let book = [("≤0.0%", Some(0.067)), ("0.1%", Some(0.165)), ("0.2%", Some(0.405)), ("0.3%", Some(0.325)), ("0.4%", Some(0.067)), ("0.5%", Some(0.001))];
        let readings = applier.apply(&book);
        let up: Vec<f64> = readings.iter().map(|r| r[0].up.unwrap()).collect();
        assert!(up.windows(2).all(|w| w[0] > w[1]), "hotter prints are ever likelier to send ETH down: {up:?}");
        assert!(up[3] < 0.5 && up[1] > 0.5, "0.3% is above the 0.22% expected, 0.1% below");
        let flagged: Vec<bool> = readings.iter().map(|r| r[0].extrapolated).collect();
        assert_eq!(flagged, [false, false, false, false, true, true], "0.4% and 0.5% lie beyond the largest surprise on record");
    }

    #[test]
    fn a_window_with_no_relation_offers_no_probability() {
        let window = Window { label: "24 小时".into(), n: 41, x_min: -0.23, x_max: 0.13, slope: 0.8, slope_se: 7.4, sigma: 3.5, significant: false };
        let applier = Applier::Surprise { unit: Unit::Pp, side: Side::Outcome, windows: vec![window] };
        let readings = applier.apply(&[("0.2%", Some(0.6)), ("0.3%", Some(0.4))]);
        assert!(readings.iter().all(|r| r[0] == CellReaction { median: None, up: None, extrapolated: false }));
    }

    #[test]
    fn an_event_already_priced_moves_less_than_one_nobody_expected() {
        let applier = Applier::OilChain { side: Side::No, effect: Some(-1.0), sigma: 3.0 };
        // "Continues through …" at 97% and at 60%: a break is the event.
        let readings = applier.apply(&[("October 9", Some(0.97)), ("October 31", Some(0.60))]);
        let (sure, doubtful) = (readings[0][0].median.unwrap(), readings[1][0].median.unwrap());
        assert!(sure < doubtful && doubtful < 0.0, "a break against 97% odds hits harder than one against 60%");
    }
}
