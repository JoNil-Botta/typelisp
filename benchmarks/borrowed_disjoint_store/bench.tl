;# Checked-reference load-GVN benchmark (#5201).
;# Both implementations may inline. The runtime shared field stays invariant
;# across writes through a disjoint exclusive reference. Each iteration updates
;# the exclusive pair from its previous state, and main consumes both fields.
(import stdlib.io)

(defstruct BorrowedPair
  (x u64)
  (y u64))

(define (borrowed-disjoint-store-touch
  [write : (&mut write BorrowedPair)]
  [value : u64]) : unit
  (set! write.y (bit-xor write.y (+ write.x value))))

(define (borrowed-disjoint-store-loop
  [read : (& read BorrowedPair)]
  [write : (&mut write BorrowedPair)]
  [iterations : u64]) : unit
  (let
    [i : u64 0]
    (while (< i iterations)
      (let
        [current : u64 read.x]
        (borrowed-disjoint-store-touch write (+ i current))
        (set! write.x (+ read.x write.y))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [argc : u64 (cast (io.arg-count) : u64)]
    [left : BorrowedPair (BorrowedPair (+ 16 argc) 0)]
    [right : BorrowedPair (BorrowedPair 23 0)]
    [iterations : u64 (+ 100000000 argc)]
    [first-iterations : u64 (/ iterations 2)]
    [second-iterations : u64 (- iterations first-iterations)]
    (borrowed-disjoint-store-loop (& left) (&mut right) first-iterations)
    (borrowed-disjoint-store-loop (& left) (&mut right) second-iterations)
    (let
      [checksum : u64 (bit-xor right.x right.y)]
      (io.println "{}" checksum)
      (cast (bit-and checksum 255) : i64))))