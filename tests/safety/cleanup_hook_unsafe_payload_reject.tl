;; An enum payload cleanup hook cannot name an unsafe declaration (#8267).
(unsafe
  (define (raw-close [fd : i64]) : unit
    unit))

; Must fail: `raw-close` is an unsafe declaration.
(defenum Res
  (:cleanup close-res)
  (Open i64 (:cleanup raw-close))
  (Closed))

(define (main) : i64
  (let
    [r : Res (Open 3)]
    (close-res r)
    0))