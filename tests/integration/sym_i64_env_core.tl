; sym_i64_env_core.tl - Immutable scoped String -> i64 symbol table.
; A focused child of #42: functional binding, head-first lookup, shadowing.

(defenum MaybeI64
  (NoneI64)
  (SomeI64 i64))

(defenum SymI64Env
  (SymI64Nil)
  (SymI64Bind String i64 SymI64Env))

(define (sym-i64-empty) : SymI64Env
  SymI64Nil)

(define (sym-i64-bind [e : SymI64Env] [k : String] [v : i64]) : SymI64Env
  (SymI64Bind k v e))

(define (sym-i64-lookup [e : SymI64Env] [k : String]) : MaybeI64
  (match e
    [(SymI64Nil) NoneI64]
    [(SymI64Bind kk vv rest)
      (if (string-eq kk k)
        (SomeI64 vv)
        (sym-i64-lookup rest k))]))

(define (sym-i64-contains [e : SymI64Env] [k : String]) : bool
  (match (sym-i64-lookup e k)
    [(SomeI64 _) true]
    [NoneI64 false]))
