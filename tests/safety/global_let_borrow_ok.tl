;; refs #8750: a borrow of a module global outlives every local scope. A local
;; may bind it, shared or mutable, whole or projected, pass it on, and have one
;; assigned to it; `+=` on a global array element expands to such a binding.
(defstruct GlobalLetRec
  (value i64)
  (other i64))

(define global-let-rec : GlobalLetRec
  (GlobalLetRec 3 4))
(define global-let-counts : (Array i64 4)
  (array 0 0 0 0))
(define global-let-items : (__tl_dyn-array GlobalLetRec)
  (__tl_make-array GlobalLetRec 2))

(define (global-let-value [rec : (& GlobalLetRec)]) : i64
  rec.value)

(define (global-let-whole) : i64
  (let
    [r (& global-let-rec)]
    (+ r.value (global-let-value r))))

(define (global-let-element [index : i64]) : i64
  (let
    [item (& (array-ref global-let-items index))]
    (global-let-value item)))

(define (global-let-field) : i64
  (let
    [other (& global-let-rec.other)]
    (deref other)))

(define (global-let-bump!) : unit
  (let
    [item (&mut (array-ref global-let-items 0))]
    (set! item.value (+ item.value 1))
    unit))

(define (global-let-plus-assign!) : unit
  (+= (array-ref global-let-counts 1) 2)
  unit)

;; Assigning a global borrow to an outer local.
(define (global-let-assign [pick-second? : bool]) : i64
  (let
    [chosen (& (array-ref global-let-items 0))]
    (when pick-second? (set! chosen (& (array-ref global-let-items 1))))
    chosen.value))

(define (main) : i64
  (set! (array-ref global-let-items 0) (GlobalLetRec 5 0))
  (set! (array-ref global-let-items 1) (GlobalLetRec 9 0))
  (global-let-bump!)
  (global-let-plus-assign!)
  ;; (3 + 3) + 6 + 4 + 2 + 9 + 6 + 9 = 42
  (+
    (global-let-whole)
    (global-let-element 0)
    (global-let-field)
    (array-ref global-let-counts 1)
    (global-let-assign true)
    (global-let-assign false)
    9))