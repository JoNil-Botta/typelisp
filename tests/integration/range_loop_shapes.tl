;; #8555. Two ways a loop over `iterator.range` reaches the optimizer, and the
;; -O2 shape each must keep (tests/codegen/asm-shape.cases, range-protocol-inline
;; and range-fields-unroll).
;;
;; `protocol-sum` is the iterator protocol written out: `into-next` returns the
;; two-word `IntoNext` register group, which the multiblock inliner now admits,
;; and the match on the inlined result reads a join of `pack`s that the group
;; split takes apart. No call is left in the loop and the `IntoIter` state lives
;; in registers, its two `bool` lanes included.
;;
;; `fields-sum` builds its range and reads the fields back, the way the prelude
;; `for` macro's range path does: the `inclusive` lane of the inlined `range`'s
;; result becomes a register SCCP folds, the loop it leaves behind collapses
;; back into one block, and the result is versioned and unrolled like a
;; hand-written counting `while`. `fields-sum-inclusive` is the same loop over
;; `range-inclusive`, where the flag folds the other way.
;;
;; The inclusive calls run the other arm of every folded flag at run time. `n`
;; arrives on the command line so nothing folds the trip counts away; a `bump`
;; of 1, 2 or 3 makes the protocol loop, the field loop or the advance-first
;; loop read one past the array, and each run must abort with the located
;; message of that loop's own `array-ref`.
(import stdlib.io)
(import stdlib.iterator)
(import stdlib.string)

(define (protocol-sum [xs : (& xs (Array i64 16))] [items : iterator.I64Range]) : i64
  (let
    [iter : iterator.IntoIter (iterator.into-iterator items)]
    [total : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (match (iterator.into-next (&mut iter))
          [(iterator.Item index) (set! total (+ total (array-ref xs index)))]
          [(iterator.Done) (set! done true)]))
      total)))

(define (fields-sum [xs : (& xs (Array i64 16))] [lo : i64] [hi : i64]) : i64
  (let
    [items : iterator.I64Range (iterator.range lo hi)]
    [total : i64 0]
    [index : i64 items.start]
    [end : i64 items.end]
    [inclusive : bool items.inclusive]
    [live : bool
      (if inclusive
        (<= index end)
        true)]
    (begin
      (while (if inclusive
        live
        (< index end))
        (begin
          (set! total (+ total (array-ref xs index)))
          (if inclusive
            (if (= index end)
              (set! live false)
              (set! index (+ index 1)))
            (set! index (+ index 1)))))
      total)))

(define (fields-sum-inclusive
  [xs : (& xs (Array i64 16))]
  [lo : i64]
  [hi : i64]) : i64
  (let
    [items : iterator.I64Range (iterator.range-inclusive lo hi)]
    [total : i64 0]
    [index : i64 items.start]
    [end : i64 items.end]
    [inclusive : bool items.inclusive]
    [live : bool
      (if inclusive
        (<= index end)
        true)]
    (begin
      (while (if inclusive
        live
        (< index end))
        (begin
          (set! total (+ total (array-ref xs index)))
          (if inclusive
            (if (= index end)
              (set! live false)
              (set! index (+ index 1)))
            (set! index (+ index 1)))))
      total)))

;; The prelude `for` macro's order: the item is bound and the index advanced
;; before the body, so the folded flag leaves an empty block between a header
;; and a latch that holds the body.
(define (advance-first-sum [xs : (& xs (Array i64 16))] [lo : i64] [hi : i64]) : i64
  (let
    [items : iterator.I64Range (iterator.range lo hi)]
    [total : i64 0]
    [index : i64 items.start]
    [end : i64 items.end]
    [inclusive : bool items.inclusive]
    [live : bool
      (if inclusive
        (<= index end)
        true)]
    (begin
      (while (if inclusive
        live
        (< index end))
        (let
          [item : i64 index]
          (begin
            (if inclusive
              (if (= index end)
                (set! live false)
                (set! index (+ index 1)))
              (set! index (+ index 1)))
            (set! total (+ total (array-ref xs item))))))
      total)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    [xs : (Array i64 16) (array 3 1 4 1 5 9 2 6 5 3 5 8 9 7 9 3)]
    [protocol : i64
      (protocol-sum
        (& xs)
        (iterator.range
          0
          (if (= bump 1)
            (+ n 1)
            n)))]
    [protocol-inclusive : i64
      (protocol-sum (& xs) (iterator.range-inclusive 2 (- n 1)))]
    [fields : i64
      (fields-sum
        (& xs)
        1
        (if (= bump 2)
          (+ n 1)
          n))]
    [fields-inclusive : i64 (fields-sum-inclusive (& xs) 0 (- n 2))]
    [advance-first : i64
      (advance-first-sum
        (& xs)
        2
        (if (= bump 3)
          (+ n 1)
          n))]
    (begin
      (io.print-format
        "{} {} {} {} {}\n"
        protocol
        protocol-inclusive
        fields
        fields-inclusive
        advance-first)
      42)))