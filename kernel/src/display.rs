//! How an instant is written for May to read.
//!
//! Every time the app shows is read in one zone: the one the settings name
//! (`GeneralPrefs.displayTimeZone`), Singapore unless changed — May,
//! 2026-10-09: 「都要用新加坡时间」, then 「支持配置时区吧，默认sg」. A rule a
//! venue keeps on its own clock stays on it — a US trading day is New
//! York's, Polymarket names a deadline by its New York day — and only how
//! the instant is written moves.

use chrono::TimeZone as _;
use chrono_tz::Tz;
use serde::Deserialize;

/// The zone a fresh install reads times in. The app takes its default from
/// here (`ms_display_zone_default`), so there is one.
pub const DEFAULT_ZONE: &str = "Asia/Singapore";

/// The zone the settings name, and what to call it next to a time
/// (`新加坡时间`). The name is Foundation's, handed over by the app: the
/// kernel keeps no localised zone names of its own.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayZone {
    pub identifier: String,
    pub name: String,
}

impl Default for DisplayZone {
    /// What a caller that names no zone reads in — the tests, the offline
    /// tools. The app always names one.
    fn default() -> Self {
        Self { identifier: DEFAULT_ZONE.into(), name: "新加坡时间".into() }
    }
}

/// A display zone resolved to a clock to write with.
#[derive(Debug, Clone)]
pub struct DisplayClock {
    tz: Tz,
    name: String,
}

impl DisplayClock {
    /// The clock `zone` names; an identifier chrono-tz does not know is an
    /// error, for the caller to say and fall back on [`Self::default`]. The
    /// app only sends identifiers Foundation knows, so this is two tz
    /// databases disagreeing, not a typo.
    pub fn of(zone: &DisplayZone) -> Result<Self, String> {
        let tz = zone.identifier.parse::<Tz>().map_err(|_| format!("内核不认识显示时区 {}", zone.identifier))?;
        Ok(Self { tz, name: zone.name.clone() })
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// An instant as `pattern` (chrono's strftime) writes it in this zone.
    pub fn format(&self, ms: i64, pattern: &str) -> Option<String> {
        let utc = chrono::DateTime::from_timestamp_millis(ms)?;
        Some(self.tz.from_utc_datetime(&utc.naive_utc()).format(pattern).to_string())
    }

    /// `10-09 21:30–04:00`: a stretch of time by the date it starts on and
    /// both clock times, the end read as the next day when it is earlier.
    pub fn span(&self, from_ms: i64, to_ms: i64) -> Option<String> {
        Some(format!("{}–{}", self.format(from_ms, "%m-%d %H:%M")?, self.format(to_ms, "%H:%M")?))
    }
}

impl Default for DisplayClock {
    fn default() -> Self {
        Self::of(&DisplayZone::default()).expect("the default zone is in chrono-tz")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(text: &str) -> i64 {
        chrono::DateTime::parse_from_rfc3339(text).unwrap().timestamp_millis()
    }

    #[test]
    fn the_default_zone_resolves() {
        assert_eq!(DisplayClock::default().name(), "新加坡时间");
        assert_eq!(DisplayClock::default().format(at("2026-10-09T13:30:00Z"), "%H:%M").as_deref(), Some("21:30"));
    }

    /// A New York session read in Singapore, across both offsets: 21:30 in
    /// summer, 22:30 once New York falls back.
    #[test]
    fn a_session_is_written_in_the_display_zone() {
        let clock = DisplayClock::default();
        assert_eq!(clock.span(at("2026-10-09T09:30:00-04:00"), at("2026-10-09T16:00:00-04:00")).as_deref(), Some("10-09 21:30–04:00"));
        assert_eq!(clock.span(at("2026-12-09T09:30:00-05:00"), at("2026-12-09T16:00:00-05:00")).as_deref(), Some("12-09 22:30–05:00"));
        let new_york = DisplayClock::of(&DisplayZone { identifier: "America/New_York".into(), name: "纽约时间".into() }).unwrap();
        assert_eq!(new_york.span(at("2026-10-09T09:30:00-04:00"), at("2026-10-09T16:00:00-04:00")).as_deref(), Some("10-09 09:30–16:00"));
    }

    #[test]
    fn an_unknown_zone_is_refused_not_guessed() {
        let unknown = DisplayZone { identifier: "Mars/Olympus".into(), name: "火星".into() };
        assert!(DisplayClock::of(&unknown).unwrap_err().contains("Mars/Olympus"));
    }

    /// The kernel writes a time only through a `DisplayClock` or on a
    /// named zone: chrono's `Local` is the machine's own zone, which is not
    /// the one May reads by. Walks every source file, so a new one is
    /// covered the day it is added.
    #[test]
    fn no_source_reads_the_machines_zone() {
        fn walk(dir: &std::path::Path, files: &mut Vec<std::path::PathBuf>) {
            for entry in std::fs::read_dir(dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    walk(&path, files);
                } else if path.extension().is_some_and(|e| e == "rs") {
                    files.push(path);
                }
            }
        }
        let mut files = Vec::new();
        walk(&std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src"), &mut files);
        assert!(files.len() > 30, "the walk found the sources");
        // Spelled in pieces, or this test would find itself.
        let needles = [["chrono::", "Local"].concat(), ["Local", "::now"].concat(), ["Local", "::today"].concat()];
        let offences: Vec<String> = files
            .iter()
            .flat_map(|path| {
                let text = std::fs::read_to_string(path).unwrap();
                text.lines()
                    .enumerate()
                    .filter(|(_, line)| !line.trim_start().starts_with("//"))
                    .filter(|(_, line)| needles.iter().any(|needle| line.contains(needle.as_str())))
                    .map(|(n, _)| format!("{}:{}", path.display(), n + 1))
                    .collect::<Vec<_>>()
            })
            .collect();
        assert!(offences.is_empty(), "write times through DisplayClock: {offences:?}");
    }

    #[test]
    fn an_instant_beyond_chrono_is_none_not_a_panic() {
        assert_eq!(DisplayClock::default().format(i64::MAX, "%H:%M"), None);
        assert_eq!(DisplayClock::default().span(i64::MIN, 0), None);
    }
}
