;; Well-typed twin of the tests/safety wide-struct rejections (#7921): members
;; past index 1000 resolve through their own struct, also when another struct
;; follows it. Returns 42 only when every probed field holds its own value.
(import wide_aggregates)

(wide_aggregates.wide-struct Wide 2500)

(defstruct Next
  (a bool)
  (b bool)
  (c bool)
  (d bool))

(define (make) : Wide
  (wide_aggregates.wide-struct-value Wide 2500))

(define (main) : i64
  (let
    [w : Wide (make)]
    [n : Next (Next true false true false)]
    (if (and
      (= w.f0 1)
      (= w.f999 1000)
      (= w.f1000 1001)
      (= w.f1001 1002)
      (= w.f2499 2500)
      (= w.tail 0)
      n.a
      (not n.b))
      42
      1)))