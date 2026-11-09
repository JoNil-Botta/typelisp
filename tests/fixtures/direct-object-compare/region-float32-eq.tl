;; A region-tagged float compare/arithmetic has no direct-object support: this
;; program must leave the direct route for the assembly route (#9690).
(define (rd [p : (& p f32)]) : (in p f32)
  (deref p))

(define hi : f32
  (cast 0.0 : f32))
(define lo : f32
  (cast -0.0 : f32))
(define flag : bool
  false)

(define (op [a : (& a f32)] [b : (& b f32)]) : bool
  (= (rd a) (rd b)))

(define (main) : i64
  (set! flag (op (& hi) (& lo)))
  (+
    41
    (bit-and
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of flag) : (Ptr i64))))
      1)))