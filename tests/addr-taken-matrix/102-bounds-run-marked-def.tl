;; Three increasing indices fit the slice. A definition of an address-taken
;; local separates those checks from the fourth, which reaches the backing
;; array's sentinel just beyond the slice and must trap. Expected exit 134.
(import stdlib.io)

(define (read-run [items : (& src (Slice i64))] [idx : i64]) : i64
  (let
    [first (array-ref items idx)]
    [second (array-ref items (+ idx 1))]
    [third (array-ref items (+ idx 2))]
    [slot : i64 (+ first (+ second third))]
    [index (cast (+ idx 3) : u64)]
    [copy index]
    [fourth (array-ref items (cast copy : i64))]
    [address
      (unsafe
        (ptr-addr-of slot))]
    (+
      fourth
      (unsafe
        (ptr-read address)))))

(define (main) : i64
  (let
    [items : (Array i64 4) (array 1 2 3 36)]
    (read-run (slice-view (& items) 0 3) (- (io.arg-count) 1))))