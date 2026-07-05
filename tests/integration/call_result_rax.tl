(import stdlib.io)

;; FORCING TEST for M-C part 2: call-result %rax preference. `spin` calls the
;; (recursive, so never inlined) `bump` in a loop; the result `r` feeds pure
;; arithmetic and dies before the loop's next call, so it spans no kind-0
;; clobber point and %rax is a legal home. Under the new contract the greedy
;; biases r's coalesce root toward %rax (free-only), turning the backend's
;; call-result store `movq %rax, <home>` into an elided self-move.
;; The runtime check guards reconstruction; target/call-result-rax-gate.sh
;; asserts the asm shape (no `movq %rax, %rN` directly after the loop call).
(define (bump [x : i64]) : i64
  (if (<= x 0)
    1
    (+ 1 (bump (- x 1)))))

(define (spin [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (let
            [r : i64 (bump i)]
            (set! acc (+ acc (* r 3))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 3)]
    [r : i64 (spin n)]
    ;; n = 4 (no args): bump(i) = i+1 for i >= 0, so r = 3*(1+2+3+4) = 30.
    (if (= r 30)
      42
      1)))