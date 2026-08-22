(import format_owner_alpha as alpha)
(import format_owner_beta as beta)
(import format_owner_multi as multi)
(import format_owner_nested as nested)
(import format_owner_point as point)
(import format_owner_state as state)
(import stdlib.format)
(import stdlib.io)
(import stdlib.string)

(define make-count : i64
  0)

(define (make-point-once) : point.Point
  (begin
    (set! make-count (+ make-count 1))
    (point.make "rvalue" 5 6)))

(define (main) : i64
  (let
    [p : point.Point (point.make "point" 1 2)]
    [wrapped : nested.Nested (nested.Nested (point.make "inner" 3 4))]
    [status : state.State (state.Count 7)]
    [primary : multi.Primary (multi.Primary 8)]
    [secondary : multi.Secondary (multi.Secondary 9)]
    [left : alpha.Token (alpha.Token 1)]
    [right : beta.Token (beta.Token 2)]
    [body : String
      (format.format
        "{}|{}|{}|{}|{}|{}|{}|{}"
        p
        status
        wrapped
        primary
        secondary
        left
        right
        (make-point-once))]
    [captured-body : String (format.format "{p}")]
    [named-body : String (format.format "{again}" (format.named again p))]
    (if (and
      (= make-count 1)
      (string.eq p.label "point")
      (string.eq captured-body "Point(1, 2)")
      (string.eq named-body "Point(1, 2)"))
      (begin
        (io.print-format "format:{}\n" body)
        (io.print-format "print:{}|" p)
        (io.println "println:{}" status)
        0)
      1)))