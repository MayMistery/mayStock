//! Hand-written lexer. No regex, no eval, no escape hatch.

use super::{ExprError, ExprResult};

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    Number(f64),
    Identifier(String),
    Symbol(String),
    LeftParen,
    RightParen,
    Comma,
    End,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Lexeme {
    pub token: Token,
    /// 1-based, counted in characters so the column matches what a human sees.
    pub column: usize,
}

pub struct Lexer {
    chars: Vec<char>,
    index: usize,
}

impl Lexer {
    pub fn tokenize(source: &str) -> ExprResult<Vec<Lexeme>> {
        let mut lexer = Lexer {
            chars: source.chars().collect(),
            index: 0,
        };
        let mut out = Vec::new();
        loop {
            let lexeme = lexer.next_lexeme()?;
            let end = lexeme.token == Token::End;
            out.push(lexeme);
            if end {
                return Ok(out);
            }
        }
    }

    fn next_lexeme(&mut self) -> ExprResult<Lexeme> {
        while self.index < self.chars.len() && self.chars[self.index].is_whitespace() {
            self.index += 1;
        }
        let column = self.index + 1;
        if self.index >= self.chars.len() {
            return Ok(Lexeme {
                token: Token::End,
                column,
            });
        }

        let ch = self.chars[self.index];
        if ch.is_ascii_digit()
            || (ch == '.'
                && self.index + 1 < self.chars.len()
                && self.chars[self.index + 1].is_ascii_digit())
        {
            let value = self.read_number(column)?;
            return Ok(Lexeme {
                token: Token::Number(value),
                column,
            });
        }
        if ch.is_alphabetic() || ch == '_' {
            let mut name = String::new();
            while self.index < self.chars.len() {
                let c = self.chars[self.index];
                if c.is_alphanumeric() || c == '_' {
                    name.push(c);
                    self.index += 1;
                } else {
                    break;
                }
            }
            return Ok(Lexeme {
                token: Token::Identifier(name),
                column,
            });
        }

        self.index += 1;
        let token = match ch {
            '(' => Token::LeftParen,
            ')' => Token::RightParen,
            ',' => Token::Comma,
            '+' | '-' | '*' | '/' | '%' => Token::Symbol(ch.to_string()),
            '>' | '<' => {
                if self.index < self.chars.len() && self.chars[self.index] == '=' {
                    self.index += 1;
                    Token::Symbol(format!("{ch}="))
                } else {
                    Token::Symbol(ch.to_string())
                }
            }
            '=' | '!' => {
                if self.index < self.chars.len() && self.chars[self.index] == '=' {
                    self.index += 1;
                    Token::Symbol(format!("{ch}="))
                } else {
                    return Err(ExprError::Syntax {
                        message: format!("孤立的 '{ch}'，比较请用 '==' 或 '!='"),
                        column,
                    });
                }
            }
            _ => {
                return Err(ExprError::Syntax {
                    message: format!("无法识别的字符 '{ch}'"),
                    column,
                })
            }
        };
        Ok(Lexeme { token, column })
    }

    fn read_number(&mut self, start_column: usize) -> ExprResult<f64> {
        let mut text = String::new();
        let mut seen_dot = false;
        while self.index < self.chars.len() {
            let ch = self.chars[self.index];
            if ch.is_ascii_digit() {
                text.push(ch);
            } else if ch == '.' && !seen_dot {
                seen_dot = true;
                text.push(ch);
            } else if ch == 'e' || ch == 'E' {
                // Exponent, optionally signed — but only when digits follow, so
                // `2e` stays the number 2 followed by the identifier `e`.
                let save = self.index;
                let mut exponent = String::from(ch);
                self.index += 1;
                if self.index < self.chars.len()
                    && (self.chars[self.index] == '+' || self.chars[self.index] == '-')
                {
                    exponent.push(self.chars[self.index]);
                    self.index += 1;
                }
                if self.index >= self.chars.len() || !self.chars[self.index].is_ascii_digit() {
                    self.index = save;
                    break;
                }
                while self.index < self.chars.len() && self.chars[self.index].is_ascii_digit() {
                    exponent.push(self.chars[self.index]);
                    self.index += 1;
                }
                text.push_str(&exponent);
                break;
            } else {
                break;
            }
            self.index += 1;
        }
        text.parse::<f64>().map_err(|_| ExprError::Syntax {
            message: format!("无效的数字 '{text}'"),
            column: start_column,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens(src: &str) -> Vec<Token> {
        Lexer::tokenize(src)
            .unwrap()
            .into_iter()
            .map(|l| l.token)
            .collect()
    }

    #[test]
    fn splits_operators_and_identifiers() {
        assert_eq!(
            tokens("ema(close, 12) >= 3"),
            vec![
                Token::Identifier("ema".into()),
                Token::LeftParen,
                Token::Identifier("close".into()),
                Token::Comma,
                Token::Number(12.0),
                Token::RightParen,
                Token::Symbol(">=".into()),
                Token::Number(3.0),
                Token::End,
            ]
        );
    }

    #[test]
    fn reads_exponents_but_not_a_bare_e() {
        assert_eq!(tokens("1e3"), vec![Token::Number(1000.0), Token::End]);
        assert_eq!(tokens("1e-2"), vec![Token::Number(0.01), Token::End]);
        assert_eq!(
            tokens("2e"),
            vec![Token::Number(2.0), Token::Identifier("e".into()), Token::End]
        );
    }

    #[test]
    fn a_lone_equals_is_rejected() {
        let err = Lexer::tokenize("a = 1").unwrap_err();
        assert!(matches!(err, ExprError::Syntax { .. }));
    }

    #[test]
    fn unknown_characters_are_rejected_with_a_column() {
        match Lexer::tokenize("close $ 1").unwrap_err() {
            ExprError::Syntax { column, .. } => assert_eq!(column, 7),
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn columns_count_characters_not_bytes() {
        // A Chinese identifier is multi-byte; the reported column must still be
        // the character position a human would point at.
        match Lexer::tokenize("均线 $").unwrap_err() {
            ExprError::Syntax { column, .. } => assert_eq!(column, 4),
            other => panic!("unexpected error: {other:?}"),
        }
    }
}
