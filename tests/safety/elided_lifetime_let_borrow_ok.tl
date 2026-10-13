(import stdlib.iterator)

;; refs #8853: an elided input reference's hidden lifetime outlives the body,
;; like an explicit signature lifetime name (#6053). A local may bind the
;; parameter itself or a borrow projected from it, shared or mutable, scalar or
;; aggregate, and pass the bound reference on.
(defstruct ElidedLetRec
  (value i64))

(defstruct ElidedLetStored
  (field i64)
  (pair (Tuple i64 i64))
  (fixed (Array i64 2))
  (rec ElidedLetRec))

(define (elided-let-value [rec : (& ElidedLetRec)]) : i64
  rec.value)

(define (elided-let-copy [value : (& i64)]) : i64
  (let
    [copy value]
    (deref copy)))

(define (elided-let-pass-on [rec : (& ElidedLetRec)]) : i64
  (let
    [bound rec]
    (elided-let-value bound)))

(define (elided-let-project [stored : (& ElidedLetStored)]) : i64
  (let
    [field (& stored.field)]
    [tuple-item (& (tuple-ref stored.pair 1))]
    [array-item (& (array-ref stored.fixed 1))]
    [rec (& stored.rec)]
    (+
      (deref field)
      (deref tuple-item)
      (deref array-item)
      (elided-let-value rec))))

(define (elided-let-element
  [items : (& (__tl_dyn-array ElidedLetRec))]
  [index : i64]) : i64
  (let
    [item (& (array-ref items index))]
    (elided-let-value item)))

(define (elided-let-touch!
  [items : (&mut (__tl_dyn-array ElidedLetRec))]
  [index : i64]) : unit
  (let
    [item (&mut (array-ref items index))]
    (set! item.value (+ item.value 1))
    unit))

;; Two elided inputs: each binds under its own hidden lifetime.
(define (elided-let-two [left : (& ElidedLetRec)] [right : (& ElidedLetRec)]) : i64
  (let
    [left-copy left]
    [right-copy right]
    (- (elided-let-value left-copy) (elided-let-value right-copy))))

;; The bound reference may leave through the elided output lifetime.
(define (elided-let-return [rec : (& ElidedLetRec)]) : (& ElidedLetRec)
  (let
    [bound rec]
    bound))

;; A body that uses macros (`when`, `for`, `+=`) is checked once against the
;; parameters as written, while macros expand, then against the elaborated
;; signature. Both checks accept the let-bound reference.
(define (elided-let-in-macros [items : (& (__tl_dyn-array ElidedLetRec))]) : i64
  (let
    [total : i64 0]
    [bound items]
    (for [index (iterator.range 0 2)]
      (when
        (> (array-ref bound index).value 0)
        (+= total (array-ref bound index).value)))
    total))

(define (main) : i64
  (let
    [items : (__tl_dyn-array ElidedLetRec) (__tl_make-array ElidedLetRec 2)]
    [stored : ElidedLetStored
      (ElidedLetStored 1 (tuple 0 2) (array 0 3) (ElidedLetRec 4))]
    [seven : i64 7]
    (set! (array-ref items 0) (ElidedLetRec 5))
    (set! (array-ref items 1) (ElidedLetRec 2))
    (elided-let-touch! (&mut items) 0)
    ;; 7 + 10 + 6 + (6 - 2) + 4 + 6 + (2 + 3) + (6 + 2) - 8 = 42
    (+
      (- (elided-let-in-macros (& items)) 8)
      (elided-let-copy (& seven))
      (elided-let-project (& stored))
      (elided-let-element (& items) 0)
      (elided-let-two (& (array-ref items 0)) (& (array-ref items 1)))
      (elided-let-pass-on (& stored.rec))
      (elided-let-pass-on (elided-let-return (& (array-ref items 0))))
      (+ (array-ref items 1).value 3))))