;; Layout queries evaluate on a macro's `type` operand during transformer
;; evaluation (#9628), both directly and inside a nested `(comptime ...)`. The
;; answers steer the transformer as well as reach the emitted literals: every
;; macro picks a branch from a query before it emits anything. Each count is
;; compared with a `(comptime ...)` fold over the same concrete type, and the
;; operand may name an imported nominal type through its alias.
(import stdlib.comptime)
(import macro_layout_operand_dep as dep)

(defstruct Pair
  (a i64)
  (b i64))

(defstruct Mixed
  (tag u8)
  (wide i64)
  (small i32))

(defenum Shape
  (Dot)
  (Box Pair))

;; Unconstrained operand: direct size, wrapped alignment.
(defmacro (size-class [T : type]) : i64
  (if (> (size-of T) 8)
    (comptime.expr-int (size-of T))
    (if (= (comptime (align-of T)) 8)
      (comptime.expr-int 8)
      (comptime.expr-int (- 0 (comptime (size-of T)))))))

(defmacro (align-direct [T : type]) : i64
  (comptime.expr-int (align-of T)))

;; Constrained operands: `offset-of` on a struct operand, and both queries on
;; scalar kinds.
(defmacro (field-gap [T : type (:kind struct)]) : i64
  (let
    [first : i64 (comptime (offset-of T wide))]
    [last : i64 (offset-of T small)]
    (if (> last first)
      (comptime.expr-int (- last first))
      (comptime.expr-int 0))))

(defmacro (y-offset [T : type (:kind struct)]) : i64
  (comptime.expr-int (comptime (offset-of T y))))

(defmacro (scalar-footprint [T : type (:kind i64 i32 u8)]) : i64
  (comptime.expr-int (+ (size-of T) (comptime (align-of T)))))

;; A Decls transformer chooses which declaration to emit from the operand's
;; layout.
(defmacro (emit-second-offset [T : type]) : Decls
  (if (= (size-of T) 16)
    `(define (pair-second-offset) : i64
      ,(comptime.expr-int (offset-of T b)))
    `(define (pair-second-offset) : i64
      -1)))

(emit-second-offset Pair)

(define (main) : i64
  (let
    [score : i64 0]
    (when (= (size-class Pair) (comptime (size-of (type Pair)))) (+= score 6))
    (when (= (size-class Shape) (comptime (size-of (type Shape)))) (+= score 6))
    (when (= (size-class i64) 8) (+= score 4))
    (when (= (size-class u8) -1) (+= score 4))
    (when (= (align-direct i32) (comptime (align-of (type i32)))) (+= score 4))
    (when (= (field-gap Mixed) 8) (+= score 4))
    (when
      (= (y-offset dep.Point) (comptime (offset-of (type dep.Point) y)))
      (+= score 4))
    (when
      (= (size-class dep.Point) (comptime (size-of (type dep.Point))))
      (+= score 4))
    (when (= (scalar-footprint i32) 8) (+= score 3))
    (when (= (scalar-footprint u8) 2) (+= score 1))
    (when (= (pair-second-offset) 8) (+= score 2))
    score))