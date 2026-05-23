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
  (OpNe))

(defenum Expr
  (EInt i64)
  (EVar String)
  (EBin BinOp Expr Expr)
  (ELet String Expr Expr)
  (EIf Expr Expr Expr)
  (ECall String ExprList)
  (EStr String)
  (EPrint Expr))

(defenum ExprList
  (ELNil)
  (ELCons Expr ExprList))

(defenum StrList
  (SLNil)
  (SLCons String StrList))

(defenum Item
  (IDefFn String StrList Expr))

(defenum ItemList
  (ILNil)
  (ILCons Item ItemList))
