;; Layout queries on compile-time type values other than a macro's own `type`
;; operand, inside a transformer body: a `(type T)` literal queried directly
;; (#9634), a type value returned by reflection, and imported type literals
;; through an alias or the module name (#9633). Some transformers branch on a
;; query before they emit; every emitted answer is compared with an ordinary
;; `(comptime ...)` fold over the same type, and imported answers also with a
;; local declaration of the same shape.
(import stdlib.comptime)
(import comptime_layout_imported_dep as dep)
(import comptime_layout_imported_other)

(defstruct LocalPoint
  (x i64)
  (y i64))

(defstruct LocalCPoint
  (:repr c)
  (tag u8)
  (y i64))

(defstruct LocalNarrow
  (x i8))

(defenum LocalShape
  (Dot)
  (Box LocalPoint))

(defstruct Holder
  (tag u8)
  (inner LocalCPoint))

;; Literal types queried directly, and the wrapped form of the same query.
(defmacro (literal-size) : i64
  (comptime.expr-int (size-of (type LocalCPoint))))

(defmacro (literal-size-wrapped) : i64
  (comptime.expr-int (comptime (size-of (type LocalCPoint)))))

(defmacro (literal-align) : i64
  (comptime.expr-int (align-of (type i32))))

(defmacro (literal-offset) : i64
  (comptime.expr-int (offset-of (type LocalCPoint) y)))

(defmacro (literal-enum-size) : i64
  (comptime.expr-int (size-of (type LocalShape))))

;; The transformer compares the direct and wrapped answers before it emits.
(defmacro (literal-agree) : i64
  (comptime.expr-int
    (+
      (if (= (size-of (type LocalShape)) (comptime (size-of (type LocalShape))))
        1
        0)
      (if (= (align-of (type u8)) (comptime (align-of (type u8))))
        1
        0)
      (if (=
        (offset-of (type LocalCPoint) y)
        (comptime (offset-of (type LocalCPoint) y)))
        1
        0))))

;; Type values returned by reflection, from a literal and from an operand.
(defmacro (field-size) : i64
  (comptime.expr-int (size-of (struct-field-type (type Holder) 1))))

(defmacro (field-size-wrapped) : i64
  (comptime.expr-int (comptime (size-of (struct-field-type (type Holder) 1)))))

(defmacro (field-align [T : type (:kind struct)]) : i64
  (comptime.expr-int (align-of (struct-field-type T 1))))

(defmacro (field-align-wrapped [T : type (:kind struct)]) : i64
  (comptime.expr-int (comptime (align-of (struct-field-type T 1)))))

;; Imported literals: an alias, the module name, and a same-named type in
;; another module.
(defmacro (alias-size) : i64
  (comptime.expr-int (comptime (size-of (type dep.Point)))))

(defmacro (module-size) : i64
  (comptime.expr-int
    (comptime (size-of (type comptime_layout_imported_dep.Point)))))

(defmacro (alias-offset) : i64
  (comptime.expr-int (comptime (offset-of (type dep.CPoint) y))))

(defmacro (alias-enum-align) : i64
  (comptime.expr-int (align-of (type dep.Shape))))

(defmacro (alias-array-size) : i64
  (comptime.expr-int (size-of (type (Array dep.Point 3)))))

(defmacro (other-size) : i64
  (comptime.expr-int
    (comptime (size-of (type comptime_layout_imported_other.Point)))))

(define (main) : i64
  (let
    [score : i64 0]
    (when
      (= (literal-size) (comptime (size-of (type LocalCPoint))))
      (+= score 3))
    (when (= (literal-size-wrapped) (literal-size)) (+= score 3))
    (when (= (literal-align) (comptime (align-of (type i32)))) (+= score 3))
    (when
      (= (literal-offset) (comptime (offset-of (type LocalCPoint) y)))
      (+= score 3))
    (when
      (= (literal-enum-size) (comptime (size-of (type LocalShape))))
      (+= score 3))
    (when (= (literal-agree) 3) (+= score 3))
    (when
      (= (field-size) (comptime (size-of (struct-field-type (type Holder) 1))))
      (+= score 3))
    (when (= (field-size-wrapped) (field-size)) (+= score 3))
    (when
      (= (field-align Holder) (comptime (align-of (type LocalCPoint))))
      (+= score 3))
    (when (= (field-align-wrapped Holder) (field-align Holder)) (+= score 3))
    (when
      (and
        (= (alias-size) (comptime (size-of (type dep.Point))))
        (= (alias-size) (comptime (size-of (type LocalPoint)))))
      (+= score 3))
    (when (= (module-size) (alias-size)) (+= score 2))
    (when
      (and
        (= (alias-offset) (comptime (offset-of (type dep.CPoint) y)))
        (= (alias-offset) (comptime (offset-of (type LocalCPoint) y))))
      (+= score 2))
    (when
      (= (alias-enum-align) (comptime (align-of (type LocalShape))))
      (+= score 2))
    (when
      (= (alias-array-size) (* 3 (comptime (size-of (type LocalPoint)))))
      (+= score 2))
    (when
      (and
        (= (other-size) (comptime (size-of (type LocalNarrow))))
        (not (= (other-size) (alias-size))))
      (+= score 1))
    score))