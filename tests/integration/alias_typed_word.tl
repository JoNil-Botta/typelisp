;; ALIAS-3. The `*-scan-ints` tokenizer shape the LICM refusal census is made
;; of: one loop that reads bytes through a `(& str)` parameter and writes
;; elements through a `(&mut Vec)` parameter.
;;
;; `atw-scan-ints`'s loop reaches its output buffer through THREE reads of
;; `out`'s own storage on every trip -- the `slots` handle at `*out + 0`, that
;; descriptor's length word and its data pointer -- and every one of them is
;; loop-invariant in fact. What kept them in was the loop's only write: an
;; element store, whose address the provenance walk roots nowhere, so
;; opt-licm-memory-safe? had no object-level proof to offer and refused with
;; `memory-root`.
;;
;; It is not an object-level proof that moves them. The element store writes an
;; `i64` word; the `slots` read is a DESCRIPTOR HANDLE word, a different alias
;; class, and a store of one class cannot write a word of another whatever
;; either address turns out to be (opt-licm-store-summary-element-class-safe?).
;; With the handle out, its length and data words are ordinary descriptor
;; header slots off an invariant handle and the existing rule takes them.
;;
;; The `len` FIELD of `out` -- an `i64` word, the same class the store writes --
;; deliberately stays inside: separating those two needs the two objects to be
;; disjoint, and this language does not make two borrows disjoint.
;;
;; `bump` shifts every store one slot up. At 0 the eight parsed values fill the
;; eight-slot vector exactly and the printed fold pins them; at 1 the last
;; store is exactly at `length`, so the run must abort at that store with the
;; same located message the base compiler produced.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (atw-byte-at [text : (& text str)] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (atw-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

;; Whitespace-separated decimal integers, with `#` starting a comment that runs
;; to the end of its line.
(define (atw-scan-ints
  [text : (& text str)]
  [out : (&mut out i64vec.Vec)]
  [bump : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [byte : i64 (atw-byte-at text n i)]
          (cond
            [(= byte 35)
              (while (and (< i n) (not (= (atw-byte-at text n i) 10)))
                (set! i (+ i 1)))]
            [(or (atw-digit? byte) (= byte 45))
              (let
                [negative : bool (= byte 45)]
                [value : i64 0]
                (begin
                  (when negative (set! i (+ i 1)))
                  (while (atw-digit? (atw-byte-at text n i))
                    (begin
                      (set!
                        value
                        (+ (* value 10) (- (atw-byte-at text n i) 48)))
                      (set! i (+ i 1))))
                  (set!
                    (array-ref (i64vec.slots-mut out) (+ count bump))
                    (if negative
                      (- 0 value)
                      value))
                  (set! count (+ count 1))))]
            [else (set! i (+ i 1))])))
      count)))

(define (atw-fold [out : (& out i64vec.Vec)] [count : i64]) : i64
  (let
    [acc : i64 0]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! acc (+ (* acc 31) (array-ref (i64vec.slots out) index)))
          (set! index (+ index 1))))
      acc)))

(define (main) : i64
  (let
    [bump : i64 (string.>int (io.arg 1))]
    [text : String (io.arg 2)]
    [tokens : i64vec.Vec (i64vec.Vec (__tl_make-array i64 8) 8)]
    [count : i64 (atw-scan-ints (& text) (&mut tokens) bump)]
    (begin
      (io.print-format "{} {}\n" count (atw-fold (& tokens) count))
      42)))