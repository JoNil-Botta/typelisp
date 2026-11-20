;; #9420 case 3: `mul_shift` turned a multiply by the local's constant initializer
;; into a shift past the store of 3. Expected exit 3 (opt2 exited 0).
(import stdlib.io)

(define big : i64
  4294967296)

(define (main) : i64
  (let
    [m : i64 big]
    [pm : (MutPtr i64)
      (unsafe
        (ptr-addr-of m))]
    (unsafe
      (ptr-write! pm 3))
    (* (io.arg-count) m)))