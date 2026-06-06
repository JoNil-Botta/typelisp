;; ast_types.tl - Shared M1 compiler AST enums (#154).
(defenum BinOp
  (OpAdd)
  (OpSub)
  (OpMul)
  (OpLt)
  (OpEq)
  (OpLe)
  (OpGt)
  (OpGe)
  (OpNe)
  (OpAnd)
  (OpOr))

(defenum Expr
  (EInt i64)
  (EVar String)
  (EBin BinOp (Box Expr) (Box Expr))
  (ENot (Box Expr))
  (ELet String (Box Expr) (Box Expr))
  (EIf (Box Expr) (Box Expr) (Box Expr))
  (EWhile (Box Expr) (Box Expr))
  (ECall String (Box ExprList))
  (EStr String)
  (EPrint (Box Expr))
  (ESet String (Box Expr))
  (EBegin (Box ExprList)))

(defenum ExprList
  (ELNil)
  (ELCons Expr (Box ExprList)))

(defenum ResultExpr
  (OkExpr Expr)
  (ErrExpr String))

(defenum ResultExprList
  (OkExprList ExprList)
  (ErrExprList String))

(defenum StrList
  (SLNil)
  (SLCons String (Box StrList)))

(defenum ResultStrList
  (OkStrList StrList)
  (ErrStrList String))

(defenum Item
  (IDefFn String StrList Expr))

(defenum ResultItem
  (OkItem Item)
  (ErrItem String))

(defenum ItemList
  (ILNil)
  (ILCons Item (Box ItemList)))

(defenum ParsedProgram
  (PProgram ItemList Expr))

(defenum ResultParsedProgram
  (OkParsedProgram ParsedProgram)
  (ErrParsedProgram String))