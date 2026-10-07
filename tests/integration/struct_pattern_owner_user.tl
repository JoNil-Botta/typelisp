;; struct_pattern_owner_user.tl - Struct patterns over another module's structs
;; in a non-root module: field types resolve in the struct's module (#8727).
(import struct_pattern_owner_shapes as shapes)

(define (point-x [p : shapes.Point]) : i64
  p.x)

(define (kind-weight [kind : shapes.Kind]) : i64
  (match kind
    [Solid 1]
    [(Dashed n) n]))

(define (line-score [line : shapes.Line]) : i64
  (match line
    [(shapes.Line start kind len) (+ (point-x start) (kind-weight kind) len)]))

(define (shape-score [shape : shapes.Shape]) : i64
  (match shape
    [(Seg (box (shapes.Line start _ _))) (point-x start)]
    [(Dot p) (point-x p)]))