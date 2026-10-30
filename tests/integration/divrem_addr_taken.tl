;; Refs #9420, section 2: pointer stores change local storage.
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