; Direct self-recursive tail calls reuse the caller's frame (#560/#559), so deep
; tail recursion runs in O(1) stack instead of overflowing. `swapdown` also
; checks that the tail call stages all argument values before overwriting the
; parameter slots, so a parameter swap (`b a`) is not corrupted.

(define (countdown [n : i64] [acc : i64]) : i64
  (if (= n 0)
      acc
      (countdown (- n 1) acc)))

(define (swapdown [a : i64] [b : i64] [n : i64]) : i64
  (if (= n 0)
      a
      (swapdown b a (- n 1))))

(define (main) : i64
  (if (= (countdown 100000 42) 42)
      (if (= (swapdown 1 2 100001) 2)
          42
          1)
      2))
