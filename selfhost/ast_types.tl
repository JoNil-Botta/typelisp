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
  (EBin BinOp Expr Expr)
  (ENot Expr)
  (ELet String Expr Expr)
  (EIf Expr Expr Expr)
  (EWhile Expr Expr)
  (ECall String ExprList)
  (EStr String)
  (EPrint Expr)
  (ESet String Expr)
  (EBegin ExprList))

(defenum ExprList
  (ELNil)
  (ELCons Expr ExprList))

(defenum ResultExpr
  (OkExpr Expr)
  (ErrExpr String))

(defenum ResultExprList
  (OkExprList ExprList)
  (ErrExprList String))

(defenum StrList
  (SLNil)
  (SLCons String StrList))

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
  (ILCons Item ItemList))

(defenum ParsedProgram
  (PProgram ItemList Expr))

(defenum ResultParsedProgram
  (OkParsedProgram ParsedProgram)
  (ErrParsedProgram String))
