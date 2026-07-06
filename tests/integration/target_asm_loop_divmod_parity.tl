;; Backend target-assembly parity corpus for loop-carried constant div/mod.
;;
;; The parity script extracts `loop-divmod-parity` across Linux and Windows
;; targets. Keep the helper no-arg and call-free in the loop body so the
;; normalized body compares backend optimizer/codegen choices rather than ABI
;; parameter or call-shadow layout.
(import stdlib.io)

(define target-asm-loop-divmod-seed : i64
  0)

(define (loop-divmod-parity) : i64
  (let
    [n : i64 target-asm-loop-divmod-seed]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (% i 1000000007)))
          (set! acc (+ acc (/ i 10)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [fn : (-> i64) loop-divmod-parity]
    (begin
      (set! target-asm-loop-divmod-seed (+ 99 (io.arg-count)))
      (if (= (fn) 5400)
        42
        1))))