use crate::ast::*;
use crate::diagnostic::Diagnostic;
use crate::lexer::{Lexer, Token};
use crate::span::Span;
use crate::types::Type;
use std::fmt;

#[derive(Debug, Clone)]
pub struct ParseError {
    pub msg: String,
    /// Source location of the offending token.
    pub span: Span,
}

impl ParseError {
    /// Render this error as a located `Diagnostic` (with the `E0100` parse-error
    /// code) so the CLI can print a snippet + caret.
    pub fn to_diagnostic(&self) -> Diagnostic {
        Diagnostic::error(self.msg.clone(), self.span).with_code("E0100")
    }
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "parse error at {}:{}: {}",
            self.span.start_line, self.span.start_col, self.msg
        )
    }
}

pub struct Parser<'a> {
    lexer: Lexer<'a>,
    current: Token,
    /// Span of `current`, used to locate parse errors at the offending token.
    current_span: Span,
}

impl<'a> Parser<'a> {
    pub fn new(input: &'a str) -> Result<Self, ParseError> {
        let mut lexer = Lexer::new(input);
        let first = lexer.next_spanned().map_err(|e| ParseError {
            msg: e.msg.clone(),
            span: e.span(),
        })?;
        Ok(Parser {
            lexer,
            current: first.token,
            current_span: first.span,
        })
    }

    /// Span of the token the parser is currently positioned on.
    fn span(&self) -> Span {
        self.current_span
    }

    fn expect_rparen_span(&mut self) -> Result<Span, ParseError> {
        let span = self.span();
        self.expect(Token::RParen)?;
        Ok(span)
    }

    fn advance(&mut self) -> Result<(), ParseError> {
        let next = self.lexer.next_spanned().map_err(|e| ParseError {
            msg: e.msg.clone(),
            span: e.span(),
        })?;
        self.current = next.token;
        self.current_span = next.span;
        Ok(())
    }

    fn expect(&mut self, tok: Token) -> Result<(), ParseError> {
        if std::mem::discriminant(&self.current) == std::mem::discriminant(&tok) {
            self.advance()?;
            Ok(())
        } else {
            Err(ParseError {
                msg: format!("expected {:?}, got {:?}", tok, self.current),
                span: self.span(),
            })
        }
    }

    fn expect_ident(&mut self) -> Result<String, ParseError> {
        match &self.current {
            Token::Ident(s) => {
                let name = s.clone();
                self.advance()?;
                Ok(name)
            }
            _ => Err(ParseError {
                msg: format!("expected identifier, got {:?}", self.current),
                span: self.span(),
            }),
        }
    }

    pub fn parse(&mut self) -> Result<Program, ParseError> {
        let mut decls = Vec::new();
        while self.current != Token::Eof {
            decls.push(self.parse_decl()?);
        }
        Ok(Program { decls })
    }

    fn parse_decl(&mut self) -> Result<Decl, ParseError> {
        self.expect(Token::LParen)?;

        match &self.current {
            Token::Define => {
                self.advance()?;
                self.parse_def()
            }
            Token::Extern => {
                self.advance()?;
                self.parse_extern()
            }
            Token::Ident(s) if s == "defenum" => {
                self.advance()?;
                self.parse_defenum()
            }
            _ => Err(ParseError {
                msg: format!("expected define, extern or defenum, got {:?}", self.current),
                span: self.span(),
            }),
        }
    }

