//! Recursive-descent parser for the grammar documented in `docs/STRATEGY.md`.

use super::lexer::{Lexeme, Lexer, Token};
use super::{BinaryOp, Expr, ExprError, ExprResult, KEYWORDS};

pub struct Parser {
    lexemes: Vec<Lexeme>,
    position: usize,
}

pub fn parse(source: &str) -> ExprResult<Expr> {
    let trimmed = source.trim();
    if trimmed.is_empty() {
        return Err(ExprError::Syntax {
            message: "表达式为空".into(),
            column: 1,
        });
    }
    let mut parser = Parser {
        lexemes: Lexer::tokenize(trimmed)?,
        position: 0,
    };
    let expression = parser.parse_or()?;
    if parser.peek().token != Token::End {
        return Err(ExprError::Syntax {
            message: "表达式末尾有多余内容".into(),
            column: parser.peek().column,
        });
    }
    Ok(expression)
}

impl Parser {
    fn peek(&self) -> &Lexeme {
        &self.lexemes[self.position]
    }

    fn advance(&mut self) -> Lexeme {
        let lexeme = self.lexemes[self.position].clone();
        self.position = (self.position + 1).min(self.lexemes.len() - 1);
        lexeme
    }

    fn match_symbol(&mut self, symbol: &str) -> bool {
        if let Token::Symbol(s) = &self.peek().token {
            if s == symbol {
                self.position += 1;
                return true;
            }
        }
        false
    }

    fn match_keyword(&mut self, keyword: &str) -> bool {
        if self.is_keyword(keyword) {
            self.position += 1;
            return true;
        }
        false
    }

    fn is_keyword(&self, name: &str) -> bool {
        matches!(&self.peek().token, Token::Identifier(id) if id == name)
    }

    fn match_comma(&mut self) -> bool {
        if self.peek().token == Token::Comma {
            self.position += 1;
            return true;
        }
        false
    }

    // MARK: Grammar

