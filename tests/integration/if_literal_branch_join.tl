;; if_literal_branch_join.tl - an `if` typed without an expected type joins a
;; literal branch with the other branch's type, as `match` joins arms (#8590).
;;
;; A comparison types its left operand without an expected type, as does an
;; unannotated `let`. An integer literal branch there used to keep its `i32`
;; default and fail "if branches must match" against an `i64` branch. Values
;; past the `i32` range check that both branches keep the full width.
(define (pick [comptime T : type] [x : T]) : T
  x)

(define (wide [x : i64]) : i64
  (* x 1000000000))

;; The literal branch first, the `i64` branch second, and the reverse.
(define (below [taken : bool] [n : i64] [limit : i64]) : bool
  (<
    (if taken
      0
      n)
    limit))

(define (below-reversed [taken : bool] [n : i64] [limit : i64]) : bool
  (<
    (if taken
      n
      0)
    limit))

;; A comptime-type call in the other branch, as reported.
(define (picked-equals [taken : bool] [want : i64]) : bool
  (=
    (if taken
      0
      (pick (type i64) (wide 5)))
    want))

;; `cond` expands to nested `if`s.
(define (cond-equals [first : bool] [second : bool] [want : i64]) : bool
  (= (cond [first 1] [second (wide 7)] [else 2]) want))

;; An unannotated `let` takes the joined type.
(define (unannotated [taken : bool] [n : i64]) : i64
  (let
    [v
      (if taken
        3
        n)]
    (+ v 1)))

;; A negative literal and one past the `i32` range keep their exact values in
;; the `i64` join.
(define (literal-values [taken : bool] [n : i64]) : bool
  (let
    [negative
      (if taken
        -1
        n)]
    [big
      (if taken
        4000000000
        n)]
    (and (= negative -1) (= big 4000000000))))

;; A narrow integer branch: the literal adopts `u8`.
(define (narrow [taken : bool] [b : u8]) : u8
  (let
    [v
      (if taken
        9
        b)]
    v))

(define (main) : i64
  (let
    [ok : bool
      (and
        (below true (wide 5) 1)
        (not (below false (wide 5) (wide 4)))
        (below false (wide 3) (wide 4))
        (below-reversed false (wide 5) 1)
        (not (below-reversed true (wide 5) (wide 4)))
        (picked-equals true 0)
        (picked-equals false 5000000000)
        (not (picked-equals false 5))
        (cond-equals true true 1)
        (cond-equals false true 7000000000)
        (cond-equals false false 2)
        (= (unannotated true (wide 6)) 4)
        (= (unannotated false (wide 6)) 6000000001)
        (literal-values true (wide 9))
        (not (literal-values false (wide 9)))
        (= (narrow true (cast 200 : u8)) (cast 9 : u8))
        (= (narrow false (cast 200 : u8)) (cast 200 : u8)))]
    (if ok
      42
      1)))