    fn parse_def(&mut self) -> Result<Decl, ParseError> {
        // (define name [: type] expr)
        // or
        // (define (name [arg : type] ...) [: ret-type] body)
        if self.current == Token::LParen {
            // Function definition
            self.advance()?;
            let name = self.expect_ident()?;
            let mut params = Vec::new();

            while self.current != Token::RParen {
                self.expect(Token::LBracket)?;
                let param_name = self.expect_ident()?;
                self.expect(Token::Colon)?;
                let param_ty = self.parse_type()?;
                self.expect(Token::RBracket)?;
                params.push((param_name, param_ty));
            }
            self.advance()?; // consume RParen

            let ret = if self.current == Token::Colon {
                self.advance()?;
                self.parse_type()?
            } else {
                Type::Unit
            };

            let body = self.parse_expr()?;
            self.expect(Token::RParen)?;

            Ok(Decl::DefFn {
                name,
                params,
                ret,
                body,
            })
        } else {
            // Variable definition
            let name = self.expect_ident()?;
            let ty = if self.current == Token::Colon {
                self.advance()?;
                Some(self.parse_type()?)
            } else {
                None
            };
            let value = self.parse_expr()?;
            self.expect(Token::RParen)?;
            Ok(Decl::Def { name, ty, value })
        }
    }

    fn parse_extern(&mut self) -> Result<Decl, ParseError> {
        let name = self.expect_ident()?;
        self.expect(Token::Colon)?;
        let ty = self.parse_type()?;
        self.expect(Token::RParen)?;
        Ok(Decl::Extern { name, ty })
    }

    /// Parse `(defenum Name (Variant Ty...) (Variant2 ...) ...)`. The leading
    /// `(` and `defenum` ident have already been consumed.
    fn parse_defenum(&mut self) -> Result<Decl, ParseError> {
        let name = self.expect_ident()?;
        let mut variants = Vec::new();
        while self.current != Token::RParen {
            self.expect(Token::LParen)?;
            let vname = self.expect_ident()?;
            let mut fields = Vec::new();
            while self.current != Token::RParen {
                fields.push(self.parse_type()?);
            }
            self.advance()?; // consume the variant's RParen
            variants.push(VariantDef {
                name: vname,
                fields,
            });
        }
        self.expect(Token::RParen)?;
        if variants.is_empty() {
            return Err(ParseError {
                msg: format!("defenum '{}' must declare at least one variant", name),
                span: self.span(),
            });
        }
        Ok(Decl::DefEnum { name, variants })
    }

    fn parse_type(&mut self) -> Result<Type, ParseError> {
        match &self.current {
            Token::Unit => {
                self.advance()?;
                Ok(Type::Unit)
            }
            Token::Ident(s) => {
                let ty = match s.as_str() {
                    "i64" => Type::I64,
                    "i32" => Type::I32,
                    "i16" => Type::I16,
                    "i8" => Type::I8,
                    "u64" => Type::U64,
                    "u32" => Type::U32,
                    "u16" => Type::U16,
                    "u8" => Type::U8,
                    "f64" => Type::F64,
                    "f32" => Type::F32,
                    "bool" => Type::Bool,
                    "char" => Type::Char,
                    _ => Type::Var(s.clone()),
                };
                self.advance()?;
                Ok(ty)
            }
            Token::LParen => {
                self.advance()?;
                match &self.current {
                    Token::Arrow => {
                        self.advance()?;
                        let mut args = Vec::new();
                        while self.current != Token::RParen {
                            args.push(self.parse_type()?);
                        }
                        if args.is_empty() {
                            return Err(ParseError {
                                msg: "function type needs at least return type".into(),
                                span: self.span(),
                            });
                        }
                        let ret = args.pop().unwrap();
                        self.advance()?; // consume RParen
                        Ok(Type::Func(args, Box::new(ret)))
                    }
                    Token::Ident(s) if s == "Tuple" => {
                        self.advance()?;
                        let mut elems = Vec::new();
                        while self.current != Token::RParen {
                            elems.push(self.parse_type()?);
                        }
                        self.advance()?;
                        Ok(Type::Tuple(elems))
                    }
                    Token::Ident(s) if s == "Array" => {
                        self.advance()?;
                        let ty = self.parse_type()?;
                        let size = match &self.current {
                            Token::Int(n) => *n as usize,
                            _ => {
                                return Err(ParseError {
                                    msg: "array size must be integer".into(),
                                    span: self.span(),
                                });
                            }
                        };
                        self.advance()?;
                        self.expect(Token::RParen)?;
                        Ok(Type::Array(Box::new(ty), size))
                    }
                    _ => Err(ParseError {
                        msg: format!("expected type constructor, got {:?}", self.current),
                        span: self.span(),
                    }),
                }
            }
            _ => Err(ParseError {
                msg: format!("expected type, got {:?}", self.current),
                span: self.span(),
            }),
        }
    }

