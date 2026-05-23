; sym_i64_env.tl — Immutable scoped String -> i64 symbol table.
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

(define (check-equal [got : i64] [want : i64] [msg : String]) : unit
  (begin
    (if (= got want)
      (print-string "PASS: ")
      (begin
        (print-string "FAIL: ")
        (panic msg)))
    (print-string msg)
    (print-string "\n")))

(define (check-true [got : bool] [msg : String]) : unit
  (check-equal (if got 1 0) 1 msg))

(define (check-false [got : bool] [msg : String]) : unit
  (check-equal (if got 1 0) 0 msg))

(define (main) : i64
  (begin
    ; Empty env miss
    (let ([e : SymI64Env (sym-i64-empty)])
      (check-false (sym-i64-contains e "x") "empty-miss"))

    ; Single bind hit
    (let ([e : SymI64Env (sym-i64-bind (sym-i64-empty) "a" 10)])
      (begin
        (check-true (sym-i64-contains e "a") "single-hit-contains")
        (check-equal (match (sym-i64-lookup e "a")
                       [(SomeI64 v) v]
                       [(NoneI64) 0])
                     10
                     "single-hit-value")))

    ; Miss after single bind
    (let ([e : SymI64Env (sym-i64-bind (sym-i64-empty) "a" 10)])
      (check-false (sym-i64-contains e "b") "single-miss"))

    ; Shadowing returns newest binding
    (let ([e : SymI64Env (sym-i64-bind (sym-i64-bind (sym-i64-empty) "a" 10) "a" 20)])
      (check-equal (match (sym-i64-lookup e "a")
                     [(SomeI64 v) v]
                     [(NoneI64) 0])
                   20
                   "shadow-newest"))

    ; Saved outer env preserved after inner bind
    (let ([outer : SymI64Env (sym-i64-bind (sym-i64-empty) "a" 10)]
          [inner : SymI64Env (sym-i64-bind outer "b" 20)])
      (begin
        (check-equal (match (sym-i64-lookup outer "a")
                       [(SomeI64 v) v]
                       [(NoneI64) 0])
                     10
                     "outer-preserved-a")
        (check-false (sym-i64-contains outer "b") "outer-no-b")
        (check-equal (match (sym-i64-lookup inner "a")
                       [(SomeI64 v) v]
                       [(NoneI64) 0])
                     10
                     "inner-sees-a")
        (check-equal (match (sym-i64-lookup inner "b")
                       [(SomeI64 v) v]
                       [(NoneI64) 0])
                     20
                     "inner-sees-b")))

    ; Substring-built key lookup
    (let ([e : SymI64Env (sym-i64-bind (sym-i64-empty) "hello" 99)])
      (let ([key : String (substring "hello world" 0 5)])
        (check-true (sym-i64-contains e key) "substring-key-hit")))

    ; String-append-built key lookup
    (let ([e : SymI64Env (sym-i64-bind (sym-i64-empty) "foobar" 77)])
      (let ([key : String (string-append "foo" "bar")])
        (check-true (sym-i64-contains e key) "append-key-hit")))

    ; Multi-bind chain
    (let ([e : SymI64Env (sym-i64-bind
                           (sym-i64-bind
                             (sym-i64-bind (sym-i64-empty) "x" 1)
                             "y" 2)
                           "z" 3)])
      (begin
        (check-equal (match (sym-i64-lookup e "x") [(SomeI64 v) v] [(NoneI64) 0]) 1 "chain-x")
        (check-equal (match (sym-i64-lookup e "y") [(SomeI64 v) v] [(NoneI64) 0]) 2 "chain-y")
        (check-equal (match (sym-i64-lookup e "z") [(SomeI64 v) v] [(NoneI64) 0]) 3 "chain-z")))

    (print-string "All sym-i64-env tests passed.\n")
    0))
