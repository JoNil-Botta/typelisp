(import stdlib.io)
(import stdlib.string)

; sym_i64_env.tl - Integration driver for the main-less selfhost sym_i64_env module.
; Retained for #2454 path-import compatibility: the integration manifest copies
; these src modules into local dependency names before compiling this fixture.
(import "sym_i64_env_core.tl")
(import "compiler_intern.tl")
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
      [e : SymI64Env (sym-i64-empty)]
      (check-false (sym-i64-contains e "x") "empty-miss"))
    ; Single bind hit
    (let
      [e : SymI64Env (sym-i64-bind (sym-i64-empty) "a" 10)]
      (begin
        (check-true (sym-i64-contains e "a") "single-hit-contains")
        (check-equal
          (match (sym-i64-lookup e "a")
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
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
          [(option_i64.Some v) v]
          [(option_i64.None) 0])
        20
        "shadow-newest"))
    ; Saved outer env preserved after inner bind
    (let
      [outer : SymI64Env (sym-i64-bind (sym-i64-empty) "a" 10)]
      [inner : SymI64Env (sym-i64-bind outer "b" 20)]
      (begin
        (check-equal
          (match (sym-i64-lookup outer "a")
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          10
          "outer-preserved-a")
        (check-false (sym-i64-contains outer "b") "outer-no-b")
        (check-equal
          (match (sym-i64-lookup inner "a")
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          10
          "inner-sees-a")
        (check-equal
          (match (sym-i64-lookup inner "b")
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          20
          "inner-sees-b")))
    ; Substring-built key lookup
    (let
      [e : SymI64Env (sym-i64-bind (sym-i64-empty) "hello" 99)]
      [key : String (string.substring "hello world" 0 5)]
      (check-true (sym-i64-contains e key) "substring-key-hit"))
    ; String-append-built key lookup
    (let
      [e : SymI64Env (sym-i64-bind (sym-i64-empty) "foobar" 77)]
      [key : String (string.append "foo" "bar")]
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
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          1
          "chain-x")
        (check-equal
          (match (sym-i64-lookup e "y")
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          2
          "chain-y")
        (check-equal
          (match (sym-i64-lookup e "z")
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          3
          "chain-z")))
    ; Intern-id API
    (let
      [id : i64 (intern "id-key")]
      [e : SymI64Env (sym-i64-bind-id (sym-i64-empty) id 88)]
      (begin
        (check-true (sym-i64-contains-id e id) "id-key-contains")
        (check-true (sym-i64-contains e "id-key") "id-key-string-contains")
        (check-equal
          (match (sym-i64-lookup-id e id)
            [(option_i64.Some v) v]
            [(option_i64.None) 0])
          88
          "id-key-value")))
    (io.print-string "All sym-i64-env tests passed.\n")
    0))