;; refs #2296: a (:repr c) struct embeds default-layout aggregates by value (a
;; default struct field and an enum field) — mixed-representation embedding.
;; Default layout follows C layout (#1867), so the inner aggregates lay out
;; inline inside the C-layout outer struct. main returns 42 only when nested
;; field projection and the projected enum match observe the constructed values.
(defstruct Point
  (x i64)
  (y i64))

(defenum Tag
  (TagNone)
  (TagVal i64))

(defstruct CWrap
  (:repr c)
  (p Point)
  (t Tag))

(define (tag-value [t : Tag]) : i64
  (match t
    [(TagNone) 0]
    [(TagVal v) v]))

(define (main) : i64
  (let
    [w : CWrap (CWrap (Point 30 5) (TagVal 7))]
    [px : i64 (struct-get (struct-get w p) x)]
    [py : i64 (struct-get (struct-get w p) y)]
    [tv : i64 (tag-value (struct-get w t))]
    (+ px (+ py tv))))