    fn parse_expr(&mut self) -> Result<Expr, ParseError> {
        let span = self.span();
        match &self.current {
            Token::Int(n) => {
                let val = *n;
                self.advance()?;
                Ok(Expr::spanned(Expr::Literal(Literal::Int(val)), span))
            }
            Token::Float(n) => {
                let val = *n;
                self.advance()?;
                Ok(Expr::spanned(Expr::Literal(Literal::Float(val)), span))
            }
            Token::Bool(b) => {
                let val = *b;
                self.advance()?;
                Ok(Expr::spanned(Expr::Literal(Literal::Bool(val)), span))
            }
            Token::Char(c) => {
                let val = *c;
                self.advance()?;
                Ok(Expr::spanned(Expr::Literal(Literal::Char(val)), span))
            }
            Token::String(s) => {
                let val = s.clone();
                self.advance()?;
                Ok(Expr::spanned(Expr::Literal(Literal::String(val)), span))
            }
            Token::Unit => {
                self.advance()?;
                Ok(Expr::spanned(Expr::Literal(Literal::Unit), span))
            }
            Token::Ident(s) => {
                let name = s.clone();
                self.advance()?;
                Ok(Expr::spanned(Expr::Var(name), span))
            }
            Token::LParen => self.parse_list_expr(),
            _ => Err(ParseError {
                msg: format!("unexpected token in expression: {:?}", self.current),
                span: self.span(),
            }),
        }
    }

