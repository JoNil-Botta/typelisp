use crate::ast::*;
use crate::lexer::{Lexer, Token};
use crate::types::Type;
use std::fmt;

#[derive(Debug, Clone)]
pub struct ParseError {
    pub msg: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "parse error: {}", self.msg)
    }
}

pub struct Parser<'a> {
    lexer: Lexer<'a>,
    current: Token,
}

impl<'a> Parser<'a> {
    pub fn new(input: &'a str) -> Result<Self, ParseError> {
        let mut lexer = Lexer::new(input);
        let current = lexer
            .next_token()
            .map_err(|e| ParseError { msg: e.to_string() })?;
        Ok(Parser { lexer, current })
    }

    fn advance(&mut self) -> Result<(), ParseError> {
        self.current = self
            .lexer
            .next_token()
            .map_err(|e| ParseError { msg: e.to_string() })?;
        Ok(())
    }

    fn expect(&mut self, tok: Token) -> Result<(), ParseError> {
        if std::mem::discriminant(&self.current) == std::mem::discriminant(&tok) {
            self.advance()?;
            Ok(())
        } else {
            Err(ParseError {
                msg: format!("expected {:?}, got {:?}", tok, self.current),
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
            _ => Err(ParseError {
                msg: format!("expected define or extern, got {:?}", self.current),
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

    fn parse_type(&mut self) -> Result<Type, ParseError> {
        match &self.current {
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
                    "unit" => Type::Unit,
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
                                });
                            }
                        };
                        self.advance()?;
                        self.expect(Token::RParen)?;
                        Ok(Type::Array(Box::new(ty), size))
                    }
                    _ => Err(ParseError {
                        msg: format!("expected type constructor, got {:?}", self.current),
                    }),
                }
            }
            _ => Err(ParseError {
                msg: format!("expected type, got {:?}", self.current),
            }),
        }
    }

    fn parse_expr(&mut self) -> Result<Expr, ParseError> {
        match &self.current {
            Token::Int(n) => {
                let val = *n;
                self.advance()?;
                Ok(Expr::Literal(Literal::Int(val)))
            }
            Token::Float(n) => {
                let val = *n;
                self.advance()?;
                Ok(Expr::Literal(Literal::Float(val)))
            }
            Token::Bool(b) => {
                let val = *b;
                self.advance()?;
                Ok(Expr::Literal(Literal::Bool(val)))
            }
            Token::Char(c) => {
                let val = *c;
                self.advance()?;
                Ok(Expr::Literal(Literal::Char(val)))
            }
            Token::String(s) => {
                let val = s.clone();
                self.advance()?;
                Ok(Expr::Literal(Literal::String(val)))
            }
            Token::Unit => {
                self.advance()?;
                Ok(Expr::Literal(Literal::Unit))
            }
            Token::Ident(s) => {
                let name = s.clone();
                self.advance()?;
                Ok(Expr::Var(name))
            }
            Token::LParen => self.parse_list_expr(),
            _ => Err(ParseError {
                msg: format!("unexpected token in expression: {:?}", self.current),
            }),
        }
    }

    fn parse_list_expr(&mut self) -> Result<Expr, ParseError> {
        self.expect(Token::LParen)?;

        match &self.current {
            Token::If => {
                self.advance()?;
                let cond = Box::new(self.parse_expr()?);
                let then_branch = Box::new(self.parse_expr()?);
                let else_branch = Box::new(self.parse_expr()?);
                self.expect(Token::RParen)?;
                Ok(Expr::If {
                    cond,
                    then_branch,
                    else_branch,
                })
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
                self.expect(Token::RParen)?;
                Ok(Expr::Let { bindings, body })
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
                self.expect(Token::RParen)?;
                Ok(Expr::Lambda { params, ret, body })
            }
            Token::While => {
                self.advance()?;
                let cond = Box::new(self.parse_expr()?);
                let body = Box::new(self.parse_expr()?);
                self.expect(Token::RParen)?;
                Ok(Expr::While { cond, body })
            }
            Token::Begin => {
                self.advance()?;
                let mut exprs = Vec::new();
                while self.current != Token::RParen {
                    exprs.push(self.parse_expr()?);
                }
                self.advance()?;
                Ok(Expr::Begin(exprs))
            }
            Token::Set => {
                self.advance()?;
                let name = self.expect_ident()?;
                let value = Box::new(self.parse_expr()?);
                self.expect(Token::RParen)?;
                Ok(Expr::Set(name, value))
            }
            Token::Ann => {
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                self.expect(Token::Colon)?;
                let ty = self.parse_type()?;
                self.expect(Token::RParen)?;
                Ok(Expr::Ann { expr, ty })
            }
            Token::Ident(s) if s == "cast" => {
                // (cast expr : ty)
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                self.expect(Token::Colon)?;
                let ty = self.parse_type()?;
                self.expect(Token::RParen)?;
                Ok(Expr::Cast { expr, ty })
            }
            Token::Ident(s) if s == "tuple" => {
                self.advance()?;
                let mut elems = Vec::new();
                while self.current != Token::RParen {
                    elems.push(self.parse_expr()?);
                }
                self.advance()?;
                Ok(Expr::Tuple(elems))
            }
            Token::Ident(s) if s == "tuple-ref" => {
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                let index = match &self.current {
                    Token::Int(n) => *n as usize,
                    _ => {
                        return Err(ParseError {
                            msg: "tuple-ref index must be integer".into(),
                        });
                    }
                };
                self.advance()?;
                self.expect(Token::RParen)?;
                Ok(Expr::TupleRef { expr, index })
            }
            Token::Ident(s) if s == "array" => {
                self.advance()?;
                let mut elems = Vec::new();
                while self.current != Token::RParen {
                    elems.push(self.parse_expr()?);
                }
                self.advance()?;
                Ok(Expr::Array(elems))
            }
            Token::Ident(s) if s == "array-ref" => {
                self.advance()?;
                let expr = Box::new(self.parse_expr()?);
                let index = Box::new(self.parse_expr()?);
                self.expect(Token::RParen)?;
                Ok(Expr::ArrayRef { expr, index })
            }
            _ => {
                // Function call or binary operator
                let op = self.try_parse_binop();
                if let Some(op) = op {
                    let lhs = Box::new(self.parse_expr()?);
                    let rhs = Box::new(self.parse_expr()?);
                    self.expect(Token::RParen)?;
                    Ok(Expr::Binary { op, lhs, rhs })
                } else {
                    // Function call
                    let func = Box::new(self.parse_expr()?);
                    let mut args = Vec::new();
                    while self.current != Token::RParen {
                        args.push(self.parse_expr()?);
                    }
                    self.advance()?;
                    Ok(Expr::Call { func, args })
                }
            }
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
                assert_eq!(*value, Expr::Literal(Literal::Int(42)));
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
}
