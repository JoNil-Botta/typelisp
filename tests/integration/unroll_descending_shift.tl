;; UNR-2. An ORDERED INSERT over a module-global table: each insert walks the
;; table downward from its last word and shifts every entry one whole entry up,
;; then writes the new entry into the hole it opened. The shift is
;;
;;   (while (>= cursor floor)
;;     (begin (set! table[cursor + entry-words] table[cursor])
;;            (set! cursor (- cursor 1))))
;;
;; -- the descending counted loop this packet admits to the unroller, and the
;; exact loop `benchmarks/regalloc_greedy`'s `rg-union-insert-segment!` runs.
;; ALIAS-1's versioner strips the two bounds checks off it first, so what the
;; unroller sees and clones is the `__bce_fast` body.
;;
;; The copy OVERLAPS: it reads `table[cursor]` and writes
;; `table[cursor + 3]`, so inside one unrolled group of four a later copy's
;; store lands on a slot an earlier copy already read. The printed fold reads
;; every word of the finished table, so a group that hoisted a store above a
;; load computes a different number here.
;;
;; The keys arrive in DESCENDING order, so every insert lands at position zero
;; and shifts the whole table: the shift runs 3, 6, 9, ... words and exercises
;; the group, its guard's skip arm and the remainder loop at every length.
;;
;; `bump` shifts the cursor one past the end. At 0 every write is in range and
;; the fold pins the table; at 1 the last insert's first write is exactly at
;; `length`, so the run must abort at that store with the same located message
;; the base compiler produced -- the versioning guard fails and the original,
;; still-checked loop runs.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define ud-entry-words : i64
  3)

(define (ud-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define ud-table : i64vec.Vec
  (ud-zero-vec 1))

(define (ud-ref [index : i64]) : i64
  (array-ref (i64vec.slots (& ud-table)) index))

(define (ud-set! [index : i64] [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut (&mut ud-table)) index) value))

(define (ud-shift! [floor : i64] [top : i64]) : unit
  (let
    [cursor : i64 top]
    (while (>= cursor floor)
      (begin
        (ud-set! (+ cursor ud-entry-words) (ud-ref cursor))
        (set! cursor (- cursor 1))))))

;; Where `key` belongs in the sorted table: the first entry whose key is not
;; below it.
(define (ud-lower-bound [held : i64] [key : i64]) : i64
  (let
    [index : i64 0]
    (begin
      (while (and (< index held) (< (ud-ref (* index ud-entry-words)) key))
        (set! index (+ index 1)))
      index)))

(define (ud-insert! [held : i64] [key : i64] [value : i64] [bump : i64]) : unit
  (let
    [at : i64 (ud-lower-bound held key)]
    [floor : i64 (* at ud-entry-words)]
    [top : i64 (+ (- (* held ud-entry-words) 1) bump)]
    (begin
      (ud-shift! floor top)
      (ud-set! floor key)
      (ud-set! (+ floor 1) value)
      (ud-set! (+ floor 2) (- key value)))))

;; The SAME descending shift over a caller-provided word array. With no
;; descriptor between the loop and its storage every access in the body is a
;; 64-bit load or store through a 64-bit-element gep, so the WORD-MERGE tier
;; prices the group at four copies rather than the load-and-store class's two
;; -- and four copies of a shift that moves each word three slots up is a group
;; whose fourth copy stores into the slot its first copy read. Program order
;; inside the group is the whole of what makes that come out right.
(define (ud-shift-words!
  [xs : (&mut xs (__tl_dyn-array i64))]
  [floor : i64]
  [top : i64]) : unit
  (let
    [cursor : i64 top]
    (while (>= cursor floor)
      (begin
        (set! (array-ref xs (+ cursor ud-entry-words)) (array-ref xs cursor))
        (set! cursor (- cursor 1))))))

(define (ud-words-fold [xs : (& xs (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index n)
        (begin
          (set! acc (+ (* acc 31) (array-ref xs index)))
          (set! index (+ index 1))))
      acc)))

(define (ud-fold [held : i64]) : i64
  (let
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index (* held ud-entry-words))
        (begin
          (set! acc (+ (* acc 31) (ud-ref index)))
          (set! index (+ index 1))))
      acc)))

(define (main) : i64
  (let
    [count : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    [index : i64 0]
    [words : i64 (* count ud-entry-words)]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 words)]
    [j : i64 0]
    (begin
      (set! ud-table (ud-zero-vec words))
      (while (< index count)
        (begin
          (ud-insert! index (- count index) (+ (* index 5) 2) bump)
          (set! index (+ index 1))))
      (while (< j words)
        (begin
          (set! (array-ref xs j) (+ (* j 7) 1))
          (set! j (+ j 1))))
      ;; `words - 4` is the last cursor whose store (`cursor + 3`) is still the
      ;; array's last slot, so the shift walks all but the top entry down.
      (ud-shift-words! (&mut xs) 0 (- words 4))
      (io.print-format "{}\n" (ud-fold count))
      (io.print-format "{}\n" (ud-words-fold (& xs) words))
      42)))