    fn parse_list_expr(&mut self) -> Result<Expr, ParseError> {
        let start = self.span();
        self.expect(Token::LParen)?;

        let (expr, end) = match &self.current {
            Token::If => {
                self.advance()?;
                let cond = Box::new(self.parse_expr()?);
                let then_branch = Box::new(self.parse_expr()?);
                let else_branch = Box::new(self.parse_expr()?);
                let end = self.expect_rparen_span()?;
                (
                    Expr::If {
                        cond,
                        then_branch,
                        else_branch,
                    },
                    end,
                )
            }
            Token::Let => {
                self.advance()?;
                self.expect(Token::LParen)?;
                let mut bindings = Vec::new();
                while self.current != Token::RParen {
                    self.expect(Token::LBracket)?;
                    let name = self.expect_ident()?;
                    let ty = if self.current == Token::Colon {
                        self.advance()?;
                        Some(self.parse_type()?)
                    } else {
                        None
                    };
                    let value = self.parse_expr()?;
                    self.expect(Token::RBracket)?;
                    bindings.push((name, ty, value));
                }
                self.advance()?; // consume RParen
                let body = Box::new(self.parse_expr()?);
                let end = self.expect_rparen_span()?;
                (Expr::Let { bindings, body }, end)
            }
            Token::Lambda => {
                self.advance()?;
                self.expect(Token::LParen)?;
                let mut params = Vec::new();
                while self.current != Token::RParen {
                    self.expect(Token::LBracket)?;
                    let name = self.expect_ident()?;
                    self.expect(Token::Colon)?;
                    let ty = self.parse_type()?;
                    self.expect(Token::RBracket)?;
                    params.push((name, ty));
                }
                self.advance()?; // consume RParen
                let ret = if self.current == Token::Colon {
                    self.advance()?;
                    Some(self.parse_type()?)
                } else {
                    None
                };
                let body = Box::new(self.parse_expr()?);
                let end = self.expect_rparen_span()?;
                (Expr::Lambda { params, ret, body }, end)
            }
            Token::While => {
                self.advance()?;
                let cond = Box::new(self.parse_expr()?);
                let body = Box::new(self.parse_expr()?);
                let end = self.expect_rparen_span()?;
                (Expr::While { cond, body }, end)
            }
            Token::Begin => {
                self.advance()?;
                let mut exprs = Vec::new();
                while self.current != Token::RParen {
                    exprs.push(self.parse_expr()?);
                }
                let end = self.expect_rparen_span()?;
                (Expr::Begin(exprs), end)
            }
            Token::Set => {
                self.advance()?;
                let name = self.expect_ident()?;
                let value = Box::new(self.parse_expr()?);
                let end = self.expect_rparen_span()?;
                (Expr::Set(name, value), end)
            }
            Token::Ann => {
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                self.expect(Token::Colon)?;
                let ty = self.parse_type()?;
                let end = self.expect_rparen_span()?;
                (Expr::Ann { expr, ty }, end)
            }
            Token::Ident(s) if s == "cast" => {
                // (cast expr : ty)
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                self.expect(Token::Colon)?;
                let ty = self.parse_type()?;
                let end = self.expect_rparen_span()?;
                (Expr::Cast { expr, ty }, end)
            }
            Token::Ident(s) if s == "tuple" => {
                self.advance()?;
                let mut elems = Vec::new();
                while self.current != Token::RParen {
                    elems.push(self.parse_expr()?);
                }
                let end = self.expect_rparen_span()?;
                (Expr::Tuple(elems), end)
            }
            Token::Ident(s) if s == "tuple-ref" => {
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                let index = match &self.current {
                    Token::Int(n) => *n as usize,
                    _ => {
                        return Err(ParseError {
                            msg: "tuple-ref index must be integer".into(),
                            span: self.span(),
                        });
                    }
                };
                self.advance()?;
                let end = self.expect_rparen_span()?;
                (Expr::TupleRef { expr, index }, end)
            }
            Token::Ident(s) if s == "array" => {
                self.advance()?;
                let mut elems = Vec::new();
                while self.current != Token::RParen {
                    elems.push(self.parse_expr()?);
                }
                let end = self.expect_rparen_span()?;
                (Expr::Array(elems), end)
            }
            Token::Ident(s) if s == "array-ref" => {
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                let index = Box::new(self.parse_expr()?);
                let end = self.expect_rparen_span()?;
                (Expr::ArrayRef { expr, index }, end)
            }
            Token::Ident(s) if s == "match" => {
                // (match scrutinee [pattern body] ...)
                self.advance()?;
                let scrutinee = Box::new(self.parse_expr()?);
                let mut arms = Vec::new();
                while self.current != Token::RParen {
                    self.expect(Token::LBracket)?;
                    let pattern = self.parse_pattern()?;
                    let body = self.parse_expr()?;
                    self.expect(Token::RBracket)?;
                    arms.push((pattern, body));
                }
                let end = self.expect_rparen_span()?;
                (Expr::Match { scrutinee, arms }, end)
            }
            _ => {
                // Function call or binary operator
                let op = self.try_parse_binop();
                if let Some(op) = op {
                    let lhs = Box::new(self.parse_expr()?);
                    let rhs = Box::new(self.parse_expr()?);
                    let end = self.expect_rparen_span()?;
                    (Expr::Binary { op, lhs, rhs }, end)
                } else {
                    // Function call
                    let func = Box::new(self.parse_expr()?);
                    let mut args = Vec::new();
                    while self.current != Token::RParen {
                        args.push(self.parse_expr()?);
                    }
                    let end = self.expect_rparen_span()?;
                    (Expr::Call { func, args }, end)
                }
            }
        };

        Ok(Expr::spanned(expr, start.merge(&end)))
    }

