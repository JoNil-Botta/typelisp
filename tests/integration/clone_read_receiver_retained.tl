;; A shared-reference auto-borrow reads the receiver of an array projection
;; without moving it, unless the index evaluated after the receiver can write a
;; variable the receiver may select: then the receiver is retained by value, as
;; any operand a later operand can write is, and the copy sees the element
;; selected before the write. Here the index reassigns `a`; the copy is the old
;; element (7) and `a` holds the new one (99).
(import stdlib.clone)

(defstruct Cell
  (items (__tl_dyn-array i64)))

(clone.gen-clone Cell)

(define (copy-before-write
  [a : (Array Cell 1)]
  [b : (Array Cell 1)]
  [flag : bool]) : i64
  (let
    [copy : Cell
      (let
        [chosen : (Array Cell 1)
          (if flag
            a
            b)]
        [idx : i64
          (begin
            (set! a (array (Cell (__tl_make-array 99))))
            0)]
        (clone-cell (& (array-ref chosen idx))))]
    [written : i64 (array-ref (array-ref a 0).items 0)]
    (if (= written 99)
      (array-ref copy.items 0)
      1)))

(define (main) : i64
  (copy-before-write
    (array (Cell (__tl_make-array 7)))
    (array (Cell (__tl_make-array 8)))
    true))