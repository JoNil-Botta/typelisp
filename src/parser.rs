use crate::ast::*;
use crate::diagnostic::Diagnostic;
use crate::lexer::{Lexer, Token};
use crate::span::Span;
use crate::types::Type;
use std::collections::HashSet;
use std::fmt;

#[derive(Debug, Clone)]
pub struct ParseError {
    pub msg: String,
    /// Source location of the offending token.
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
#[allow(dead_code)] // Used by the REPL command added in follow-up issues.
pub enum ReplItem {
    Decl(Decl),
    Expr(Expr),
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
        Self::new_with_file_id(input, 0)
    }

    pub fn new_with_file_id(input: &'a str, file_id: u32) -> Result<Self, ParseError> {
        let mut lexer = Lexer::new_with_file_id(input, file_id);
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

    #[allow(dead_code)] // Used by the REPL command added in follow-up issues.
    pub fn parse_repl_item(&mut self) -> Result<ReplItem, ParseError> {
        if self.current == Token::Eof {
            return Err(ParseError {
                msg: "expected REPL item, got EOF".into(),
                span: self.span(),
            });
        }

        let item = match &self.current {
            Token::LParen => {
                let start = self.span();
                self.expect(Token::LParen)?;
                match &self.current {
                    Token::Define | Token::Extern | Token::Import => {
                        ReplItem::Decl(self.parse_decl_after_open()?)
                    }
                    Token::Ident(s) if s == "defenum" || s == "defstruct" => {
                        ReplItem::Decl(self.parse_decl_after_open()?)
                    }
                    _ => ReplItem::Expr(self.parse_list_expr_after_open(start)?),
                }
            }
            _ => ReplItem::Expr(self.parse_expr()?),
        };
        self.expect_eof()?;
        Ok(item)
    }

    fn parse_decl(&mut self) -> Result<Decl, ParseError> {
        self.expect(Token::LParen)?;
        self.parse_decl_after_open()
    }

    fn parse_decl_after_open(&mut self) -> Result<Decl, ParseError> {
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
            Token::Ident(s) if s == "defstruct" => {
                self.advance()?;
                self.parse_defstruct()
            }
            Token::Ident(s) if s == "comptime-decl" => {
                let span = self.span();
                self.advance()?;
                self.parse_comptime_decl(span)
            }
            Token::Ident(s) if s == "test" => {
                let span = self.span();
                self.advance()?;
                self.parse_test(span)
            }
            Token::Import => {
                self.advance()?;
                self.parse_import()
            }
            _ => Err(ParseError {
                msg: format!(
                    "expected define, extern, defenum, defstruct, comptime-decl, import or test, got {:?}",
                    self.current
                ),
                span: self.span(),
            }),
        }
    }

