;; A region-tagged float compare/arithmetic has no direct-object support: this
;; program must leave the direct route for the assembly route (#9690).
(define (rd [p : (& p f64)]) : (in p f64)
  (deref p))

(define hi : f64
  3.0)
(define lo : f64
  2.0)
(define flag : bool
  false)

(define (op [a : (& a f64)] [b : (& b f64)]) : bool
  (> (* (rd a) (rd b)) 5.0))

(define (main) : i64
  (set! flag (op (& hi) (& lo)))
  (+
    41
    (bit-and
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of flag) : (Ptr i64))))
      1)))