(import stdlib.array)
(import stdlib.io)

;; #4720: keep the shifted loop bound in a real outlined function. Opt2 rotates
;; the first loop into `0 < word-count`; a scratch collision with a register
;; homed word-count used to turn that entry test into a self-compare and skip
;; all ten iterations on Win64.
(define (array-zero-count [buf : (MutPtr u8)] [byte-count : i64]) : i64
  (let
    [word-count : i64 (shr byte-count 3)]
    [tail-start : i64 (* word-count 8)]
    [slots : (MutPtr u64)
      (unsafe
        (ptr-cast buf : (MutPtr u64)))]
    [w : i64 0]
    [i : i64 tail-start]
    (begin
      (while (< w word-count)
        (begin
          (unsafe
            (ptr-write! (ptr-offset slots w) (cast 0 : u64)))
          (set! w (+ w 1))))
      (while (< i byte-count)
        (begin
          (unsafe
            (ptr-write! (ptr-offset buf i) (cast 0 : u8)))
          (set! i (+ i 1))))
      w)))

;; Taking the function value prevents the opt2 inliner from absorbing the
;; helper into main and changing the register-allocation shape under test.
(define (keep-array-zero
  [f : (-> (MutPtr u8) i64 i64)]
  [buf : (MutPtr u8)]
  [byte-count : i64]) : i64
  (f buf byte-count))

(define (main) : i64
  (let
    [items : (Array u8) (array.make-array u8 80)]
    [buf : (MutPtr u8)
      (unsafe
        (array-data items))]
    [count : i64
      (if (> (io.arg-count) 100)
        (keep-array-zero array-zero-count buf 80)
        (array-zero-count buf 80))]
    (if (= count 10)
      42
      1)))