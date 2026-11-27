(module field_opacity_model)

(defstruct Reading
  (value i64)
  (scale i64 (:opaque)))

(defstruct Sample
  (reading Reading))

(defstruct Aligned
  (:repr c)
  (value i64 (:align 8))
  (scale i64 (:opaque) (:align 8)))

(define (reading [value : i64]) : Reading
  (Reading value 2))

(defmacro (build-reading [value : Expr]) : Expr
  `(Reading ,value 2))

(defmacro (declare-label) : Decls
  `(defstruct Label
    (text-code i64 (:opaque))))

(declare-label)

(unsafe
  (define (finish-number [_n : i64]) : unit
    unit))

(defstruct SavedReading
  (:cleanup finish-reading)
  (value i64 (:cleanup finish-number) (:opaque)))