;; tl_ast_types.tl - Shared M1 compiler AST enums (#154).

(defenum BinOp
  (OpAdd)
  (OpSub)
  (OpMul))

(defenum Expr
  (EInt i64)
  (EVar String)
  (EBin BinOp Expr Expr)
  (ECall String ExprList))

(defenum ExprList
  (ELNil)
  (ELCons Expr ExprList))

(defenum StrList
  (SLNil)
  (SLCons String StrList))

(defenum Item
  (IDefFn String StrList Expr))
