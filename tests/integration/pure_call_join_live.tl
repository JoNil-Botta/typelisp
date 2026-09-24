;; Write-free runtime diamond: the final probe reuses the dominating result.
(import stdlib.io)
(import stdlib.string)

(define (probe [depth : i64] [key : u64]) : u64
  (let
    [index : i64 0]
    [result : u64 key]
    (begin
      (while (< index depth)
        (begin
          (set! result (+ (* result 1664525) 1013904223))
          (set! result (bit-xor result (shr result 13)))
          (set! index (+ index 1))))
      result)))

(define (exercise [rounds : i64] [depth : i64]) : u64
  (let
    [index : i64 0]
    [result : u64 0]
    (begin
      (while (< index rounds)
        (let
          [key : u64 (cast index : u64)]
          [before : u64 (probe depth key)]
          [middle : u64
            (if (= (bit-and key 1) 0)
              (probe (- depth 1) (+ key 11))
              (probe (- depth 2) (+ key 19)))]
          [after : u64 (probe depth key)]
          (begin
            (set! result (+ result before middle after))
            (set! index (+ index 1)))))
      result)))

(define (main) : i64
  (begin
    (io.println
      "{}"
      (exercise (string.>int (io.arg 1)) (string.>int (io.arg 2))))
    0))