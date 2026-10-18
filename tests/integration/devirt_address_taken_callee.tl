;; A function-valued local whose address is taken can be rewritten through
;; that address, so its one initializing value no longer names what a later
;; indirect call reaches. Devirtualizing the call to the initializer (and then
;; inlining it) calls the replaced function.
(define (devirt-replaced [_effect : unit]) : i64
  7)

(define (devirt-stored [_effect : unit]) : i64
  35)

(define (devirt-tail-call) : i64
  (let
    [fn : (-> unit i64) devirt-replaced]
    (unsafe
      (ptr-write! (ptr-addr-of fn) devirt-stored))
    (fn unit)))

(define (devirt-value-call) : i64
  (let
    [fn : (-> unit i64) devirt-replaced]
    (unsafe
      (ptr-write! (ptr-addr-of fn) devirt-stored))
    (+ (fn unit) 1)))

(define (main) : i64
  (if (and (= (devirt-tail-call) 35) (= (devirt-value-call) 36))
    42
    1))