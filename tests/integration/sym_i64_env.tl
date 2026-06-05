(import "stdlib/io.tl")

; sym_i64_env.tl - Integration driver for the main-less selfhost sym_i64_env module.
(import "sym_i64_env_core.tl")

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
  (check-equal
    (if got
      1
      0)
    1
    msg))

(define (check-false [got : bool] [msg : String]) : unit
  (check-equal
    (if got
      1
      0)
    0
    msg))

(define (main) : i64
  (begin
    ; Empty env miss
    (let
      [e : SymI64Env (sym-i64-empty)]
      (check-false (sym-i64-contains e "x") "empty-miss"))
    ; Single bind hit
    (let
      [e : SymI64Env (sym-i64-bind (sym-i64-empty) "a" 10)]
      (begin
        (check-true (sym-i64-contains e "a") "single-hit-contains")
        (check-equal
          (match (sym-i64-lookup e "a")
            [(SomeI64 v) v]
            [(NoneI64) 0])
          10
          "single-hit-value")))
    ; Miss after single bind
    (let
      [e : SymI64Env (sym-i64-bind (sym-i64-empty) "a" 10)]
      (check-false (sym-i64-contains e "b") "single-miss"))
    ; Shadowing returns newest binding
    (let
      [e : SymI64Env
        (sym-i64-bind (sym-i64-bind (sym-i64-empty) "a" 10) "a" 20)]
      (check-equal
        (match (sym-i64-lookup e "a")
          [(SomeI64 v) v]
          [(NoneI64) 0])
        20
        "shadow-newest"))
    ; Saved outer env preserved after inner bind
    (let
      [outer : SymI64Env (sym-i64-bind (sym-i64-empty) "a" 10)]
      [inner : SymI64Env (sym-i64-bind outer "b" 20)]
      (begin
        (check-equal
          (match (sym-i64-lookup outer "a")
            [(SomeI64 v) v]
            [(NoneI64) 0])
          10
          "outer-preserved-a")
        (check-false (sym-i64-contains outer "b") "outer-no-b")
        (check-equal
          (match (sym-i64-lookup inner "a")
            [(SomeI64 v) v]
            [(NoneI64) 0])
          10
          "inner-sees-a")
        (check-equal
          (match (sym-i64-lookup inner "b")
            [(SomeI64 v) v]
            [(NoneI64) 0])
          20
          "inner-sees-b")))
    ; Substring-built key lookup
    (let
      [e : SymI64Env (sym-i64-bind (sym-i64-empty) "hello" 99)]
      [key : String (substring "hello world" 0 5)]
      (check-true (sym-i64-contains e key) "substring-key-hit"))
    ; String-append-built key lookup
    (let
      [e : SymI64Env (sym-i64-bind (sym-i64-empty) "foobar" 77)]
      [key : String (string-append "foo" "bar")]
      (check-true (sym-i64-contains e key) "append-key-hit"))
    ; Multi-bind chain
    (let
      [e : SymI64Env
        (sym-i64-bind
          (sym-i64-bind (sym-i64-bind (sym-i64-empty) "x" 1) "y" 2)
          "z"
          3)]
      (begin
        (check-equal
          (match (sym-i64-lookup e "x")
            [(SomeI64 v) v]
            [(NoneI64) 0])
          1
          "chain-x")
        (check-equal
          (match (sym-i64-lookup e "y")
            [(SomeI64 v) v]
            [(NoneI64) 0])
          2
          "chain-y")
        (check-equal
          (match (sym-i64-lookup e "z")
            [(SomeI64 v) v]
            [(NoneI64) 0])
          3
          "chain-z")))
    (print-string "All sym-i64-env tests passed.\n")
    0))