    /// Parse a `match` arm pattern: `_`, a bare nullary variant `Variant`, or a
    /// variant with positional bindings `(Variant b1 b2 ...)`.
    fn parse_pattern(&mut self) -> Result<Pattern, ParseError> {
        match &self.current {
            Token::Ident(s) if s == "_" => {
                self.advance()?;
                Ok(Pattern::Wildcard)
            }
            Token::Ident(s) => {
                let name = s.clone();
                self.advance()?;
                Ok(Pattern::Variant {
                    name,
                    bindings: Vec::new(),
                })
            }
            Token::LParen => {
                self.advance()?;
                let name = self.expect_ident()?;
                let mut bindings = Vec::new();
                while self.current != Token::RParen {
                    bindings.push(self.expect_ident()?);
                }
                self.advance()?; // consume RParen
                Ok(Pattern::Variant { name, bindings })
            }
            _ => Err(ParseError {
                msg: format!("expected pattern, got {:?}", self.current),
                span: self.span(),
            }),
        }
    }

    fn try_parse_binop(&mut self) -> Option<BinOp> {
        let op = match &self.current {
            Token::Ident(s) => match s.as_str() {
                "+" => Some(BinOp::Add),
                "-" => Some(BinOp::Sub),
                "*" => Some(BinOp::Mul),
                "/" => Some(BinOp::Div),
                "%" => Some(BinOp::Mod),
                "=" => Some(BinOp::Eq),
                "!=" => Some(BinOp::Ne),
                "<" => Some(BinOp::Lt),
                "<=" => Some(BinOp::Le),
                ">" => Some(BinOp::Gt),
                ">=" => Some(BinOp::Ge),
                "and" => Some(BinOp::And),
                "or" => Some(BinOp::Or),
                "bit-and" => Some(BinOp::BitAnd),
                "bit-or" => Some(BinOp::BitOr),
                "bit-xor" => Some(BinOp::BitXor),
                "shl" => Some(BinOp::Shl),
                "shr" => Some(BinOp::Shr),
                _ => None,
            },
            _ => None,
        };
        if op.is_some() {
            // Don't advance here - we need to consume it in parse_list_expr
            // Actually we do need to advance since we're consuming the operator
            let _ = self.advance();
        }
        op
    }
}

