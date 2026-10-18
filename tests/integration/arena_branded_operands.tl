(import stdlib.arena)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.test)

(defstruct Holder
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (count [_owner : (arena.Arena r)]) : i64
  2)

(define (holder-count [_holder : (Holder r)]) : i64
  2)

(define (holder-answer [_holder : (Holder r)]) : i64
  42)

(define (sum [left : i64] [right : i64]) : i64
  (+ left right))

(define (scoped-count [_owner : (& a (arena.Arena r))] [_text : (in r String)]) : i64
  2)

(define (operand-case [kind : i64]) : i64
  (let
    [owner (arena.make)]
    (match kind
      [0 (+ 40 (count owner))]
      [1 (+ (count owner) 40)]
      [2 (- 44 (count owner))]
      [3
        (if (= (count owner) 2)
          42
          1)]
      [4
        (let
          [value : i64 (count owner)]
          (+ 40 value))]
      [5 (holder-answer (Holder owner))]
      [6 (sum 40 (count owner))]
      [7
        (let
          [value (+ 40 (count owner))]
          value)]
      [8
        (if (> (count owner) 1)
          42
          1)]
      [9
        (let
          [alias owner]
          (+ 40 (count alias)))]
      [10
        (let
          [holder (Holder owner)]
          (+ 40 (holder-count holder)))]
      [12
        (in-arena
          owner
          (let
            [text (string.append "inside" "-scope")]
            (+ 40 (scoped-count (& owner) text))))]
      [13
        (let
          [value (count owner)]
          (+ 40 value))]
      [_
        (holder-answer
          (let
            [holder (Holder owner)]
            holder))])))

(define (main) : i64
  (for [kind (iterator.range 0 14)]
    (test.assert-true
      (= (operand-case kind) 42)
      "operand position preserves arena brands"))
  42)