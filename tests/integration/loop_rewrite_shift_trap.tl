;; loop_rewrite_shift_trap.tl - a dynamic shift trap survives loop rewrites (#8451).
;;
;; Each loop discards a `shl` whose count, `i * 7`, first leaves its valid range
;; at i = 10. The opt0 program raises `shift count out of range` there. A rewrite
;; that skips that iteration's body or runs it once must not lose the trap:
;;
;;   mode 0  flag_exit: the clear at i = N redirects to the loop exit, past the
;;           shift that follows it in the same iteration;
;;   mode 1  fill_call: the constant fill becomes one runtime fill that runs the
;;           body once, with the first iteration's count;
;;   mode 2  copy_call: the same for an element copy.
;;
;; Argument 2 is N: the clearing index for mode 0, the last index otherwise.
;; N = 10 traps on that iteration; N = 9 stays in range and returns 42.
(import stdlib.io)
(import stdlib.string)

(define (flag-exit-probe [clear-at : i64]) : i64
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (and (< i 16) ok)
        (begin
          (if (= i clear-at)
            (set! ok false)
            unit)
          (shl 1 (* i 7))
          (set! i (+ i 1))))
      0)))

(define (fill-probe [marks : (&mut marks (__tl_dyn-array i64))] [count : i64]) : i64
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! (array-ref marks i) 7)
          (shl 1 (* i 7))
          (set! i (+ i 1))))
      0)))

(define (copy-probe
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [count : i64]) : i64
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! (array-ref dst i) (array-ref src i))
          (shl 1 (* i 7))
          (set! i (+ i 1))))
      0)))

(define (main) : i64
  (let
    [mode : i64 (string.>int (io.arg 1))]
    [n : i64 (string.>int (io.arg 2))]
    [marks : (__tl_dyn-array i64) (__tl_make-array i64 32)]
    [src : (__tl_dyn-array i64) (__tl_make-array i64 32)]
    (begin
      (cond
        [(= mode 0) (flag-exit-probe n)]
        [(= mode 1) (fill-probe (&mut marks) (+ n 1))]
        [else (copy-probe (&mut marks) (& src) (+ n 1))])
      42)))