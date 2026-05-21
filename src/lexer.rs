use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    // Delimiters
    LParen,
    RParen,
    LBracket,
    RBracket,

    // Keywords
    Define,
    Lambda,
    If,
    Let,
    While,
    Begin,
    Set,
    Extern,
    Ann,

    // Literals
    Int(i64),
    Float(f64),
    Bool(bool),
    Char(char),
    String(String),

    // Special
    Unit,
    Colon,
    Arrow,      // ->
    Quote,      // '
    Backtick,   // `
    Comma,      // ,
    CommaAt,    // ,@
    Dot,

    // Identifier
    Ident(String),

    // End of file
    Eof,
}

impl fmt::Display for Token {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Token::LParen => write!(f, "("),
            Token::RParen => write!(f, ")"),
            Token::LBracket => write!(f, "["),
            Token::RBracket => write!(f, "]"),
            Token::Define => write!(f, "define"),
            Token::Lambda => write!(f, "lambda"),
            Token::If => write!(f, "if"),
            Token::Let => write!(f, "let"),
            Token::While => write!(f, "while"),
            Token::Begin => write!(f, "begin"),
            Token::Set => write!(f, "set!"),
            Token::Extern => write!(f, "extern"),
            Token::Ann => write!(f, "ann"),
            Token::Int(n) => write!(f, "{}", n),
            Token::Float(n) => write!(f, "{}", n),
            Token::Bool(b) => write!(f, "{}", b),
            Token::Char(c) => write!(f, "'{}'", c),
            Token::String(s) => write!(f, "\"{}\"", s),
            Token::Unit => write!(f, "unit"),
            Token::Colon => write!(f, ":"),
            Token::Arrow => write!(f, "->"),
            Token::Quote => write!(f, "'"),
            Token::Backtick => write!(f, "`"),
            Token::Comma => write!(f, ","),
            Token::CommaAt => write!(f, ",@"),
            Token::Dot => write!(f, "."),
            Token::Ident(s) => write!(f, "{}", s),
            Token::Eof => write!(f, "<eof>"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct LexerError {
    pub msg: String,
    pub line: usize,
    pub col: usize,
}

impl fmt::Display for LexerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "lexer error at {}:{}: {}", self.line, self.col, self.msg)
    }
}

pub struct Lexer<'a> {
    input: &'a str,
    chars: std::str::Chars<'a>,
    current: Option<char>,
    line: usize,
    col: usize,
}

impl<'a> Lexer<'a> {
    pub fn new(input: &'a str) -> Self {
        let mut chars = input.chars();
        let current = chars.next();
        Lexer {
            input,
            chars,
            current,
            line: 1,
            col: 1,
        }
    }

