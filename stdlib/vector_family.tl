;# Named generated vector-family macro.
;#
;# Use this lightweight macro module when compiler-internal code needs generated
;# vector families without importing the full concrete vector implementation in
;# `stdlib/vector.tl`.
;#
;# ```typelisp
;# (import stdlib.vector_family as vf)
;#
;# (defstruct Point
;#   (x i64))
;#
;# (defstruct Token
;#   (id i64))
;#
;# (vf.vector-family Point PointVec point-vec)
;# (vf.vector-family Token TokenVec token-vec)
;#
;# (define (main) : i64
;#   (+ (point-vec-len (point-vec-push (point-vec-new) (Point 1)))
;#      (token-vec-len (token-vec-push (token-vec-new) (Token 2)))))
;# ```
;: Emit a named growable vector family for element type `T`.
;:
;: `(vector-family Point PointVec point-vec)` defines `PointVec` plus
;: `point-vec-new`, `point-vec-with-capacity`, `point-vec-push`,
;: `point-vec-len`, `point-vec-capacity`, `point-vec-get`,
;: `point-vec-set!`, and private copy/grow helpers. Use this helper when a
;: module needs more than one concrete vector instantiation or when stable
;: prefixed names are clearer than the one-instantiation `(vector T)` surface.
(module stdlib.vector_family)

(defmacro (vector-family [T : type] [vec-name : Expr] [prefix : Expr]) : Decls
  (match prefix
    [(ExprVar base)
      (match vec-name
        [(ExprVar _)
          (let
            [slots-name : Expr (expr-var (string-append base "-slots"))]
            [len-name : Expr (expr-var (string-append base "-len"))]
            [capacity-name : Expr (expr-var (string-append base "-capacity"))]
            [with-capacity-name : Expr
              (expr-var (string-append base "-with-capacity"))]
            [new-name : Expr (expr-var (string-append base "-new"))]
            [get-name : Expr (expr-var (string-append base "-get"))]
            [set-name : Expr (expr-var (string-append base "-set!"))]
            [copy-range-name : Expr
              (expr-var (string-append base "-copy-range"))]
            [grow-name : Expr (expr-var (string-append base "-grow"))]
            [push-name : Expr (expr-var (string-append base "-push"))]
            `(begin
              (defstruct ,vec-name
                (slots (Array ,T))
                (len i64))
              (define (,slots-name [v : ,vec-name]) : (Array ,T)
                (struct-get v slots))
              (define (,len-name [v : ,vec-name]) : i64
                (struct-get v len))
              (define (,capacity-name [v : ,vec-name]) : i64
                (array-length (,slots-name v)))
              (define (,with-capacity-name [capacity : i64]) : ,vec-name
                (let
                  [cap : i64
                    (if (< capacity 1)
                      1
                      capacity)]
                  (,vec-name (make-array ,T cap) 0)))
              (define (,new-name) : ,vec-name
                (,with-capacity-name 4))
              (define (,get-name [v : ,vec-name] [index : i64] [fallback : ,T]) : ,T
                (if (if (>= index 0)
                  (< index (,len-name v))
                  false)
                  (array-ref (,slots-name v) index)
                  fallback))
              (define (,set-name [v : ,vec-name] [index : i64] [value : ,T]) : ,vec-name
                (begin
                  (if (if (>= index 0)
                    (< index (,len-name v))
                    false)
                    (array-set! (,slots-name v) index value)
                    unit)
                  v))
              (define (,copy-range-name
                [dst : (Array ,T)]
                [src : (Array ,T)]
                [index : i64]
                [count : i64]) : unit
                (if (>= index count)
                  unit
                  (begin
                    (array-set! dst index (array-ref src index))
                    (,copy-range-name dst src (+ index 1) count))))
              (define (,grow-name [v : ,vec-name]) : ,vec-name
                (let
                  [n : i64 (,len-name v)]
                  [bigger : (Array ,T) (make-array ,T (* (,capacity-name v) 2))]
                  (begin
                    (,copy-range-name bigger (,slots-name v) 0 n)
                    (set! (struct-get v slots) bigger)
                    v)))
              (define (,push-name [v : ,vec-name] [value : ,T]) : ,vec-name
                (if (< (,len-name v) (,capacity-name v))
                  (let
                    [slots : (Array ,T) (,slots-name v)]
                    [index : i64 (,len-name v)]
                    (begin
                      (array-set! slots index value)
                      (set! (struct-get v len) (+ index 1))
                      v))
                  (,push-name (,grow-name v) value)))))]
        [_ `(begin)])]
    [_ `(begin)]))

(export (macro vector-family))