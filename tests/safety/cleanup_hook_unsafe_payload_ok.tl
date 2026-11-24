;; An enum payload cleanup hook may name an unsafe declaration; the enum is a
;; sealed handle type its own module family builds in safe code (#9783).
(unsafe
  (define (raw-close [fd : i64]) : unit
    unit))

(defenum Res
  (:cleanup close-res)
  (Open i64 (:cleanup raw-close))
  (Closed))

(define (main) : i64
  (let
    [r : Res (Open 3)]
    (close-res r)
    0))