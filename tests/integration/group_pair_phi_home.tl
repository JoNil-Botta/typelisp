(import stdlib.io)

;; A loop-carried 16-byte enum must be eligible for register-pair homing. The
;; mutable `state` lowers to a group Phi at the loop header; each incoming call
;; result is copied into it through the pair-aware parallel-move solver. The
;; checksum catches a swapped pair half, a prematurely clobbered source half,
;; or a stale stack reload.
(defenum MaybeVal
  (MNone)
  (MSome i64))

(define (mk [i : i64] [flag : i64]) : MaybeVal
  ;; The unreachable recursion keeps the call in `probe` visible to regalloc.
  (if (> flag 1000000)
    (mk i (- flag 1000000))
    (if (= (% i 3) 0)
      (MNone)
      (MSome (+ (* i 5) 1)))))

(define (probe [n : i64]) : i64
  (if (> n 1000000)
    (probe (- n 1000000))
    (let
      [state : MaybeVal (mk 1 1)]
      [i : i64 0]
      [acc : i64 0]
      (begin
        (while (< i n)
          (begin
            (match state
              [(MSome value) (set! acc (+ acc value))]
              [(MNone) (set! acc (+ acc 1))])
            (set! state (mk (+ i 1) i))
            (set! i (+ i 1))))
        acc))))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 9)]
    [result : i64 (probe n)]
    ;; io.arg-count includes the executable: n = 10 has Some payloads
    ;; 6, 6, 11, 21, 26, 36, 41 and three None tags.
    (if (= result 150)
      42
      1)))