    fn parse_or(&mut self) -> ExprResult<Expr> {
        let mut left = self.parse_and()?;
        while self.match_keyword("or") {
            let right = self.parse_and()?;
            left = Expr::Binary(BinaryOp::Or, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_and(&mut self) -> ExprResult<Expr> {
        let mut left = self.parse_not()?;
        while self.match_keyword("and") {
            let right = self.parse_not()?;
            left = Expr::Binary(BinaryOp::And, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_not(&mut self) -> ExprResult<Expr> {
        if self.match_keyword("not") {
            return Ok(Expr::Not(Box::new(self.parse_not()?)));
        }
        self.parse_comparison()
    }

    fn parse_comparison(&mut self) -> ExprResult<Expr> {
        let left = self.parse_sum()?;
        for keyword in ["crosses_above", "crosses_below"] {
            if self.is_keyword(keyword) {
                self.position += 1;
                let op = if keyword == "crosses_above" {
                    BinaryOp::CrossesAbove
                } else {
                    BinaryOp::CrossesBelow
                };
                let right = self.parse_sum()?;
                return Ok(Expr::Binary(op, Box::new(left), Box::new(right)));
            }
        }
        if let Token::Symbol(s) = &self.peek().token {
            if let Some(op) = BinaryOp::from_symbol(s) {
                if op.is_comparison() {
                    self.position += 1;
                    let right = self.parse_sum()?;
                    return Ok(Expr::Binary(op, Box::new(left), Box::new(right)));
                }
            }
        }
        Ok(left)
    }

    fn parse_sum(&mut self) -> ExprResult<Expr> {
        let mut left = self.parse_product()?;
        loop {
            if self.match_symbol("+") {
                let right = self.parse_product()?;
                left = Expr::Binary(BinaryOp::Add, Box::new(left), Box::new(right));
            } else if self.match_symbol("-") {
                let right = self.parse_product()?;
                left = Expr::Binary(BinaryOp::Subtract, Box::new(left), Box::new(right));
            } else {
                return Ok(left);
            }
        }
    }

    fn parse_product(&mut self) -> ExprResult<Expr> {
        let mut left = self.parse_unary()?;
        loop {
            if self.match_symbol("*") {
                let right = self.parse_unary()?;
                left = Expr::Binary(BinaryOp::Multiply, Box::new(left), Box::new(right));
            } else if self.match_symbol("/") {
                let right = self.parse_unary()?;
                left = Expr::Binary(BinaryOp::Divide, Box::new(left), Box::new(right));
            } else if self.match_symbol("%") {
                let right = self.parse_unary()?;
                left = Expr::Binary(BinaryOp::Modulo, Box::new(left), Box::new(right));
            } else {
                return Ok(left);
            }
        }
    }

    fn parse_unary(&mut self) -> ExprResult<Expr> {
        if self.match_symbol("-") {
            return Ok(Expr::Negate(Box::new(self.parse_unary()?)));
        }
        if self.match_symbol("+") {
            return self.parse_unary();
        }
        self.parse_primary()
    }

    fn parse_primary(&mut self) -> ExprResult<Expr> {
        let lexeme = self.advance();
        match lexeme.token {
            Token::Number(value) => Ok(Expr::number(value)),

            Token::Identifier(name) => {
                if KEYWORDS.contains(&name.as_str()) {
                    return Err(ExprError::Syntax {
                        message: format!("'{name}' 不能出现在这里"),
                        column: lexeme.column,
                    });
                }
                if self.peek().token != Token::LeftParen {
                    return Ok(Expr::Variable(name));
                }
                self.position += 1; // consume '('
                let mut arguments = Vec::new();
                if self.peek().token != Token::RightParen {
                    loop {
                        arguments.push(self.parse_or()?);
                        if !self.match_comma() {
                            break;
                        }
                    }
                }
                if self.peek().token != Token::RightParen {
                    return Err(ExprError::Syntax {
                        message: format!("{name}( 缺少右括号"),
                        column: self.peek().column,
                    });
                }
                self.position += 1;
                Ok(Expr::Call(name, arguments))
            }

            Token::LeftParen => {
                let inner = self.parse_or()?;
                if self.peek().token != Token::RightParen {
                    return Err(ExprError::Syntax {
                        message: "缺少右括号".into(),
                        column: self.peek().column,
                    });
                }
                self.position += 1;
                Ok(inner)
            }

            Token::RightParen | Token::Comma | Token::Symbol(_) | Token::End => {
                Err(ExprError::Syntax {
                    message: "此处需要一个数值、变量或函数".into(),
                    column: lexeme.column,
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn precedence_binds_multiplication_tighter_than_addition() {
        // 1 + 2 * 3 must parse as 1 + (2 * 3).
        let e = parse("1 + 2 * 3").unwrap();
        match e {
            Expr::Binary(BinaryOp::Add, lhs, rhs) => {
                assert_eq!(*lhs, Expr::number(1.0));
                assert!(matches!(*rhs, Expr::Binary(BinaryOp::Multiply, _, _)));
            }
            other => panic!("unexpected shape: {other:?}"),
        }
    }

    #[test]
    fn comparison_binds_looser_than_arithmetic() {
        let e = parse("close + 1 > sma(close, 20)").unwrap();
        assert!(matches!(e, Expr::Binary(BinaryOp::Greater, _, _)));
    }

    #[test]
    fn and_binds_tighter_than_or() {
        // a or b and c  ==  a or (b and c)
        let e = parse("a or b and c").unwrap();
        match e {
            Expr::Binary(BinaryOp::Or, lhs, rhs) => {
                assert_eq!(*lhs, Expr::Variable("a".into()));
                assert!(matches!(*rhs, Expr::Binary(BinaryOp::And, _, _)));
            }
            other => panic!("unexpected shape: {other:?}"),
        }
    }

    #[test]
    fn crossing_operators_parse_as_binaries() {
        let e = parse("ema(close, 12) crosses_above ema(close, 26)").unwrap();
        assert!(matches!(e, Expr::Binary(BinaryOp::CrossesAbove, _, _)));
    }

    #[test]
    fn calls_take_full_expressions_as_arguments() {
        let e = parse("sma(close * 2, fast + 1)").unwrap();
        match e {
            Expr::Call(name, args) => {
                assert_eq!(name, "sma");
                assert_eq!(args.len(), 2);
            }
            other => panic!("unexpected shape: {other:?}"),
        }
    }

    #[test]
    fn trailing_junk_is_rejected() {
        assert!(parse("close 5").is_err());
        assert!(parse("").is_err());
        assert!(parse("   ").is_err());
    }

    #[test]
    fn unbalanced_parentheses_are_rejected() {
        assert!(parse("sma(close, 20").is_err());
        assert!(parse("(close + 1").is_err());
    }

    #[test]
    fn keywords_cannot_be_used_as_values() {
        assert!(parse("and").is_err());
        assert!(parse("close > and").is_err());
    }

    #[test]
    fn unary_minus_nests() {
        let e = parse("--close").unwrap();
        assert!(matches!(e, Expr::Negate(_)));
    }

    #[test]
    fn nothing_in_the_grammar_can_name_an_effect() {
        // There is no statement, assignment or block production at all: these
        // are syntax errors, not privileged operations.
        for source in ["x = 1", "import os", "close; close", "{ close }"] {
            assert!(parse(source).is_err(), "{source} must not parse");
        }
    }
}
