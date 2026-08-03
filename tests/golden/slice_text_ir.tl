;; Tiny textual-IR fixture: the borrowed Slice signature must remain visible in
;; the dumped function while the call is retained by main.
(define (slice-text-identity [view : (& lifetime (Slice i64))]) : (&
    lifetime
    (Slice i64))
  view)

(define (main) : i64
  (let
    [items : (Array i64 2) (array 41 1)]
    [view : (& items (Slice i64)) (slice-text-identity (& items))]
    (+ (array-ref view 0) (array-ref view 1))))