; sym_i64_env module - Immutable scoped String -> i64 symbol table.
; A focused child of #42: functional binding, head-first lookup, shadowing.
(defenum MaybeI64
  (NoneI64)
  (SomeI64 i64))

(defenum SymI64Env
  (SymI64Nil)
  (SymI64Bind String i64 i64 i64 (Box SymI64Env)))

(define (sym-i64-empty) : SymI64Env
  SymI64Nil)

(define (sym-i64-first-code [k : String] [len : i64]) : i64
  (if (> len 0)
    (cast (string-ref k 0) : i64)
    -1))

(define (sym-i64-bind [e : SymI64Env] [k : String] [v : i64]) : SymI64Env
  (let
    [len : i64 (string-length k)]
    (SymI64Bind k v len (sym-i64-first-code k len) (box e))))

(define (sym-i64-lookup [e : SymI64Env] [k : String]) : MaybeI64
  (let
    [cursor : SymI64Env e]
    [len : i64 (string-length k)]
    [first-code : i64 (sym-i64-first-code k len)]
    [found : bool false]
    [out : MaybeI64 NoneI64]
    (begin
      (while (not found)
        (match cursor
          [(SymI64Nil) (return NoneI64)]
          [(SymI64Bind kk vv kk-len kk-first-code rest)
            (if (if (= kk-len len)
              (if (= kk-first-code first-code)
                (string-eq kk k)
                false)
              false)
              (begin
                (set! out (SomeI64 vv))
                (set! found true))
              (set! cursor (box-get rest)))]))
      out)))

(define (sym-i64-contains [e : SymI64Env] [k : String]) : bool
  (match (sym-i64-lookup e k)
    [(SomeI64 _) true]
    [NoneI64 false]))
