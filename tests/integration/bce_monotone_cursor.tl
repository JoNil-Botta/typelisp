;; bce_monotone_cursor.tl - bounds-check versioning of a MONOTONE CURSOR loop.
;;
;; The multi-block versioner reads a top-tested loop's counter off its latch
;; value. A scanner's cursor is not a canonical counter -- it advances on the
;; arm that keeps scanning and stalls on the arm that stops -- so its latch
;; value is a merge of `j` and `j + 1`. Such a cursor still lies in
;; [start, n) on every trip the loop test lets through, which is all the range
;; derivations read, so the versioner recovers it as an inexact counter
;; (#8261) and takes the loop when its clone removes every check.
;;
;;   arg 0  in-range scans: the guard holds and every scan runs its fast
;;          clone. The results must match the checked loop's. Exit 42.
;;   arg 1  ABORT TWIN. The same scanner handed `n` past the array's end, over
;;          bytes with no stop byte: the guard (`n <= length`) fails, the
;;          original loop runs, and its own check aborts at the end of the
;;          array -- the diagnostic the unversioned program prints.
;;   arg 2  A cursor that stalls while a second phi advances on every trip.
;;          That phi is NOT bounded by the cursor's range (the cursor may
;;          stall where it would have advanced), so its check must stay: the
;;          loop runs it past the array's end and aborts there. Deriving it
;;          from the cursor's range would let the fast clone read past the
;;          end instead.
;;
;; The manifest pins both stderr messages.
(import stdlib.io)
(import stdlib.string)

(define (make-bytes [n : i64] [stop-at : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            (array-ref out i)
            (if (= i stop-at)
              10
              (+ 32 (% i 90))))
          (set! i (+ i 1))))
      out)))

;; The scanner: advance while the byte is not 10, stop on it or at `n`.
(define (scan-to-newline
  [bytes : (& bytes (__tl_dyn-array i64))]
  [start : i64]
  [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (= (array-ref bytes j) 10)
            (set! keep false)
            (set! j (+ j 1)))
          (set! keep false)))
      j)))

;; The scanner's shape again, but the index is a SECOND phi, `seen`, which
;; advances on every trip while the cursor `j` advances on every third. `seen`
;; shares `j`'s seed and grows by one per trip -- exactly what places a phi in
;; an EXACT counter's range -- but a stalling cursor's range says nothing about
;; it, so its check must stay. Handed a short array, `seen` walks off the end
;; while `j` is still below `n`, and the loop aborts there.
(define (stall-and-count [bytes : (& bytes (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [j : i64 0]
    [seen : i64 0]
    [acc : i64 0]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (begin
            (set! acc (+ acc (array-ref bytes seen)))
            (set! seen (+ seen 1))
            (if (= (% seen 3) 0)
              (set! j (+ j 1))
              unit))
          (set! keep false)))
      acc)))

(define (in-range) : i64
  (let
    [bytes : (__tl_dyn-array i64) (make-bytes 64 40)]
    [a : i64 (scan-to-newline (& bytes) 0 64)]
    [b : i64 (scan-to-newline (& bytes) 41 64)]
    [c : i64 (scan-to-newline (& bytes) 10 30)]
    [d : i64 (scan-to-newline (& bytes) 64 64)]
    [e : i64 (scan-to-newline (& bytes) 50 20)]
    [short : (__tl_dyn-array i64) (make-bytes 30 (- 0 1))]
    [f : i64 (stall-and-count (& short) 10)]
    (if (and (= a 40) (= b 64) (= c 30) (= d 64) (= e 50) (> f 0))
      42
      1)))

(define (main) : i64
  (let
    [mode : i64 (string.>int (io.arg 1))]
    (cond
      [(= mode 1)
        (let
          [bytes : (__tl_dyn-array i64) (make-bytes 24 (- 0 1))]
          (scan-to-newline (& bytes) 3 27))]
      [(= mode 2)
        (let
          [bytes : (__tl_dyn-array i64) (make-bytes 24 (- 0 1))]
          (stall-and-count (& bytes) 24))]
      [else (in-range)])))