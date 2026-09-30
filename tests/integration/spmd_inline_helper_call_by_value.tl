;; An inlined SPMD helper evaluates its arguments like an ordinary call (#7541):
;; each exactly once, left to right, before the body, however often the body
;; reads the parameter. `observe` counts its evaluations per lane, and `order`
;; records which argument ran first, so one evaluation is told apart from
;; merely equal results. Exits 42, or the number of the first failed check.
(define (observe
  [counts : (&mut counts (__tl_dyn-array i64))]
  [i : i64]
  [value : i64]) : i64
  (begin
    (set! (array-ref counts i) (+ (array-ref counts i) 1))
    value))

;; Records `tag` in lane `i`'s slot the first time any argument of that lane
;; runs, so the slot names the argument evaluated first. Two copies, because
;; sibling calls to one helper in a body are refused today (#8368).
(define (order-a [first : (&mut first (__tl_dyn-array i64))] [i : i64]) : i64
  (begin
    (if (= (array-ref first i) 0)
      (set! (array-ref first i) 1)
      unit)
    1))

(define (order-b [first : (&mut first (__tl_dyn-array i64))] [i : i64]) : i64
  (begin
    (if (= (array-ref first i) 0)
      (set! (array-ref first i) 2)
      unit)
    2))

(define (twice [value : i64]) : i64
  (+ value value))

(define (ignore [_value : i64]) : i64
  7)

(define (second-minus-first [a : i64] [b : i64]) : i64
  (- b a))

;; Exactly at the inline node limit (12 nodes): inlined, reading its parameter
;; three times.
(define (thrice-at-limit [x : i64]) : i64
  (+ (+ (+ x x) (+ x 1)) (neg (+ 2 3))))

;; One node over the limit: kept as an ordinary call.
(define (thrice-over-limit [x : i64]) : i64
  (+ (+ (+ x x) (+ x 1)) (neg (neg (+ 2 3)))))

(define (run-twice
  [counts : (&mut counts (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (twice (observe counts i (+ i 1))))))

(define (run-ignore
  [counts : (&mut counts (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (ignore (observe counts i i)))))

(define (run-reversed
  [first : (&mut first (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (second-minus-first (order-a first i) (order-b first i)))))

(define (run-nested
  [counts : (&mut counts (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (twice (twice (observe counts i i))))))

;; The caller's `value` shares the helper parameter's spelling.
(define (run-same-spelling
  [counts : (&mut counts (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [value : i64 (+ i 10)]
      (set! (array-ref out i) (twice (observe counts i value))))))

(define (run-at-limit
  [counts : (&mut counts (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (thrice-at-limit (observe counts i i)))))

(define (run-over-limit
  [counts : (&mut counts (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (thrice-over-limit (observe counts i i)))))

;; Reading a variable is effect-free, but its value must be captured before a
;; later argument changes it. Also require the later argument's write to occur.
(define (run-variable-snapshot
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (+ i 1)]
      [result : i64
        (second-minus-first
          x
          (begin
            (set! x 99)
            0))]
      (begin
        (set! (array-ref out i) result)
        (if (= x 99)
          unit
          (set! (array-ref out i) 1000))))))

(define (all-equal [xs : (& xs (__tl_dyn-array i64))] [n : i64] [want : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (= (array-ref xs i) want)
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (fresh [n : i64]) : (__tl_dyn-array i64)
  (__tl_make-array i64 n))

(define (main) : i64
  (let
    [n : i64 7]
    [out : (__tl_dyn-array i64) (fresh n)]
    [twice-counts : (__tl_dyn-array i64) (fresh n)]
    [ignore-counts : (__tl_dyn-array i64) (fresh n)]
    [first : (__tl_dyn-array i64) (fresh n)]
    [nested-counts : (__tl_dyn-array i64) (fresh n)]
    [spelling-counts : (__tl_dyn-array i64) (fresh n)]
    [at-counts : (__tl_dyn-array i64) (fresh n)]
    [over-counts : (__tl_dyn-array i64) (fresh n)]
    (begin
      (run-variable-snapshot (&mut out) n)
      (if (or (!= (array-ref out 0) -1) (!= (array-ref out 6) -7))
        (return 14)
        unit)
      (run-twice (&mut twice-counts) (&mut out) n)
      (if (not (all-equal (& twice-counts) n 1))
        1
        (if (not (= (array-ref out 6) 14))
          2
          (begin
            (run-ignore (&mut ignore-counts) (&mut out) n)
            (if (not (all-equal (& ignore-counts) n 1))
              3
              (begin
                (run-reversed (&mut first) (&mut out) n)
                (if (not (all-equal (& first) n 1))
                  4
                  (if (not (= (array-ref out 3) 1))
                    5
                    (begin
                      (run-nested (&mut nested-counts) (&mut out) n)
                      (if (not (all-equal (& nested-counts) n 1))
                        6
                        (if (not (= (array-ref out 5) 20))
                          7
                          (begin
                            (run-same-spelling
                              (&mut spelling-counts)
                              (&mut out)
                              n)
                            (if (not (all-equal (& spelling-counts) n 1))
                              8
                              (if (not (= (array-ref out 2) 24))
                                9
                                (begin
                                  (run-at-limit (&mut at-counts) (&mut out) n)
                                  (if (not (all-equal (& at-counts) n 1))
                                    10
                                    (if (not (= (array-ref out 4) 8))
                                      11
                                      (begin
                                        (run-over-limit
                                          (&mut over-counts)
                                          (&mut out)
                                          n)
                                        (if (not
                                          (all-equal (& over-counts) n 1))
                                          12
                                          (if (not (= (array-ref out 4) 18))
                                            13
                                            42))))))))))))))))))))))