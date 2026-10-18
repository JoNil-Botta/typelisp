;; refs #8853: with the elided lifetime in scope, a let may bind a non-Copy
;; field read through the reference, as with an explicit lifetime name. The
;; binding is a region-tagged copy, which must not escape the reference's
;; region.
(defstruct CopyPt
  (name String)
  (x i64))

(defstruct CopyOuter
  (inner CopyPt))

(define (elided-let-region-copy [outer : (& CopyOuter)]) : CopyPt
  (let
    [inner outer.inner]
    inner))

(define (main) : i64
  (let
    [outer (CopyOuter (CopyPt "a" 42))]
    (elided-let-region-copy (& outer)).x))