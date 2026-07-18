(import stdlib.io)

;; Win64 FPO forcing case: eight values stay live across the recursive probe
;; call in the loop. The seven pre-FPO Win64 nonvolatile homes
;; (%r12-%r15/%rbx/%rsi/%rdi) are all occupied, so the eighth value must use
;; %rbp. The backend shape test checks that churn8 is frame-pointer-free while
;; preserving %rbp with SEH push/pop unwind metadata.
(define (probe8 [x : i64]) : i64
  (if (<= x 0)
    0
    (+ 1 (probe8 (- x 1)))))

(define (churn8 [v : i64] [rounds : i64]) : i64
  (let
    [a : i64 1]
    [b : i64 2]
    [c : i64 3]
    [d : i64 4]
    [e : i64 5]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i 100)
        (begin
          (set! acc (+ acc (probe8 i)))
          (set! acc (+ acc (+ a i)))
          (set! acc (+ acc (* 2 a)))
          (set! a (+ a 1))
          (set! acc (+ acc (+ b i)))
          (set! acc (+ acc (* 2 b)))
          (set! b (+ b 1))
          (set! acc (+ acc (+ c i)))
          (set! acc (+ acc (* 2 c)))
          (set! c (+ c 1))
          (set! acc (+ acc (+ d i)))
          (set! acc (+ acc (* 2 d)))
          (set! d (+ d 1))
          (set! acc (+ acc (+ e i)))
          (set! acc (+ acc (* 2 e)))
          (set! e (+ e 1))
          (set! acc (+ acc (* v i)))
          (set! acc (+ acc (* v a)))
          (set! acc (+ acc (* v e)))
          (set! i (+ i 1))))
      (let
        [r : i64 (+ acc (+ a (+ b (+ c (+ d (+ e v))))))]
        (if (> rounds 1)
          (+ r (churn8 v (- rounds 1)))
          r)))))

(define (main) : i64
  (let
    [v : i64 (+ 9 (io.arg-count))]
    [r : i64 (churn8 v 1)]
    (if (= r 265475)
      42
      1)))