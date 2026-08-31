;; I3-1 runtime coverage: sole-call absorption, and the two shapes it refuses.
;;
;; Three helpers, each with EXACTLY ONE call site, each carrying locals:
;;
;;   `sc-classify` is acyclic and its site is straight-line, so the sole-call
;;     tier absorbs it whole into `sc-driver` at opt2 -- five parameters (below
;;     the arity floor) and far past the cost model's block fuel, so no other
;;     band in the inliner can take it;
;;   `sc-scan-run` carries a `while`, so the tier refuses it and the call
;;     survives at every level: a loop-carrying body absorbed into a caller
;;     compounds the pressure the caller's own regions already carry;
;;   `sc-fold-step` is acyclic but its one site sits INSIDE `sc-driver`'s loop,
;;     so the tier refuses it too: an import there lands the whole body in a
;;     region the caller's allocator has already priced.
;;
;; The multiblock inliner runs only at opt2, so the opt0 and opt1 rows are the
;; parity reference: the answer must be identical at every level and every
;; index must stay in range. The sizes come from argv so no level can fold the
;; program away.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (sc-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define sc-data : i64vec.Vec
  (sc-zero-vec 1))

;; Acyclic, five parameters, one straight-line site: the sole-call tier's
;; headline admission. Nothing here is a loop, so every path is a forward edge.
(define (sc-classify
  [byte : i64]
  [prev : i64]
  [depth : i64]
  [total : i64]
  [salt : i64]) : i64
  (let
    [kind : i64 0]
    [weight : i64 1]
    [carry : i64 (+ salt depth)]
    (begin
      (cond
        [(< byte 32) (set! kind 1)]
        [(< byte 48) (set! kind 2)]
        [(< byte 58) (set! kind 3)]
        [(< byte 65) (set! kind 4)]
        [(< byte 91) (set! kind 5)]
        [(< byte 97) (set! kind 6)]
        [(< byte 123) (set! kind 7)]
        [else (set! kind 8)])
      (cond
        [(= kind 3) (set! weight 5)]
        [(= kind 5) (set! weight 3)]
        [(= kind 7) (set! weight 2)]
        [else (set! weight 1)])
      (if (= prev kind)
        (set! carry (+ carry 7))
        (set! carry (+ carry 11)))
      (if (> total 0)
        (set! carry (+ carry (% total 13)))
        (set! carry (+ carry 3)))
      (+ (* kind 100) (+ (* weight 10) (% carry 10))))))

;; A loop-carrying sole-call helper: refused, and its call survives at opt2.
(define (sc-scan-run
  [values-vec : (& values i64vec.Vec)]
  [start : i64]
  [limit : i64]) : i64
  (let
    [values (i64vec.slots values-vec)]
    [i : i64 start]
    [run : i64 0]
    (begin
      (while (< i limit)
        (begin
          (set! run (+ run (array-ref values i)))
          (set! i (+ i 1))))
      run)))

;; Acyclic, but called from inside the driver's loop: refused on the site. It
;; is padded to the same shape as `sc-classify` on purpose -- past the cost
;; model's block fuel and below the arity floor -- so the only tier that could
;; take it is the sole-call tier, and the only reason it does not is the site.
(define (sc-fold-step
  [acc : i64]
  [value : i64]
  [kind : i64]
  [salt : i64]
  [round : i64]) : i64
  (let
    [next : i64 acc]
    [mix : i64 (+ salt round)]
    (begin
      (cond
        [(= kind 0) (set! next (+ (* acc 31) value))]
        [(= kind 1) (set! next (+ (* acc 17) value))]
        [(= kind 2) (set! next (+ (* acc 13) (* value 3)))]
        [(= kind 3) (set! next (+ (* acc 7) (* value 5)))]
        [(= kind 4) (set! next (- (* acc 11) value))]
        [(= kind 5) (set! next (+ (* acc 23) (* value 2)))]
        [(= kind 6) (set! next (+ (* acc 29) (- value 1)))]
        [else (set! next (+ (* acc 3) (+ value 9)))])
      (cond
        [(< value 16) (set! mix (+ mix 1))]
        [(< value 32) (set! mix (+ mix 2))]
        [(< value 48) (set! mix (+ mix 3))]
        [(< value 64) (set! mix (+ mix 4))]
        [(< value 80) (set! mix (+ mix 5))]
        [(< value 96) (set! mix (+ mix 6))]
        [(< value 112) (set! mix (+ mix 7))]
        [else (set! mix (+ mix 8))])
      (if (= (% mix 3) 0)
        (set! next (+ next 101))
        (if (= (% mix 3) 1)
          (set! next (+ next 211))
          (set! next (+ next 307))))
      (% (+ next mix) 1000003))))

(define (sc-driver
  [data-vec : (&mut data i64vec.Vec)]
  [count : i64]
  [salt : i64]) : i64
  (let
    [values (i64vec.slots-mut data-vec)]
    [i : i64 0]
    [acc : i64 1]
    [prev : i64 0]
    [classified : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! (array-ref values i) (% (+ (* i 37) salt) 128))
          (set! i (+ i 1))))
      ;; The straight-line site: absorbed at opt2.
      (set! classified (sc-classify 65 prev 2 count salt))
      (set! i 0)
      (while (< i count)
        (let
          [v : i64 (array-ref values i)]
          (begin
            ;; The in-loop site: refused.
            (set! acc (sc-fold-step acc v (% v 8) salt i))
            (set! i (+ i 1)))))
      ;; The loop-carrying callee: refused.
      (+ classified (+ acc (sc-scan-run (& sc-data) 0 count))))))

(define (main) : i64
  (let
    [count : i64 (string.>int (io.arg 1))]
    [salt : i64 (string.>int (io.arg 2))]
    (begin
      (set! sc-data (sc-zero-vec count))
      (io.print-format "{}\n" (sc-driver (&mut sc-data) count salt))
      42)))