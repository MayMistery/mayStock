//! `schwabctl` — the credential boundary between MayStock and Charles Schwab.
//!
//! MayStock never holds a Schwab credential. This tool keeps the app key,
//! the app secret and the OAuth tokens in the keychain, mints thirty-minute
//! access tokens for the app, and is the only process that sends an order.
//! It is written in Rust for the same reason the trading kernel is: a native
//! binary starts in milliseconds, and every order on the live path goes
//! through it.
//!
//! Every command prints JSON to stdout. A failure prints
//! `{"error":{"code":…,"message":…}}` and exits non-zero; the code is the
//! contract the app reads, not the exit status.

mod api;
mod commands;
mod listener;
mod oauth;
mod store;

use clap::{Parser, Subcommand};

pub use api::Error;

#[derive(Parser, Debug)]
#[command(name = "schwabctl", version, about = "MayStock 的嘉信证券凭据边界与交易通道", disable_help_subcommand = true)]
pub struct Cli {
    /// Accepted for the subprocess contract; output is always JSON.
    #[arg(long, global = true)]
    pub json: bool,
    /// Required for place / replace / cancel. There is no demo account.
    #[arg(long, global = true)]
    pub live: bool,
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// Print the version.
    Version,
    /// Store the App Key and Secret (prompted, never echoed).
    Configure {
        /// The callback registered on the app; default https://127.0.0.1:8182.
        #[arg(long)]
        callback: Option<String>,
    },
    /// Log in through the browser; keeps the refresh token for seven days.
    Login {
        /// Paste the redirected URL instead of listening for it.
        #[arg(long)]
        manual: bool,
        /// Print the authorisation URL without opening a browser.
        #[arg(long)]
        no_browser: bool,
        /// Accept a callback that does not echo the state nonce.
        #[arg(long)]
        allow_missing_state: bool,
        /// Seconds to wait for the callback.
        #[arg(long, default_value_t = 300)]
        timeout: u64,
    },
    /// Forget the tokens; --all also forgets the App Key and Secret.
    Logout {
        #[arg(long)]
        all: bool,
    },
    /// Whether the tool is configured and logged in. No secrets, no network.
    Status,
    /// A thirty-minute access token for the app.
    Token,
    /// The accounts the login can see.
    Accounts,
    /// Choose the account orders go to.
    Use {
        #[arg(long)]
        account: String,
    },
    /// The chosen account with balances and positions.
    Account,
    /// Just the positions.
    Positions,
    /// Orders entered in a window (ISO-8601 with milliseconds and Z).
    Orders {
        #[arg(long)]
        from: String,
        #[arg(long)]
        to: String,
        #[arg(long)]
        status: Option<String>,
    },
    /// One order.
    Order {
        #[arg(long)]
        id: String,
    },
    /// Send an order (Schwab's JSON body; `-` reads stdin). Needs --live.
    Place {
        #[arg(long)]
        body: String,
    },
    /// Replace an order with a new body. Needs --live.
    Replace {
        #[arg(long)]
        id: String,
        #[arg(long)]
        body: String,
    },
    /// Cancel an order. Needs --live.
    Cancel {
        #[arg(long)]
        id: String,
    },
    /// Trades settled in a window.
    Fills {
        #[arg(long)]
        from: String,
        #[arg(long)]
        to: String,
        #[arg(long)]
        symbol: Option<String>,
    },
    /// Quotes for one or more symbols.
    Quotes {
        symbols: Vec<String>,
    },
    /// Price history for a symbol.
    Candles {
        symbol: String,
        /// 1m 5m 15m 1H 1D
        #[arg(long, default_value = "1D")]
        bar: String,
        #[arg(long, default_value_t = 30)]
        days: u32,
        #[arg(long)]
        extended: bool,
    },
    /// Equity session hours for a New York day (yyyy-MM-dd; today by default).
    Hours {
        #[arg(long)]
        date: Option<String>,
    },
    /// Instruments matching a symbol prefix or a name.
    Search {
        query: String,
    },
}

fn run(cli: &Cli) -> Result<serde_json::Value, Error> {
    match &cli.command {
        Command::Version => commands::version(),
        Command::Configure { callback } => commands::configure(callback.clone()),
        Command::Login { manual, no_browser, allow_missing_state, timeout } => {
            commands::login(cli, *manual, *no_browser, *allow_missing_state, *timeout)
        }
        Command::Logout { all } => commands::logout(*all),
        Command::Status => commands::status(),
        Command::Token => commands::token(),
        Command::Accounts => commands::accounts(),
        Command::Use { account } => commands::use_account(account),
        Command::Account => commands::account(),
        Command::Positions => commands::positions(),
        Command::Orders { from, to, status } => commands::orders(from, to, status.as_deref()),
        Command::Order { id } => commands::order(id),
        Command::Place { body } => commands::place(cli, body),
        Command::Replace { id, body } => commands::replace(cli, id, body),
        Command::Cancel { id } => commands::cancel(cli, id),
        Command::Fills { from, to, symbol } => commands::fills(from, to, symbol.as_deref()),
        Command::Quotes { symbols } => commands::quotes(symbols),
        Command::Candles { symbol, bar, days, extended } => commands::candles(symbol, bar, *days, *extended),
        Command::Hours { date } => commands::hours(date.as_deref()),
        Command::Search { query } => commands::search(query),
    }
}

fn main() {
    // One crypto provider is compiled in; naming it keeps rustls from
    // guessing if a second one ever arrives through a dependency.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let cli = Cli::parse();
    match run(&cli) {
        Ok(value) => {
            println!("{}", serde_json::to_string_pretty(&value).unwrap_or_else(|_| "null".into()));
        }
        Err(error) => {
            println!("{}", serde_json::to_string_pretty(&error.envelope()).unwrap_or_default());
            eprintln!("schwabctl: {error}");
            std::process::exit(error.exit_code());
        }
    }
}
