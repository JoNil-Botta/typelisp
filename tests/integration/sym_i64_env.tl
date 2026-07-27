(import stdlib.io)
(import stdlib.arena)

; sym_i64_env.tl - Integration driver for the main-less selfhost sym_i64_env module.
; The integration manifest copies these src modules into local dependency names;
; import them by implicit module identity so copied source modules deduplicate.
(import sym_i64_env_core as env)
(import stdlib.option)
(import (option.option i64) as option_i64)

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

(define (bind-range [initial : env.SymI64Env] [count : i64]) : env.SymI64Env
  (let
    [out : env.SymI64Env initial]
    [key : i64 0]
    (begin
      (while (< key count)
        (begin
          (set! out (env.sym-i64-bind-id out key (* key 3)))
          (set! key (+ key 1))))
      out)))

(define (count-via-view [initial : env.SymI64Env]) : i64
  (let
    [cursor : env.SymI64Env initial]
    [count : i64 0]
    (begin
      (while true
        (match (env.sym-i64-view cursor)
          [(env.SymI64ViewNil) (return count)]
          [(env.SymI64ViewBind _ _ rest)
            (begin
              (set! cursor rest)
              (set! count (+ count 1)))]))
      count)))

(define (main) : i64
  (begin
    ; Empty env miss
    (let
      [e : env.SymI64Env (env.sym-i64-empty)]
      (begin
        (check-false (env.sym-i64-contains-id e 1) "empty-miss")
        (check-equal (env.sym-i64-lookup-id-or e 1 91) 91 "empty-lookup-or")))
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
      (begin
        (check-false (env.sym-i64-contains-id e 2) "single-miss")
        (check-equal
          (env.sym-i64-lookup-id-or e 2 92)
          92
          "bound-miss-lookup-or")))
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
    ; Sibling forks remain isolated even though they share append-only storage.
    (let
      [parent : env.SymI64Env (env.sym-i64-bind-id (env.sym-i64-empty) 1 10)]
      [left : env.SymI64Env (env.sym-i64-bind-id parent 2 20)]
      [right : env.SymI64Env (env.sym-i64-bind-id parent 3 30)]
      (begin
        (check-false (env.sym-i64-contains-id parent 2) "fork-parent-no-left")
        (check-false (env.sym-i64-contains-id parent 3) "fork-parent-no-right")
        (check-true (env.sym-i64-contains-id left 2) "fork-left-sees-left")
        (check-false (env.sym-i64-contains-id left 3) "fork-left-no-right")
        (check-true (env.sym-i64-contains-id right 3) "fork-right-sees-right")
        (check-false (env.sym-i64-contains-id right 2) "fork-right-no-left")))
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
    ; Exercise growth beyond the largest observed self-host member set (26,863).
    (let
      [e : env.SymI64Env (bind-range (env.sym-i64-empty) 32768)]
      (begin
        (check-equal (env.sym-i64-lookup-id-or e 32767 -1) 98301 "deep-newest")
        (check-equal (env.sym-i64-lookup-id-or e 16384 -1) 49152 "deep-middle")
        (check-equal (env.sym-i64-lookup-id-or e 0 -1) 0 "deep-oldest")
        (check-equal (env.sym-i64-lookup-id-or e 40000 -1) -1 "deep-miss")
        (check-equal (count-via-view e) 32768 "deep-view-count")))
    ; Growth while a scratch arena is active must retain the store owner.
    (let
      [home : arena.Arena (arena.current)]
      [owner : arena.Arena (arena.make)]
      [scratch : arena.Arena (arena.make)]
      [parent : env.SymI64Env (env.sym-i64-empty)]
      [child : env.SymI64Env (env.sym-i64-empty)]
      (begin
        (unsafe
          (arena.set! owner))
        (set! parent (bind-range (env.sym-i64-empty) 8))
        (unsafe
          (arena.set! scratch))
        (set! child (env.sym-i64-bind-id parent 8 24))
        (unsafe
          (begin
            (arena.set! home)
            (arena.destroy scratch)))
        (check-equal
          (env.sym-i64-lookup-id-or parent 0 -1)
          0
          "arena-growth-parent")
        (check-equal
          (env.sym-i64-lookup-id-or child 8 -1)
          24
          "arena-growth-child")
        (unsafe
          (arena.destroy owner))))
    (io.print-string "All sym-i64-env tests passed.\n")
    0))