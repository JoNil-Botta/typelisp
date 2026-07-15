(import stdlib.io)

; sym_i64_env.tl - Integration driver for the main-less selfhost sym_i64_env module.
; The integration manifest copies these src modules into local dependency names;
; import them by implicit module identity so copied source modules deduplicate.
(import sym_i64_env_core as env)
(import stdlib.option)
(import (option i64) as option_i64)

(define (check-equal [got : i64] [want : i64] [msg : String]) : unit
  (begin
    (if (= got want)
      (io.print-string "PASS: ")
      (begin
        (io.print-string "FAIL: ")
        (io.panic msg)))
    (io.print-string msg)
    (io.print-string "\n")))

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
      [e : env.SymI64Env (env.sym-i64-empty)]
      (check-false (env.sym-i64-contains-id e 1) "empty-miss"))
    ; Single bind hit
    (let
      [e : env.SymI64Env (env.sym-i64-bind-id (env.sym-i64-empty) 1 10)]
      (begin
        (check-true (env.sym-i64-contains-id e 1) "single-hit-contains")
        (check-equal
          (match (env.sym-i64-lookup-id e 1)
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          10
          "single-hit-value")))
    ; Miss after single bind
    (let
      [e : env.SymI64Env (env.sym-i64-bind-id (env.sym-i64-empty) 1 10)]
      (check-false (env.sym-i64-contains-id e 2) "single-miss"))
    ; Shadowing returns newest binding
    (let
      [e : env.SymI64Env
        (env.sym-i64-bind-id
          (env.sym-i64-bind-id (env.sym-i64-empty) 1 10)
          1
          20)]
      (check-equal
        (match (env.sym-i64-lookup-id e 1)
          [(option_i64.Some v) v]
          [(option_i64.None) 0])
        20
        "shadow-newest"))
    ; Saved outer env preserved after inner bind
    (let
      [outer : env.SymI64Env (env.sym-i64-bind-id (env.sym-i64-empty) 1 10)]
      [inner : env.SymI64Env (env.sym-i64-bind-id outer 2 20)]
      (begin
        (check-equal
          (match (env.sym-i64-lookup-id outer 1)
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          10
          "outer-preserved-a")
        (check-false (env.sym-i64-contains-id outer 2) "outer-no-b")
        (check-equal
          (match (env.sym-i64-lookup-id inner 1)
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          10
          "inner-sees-a")
        (check-equal
          (match (env.sym-i64-lookup-id inner 2)
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          20
          "inner-sees-b")))
    ; Computed key lookup
    (let
      [e : env.SymI64Env (env.sym-i64-bind-id (env.sym-i64-empty) 42 99)]
      [key : i64 (+ 40 2)]
      (check-true (env.sym-i64-contains-id e key) "computed-key-hit"))
    ; Distinct computed key lookup
    (let
      [e : env.SymI64Env (env.sym-i64-bind-id (env.sym-i64-empty) 77 77)]
      [key : i64 (- 100 23)]
      (check-true (env.sym-i64-contains-id e key) "second-computed-key-hit"))
    ; Multi-bind chain
    (let
      [e : env.SymI64Env
        (env.sym-i64-bind-id
          (env.sym-i64-bind-id
            (env.sym-i64-bind-id (env.sym-i64-empty) 1 1)
            2
            2)
          3
          3)]
      (begin
        (check-equal
          (match (env.sym-i64-lookup-id e 1)
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          1
          "chain-x")
        (check-equal
          (match (env.sym-i64-lookup-id e 2)
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          2
          "chain-y")
        (check-equal
          (match (env.sym-i64-lookup-id e 3)
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          3
          "chain-z")))
    ; ID API
    (let
      [id : i64 88]
      [e : env.SymI64Env (env.sym-i64-bind-id (env.sym-i64-empty) id 88)]
      (begin
        (check-true (env.sym-i64-contains-id e id) "id-key-contains")
        (check-equal
          (match (env.sym-i64-lookup-id e id)
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          88
          "id-key-value")))
    (io.print-string "All sym-i64-env tests passed.\n")
    0))