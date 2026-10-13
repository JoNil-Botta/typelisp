;; refs #8880: the borrow checker prunes a loop's loans by scanning the rest of
;; the loop for uses of a lifetime. Here that scan walks into the `for` and
;; `+=` expansions, whose let bindings have macro-hygiene names. The scan
;; must spell those names as it spells variables; reading them from the intern
;; pool crashed the checker.
(import stdlib.iterator)

(defenum Step
  (Add i64)
  (Skip))

(define (walk [steps : (& a (__tl_dyn-array Step))]) : i64
  (let
    [total : i64 0]
    [i : i64 0]
    [r : (& a (__tl_dyn-array Step)) steps]
    (while (< i 2)
      (match (& (array-ref r i))
        [(Add n)
          (for [k (iterator.range 0 1)]
            (+= total (+ n k)))]
        [(Skip) unit])
      (+= i 1))
    total))

(define (main) : i64
  (let
    [steps : (__tl_dyn-array Step) (__tl_make-array Step 2)]
    (set! (array-ref steps 0) (Add 40))
    (set! (array-ref steps 1) (Add 2))
    (walk (& steps))))