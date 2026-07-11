;; The explicit dotted identity is the legacy import path exercised by the
;; struct-match fixture, so it must not fall back to the filename identity.
(module struct.match.geom)

(defstruct QPoint
  (x i64)
  (y i64))