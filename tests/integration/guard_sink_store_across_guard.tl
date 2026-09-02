;; GS-1 negative coverage: a global cell read that a store to the SAME global
;; separates from its only reader. `guard_sink` would otherwise move the read
;; below the guard, past the store, and the snapshot would observe the written
;; value instead of the one that was there. The memory rule (P18's cell row plus
;; IAG-2's storage row) is what refuses it, and the printed sum is the proof: the
;; loop must accumulate the value the cell held BEFORE the store.
(import stdlib.io)

(define gs-cell : i64
  0)

(define (gs-probe [n : i64]) : i64
  (let
    [snapshot : i64 gs-cell]
    (begin
      (set! gs-cell (+ gs-cell 100))
      (if (> n 0)
        (let
          [acc : i64 0]
          [i : i64 0]
          (begin
            (while (< i n)
              (begin
                (set! acc (+ acc snapshot))
                (set! i (+ i 1))))
            acc))
        -1))))

(define (main) : i64
  (begin
    (set! gs-cell 5)
    ;; 5 * 5, not 105 * 5.
    (io.print-format "{}\n" (gs-probe 5))
    ;; The store from the first call is visible here: 105 * 2.
    (io.print-format "{}\n" (gs-probe 2))
    ;; The guard's bypass arm never reads the snapshot at all.
    (io.print-format "{}\n" (gs-probe 0))
    42))