    fn advance(&mut self) {
        if let Some(c) = self.current {
            if c == '\n' {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }
        self.current = self.chars.next();
    }

    fn peek(&self) -> Option<char> {
        self.current
    }

    fn skip_whitespace(&mut self) {
        while let Some(c) = self.peek() {
            if c.is_whitespace() {
                self.advance();
            } else if c == ';' {
                // Line comment
                while let Some(c) = self.peek() {
                    self.advance();
                    if c == '\n' {
                        break;
                    }
                }
            } else {
                break;
            }
        }
    }

    fn read_string(&mut self) -> Result<Token, LexerError> {
        self.advance(); // consume opening "
        let mut s = String::new();
        while let Some(c) = self.peek() {
            if c == '"' {
                self.advance();
                return Ok(Token::String(s));
            } else if c == '\\' {
                self.advance();
                match self.peek() {
                    Some('n') => s.push('\n'),
                    Some('t') => s.push('\t'),
                    Some('r') => s.push('\r'),
                    Some('\\') => s.push('\\'),
                    Some('"') => s.push('"'),
                    Some(c) => s.push(c),
                    None => {
                        return Err(LexerError {
                            msg: "unterminated string escape".into(),
                            line: self.line,
                            col: self.col,
                        })
                    }
                }
                self.advance();
            } else {
                s.push(c);
                self.advance();
            }
        }
        Err(LexerError {
            msg: "unterminated string literal".into(),
            line: self.line,
            col: self.col,
        })
    }

    fn read_char(&mut self) -> Result<Token, LexerError> {
        self.advance(); // consume #
        if self.peek() == Some('\\') {
            self.advance();
            let c = match self.peek() {
                Some('n') => '\n',
                Some('t') => '\t',
                Some('r') => '\r',
                Some('0') => '\0',
                Some(c) => c,
                None => {
                    return Err(LexerError {
                        msg: "unterminated character literal".into(),
                        line: self.line,
                        col: self.col,
                    })
                }
            };
            self.advance();
            if self.peek() == Some('\'') {
                self.advance();
                Ok(Token::Char(c))
            } else {
                Err(LexerError {
                    msg: "expected ' after character".into(),
                    line: self.line,
                    col: self.col,
                })
            }
        } else if let Some(c) = self.peek() {
            self.advance();
            if self.peek() == Some('\'') {
                self.advance();
                Ok(Token::Char(c))
            } else {
                Err(LexerError {
                    msg: "expected ' after character".into(),
                    line: self.line,
                    col: self.col,
                })
            }
        } else {
            Err(LexerError {
                msg: "unterminated character literal".into(),
                line: self.line,
                col: self.col,
            })
        }
    }

    fn read_number(&mut self, first: char) -> Result<Token, LexerError> {
        let mut s = String::new();
        s.push(first);
        let mut is_float = false;

        while let Some(c) = self.peek() {
            if c.is_ascii_digit() {
                s.push(c);
                self.advance();
            } else if c == '.' && !is_float {
                is_float = true;
                s.push(c);
                self.advance();
            } else if c == '_' {
                // Allow underscores in numbers like 1_000_000
                self.advance();
            } else {
                break;
            }
        }

        if is_float {
            match s.parse::<f64>() {
                Ok(n) => Ok(Token::Float(n)),
                Err(_) => Err(LexerError {
                    msg: format!("invalid float literal: {}", s),
                    line: self.line,
                    col: self.col,
                }),
            }
        } else {
            match s.parse::<i64>() {
                Ok(n) => Ok(Token::Int(n)),
                Err(_) => Err(LexerError {
                    msg: format!("invalid integer literal: {}", s),
                    line: self.line,
                    col: self.col,
                }),
            }
        }
    }

    fn read_ident(&mut self, first: char) -> Token {
        let mut s = String::new();
        s.push(first);

        while let Some(c) = self.peek() {
            if c.is_alphanumeric() || c == '_' || c == '-' || c == '!' || c == '?' || c == '+' || c == '*' || c == '/' || c == '=' || c == '<' || c == '>' || c == '$' || c == '%' || c == '&' {
                s.push(c);
                self.advance();
            } else {
                break;
            }
        }

        match s.as_str() {
            "define" => Token::Define,
            "lambda" => Token::Lambda,
            "if" => Token::If,
            "let" => Token::Let,
            "while" => Token::While,
            "begin" => Token::Begin,
            "set!" => Token::Set,
            "extern" => Token::Extern,
            "ann" => Token::Ann,
            "true" => Token::Bool(true),
            "false" => Token::Bool(false),
            "unit" => Token::Unit,
            _ => Token::Ident(s),
        }
    }

    pub fn next_token(&mut self) -> Result<Token, LexerError> {
        self.skip_whitespace();

        let c = match self.peek() {
            Some(c) => c,
            None => return Ok(Token::Eof),
        };

        match c {
            '(' => {
                self.advance();
                Ok(Token::LParen)
            }
            ')' => {
                self.advance();
                Ok(Token::RParen)
            }
            '[' => {
                self.advance();
                Ok(Token::LBracket)
            }
            ']' => {
                self.advance();
                Ok(Token::RBracket)
            }
            ':' => {
                self.advance();
                Ok(Token::Colon)
            }
            '\'' => {
                self.advance();
                Ok(Token::Quote)
            }
            '`' => {
                self.advance();
                Ok(Token::Backtick)
            }
            '.' => {
                self.advance();
                Ok(Token::Dot)
            }
            '"' => self.read_string(),
            '#' => self.read_char(),
            '-' => {
                self.advance();
                if self.peek() == Some('>') {
                    self.advance();
                    Ok(Token::Arrow)
                } else if let Some(c) = self.peek() {
                    if c.is_ascii_digit() {
                        self.read_number('-')
                    } else {
                        Ok(self.read_ident('-'))
                    }
                } else {
                    Ok(Token::Ident("-".into()))
                }
            }
            ',' => {
                self.advance();
                if self.peek() == Some('@') {
                    self.advance();
                    Ok(Token::CommaAt)
                } else {
                    Ok(Token::Comma)
                }
            }
            c if c.is_ascii_digit() => {
                self.advance();
                self.read_number(c)
            }
            c => {
                self.advance();
                Ok(self.read_ident(c))
            }
        }
    }

    pub fn tokenize(&mut self) -> Result<Vec<Token>, LexerError> {
        let mut tokens = Vec::new();
        loop {
            let tok = self.next_token()?;
            if tok == Token::Eof {
                break;
            }
            tokens.push(tok);
        }
        Ok(tokens)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_tokens() {
        let mut lexer = Lexer::new("(define x 42)");
        let tokens = lexer.tokenize().unwrap();
        assert_eq!(tokens, vec![
            Token::LParen,
            Token::Define,
            Token::Ident("x".into()),
            Token::Int(42),
            Token::RParen,
        ]);
    }

    #[test]
    fn test_types() {
        let mut lexer = Lexer::new("(-> i64 i64)");
        let tokens = lexer.tokenize().unwrap();
        assert_eq!(tokens, vec![
            Token::LParen,
            Token::Arrow,
            Token::Ident("i64".into()),
            Token::Ident("i64".into()),
            Token::RParen,
        ]);
    }
}
