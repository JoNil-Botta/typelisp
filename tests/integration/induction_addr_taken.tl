;; Refs #9420, section 6: pointer stores change local storage.
(import stdlib.io)

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [x : i64 (+ 40 n)]
    [px : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i (+ n 3))
      (set! acc (+ acc (+ x (* i 3))))
      (unsafe
        (ptr-write! px (+ i 100)))
      (set! i (+ i 1)))
    ;; n=1: x=41; acc = 41 + 103 + 107 + 111 = 362 -> 362-320 = 42
    (- acc 320)))