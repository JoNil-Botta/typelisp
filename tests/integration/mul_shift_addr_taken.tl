;; Refs #9420, section 3: pointer stores change local storage.
(import stdlib.io)

(define BIG : i64
  4294967296)

(define (main) : i64
  (let
    [m : i64 BIG]
    [pm : (MutPtr i64)
      (unsafe
        (ptr-addr-of m))]
    (unsafe
      (ptr-write! pm 3))
    ;; argc 1: 1 * 3 = 3
    (* (io.arg-count) m)))