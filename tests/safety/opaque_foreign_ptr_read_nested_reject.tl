;; A pointee that holds the opaque type by value inside a tuple is read by
;; value too, even when the caller never writes the type (#8734).
(import opaque_dep)

(define (peek) : i64
  (match (unsafe
    (ptr-read (opaque_dep.pair-ptr)))
    [_ 0]))

(define (main) : i64
  0)