    #[allow(dead_code)] // Used by the REPL parser entry point.
    fn expect_eof(&self) -> Result<(), ParseError> {
        if self.current == Token::Eof {
            Ok(())
        } else {
            Err(ParseError {
                msg: format!("unexpected trailing token: {:?}", self.current),
                span: self.span(),
            })
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
            let mut comptime_params = Vec::new();
            let mut seen_params = HashSet::new();

            while self.current != Token::RParen {
                self.expect(Token::LBracket)?;
                let comptime = matches!(&self.current, Token::Ident(s) if s == "comptime");
                if comptime {
                    self.advance()?;
                }
                let param_name = self.expect_ident()?;
                if !seen_params.insert(param_name.clone()) {
                    return Err(ParseError {
                        msg: format!("duplicate parameter name '{}'", param_name),
                        span: self.span(),
                    });
                }
                self.expect(Token::Colon)?;
                let param_ty = self.parse_type()?;
                self.expect(Token::RBracket)?;
                if comptime {
                    comptime_params.push(params.len());
                }
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
                comptime_params,
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

    /// Parse `(import "path")`. The leading `(` and `import` keyword have
    /// already been consumed. The path is a plain string literal, resolved by
    /// the module-graph loader relative to the importing file.
    fn parse_import(&mut self) -> Result<Decl, ParseError> {
        let path = match &self.current {
            Token::String(s) => {
                let p = s.clone();
                self.advance()?;
                p
            }
            _ => {
                return Err(ParseError {
                    msg: format!("expected import path string, got {:?}", self.current),
                    span: self.span(),
                });
            }
        };
        self.expect(Token::RParen)?;
        Ok(Decl::Import(path))
    }

    fn parse_test(&mut self, span: Span) -> Result<Decl, ParseError> {
        let name = self.expect_ident()?;
        let mut exprs = Vec::new();
        while self.current != Token::RParen {
            if self.current == Token::Eof {
                return Err(ParseError {
                    msg: "unterminated test item".into(),
                    span: self.span(),
                });
            }
            exprs.push(self.parse_expr()?);
        }
        self.expect(Token::RParen)?;
        if exprs.is_empty() {
            return Err(ParseError {
                msg: format!("test '{}' must contain at least one expression", name),
                span,
            });
        }
        let body = if exprs.len() == 1 {
            exprs.remove(0)
        } else {
            Expr::Begin(exprs)
        };
        Ok(Decl::Test { name, body, span })
    }

    /// Parse `(comptime-decl (defstruct ...))` / `(comptime-decl (defenum ...))`.
    /// The leading `(` and `comptime-decl` ident have already been consumed;
    /// `generator_span` is the span of the `comptime-decl` keyword. This first
    /// slice accepts exactly one literal `defstruct` or `defenum` template;
    /// computed names, generated functions, and arbitrary CTFE payloads are
    /// rejected here.
    fn parse_comptime_decl(&mut self, generator_span: Span) -> Result<Decl, ParseError> {
        self.expect(Token::LParen)?;
        let template = match &self.current {
            Token::Ident(s) if s == "defenum" => {
                self.advance()?;
                self.parse_defenum()?
            }
            Token::Ident(s) if s == "defstruct" => {
                self.advance()?;
                self.parse_defstruct()?
            }
            other => {
                return Err(ParseError {
                    msg: format!(
                        "comptime-decl accepts only a defstruct or defenum template, got {:?}",
                        other
                    ),
                    span: self.span(),
                });
            }
        };
        self.expect(Token::RParen)?; // close the (comptime-decl ...) wrapper
        Ok(Decl::ComptimeDecl {
            template: Box::new(template),
            span: generator_span,
        })
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

    /// Parse `(defstruct Name (field1 Ty1) (field2 Ty2) ...)`. The leading `(`
    /// and `defstruct` ident have already been consumed. Each field is a
    /// `(field-name type)` pair.
    fn parse_defstruct(&mut self) -> Result<Decl, ParseError> {
        let name = self.expect_ident()?;
        let mut fields = Vec::new();
        while self.current != Token::RParen {
            self.expect(Token::LParen)?;
            let fname = self.expect_ident()?;
            let fty = self.parse_type()?;
            self.expect(Token::RParen)?;
            fields.push(FieldDef {
                name: fname,
                ty: fty,
            });
        }
        self.expect(Token::RParen)?;
        if fields.is_empty() {
            return Err(ParseError {
                msg: format!("defstruct '{}' must declare at least one field", name),
                span: self.span(),
            });
        }
        Ok(Decl::DefStruct { name, fields })
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
                    "String" => Type::String,
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
                        // `(Array elem N)` is a fixed-size array; `(Array elem)`
                        // (no size) is a dynamic, runtime-sized array.
                        match &self.current {
                            Token::Int(n) => {
                                let size = *n as usize;
                                self.advance()?;
                                self.expect(Token::RParen)?;
                                Ok(Type::Array(Box::new(ty), size))
                            }
                            Token::RParen => {
                                self.advance()?;
                                Ok(Type::DynArray(Box::new(ty)))
                            }
                            _ => Err(ParseError {
                                msg: "array size must be integer".into(),
                                span: self.span(),
                            }),
                        }
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

    fn parse_cond_expr(&mut self) -> Result<(Expr, Span), ParseError> {
        let mut arms = Vec::new();
        let mut fallback = None;

        while self.current != Token::RParen {
            self.expect(Token::LBracket)?;
            if matches!(&self.current, Token::Ident(s) if s == "else") {
                self.advance()?;
                let body = self.parse_expr()?;
                self.expect(Token::RBracket)?;
                if self.current != Token::RParen {
                    return Err(ParseError {
                        msg: "cond else arm must be final".into(),
                        span: self.span(),
                    });
                }
                fallback = Some(body);
            } else {
                let cond = self.parse_expr()?;
                let body = self.parse_expr()?;
                self.expect(Token::RBracket)?;
                arms.push((cond, body));
            }
        }

        let end = self.expect_rparen_span()?;
        if arms.is_empty() {
            return Err(ParseError {
                msg: "cond requires at least one test arm".into(),
                span: end,
            });
        }
        let Some(mut expr) = fallback else {
            return Err(ParseError {
                msg: "cond requires final else arm".into(),
                span: end,
            });
        };

        for (cond, then_branch) in arms.into_iter().rev() {
            let span = cond.span().merge(&expr.span());
            expr = Expr::spanned(
                Expr::If {
                    cond: Box::new(cond),
                    then_branch: Box::new(then_branch),
                    else_branch: Box::new(expr),
                },
                span,
            );
        }

        Ok((expr, end))
    }

    fn parse_list_expr(&mut self) -> Result<Expr, ParseError> {
        let start = self.span();
        self.expect(Token::LParen)?;
        self.parse_list_expr_after_open(start)
    }

    fn parse_let_binding(&mut self) -> Result<(String, Option<Type>, Expr), ParseError> {
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
        Ok((name, ty, value))
    }

    fn parse_flat_let_bindings(&mut self) -> Result<Vec<(String, Option<Type>, Expr)>, ParseError> {
        let mut bindings = Vec::new();
        while self.current == Token::LBracket {
            bindings.push(self.parse_let_binding()?);
        }
        if bindings.is_empty() {
            return Err(ParseError {
                msg: "let requires at least one binding".into(),
                span: self.span(),
            });
        }
        Ok(bindings)
    }

    fn parse_legacy_let_bindings(
        &mut self,
    ) -> Result<Vec<(String, Option<Type>, Expr)>, ParseError> {
        self.expect(Token::LParen)?;
        let mut bindings = Vec::new();
        while self.current != Token::RParen {
            bindings.push(self.parse_let_binding()?);
        }
        let end = self.span();
        self.expect(Token::RParen)?;
        if bindings.is_empty() {
            return Err(ParseError {
                msg: "let requires at least one binding".into(),
                span: end,
            });
        }
        Ok(bindings)
    }

    fn parse_list_expr_after_open(&mut self, start: Span) -> Result<Expr, ParseError> {
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
            Token::Ident(s) if s == "cond" => {
                self.advance()?;
                self.parse_cond_expr()?
            }
            Token::Let => {
                self.advance()?;
                let bindings = if self.current == Token::LParen {
                    self.parse_legacy_let_bindings()?
                } else {
                    self.parse_flat_let_bindings()?
                };
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
                    if matches!(&self.current, Token::Ident(s) if s == "comptime") {
                        return Err(ParseError {
                            msg: "comptime parameters are only supported on top-level function definitions".into(),
                            span: self.span(),
                        });
                    }
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
            Token::Ident(s) if s == "comptime-decl" => {
                return Err(ParseError {
                    msg: "comptime-decl is only valid as a top-level declaration, not in expression position".into(),
                    span: self.span(),
                });
            }
            Token::Ident(s) if s == "comptime" => {
                self.advance()?;
                if self.current == Token::RParen {
                    return Err(ParseError {
                        msg: "comptime expects exactly one expression".into(),
                        span: self.span(),
                    });
                }
                let expr = Box::new(self.parse_expr()?);
                if self.current != Token::RParen {
                    return Err(ParseError {
                        msg: "comptime expects exactly one expression".into(),
                        span: self.span(),
                    });
                }
                let end = self.expect_rparen_span()?;
                (Expr::Comptime { expr }, end)
            }
            Token::Ident(s) if s == "type" => {
                self.advance()?;
                if self.current == Token::RParen {
                    return Err(ParseError {
                        msg: "type expects exactly one type".into(),
                        span: self.span(),
                    });
                }
                let ty = self.parse_type()?;
                if self.current != Token::RParen {
                    return Err(ParseError {
                        msg: "type expects exactly one type".into(),
                        span: self.span(),
                    });
                }
                let end = self.expect_rparen_span()?;
                (Expr::TypeLiteral { ty }, end)
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
            Token::Ident(s) if s == "struct-get" => {
                // (struct-get s field)
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                let field = self.expect_ident()?;
                let end = self.expect_rparen_span()?;
                (Expr::StructGet { expr, field }, end)
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
            Token::Ident(s) if s == "make-array" => {
                // (make-array elem-ty len)
                self.advance()?;
                let elem_ty = self.parse_type()?;
                let len = Box::new(self.parse_expr()?);
                let end = self.expect_rparen_span()?;
                (Expr::MakeArray { elem_ty, len }, end)
            }
            Token::Ident(s) if s == "array-ref" => {
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                let index = Box::new(self.parse_expr()?);
                let end = self.expect_rparen_span()?;
                (Expr::ArrayRef { expr, index }, end)
            }
            Token::Ident(s) if s == "array-set!" => {
                // (array-set! arr index value)
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                let index = Box::new(self.parse_expr()?);
                let value = Box::new(self.parse_expr()?);
                let end = self.expect_rparen_span()?;
                (Expr::ArraySet { expr, index, value }, end)
            }
            // `string-ref`/`char-at` are NOT special-cased at parse time: the
            // parser cannot know whether a user `define` shadows the builtin, so
            // these names parse as ordinary `Expr::Call`s (head `Var("string-ref"
            // | "char-at")`). The typechecker and lowerer rewrite an *unshadowed*
            // call back into the builtin String-index behavior (yielding `char`,
            // lowering to the bounds-checked byte load), while a shadowing
            // user-defined function is left as a normal direct call (#677).
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
            Token::Ident(s) if s == "foreach" => {
                // (foreach ([i : i64 start end]) body)
                self.advance()?;
                self.expect(Token::LParen)?;
                self.expect(Token::LBracket)?;
                let index = self.expect_ident()?;
                self.expect(Token::Colon)?;
                let index_ty = self.parse_type()?;
                let start = Box::new(self.parse_expr()?);
                let end_expr = Box::new(self.parse_expr()?);
                self.expect(Token::RBracket)?;
                self.expect(Token::RParen)?;
                let body = Box::new(self.parse_expr()?);
                let end_span = self.expect_rparen_span()?;
                (
                    Expr::Foreach {
                        index,
                        index_ty,
                        start,
                        end: end_expr,
                        body,
                    },
                    end_span,
                )
            }
            Token::Ident(s) if s == "spmd-reduce" => {
                // (spmd-reduce op ([i : i64 start end]) init value)
                self.advance()?;
                // `op` is a fixed operator symbol, not an expression. Reject
                // anything outside the first supported set with a focused
                // diagnostic pointing at the operator token (SPEC.md §5.16).
                let op_span = self.span();
                let op_name = self.expect_ident()?;
                let op = ReduceOp::from_symbol(&op_name).ok_or_else(|| ParseError {
                    msg: format!(
                        "unsupported spmd-reduce operator `{}`; expected one of \
                         sum, min, max, all, any",
                        op_name
                    ),
                    span: op_span,
                })?;
                self.expect(Token::LParen)?;
                self.expect(Token::LBracket)?;
                let index = self.expect_ident()?;
                self.expect(Token::Colon)?;
                let index_ty = self.parse_type()?;
                let start_expr = Box::new(self.parse_expr()?);
                let end_expr = Box::new(self.parse_expr()?);
                self.expect(Token::RBracket)?;
                self.expect(Token::RParen)?;
                let init = Box::new(self.parse_expr()?);
                let value = Box::new(self.parse_expr()?);
                let end_span = self.expect_rparen_span()?;
                (
                    Expr::SpmdReduce {
                        op,
                        index,
                        index_ty,
                        start: start_expr,
                        end: end_expr,
                        init,
                        value,
                    },
                    end_span,
                )
            }
            Token::Ident(s) if s == "with-arena" => {
                // (with-arena <region-ident> <body-expr>...) — #548. The binder
                // names a region whose lifetime is the body; the body is a
                // non-empty expression sequence. Region typing/escape checking and
                // lowering are separate slices (#549 and later).
                self.advance()?;
                let region = match &self.current {
                    Token::Ident(name) => {
                        let name = name.clone();
                        self.advance()?;
                        name
                    }
                    Token::RParen => {
                        return Err(ParseError {
                            msg: "with-arena requires a region name before its body".into(),
                            span: self.span(),
                        });
                    }
                    other => {
                        return Err(ParseError {
                            msg: format!(
                                "with-arena region name must be an identifier, got {:?}",
                                other
                            ),
                            span: self.span(),
                        });
                    }
                };
                let mut body = Vec::new();
                while self.current != Token::RParen {
                    body.push(self.parse_expr()?);
                }
                if body.is_empty() {
                    return Err(ParseError {
                        msg: format!("with-arena '{}' requires a non-empty body", region),
                        span: self.span(),
                    });
                }
                let end = self.expect_rparen_span()?;
                (Expr::WithRegion { region, body }, end)
            }
            _ => {
                // Unary operator, binary operator, or function call. Unary is
                // tried first: `not`/`neg`/`bit-not` are distinct identifiers
                // from the binary `bit-and`/`bit-or`/`bit-xor` spellings, so
                // there is no collision.
                if let Some(op) = self.try_parse_unop() {
                    let expr = Box::new(self.parse_expr()?);
                    let end = self.expect_rparen_span()?;
                    (Expr::Unary { op, expr }, end)
                } else if let Some(op) = self.try_parse_binop() {
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

    /// Parse a `match` arm pattern. Recursive, so a variant's arguments may
    /// themselves be patterns:
    /// - `_`                     → `Wildcard`
    /// - a scalar (`0`/`true`/`#\a`) → `Literal`
    /// - a bare identifier       → `Binding(name)` (names/binds this position)
    /// - `Variant`               → nullary `Variant { args: [] }`
    /// - `(Variant sub ...)`     → a `Variant` whose `sub`s are nested patterns
    ///
    /// A bare identifier is a `Binding`, never a nullary variant, at this
    /// (top) level too — the typechecker resolves which identifiers are nullary
    /// variants vs. fresh bindings against the scrutinee's enum, so a leading
    /// bare-`Variant` arm (`[Red 0]`) and a binding sub-pattern (`(SSym op)`)
    /// share one syntactic form.
    fn parse_pattern(&mut self) -> Result<Pattern, ParseError> {
        match &self.current {
            Token::Ident(s) if s == "_" => {
                self.advance()?;
                Ok(Pattern::Wildcard)
            }
            Token::Int(n) => {
                let val = *n;
                self.advance()?;
                Ok(Pattern::Literal(Literal::Int(val)))
            }
            Token::Bool(b) => {
                let val = *b;
                self.advance()?;
                Ok(Pattern::Literal(Literal::Bool(val)))
            }
            Token::Char(c) => {
                let val = *c;
                self.advance()?;
                Ok(Pattern::Literal(Literal::Char(val)))
            }
            Token::String(s) => {
                let val = s.clone();
                self.advance()?;
                Ok(Pattern::Literal(Literal::String(val)))
            }
            Token::Ident(s) => {
                let name = s.clone();
                self.advance()?;
                Ok(Pattern::Binding(name))
            }
            Token::LParen => {
                self.advance()?;
                let name = self.expect_ident()?;
                let mut args = Vec::new();
                while self.current != Token::RParen {
                    args.push(self.parse_pattern()?);
                }
                self.advance()?; // consume RParen
                Ok(Pattern::Variant { name, args })
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

    /// Recognize a prefix unary operator at the head of a list:
    /// `not` (boolean), `neg` (numeric negation), `bit-not` (one's
    /// complement). Returns `None` (leaving the cursor untouched) for anything
    /// else, so the caller falls through to binary-op / call parsing.
    fn try_parse_unop(&mut self) -> Option<UnOp> {
        let op = match &self.current {
            Token::Ident(s) => match s.as_str() {
                "not" => Some(UnOp::Not),
                "neg" => Some(UnOp::Neg),
                "bit-not" => Some(UnOp::BitNot),
                _ => None,
            },
            _ => None,
        };
        if op.is_some() {
            let _ = self.advance();
        }
        op
    }
}

#[allow(dead_code)]
pub fn parse(input: &str) -> Result<Program, ParseError> {
    let mut parser = Parser::new(input)?;
    parser.parse()
}

pub fn parse_with_file_id(input: &str, file_id: u32) -> Result<Program, ParseError> {
    let mut parser = Parser::new_with_file_id(input, file_id)?;
    parser.parse()
}

#[allow(dead_code)] // Used by the REPL command added in follow-up issues.
pub fn parse_repl_item(input: &str) -> Result<ReplItem, ParseError> {
    let mut parser = Parser::new(input)?;
    parser.parse_repl_item()
}

#[allow(dead_code)] // Mirrors parse_with_file_id for future REPL diagnostics.
pub fn parse_repl_item_with_file_id(input: &str, file_id: u32) -> Result<ReplItem, ParseError> {
    let mut parser = Parser::new_with_file_id(input, file_id)?;
    parser.parse_repl_item()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed_function_body(src: &str) -> Expr {
        let prog = parse(src).unwrap();
        match prog.decls.into_iter().next().unwrap() {
            Decl::DefFn { body, .. } => body,
            other => panic!("expected DefFn, got {:?}", other),
        }
    }

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
    fn test_parse_import() {
        let prog = parse("(import \"a.tl\")").unwrap();
        assert_eq!(prog.decls.len(), 1);
        match &prog.decls[0] {
            Decl::Import(path) => assert_eq!(path, "a.tl"),
            other => panic!("expected Import, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_import_then_define() {
        let prog = parse("(import \"a.tl\")\n(define (b) : i64 (a))").unwrap();
        assert_eq!(prog.decls.len(), 2);
        assert!(matches!(&prog.decls[0], Decl::Import(p) if p == "a.tl"));
        assert!(matches!(&prog.decls[1], Decl::DefFn { name, .. } if name == "b"));
    }

    #[test]
    fn test_parse_import_requires_string() {
        // A bare identifier where the path string is expected is a parse error.
        assert!(parse("(import foo)").is_err());
    }

    #[test]
    fn test_parse_repl_item_decl() {
        let item = parse_repl_item("(define x : i64 42)").unwrap();
        match item {
            ReplItem::Decl(Decl::Def { name, ty, value }) => {
                assert_eq!(name, "x");
                assert_eq!(ty, Some(Type::I64));
                assert_eq!(value.unspan(), &Expr::Literal(Literal::Int(42)));
            }
            other => panic!("expected REPL decl, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_repl_item_expr() {
        let item = parse_repl_item("(+ 1 2)").unwrap();
        match item {
            ReplItem::Expr(expr) => match expr.unspan() {
                Expr::Binary { op, .. } => assert_eq!(*op, BinOp::Add),
                other => panic!("expected binary expression, got {:?}", other),
            },
            other => panic!("expected REPL expression, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_repl_item_bare_expr() {
        let item = parse_repl_item("42").unwrap();
        match item {
            ReplItem::Expr(expr) => {
                assert_eq!(expr.unspan(), &Expr::Literal(Literal::Int(42)));
            }
            other => panic!("expected REPL expression, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_repl_item_rejects_trailing_tokens() {
        let err = parse_repl_item("42 43").unwrap_err();
        assert!(
            err.msg.contains("unexpected trailing token"),
            "got: {}",
            err
        );
    }

    #[test]
    fn test_parse_repl_item_reports_malformed_expr() {
        let err = parse_repl_item("(+ 1)").unwrap_err();
        assert!(
            err.msg.contains("unexpected token in expression"),
            "got: {}",
            err
        );
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
    fn test_parse_flat_let_bindings() {
        let body =
            parsed_function_body("(define (main) : i64 (let [x : i64 1] [y : i64 (+ x 1)] y))");
        match body.unspan() {
            Expr::Let {
                bindings,
                body: let_body,
            } => {
                assert_eq!(bindings.len(), 2);
                assert_eq!(bindings[0].0, "x");
                assert_eq!(bindings[0].1, Some(Type::I64));
                assert_eq!(bindings[1].0, "y");
                assert_eq!(bindings[1].1, Some(Type::I64));
                assert_eq!(let_body.unspan(), &Expr::Var("y".into()));
            }
            other => panic!("expected Let, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_flat_let_untyped_binding() {
        let body = parsed_function_body("(define (main) : i64 (let [x 41] (+ x 1)))");
        match body.unspan() {
            Expr::Let { bindings, .. } => {
                assert_eq!(bindings.len(), 1);
                assert_eq!(bindings[0].0, "x");
                assert_eq!(bindings[0].1, None);
            }
            other => panic!("expected Let, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_legacy_parenthesized_let_bindings_temporarily() {
        let body = parsed_function_body("(define (main) : i64 (let ([x : i64 1]) x))");
        match body.unspan() {
            Expr::Let { bindings, .. } => {
                assert_eq!(bindings.len(), 1);
                assert_eq!(bindings[0].0, "x");
            }
            other => panic!("expected Let, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_let_rejects_empty_bindings() {
        let err = parse("(define (main) : i64 (let () 1))").unwrap_err();
        assert!(
            err.msg.contains("let requires at least one binding"),
            "got: {}",
            err
        );
    }

    #[test]
    fn test_parse_let_rejects_malformed_binding() {
        let err = parse("(define (main) : i64 (let [x : i64 1 2] x))").unwrap_err();
        assert!(err.msg.contains("expected RBracket"), "got: {}", err);
    }

    #[test]
    fn test_parse_let_rejects_missing_body() {
        let err = parse("(define (main) : i64 (let [x : i64 1]))").unwrap_err();
        assert!(err.msg.contains("unexpected token"), "got: {}", err);
    }

    #[test]
    fn test_parse_let_rejects_extra_body_form() {
        let err = parse("(define (main) : i64 (let [x : i64 1] x x))").unwrap_err();
        assert!(err.msg.contains("expected RParen"), "got: {}", err);
    }

    #[test]
    fn test_parse_comptime_function_param() {
        let prog = parse("(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))").unwrap();
        match &prog.decls[0] {
            Decl::DefFn {
                name,
                params,
                comptime_params,
                ..
            } => {
                assert_eq!(name, "scale");
                assert_eq!(params[0], ("n".into(), Type::I64));
                assert_eq!(params[1], ("x".into(), Type::I64));
                assert_eq!(comptime_params, &vec![0]);
            }
            other => panic!("expected DefFn, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_type_valued_comptime_param() {
        // `[comptime T : type]` parses with the `type` kind recorded as the
        // parameter annotation `Type::Var("type")` (a compile-time type kind,
        // not a runtime value type), and the index marked comptime.
        let prog =
            parse("(define (alloc [comptime T : type] [n : i64]) : (Array i64) (make-array T n))")
                .unwrap();
        match &prog.decls[0] {
            Decl::DefFn {
                name,
                params,
                comptime_params,
                ..
            } => {
                assert_eq!(name, "alloc");
                assert_eq!(params[0], ("T".into(), Type::Var("type".into())));
                assert_eq!(params[1], ("n".into(), Type::I64));
                assert_eq!(comptime_params, &vec![0]);
            }
            other => panic!("expected DefFn, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_comptime_lambda_param_rejected() {
        let err = parse("(define (main) : i64 ((lambda ([comptime n : i64]) n) 1))").unwrap_err();
        assert!(
            err.msg.contains("only supported on top-level function"),
            "got: {}",
            err
        );
    }

    #[test]
    fn test_parse_duplicate_function_param_rejected() {
        let err = parse("(define (bad [x : i64] [x : i64]) : i64 x)").unwrap_err();
        assert!(err.msg.contains("duplicate parameter name"), "got: {}", err);
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
    fn test_parse_cond_desugars_to_nested_if() {
        let prog = parse(
            "(define (f [x : i64]) : i64 \
               (cond [(= x 0) 1] [(= x 1) 2] [else 3]))",
        )
        .unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };

        match body {
            Expr::If {
                cond,
                then_branch,
                else_branch,
            } => {
                assert!(matches!(cond.unspan(), Expr::Binary { .. }));
                assert_eq!(then_branch.unspan(), &Expr::Literal(Literal::Int(1)));
                match else_branch.unspan() {
                    Expr::If {
                        cond,
                        then_branch,
                        else_branch,
                    } => {
                        assert!(matches!(cond.unspan(), Expr::Binary { .. }));
                        assert_eq!(then_branch.unspan(), &Expr::Literal(Literal::Int(2)));
                        assert_eq!(else_branch.unspan(), &Expr::Literal(Literal::Int(3)));
                    }
                    other => panic!("expected nested If, got {:?}", other),
                }
            }
            other => panic!("expected If, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_cond_requires_test_arm() {
        let err = parse("(define (f) : i64 (cond [else 3]))").unwrap_err();
        assert!(
            err.msg.contains("cond requires at least one test arm"),
            "got: {}",
            err
        );

        let err = parse("(define (f) : i64 (cond))").unwrap_err();
        assert!(
            err.msg.contains("cond requires at least one test arm"),
            "got: {}",
            err
        );
    }

    #[test]
    fn test_parse_cond_requires_final_else() {
        let err = parse("(define (f [x : i64]) : i64 (cond [(= x 0) 1]))").unwrap_err();
        assert!(
            err.msg.contains("cond requires final else arm"),
            "got: {}",
            err
        );
    }

    #[test]
    fn test_parse_cond_rejects_non_final_else() {
        let err = parse(
            "(define (f [x : i64]) : i64 \
               (cond [else 3] [(= x 0) 1]))",
        )
        .unwrap_err();
        assert!(
            err.msg.contains("cond else arm must be final"),
            "got: {}",
            err
        );
    }

    #[test]
    fn test_parse_comptime_reserved_form() {
        let prog = parse("(define (main) : i64 (comptime (+ 1 2)))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Comptime { expr } => {
                assert!(matches!(expr.unspan(), Expr::Binary { op: BinOp::Add, .. }));
            }
            other => panic!("expected Comptime, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_type_literal_expression() {
        let prog = parse("(define (main) : i64 (comptime (type (Array i64 4))))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Comptime { expr } => match expr.unspan() {
                Expr::TypeLiteral { ty } => {
                    assert_eq!(ty, &Type::Array(Box::new(Type::I64), 4));
                }
                other => panic!("expected TypeLiteral, got {:?}", other),
            },
            other => panic!("expected Comptime, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_type_literal_rejects_extra_type() {
        let err = parse("(define (main) : i64 (comptime (type i64 i32)))").unwrap_err();
        assert!(
            err.msg.contains("type expects exactly one type"),
            "got: {}",
            err
        );
    }

    #[test]
    fn test_parse_type_literal_rejects_missing_type() {
        let err = parse("(define (main) : i64 (comptime (type)))").unwrap_err();
        assert!(
            err.msg.contains("type expects exactly one type"),
            "got: {}",
            err
        );
    }

    #[test]
    fn test_parse_comptime_rejects_extra_expression() {
        let err = parse("(define (main) : i64 (comptime 1 2))").unwrap_err();
        assert!(
            err.msg.contains("comptime expects exactly one expression"),
            "got: {}",
            err
        );
        assert_eq!(err.span.start_col, 34, "error: {}", err);
    }

    #[test]
    fn test_parse_comptime_rejects_missing_expression() {
        let err = parse("(define (main) : i64 (comptime))").unwrap_err();
        assert!(
            err.msg.contains("comptime expects exactly one expression"),
            "got: {}",
            err
        );
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
                        args: vec![Pattern::Binding("r".into())]
                    }
                );
                assert_eq!(
                    arms[1].0,
                    Pattern::Variant {
                        name: "Square".into(),
                        args: vec![Pattern::Binding("w".into())]
                    }
                );
                assert_eq!(arms[2].0, Pattern::Wildcard);
            }
            other => panic!("expected Match, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_nested_variant_pattern() {
        // `(SCons (SSym op) rest)` — the first variant arg is itself a nested
        // variant pattern binding `op`; the second is a flat binding `rest`.
        let prog = parse(
            "(defenum Sexpr (SInt i64) (SSym String) (SNil) (SCons Sexpr Sexpr)) \
             (define (f [s : Sexpr]) : i64 \
               (match s [(SCons (SSym op) rest) 1] [_ 0]))",
        )
        .unwrap();
        let body = match &prog.decls[1] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Match { arms, .. } => {
                assert_eq!(
                    arms[0].0,
                    Pattern::Variant {
                        name: "SCons".into(),
                        args: vec![
                            Pattern::Variant {
                                name: "SSym".into(),
                                args: vec![Pattern::Binding("op".into())],
                            },
                            Pattern::Binding("rest".into()),
                        ],
                    }
                );
                assert_eq!(arms[1].0, Pattern::Wildcard);
            }
            other => panic!("expected Match, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_nested_wildcard_and_literal_in_variant() {
        // A variant arg may be `_` or a scalar literal.
        let prog = parse(
            "(defenum Sexpr (SInt i64) (SNil) (SCons Sexpr Sexpr)) \
             (define (f [s : Sexpr]) : i64 \
               (match s [(SCons (SInt 0) _) 1] [_ 0]))",
        )
        .unwrap();
        let body = match &prog.decls[1] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Match { arms, .. } => {
                assert_eq!(
                    arms[0].0,
                    Pattern::Variant {
                        name: "SCons".into(),
                        args: vec![
                            Pattern::Variant {
                                name: "SInt".into(),
                                args: vec![Pattern::Literal(Literal::Int(0))],
                            },
                            Pattern::Wildcard,
                        ],
                    }
                );
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
                // A bare nullary-variant arm parses as a `Binding`; the
                // typechecker resolves it to the `Red` variant against `Color`.
                assert_eq!(arms[0].0, Pattern::Binding("Red".into()));
            }
            other => panic!("expected Match, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_literal_patterns() {
        let prog = parse("(define (f [n : i64]) : i64 (match n [0 10] [1 20] [_ 0]))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Match { arms, .. } => {
                assert_eq!(arms.len(), 3);
                assert_eq!(arms[0].0, Pattern::Literal(Literal::Int(0)));
                assert_eq!(arms[1].0, Pattern::Literal(Literal::Int(1)));
                assert_eq!(arms[2].0, Pattern::Wildcard);
            }
            other => panic!("expected Match, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_string_literal_patterns() {
        let prog = parse(r#"(define (f [s : String]) : i64 (match s ["if" 10] ["let" 20] [_ 0]))"#)
            .unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Match { arms, .. } => {
                assert_eq!(arms.len(), 3);
                assert_eq!(arms[0].0, Pattern::Literal(Literal::String("if".into())));
                assert_eq!(arms[1].0, Pattern::Literal(Literal::String("let".into())));
                assert_eq!(arms[2].0, Pattern::Wildcard);
            }
            other => panic!("expected Match, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_nested_string_literal_pattern() {
        let prog =
            parse(r#"(define (f [t : Token]) : i64 (match t [(TIdent "if") 1] [_ 0]))"#).unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Match { arms, .. } => {
                assert_eq!(
                    arms[0].0,
                    Pattern::Variant {
                        name: "TIdent".into(),
                        args: vec![Pattern::Literal(Literal::String("if".into()))],
                    }
                );
            }
            other => panic!("expected Match, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_bool_and_char_literal_patterns() {
        let prog = parse(r"(define (f [b : bool]) : i64 (match b [true 1] [_ 0]))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Match { arms, .. } => {
                assert_eq!(arms[0].0, Pattern::Literal(Literal::Bool(true)));
            }
            other => panic!("expected Match, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_named_char_literal() {
        // A named char literal `#\newline'` parses to a Char literal carrying
        // its code point (10), proving the lexer's named-literal support flows
        // through the parser into the AST.
        let prog = parse(r"(define (f) : char #\newline')").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Literal(Literal::Char(c)) => {
                assert_eq!(*c, '\n');
                assert_eq!(*c as u32, 10);
            }
            other => panic!("expected Char literal, got {:?}", other),
        }
    }

    // ------------------------------------------------------------------
    // Structs / records — Issue #18
    // ------------------------------------------------------------------

    #[test]
    fn test_parse_defstruct() {
        let prog = parse("(defstruct Point (x i64) (y i64))").unwrap();
        assert_eq!(prog.decls.len(), 1);
        match &prog.decls[0] {
            Decl::DefStruct { name, fields } => {
                assert_eq!(name, "Point");
                assert_eq!(fields.len(), 2);
                assert_eq!(fields[0].name, "x");
                assert_eq!(fields[0].ty, Type::I64);
                assert_eq!(fields[1].name, "y");
                assert_eq!(fields[1].ty, Type::I64);
            }
            other => panic!("expected DefStruct, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_defstruct_mixed_field_types() {
        let prog = parse("(defstruct Mixed (a i64) (b bool) (c f64))").unwrap();
        match &prog.decls[0] {
            Decl::DefStruct { fields, .. } => {
                assert_eq!(fields[0].ty, Type::I64);
                assert_eq!(fields[1].ty, Type::Bool);
                assert_eq!(fields[2].ty, Type::F64);
            }
            other => panic!("expected DefStruct, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_defstruct_empty_is_error() {
        assert!(parse("(defstruct Empty)").is_err());
    }

    #[test]
    fn test_parse_comptime_decl_struct() {
        let prog = parse("(comptime-decl (defstruct Point (x i64) (y i64)))").unwrap();
        match &prog.decls[0] {
            Decl::ComptimeDecl { template, .. } => match template.as_ref() {
                Decl::DefStruct { name, fields } => {
                    assert_eq!(name, "Point");
                    assert_eq!(fields.len(), 2);
                }
                other => panic!("expected DefStruct template, got {:?}", other),
            },
            other => panic!("expected ComptimeDecl, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_comptime_decl_enum() {
        let prog = parse("(comptime-decl (defenum Maybe (Just i64) (Nothing)))").unwrap();
        match &prog.decls[0] {
            Decl::ComptimeDecl { template, .. } => match template.as_ref() {
                Decl::DefEnum { name, variants } => {
                    assert_eq!(name, "Maybe");
                    assert_eq!(variants.len(), 2);
                }
                other => panic!("expected DefEnum template, got {:?}", other),
            },
            other => panic!("expected ComptimeDecl, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_comptime_decl_rejects_non_type_payload() {
        // Only defstruct/defenum templates are allowed in this slice.
        assert!(parse("(comptime-decl (define x : i64 1))").is_err());
        assert!(parse("(comptime-decl (define (f) : i64 1))").is_err());
    }

    #[test]
    fn test_parse_comptime_decl_rejected_in_expression_position() {
        let err = parse("(define (main) : i64 (comptime-decl (defstruct P (x i64))))").unwrap_err();
        assert!(
            err.msg.contains("only valid as a top-level declaration"),
            "err: {}",
            err.msg
        );
    }

    #[test]
    fn test_parse_struct_get() {
        let prog = parse("(define (f [p : Point]) : i64 (struct-get p x))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::StructGet { field, .. } => assert_eq!(field, "x"),
            other => panic!("expected StructGet, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_struct_construction_is_call() {
        // `(Point 1 2)` parses as a call whose head names the struct; the
        // lowerer/typechecker recognise the struct name and build a value.
        let prog = parse("(define (f) : Point (Point 1 2))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Call { func, args } => {
                assert_eq!(func.unspan(), &Expr::Var("Point".into()));
                assert_eq!(args.len(), 2);
            }
            other => panic!("expected Call, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_not_is_unary() {
        // `(not b)` parses as a unary `Not`, not a call to a `not` function.
        let prog = parse("(define (f [b : bool]) : bool (not b))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Unary { op, expr } => {
                assert_eq!(*op, UnOp::Not);
                assert_eq!(expr.unspan(), &Expr::Var("b".into()));
            }
            other => panic!("expected Unary Not, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_neg_and_bit_not_are_unary() {
        // `neg` and `bit-not` share the unary parse path with `not`.
        let prog = parse("(define (f [n : i64]) : i64 (neg n))").unwrap();
        match prog.decls[0] {
            Decl::DefFn { ref body, .. } => match body.unspan() {
                Expr::Unary { op, .. } => assert_eq!(*op, UnOp::Neg),
                other => panic!("expected Unary Neg, got {:?}", other),
            },
            ref other => panic!("expected DefFn, got {:?}", other),
        }

        let prog = parse("(define (f [n : i64]) : i64 (bit-not n))").unwrap();
        match prog.decls[0] {
            Decl::DefFn { ref body, .. } => match body.unspan() {
                Expr::Unary { op, .. } => assert_eq!(*op, UnOp::BitNot),
                other => panic!("expected Unary BitNot, got {:?}", other),
            },
            ref other => panic!("expected DefFn, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_and_or_are_binary() {
        // `(and a b)` / `(or a b)` parse as strict binary logical operators.
        for (src, want) in [
            (
                "(define (f [a : bool] [b : bool]) : bool (and a b))",
                BinOp::And,
            ),
            (
                "(define (f [a : bool] [b : bool]) : bool (or a b))",
                BinOp::Or,
            ),
        ] {
            let prog = parse(src).unwrap();
            match prog.decls[0] {
                Decl::DefFn { ref body, .. } => match body.unspan() {
                    Expr::Binary { op, .. } => assert_eq!(*op, want),
                    other => panic!("expected Binary, got {:?}", other),
                },
                ref other => panic!("expected DefFn, got {:?}", other),
            }
        }
    }

    // ------------------------------------------------------------------
    // SPMD foreach — Issue #343
    // ------------------------------------------------------------------

    #[test]
    fn test_parse_foreach_basic() {
        let prog = parse(
            "(define (f [n : i64]) : unit \
               (foreach ([i : i64 0 n]) (print i)))",
        )
        .unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Foreach {
                index,
                index_ty,
                start,
                end,
                body: foreach_body,
            } => {
                assert_eq!(index, "i");
                assert_eq!(*index_ty, Type::I64);
                assert_eq!(start.unspan(), &Expr::Literal(Literal::Int(0)));
                assert_eq!(end.unspan(), &Expr::Var("n".into()));
                // The body is a call to print with arg i.
                match foreach_body.unspan() {
                    Expr::Call { func, args } => {
                        assert_eq!(func.unspan(), &Expr::Var("print".into()));
                        assert_eq!(args.len(), 1);
                        assert_eq!(args[0].unspan(), &Expr::Var("i".into()));
                    }
                    other => panic!("expected Call, got {:?}", other),
                }
            }
            other => panic!("expected Foreach, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_foreach_empty_range() {
        let prog = parse("(define (f) : unit (foreach ([i : i64 0 0]) unit))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        assert!(matches!(body, Expr::Foreach { .. }), "got {:?}", body);
    }

    #[test]
    fn test_parse_foreach_non_i64_index_type() {
        // `u32` is valid syntax; type-checker will decide whether it's accepted.
        let prog = parse("(define (f [n : u32]) : unit (foreach ([i : u32 0 n]) unit))").unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Foreach { index_ty, .. } => {
                assert_eq!(*index_ty, Type::U32);
            }
            other => panic!("expected Foreach, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_foreach_expressions_as_start_end() {
        // Start and end can be arbitrary expressions (type-checked later).
        let src = "(define (f [a : i64] [b : i64]) : unit \
                     (foreach ([i : i64 (+ a 1) (- b 1)]) (print i)))";
        let prog = parse(src).unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::Foreach { start, end, .. } => {
                assert!(matches!(start.unspan(), Expr::Binary { .. }));
                assert!(matches!(end.unspan(), Expr::Binary { .. }));
            }
            other => panic!("expected Foreach, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_foreach_malformed_missing_brackets_is_error() {
        // Missing the inner `([` — `(foreach i 0 n) body)` is wrong shape.
        assert!(parse("(define (f) : unit (foreach i 0 n unit))").is_err());
    }

    #[test]
    fn test_parse_foreach_malformed_missing_body_is_error() {
        // Missing body after range spec.
        assert!(parse("(define (f) : unit (foreach ([i : i64 0 1])))").is_err());
    }

    // ------------------------------------------------------------------
    // SPMD reduction — Issue #498
    // ------------------------------------------------------------------

    #[test]
    fn test_parse_spmd_reduce_basic() {
        let prog = parse(
            "(define (f [xs : (Array i64)] [n : i64]) : i64 \
               (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))",
        )
        .unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::SpmdReduce {
                op,
                index,
                index_ty,
                start,
                end,
                init,
                value,
            } => {
                assert_eq!(*op, ReduceOp::Sum);
                assert_eq!(index, "i");
                assert_eq!(*index_ty, Type::I64);
                assert_eq!(start.unspan(), &Expr::Literal(Literal::Int(0)));
                assert_eq!(end.unspan(), &Expr::Var("n".into()));
                assert_eq!(init.unspan(), &Expr::Literal(Literal::Int(0)));
                assert!(
                    matches!(value.unspan(), Expr::ArrayRef { .. }),
                    "got {:?}",
                    value
                );
            }
            other => panic!("expected SpmdReduce, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_spmd_reduce_all_operators() {
        for (sym, expected) in [
            ("sum", ReduceOp::Sum),
            ("min", ReduceOp::Min),
            ("max", ReduceOp::Max),
            ("all", ReduceOp::All),
            ("any", ReduceOp::Any),
        ] {
            let src = format!(
                "(define (f [n : i64]) : i64 \
                   (spmd-reduce {} ([i : i64 0 n]) 0 i))",
                sym
            );
            let prog = parse(&src).unwrap();
            let body = match &prog.decls[0] {
                Decl::DefFn { body, .. } => body.unspan(),
                other => panic!("expected DefFn, got {:?}", other),
            };
            match body {
                Expr::SpmdReduce { op, .. } => assert_eq!(*op, expected, "operator {}", sym),
                other => panic!("expected SpmdReduce for {}, got {:?}", sym, other),
            }
        }
    }

    #[test]
    fn test_parse_spmd_reduce_unknown_operator_is_error() {
        // `shuffle` is not a reduction operator: rejected at parse time with the
        // diagnostic pointing at the operator token (SPEC.md §5.16).
        let src = "(define (f [n : i64]) : i64 (spmd-reduce shuffle ([i : i64 0 n]) 0 i))";
        let err = parse(src).unwrap_err();
        assert!(
            err.msg
                .contains("unsupported spmd-reduce operator `shuffle`"),
            "got: {}",
            err.msg
        );
        let col = src.find("shuffle").unwrap() + 1;
        assert_eq!(err.span.start_line, 1);
        assert_eq!(err.span.start_col, col);
    }

    #[test]
    fn test_parse_spmd_reduce_missing_value_is_error() {
        // Only the seed is present; the per-lane value expression is missing.
        let src = "(define (f [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0))";
        assert!(parse(src).is_err());
    }

    #[test]
    fn test_parse_spmd_reduce_malformed_clause_is_error() {
        // Missing the inner `([ ... ])` range clause shape.
        let src = "(define (f [n : i64]) : i64 (spmd-reduce sum i 0 n 0 i))";
        assert!(parse(src).is_err());
    }

    // ------------------------------------------------------------------
    // with-arena scoped form — Issue #548
    // ------------------------------------------------------------------

    #[test]
    fn test_parse_with_region_basic() {
        let prog = parse(
            "(define (f) : i64 \
               (with-arena r (+ 1 2)))",
        )
        .unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::WithRegion { region, body } => {
                assert_eq!(region, "r");
                assert_eq!(body.len(), 1);
                assert!(
                    matches!(body[0].unspan(), Expr::Binary { .. }),
                    "got {:?}",
                    body[0]
                );
            }
            other => panic!("expected WithRegion, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_with_region_multi_expr_body() {
        let prog = parse(
            "(define (f) : i64 \
               (with-arena r (print 1) (print 2) 42))",
        )
        .unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::WithRegion { region, body } => {
                assert_eq!(region, "r");
                assert_eq!(body.len(), 3);
                // The last body expression is the result.
                assert_eq!(body[2].unspan(), &Expr::Literal(Literal::Int(42)));
            }
            other => panic!("expected WithRegion, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_with_region_nested() {
        let prog = parse(
            "(define (f) : i64 \
               (with-arena outer (with-arena inner 7)))",
        )
        .unwrap();
        let body = match &prog.decls[0] {
            Decl::DefFn { body, .. } => body.unspan(),
            other => panic!("expected DefFn, got {:?}", other),
        };
        match body {
            Expr::WithRegion { region, body } => {
                assert_eq!(region, "outer");
                assert_eq!(body.len(), 1);
                match body[0].unspan() {
                    Expr::WithRegion {
                        region: inner,
                        body: inner_body,
                    } => {
                        assert_eq!(inner, "inner");
                        assert_eq!(inner_body.len(), 1);
                    }
                    other => panic!("expected nested WithRegion, got {:?}", other),
                }
            }
            other => panic!("expected WithRegion, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_with_region_missing_binder_is_error() {
        let err = parse("(define (f) : i64 (with-arena))").unwrap_err();
        assert!(
            err.msg.contains("with-arena requires a region name"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_parse_with_region_non_identifier_binder_is_error() {
        let err = parse("(define (f) : i64 (with-arena 5 (+ 1 2)))").unwrap_err();
        assert!(
            err.msg
                .contains("with-arena region name must be an identifier"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_parse_with_region_empty_body_is_error() {
        let err = parse("(define (f) : i64 (with-arena r))").unwrap_err();
        assert!(
            err.msg.contains("requires a non-empty body"),
            "got: {}",
            err.msg
        );
    }
}
