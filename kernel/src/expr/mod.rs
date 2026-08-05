//! The sandboxed strategy expression language.
//!
//! The AST is deliberately tiny and closed: numbers, named series, function
//! calls from a fixed table, and arithmetic/boolean combinators. There is no
//! assignment, no loop, no I/O, and no way to name a function outside
//! [`FUNCTION_ARITY`] — so evaluating an imported strategy can do nothing but
//! arithmetic over arrays.
//!
//! Ported from `Sources/MayStockKit/Strategy/StrategyExpression.swift` and
//! `StrategyEvaluator.swift`.

pub mod eval;
pub mod lexer;
pub mod parser;

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BinaryOp {
    Add,
    Subtract,
    Multiply,
    Divide,
    Modulo,
    Greater,
    GreaterEqual,
    Less,
    LessEqual,
    Equal,
    NotEqual,
    And,
    Or,
    CrossesAbove,
    CrossesBelow,
}

impl BinaryOp {
    pub fn from_symbol(s: &str) -> Option<Self> {
        Some(match s {
            "+" => Self::Add,
            "-" => Self::Subtract,
            "*" => Self::Multiply,
            "/" => Self::Divide,
            "%" => Self::Modulo,
            ">" => Self::Greater,
            ">=" => Self::GreaterEqual,
            "<" => Self::Less,
            "<=" => Self::LessEqual,
            "==" => Self::Equal,
            "!=" => Self::NotEqual,
            _ => return None,
        })
    }

    pub fn is_comparison(self) -> bool {
        matches!(
            self,
            Self::Greater
                | Self::GreaterEqual
                | Self::Less
                | Self::LessEqual
                | Self::Equal
                | Self::NotEqual
                | Self::CrossesAbove
                | Self::CrossesBelow
        )
    }
}

/// A parsed strategy expression.
///
/// `Hash`/`Eq` are derived because the evaluator memoises by whole subtree:
/// `ema(close, 12)` written in three rules is computed once. `f64` is hashed
/// through its bit pattern by [`NumberKey`] so the derive is well defined.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Expr {
    Number(NumberKey),
    Variable(String),
    Call(String, Vec<Expr>),
    Negate(Box<Expr>),
    Not(Box<Expr>),
    Binary(BinaryOp, Box<Expr>, Box<Expr>),
}

/// A hashable, totally-ordered wrapper for the literal numbers in an AST.
///
/// Literals come from parsing decimal text, so they are never NaN; comparing by
/// bit pattern is therefore exactly value equality here, and it lets `Expr`
/// derive the `Hash` + `Eq` the memo table needs.
#[derive(Debug, Clone, Copy)]
pub struct NumberKey(pub f64);

impl NumberKey {
    pub fn get(self) -> f64 {
        self.0
    }
}

impl PartialEq for NumberKey {
    fn eq(&self, other: &Self) -> bool {
        self.0.to_bits() == other.0.to_bits()
    }
}
impl Eq for NumberKey {}
impl std::hash::Hash for NumberKey {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.0.to_bits().hash(state);
    }
}

impl Expr {
    pub fn number(value: f64) -> Self {
        Expr::Number(NumberKey(value))
    }

    /// Every identifier the expression reads. Used to reject manifests that
    /// reference an undeclared parameter *before* anything runs.
    pub fn identifiers(&self, out: &mut std::collections::BTreeSet<String>) {
        match self {
            Expr::Number(_) => {}
            Expr::Variable(name) => {
                out.insert(name.clone());
            }
            Expr::Negate(inner) | Expr::Not(inner) => inner.identifiers(out),
            Expr::Binary(_, lhs, rhs) => {
                lhs.identifiers(out);
                rhs.identifiers(out);
            }
            Expr::Call(_, args) => {
                for arg in args {
                    arg.identifiers(out);
                }
            }
        }
    }
}

// MARK: - Errors

#[derive(Debug, Clone, PartialEq)]
pub enum ExprError {
    Syntax { message: String, column: usize },
    UnknownIdentifier(String),
    UnknownFunction(String),
    BadArity {
        function: String,
        expected: String,
        got: usize,
    },
    NonConstantArgument {
        function: String,
        position: usize,
    },
    InvalidPeriod {
        function: String,
        value: f64,
    },
}

impl fmt::Display for ExprError {
    /// Messages are Chinese to match the Swift original — they surface verbatim
    /// in the strategy studio when an imported manifest fails to compile.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Syntax { message, column } => {
                write!(f, "表达式语法错误（第 {column} 列）：{message}")
            }
            Self::UnknownIdentifier(name) => write!(f, "未知的变量或参数：{name}"),
            Self::UnknownFunction(name) => write!(f, "未知的函数：{name}()"),
            Self::BadArity {
                function,
                expected,
                got,
            } => write!(f, "{function}() 需要 {expected} 个参数，实际 {got} 个"),
            Self::NonConstantArgument { function, position } => write!(
                f,
                "{function}() 的第 {position} 个参数必须是常量或策略参数，不能是行情序列"
            ),
            Self::InvalidPeriod { function, value } => {
                write!(f, "{function}() 的周期无效：{value}（必须是 ≥1 的整数）")
            }
        }
    }
}

impl std::error::Error for ExprError {}

pub type ExprResult<T> = Result<T, ExprError>;

/// Every callable name, with its inclusive arity range. Anything not listed is
/// rejected at manifest-import time, so a strategy file cannot name unknown
/// behaviour.
pub const FUNCTION_ARITY: &[(&str, usize, usize)] = &[
    ("sma", 2, 2),
    ("ema", 2, 2),
    ("rma", 2, 2),
    ("wma", 2, 2),
    ("rsi", 2, 2),
    ("stdev", 2, 2),
    ("highest", 2, 2),
    ("lowest", 2, 2),
    ("roc", 2, 2),
    ("ref", 2, 2),
    ("atr", 1, 1),
    ("natr", 1, 1),
    ("macd", 3, 3),
    ("macd_signal", 4, 4),
    ("macd_hist", 4, 4),
    ("bb_upper", 3, 3),
    ("bb_lower", 3, 3),
    ("bb_width", 3, 3),
    ("abs", 1, 1),
    ("sign", 1, 1),
    ("min", 2, 2),
    ("max", 2, 2),
    ("clamp", 3, 3),
    ("crossover", 2, 2),
    ("crossunder", 2, 2),
];

pub fn arity_of(name: &str) -> Option<(usize, usize)> {
    FUNCTION_ARITY
        .iter()
        .find(|(n, _, _)| *n == name)
        .map(|(_, lo, hi)| (*lo, *hi))
}

pub const MARKET_SERIES: &[&str] = &[
    "open", "high", "low", "close", "volume", "hl2", "hlc3", "ohlc4", "bar_index",
];

/// Longest rolling window any single function may request. Guards an imported
/// manifest from asking for `sma(close, 10_000_000)`.
pub const MAX_PERIOD: usize = 5_000;

/// Reserved words that can never be used as a bare identifier.
pub const KEYWORDS: &[&str] = &["and", "or", "not", "crosses_above", "crosses_below"];

/// Averages of the EMA family keep converging well past their nominal period;
/// three times the window is the usual safe margin when deciding how much
/// history to fetch.
pub const EMA_FAMILY: &[&str] = &[
    "ema",
    "rma",
    "rsi",
    "atr",
    "natr",
    "macd",
    "macd_signal",
    "macd_hist",
];
