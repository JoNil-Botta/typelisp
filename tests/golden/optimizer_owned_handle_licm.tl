(import compiler_owned_view as owned_view)

(defstruct OwnedIrHolder
  (items (__tl_dyn-array i64)))

(define (owned-ir-sum [holder : OwnedIrHolder]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i (array-length holder.items))
        (begin
          (set! sum (+ sum (array-ref holder.items i)))
          (set! i (+ i 1))))
      sum)))

(define (owned-ir-positive) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items 0) 20)
      (set! (array-ref items 1) 22)
      (owned-ir-sum (OwnedIrHolder items)))))

;; The compiler-owned view is an explicit shallow representation alias. Even
;; though it is moved into a fresh holder with the same field type, it must not
;; manufacture an owning-tree capability from that shape.
(define (owned-ir-shallow-negative) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [shallow : (__tl_dyn-array i64)
      (owned_view.compiler-owned-shared-view items)]
    (begin
      (set! (array-ref items 0) 7)
      (owned-ir-sum (OwnedIrHolder shallow)))))

(define (main) : i64
  (+ (owned-ir-positive) (owned-ir-shallow-negative)))