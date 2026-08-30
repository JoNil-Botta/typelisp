; IAG-1: a runtime-initialised memory-aggregate global whose cell holds the
; aggregate inline. `install!` is the only cell writer and nothing that reads
; the global can reach it, so the classification keeps this one inline; the body
; still exercises a rebind, `&mut` field writes and `&` reads.
(import stdlib.io)

(defstruct Cell
  (slots (__tl_dyn-array i64))
  (len i64))

(define grid : Cell
  (Cell (__tl_make-array i64 4) 4))

(define (peek [c : (& Cell)] [index : i64]) : i64
  (array-ref c.slots index))

(define (poke [c : (&mut Cell)] [index : i64] [value : i64]) : unit
  (set! (array-ref c.slots index) value))

(define (install! [n : i64]) : unit
  (set! grid (Cell (__tl_make-array i64 n) n)))

(define (fill [index : i64]) : unit
  (if (>= index grid.len)
    unit
    (begin
      (poke (&mut grid) index (* index 3))
      (fill (+ index 1)))))

(define (sum [index : i64] [acc : i64]) : i64
  (if (>= index grid.len)
    acc
    (sum (+ index 1) (+ acc (peek (& grid) index)))))

(define (report) : i64
  (begin
    (fill 0)
    (+ (sum 0 0) (+ grid.len (array-ref grid.slots 2)))))

(define (main) : i64
  (begin
    (install! 8)
    (io.print-format "{}\n" (report))
    42))