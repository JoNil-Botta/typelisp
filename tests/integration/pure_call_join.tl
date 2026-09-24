(import stdlib.io)
(import stdlib.string)

(define cell : u64
  7)

(define (mix [seed : u64] [salt : u64]) : u64
  (let
    [index : i64 0]
    [value : u64 (+ seed salt)]
    (begin
      (while (< index 37)
        (begin
          (set! value (+ (* value 1664525) 1013904223))
          (set! value (bit-xor value (shr value 13)))
          (set! index (+ index 1))))
      value)))

(define (read-cell [seed : u64]) : u64
  (mix seed cell))

(define (write-cell [value : u64]) : u64
  (begin
    (set! cell value)
    value))

(define (check-mode [seed : u64] [mode : i64]) : bool
  (begin
    (set! cell 7)
    (let
      [before : u64 (read-cell seed)]
      [middle : u64
        (if (= mode 1)
          (begin
            (set! cell 11)
            11)
          (if (= mode 2)
            (write-cell 13)
            (read-cell (+ seed 3))))]
      [after : u64 (read-cell seed)]
      [expected-salt : u64
        (if (= mode 1)
          11
          (if (= mode 2)
            13
            7))]
      (and
        (= before (mix seed 7))
        (= after (mix seed expected-salt))
        (=
          middle
          (if (= mode 1)
            11
            (if (= mode 2)
              13
              (mix (+ seed 3) 7))))))))

(define (partial-path [seed : u64] [take-first : bool]) : bool
  (let
    [first : u64
      (if take-first
        (read-cell seed)
        0)]
    [second : u64 (read-cell seed)]
    (and
      (= second (mix seed cell))
      (=
        first
        (if take-first
          second
          0)))))

(define (main) : i64
  (let
    [seed : u64 (cast (string.>int (io.arg 1)) : u64)]
    (if (and
      (check-mode seed 0)
      (check-mode seed 1)
      (check-mode seed 2)
      (partial-path seed false)
      (partial-path seed true))
      42
      1)))