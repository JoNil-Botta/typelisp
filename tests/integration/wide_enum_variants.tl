;; Well-typed twin of the tests/safety wide-enum rejection (#7921): variants
;; past index 1000 construct and match through their own enum, also when
;; another enum follows it. Returns 42 only when every probe matches.
(import wide_aggregates)

(wide_aggregates.wide-enum Big 2500)

(defenum Small
  (A bool)
  (B bool))

(define (payload [value : Big]) : i64
  (match value
    [(Big.V1001 n) n]
    [(Big.V2499 n) (+ n 1000)]
    [(Big.V0 n) (+ n 2000)]
    [_ -1]))

(define (main) : i64
  (let
    [small : Small (Small.B true)]
    (if (and
      (= (payload (Big.V1001 7)) 7)
      (= (payload (Big.V2499 9)) 1009)
      (= (payload (Big.V0 3)) 2003)
      (= (payload (Big.V1000 5)) -1)
      (match small
        [(Small.B flag) flag]
        [(Small.A _) false]))
      42
      1)))