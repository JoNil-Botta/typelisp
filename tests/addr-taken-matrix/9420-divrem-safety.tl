;; #9420 case 2: `divrem_safety` kept the `d != 0` fact across a store of 0 through
;; `&d`, so the checked division abort (expected exit 135) became SIGFPE at opt2.
(import stdlib.io)

(define (main) : i64
  (let
    [d : i64 (io.arg-count)]
    [pd : (MutPtr i64)
      (unsafe
        (ptr-addr-of d))]
    (if (!= d 0)
      (begin
        (unsafe
          (ptr-write! pd 0))
        (/ 10 d))
      7)))