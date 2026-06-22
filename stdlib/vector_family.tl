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
;#   (let
;#     [points : PointVec (point-vec-new)]
;#     [tokens : TokenVec (token-vec-new)]
;#     (begin
;#       (point-vec-push (&mut points) (Point 1))
;#       (token-vec-push (&mut tokens) (Token 2))
;#       (+ (point-vec-len (& points)) (token-vec-len (& tokens))))))
;# ```
(module stdlib.vector_family)

;: Emit a named growable vector family for element type `T`.
;:
;: `(vector-family Point PointVec point-vec)` defines `PointVec` plus
;: `point-vec-new`, `point-vec-with-capacity`, `point-vec-push`,
;: `point-vec-len`, `point-vec-capacity`, `point-vec-get`,
;: `point-vec-set!`, and private copy/grow helpers. Reads take `&` and mutators
;: take `&mut`, matching the module-emitting `(vector T)` surface.
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
              (define (,slots-name [v : (& v ,vec-name)]) : (& v (Array ,T))
                (& (struct-get v slots)))
              (define (,len-name [v : (& v ,vec-name)]) : i64
                (struct-get v len))
              (define (,capacity-name [v : (& v ,vec-name)]) : i64
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
              (define (,get-name
                [v : (& v ,vec-name)]
                [index : i64]
                [fallback : ,T]) : ,T
                (if (if (>= index 0)
                  (< index (,len-name v))
                  false)
                  (array-ref (,slots-name v) index)
                  fallback))
              (define (,set-name
                [v : (&mut v ,vec-name)]
                [index : i64]
                [value : ,T]) : unit
                (if (if (>= index 0)
                  (< index (struct-get v len))
                  false)
                  (array-set! (struct-get v slots) index value)
                  unit))
              (define (,copy-range-name
                [dst : (&mut dst (Array ,T))]
                [src : (& src (Array ,T))]
                [index : i64]
                [count : i64]) : unit
                (if (>= index count)
                  unit
                  (begin
                    (array-set! dst index (array-ref src index))
                    (,copy-range-name dst src (+ index 1) count))))
              (define (,grow-name [v : (&mut v ,vec-name)]) : unit
                (let
                  [n : i64 (struct-get v len)]
                  [old-cap : i64 (array-length (struct-get v slots))]
                  [new-cap : i64
                    (if (< old-cap 1)
                      1
                      (* old-cap 2))]
                  [bigger : (Array ,T) (make-array ,T new-cap)]
                  (begin
                    (,copy-range-name
                      (&mut bigger)
                      (& (struct-get v slots))
                      0
                      n)
                    (set! (struct-get v slots) bigger))))
              (define (,push-name [v : (&mut v ,vec-name)] [value : ,T]) : unit
                (begin
                  (if (< (struct-get v len) (array-length (struct-get v slots)))
                    unit
                    (,grow-name v))
                  (let
                    [index : i64 (struct-get v len)]
                    (begin
                      (array-set! (struct-get v slots) index value)
                      (set! (struct-get v len) (+ index 1))))))))]
        [_ `(begin)])]
    [_ `(begin)]))

(export (macro vector-family))