pub fn parse(input: &str) -> Result<Program, ParseError> {
    let mut parser = Parser::new(input)?;
    parser.parse()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_define() {
        let prog = parse("(define x : i64 42)").unwrap();
        assert_eq!(prog.decls.len(), 1);
        match &prog.decls[0] {
            Decl::Def { name, ty, value } => {
                assert_eq!(name, "x");
                assert_eq!(*ty, Some(Type::I64));
                assert_eq!(value.unspan(), &Expr::Literal(Literal::Int(42)));
                assert_eq!(value.span(), Span::new(1, 17, 1, 19));
            }
            _ => panic!("expected Def"),
        }
    }

    #[test]
    fn test_parse_function() {
        let prog = parse("(define (add [a : i64] [b : i64]) : i64 (+ a b))").unwrap();
        assert_eq!(prog.decls.len(), 1);
        match &prog.decls[0] {
            Decl::DefFn {
                name, params, ret, ..
            } => {
                assert_eq!(name, "add");
                assert_eq!(params.len(), 2);
                assert_eq!(ret, &Type::I64);
            }
            _ => panic!("expected DefFn"),
        }
    }

    #[test]
    fn test_parse_unit_return_type() {
        let prog = parse("(define (noop) : unit unit)").unwrap();
        assert_eq!(prog.decls.len(), 1);
        match &prog.decls[0] {
            Decl::DefFn { ret, body, .. } => {
                assert_eq!(ret, &Type::Unit);
                assert_eq!(body.unspan(), &Expr::Literal(Literal::Unit));
            }
            _ => panic!("expected DefFn"),
        }
    }

    #[test]
    fn test_parse_expression_nodes_carry_spans() {
        let prog = parse("(define (add [a : i64] [b : i64]) : i64 (+ a b))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body,
            _ => panic!("expected DefFn"),
        };
        assert_eq!(body.span(), Span::new(1, 41, 1, 48));
        match body.unspan() {
            Expr::Binary { lhs, rhs, .. } => {
                assert_eq!(lhs.span(), Span::new(1, 44, 1, 45));
                assert_eq!(rhs.span(), Span::new(1, 46, 1, 47));
            }
            other => panic!("expected binary body, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_error_carries_span() {
        // ")" cannot start a declaration; the error must point at it.
        // Source: "(define x 42))"  — the trailing ')' on column 14 begins a
        // bogus decl (LParen expected).
        let err = parse("(define x 42))").unwrap_err();
        // The offending token is the stray ')' at column 14.
        assert_eq!(err.span.start_line, 1);
        assert_eq!(err.span.start_col, 14, "error: {}", err);
    }

    #[test]
    fn test_parse_error_diagnostic_renders_caret() {
        use crate::diagnostic::format_diagnostic;
        // Unexpected token inside an expression: ':' where an expression is
        // expected. Source line 1, the ':' is at column 11.
        let src = "(define x :)";
        let err = parse(src).unwrap_err();
        let diag = err.to_diagnostic();
        let rendered = format_diagnostic(&diag, src, "test.tl");
        assert!(
            rendered.contains("error[E0100]"),
            "missing code; got:\n{}",
            rendered
        );
        assert!(
            rendered.contains("--> test.tl:1:"),
            "missing location; got:\n{}",
            rendered
        );
        assert!(
            rendered.contains(" 1 | (define x :)"),
            "missing source snippet; got:\n{}",
            rendered
        );
        assert!(rendered.contains('^'), "no caret; got:\n{}", rendered);
    }

    #[test]
    fn test_parse_error_span_on_later_line() {
        // The bad token (an integer where a type is expected) is on line 3.
        let src = "(define a 1)\n(define b 2)\n(define c : 3 4)";
        let err = parse(src).unwrap_err();
        assert_eq!(err.span.start_line, 3, "error: {}", err);
    }

    // ------------------------------------------------------------------
    // Sum types + pattern matching — Issue #41
    // ------------------------------------------------------------------

    #[test]
    fn test_parse_defenum() {
        let prog = parse("(defenum Shape (Circle f64) (Square i64) (Nothing))").unwrap();
        assert_eq!(prog.decls.len(), 1);
        match &prog.decls[0] {
            Decl::DefEnum { name, variants } => {
                assert_eq!(name, "Shape");
                assert_eq!(variants.len(), 3);
                assert_eq!(variants[0].name, "Circle");
                assert_eq!(variants[0].fields, vec![Type::F64]);
                assert_eq!(variants[1].name, "Square");
                assert_eq!(variants[1].fields, vec![Type::I64]);
                assert_eq!(variants[2].name, "Nothing");
                assert!(variants[2].fields.is_empty());
            }
            other => panic!("expected DefEnum, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_defenum_empty_is_error() {
        assert!(parse("(defenum Empty)").is_err());
    }

    #[test]
    fn test_parse_match_arms_and_patterns() {
        let prog = parse(
            "(define (f [s : Shape]) : i64 \
               (match s [(Circle r) 1] [(Square w) 2] [_ 3]))",
        )
        .unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Match { arms, .. } => {
                assert_eq!(arms.len(), 3);
                assert_eq!(
                    arms[0].0,
                    Pattern::Variant {
                        name: "Circle".into(),
                        bindings: vec!["r".into()]
                    }
                );
                assert_eq!(
                    arms[1].0,
                    Pattern::Variant {
                        name: "Square".into(),
                        bindings: vec!["w".into()]
                    }
                );
                assert_eq!(arms[2].0, Pattern::Wildcard);
            }
            other => panic!("expected Match, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_nullary_variant_pattern() {
        let prog = parse("(define (f [c : Color]) : i64 (match c [Red 0] [_ 1]))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Match { arms, .. } => {
                assert_eq!(
                    arms[0].0,
                    Pattern::Variant {
                        name: "Red".into(),
                        bindings: vec![]
                    }
                );
            }
            other => panic!("expected Match, got {:?}", other),
        }
    }
}
