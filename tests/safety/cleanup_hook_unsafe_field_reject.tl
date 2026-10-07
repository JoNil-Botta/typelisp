;; A field cleanup hook runs implicitly at scope end, in safe code too, so it
;; cannot name an unsafe declaration (#8267).
(unsafe
  (define (raw-close [fd : i64]) : unit
    unit))

; Must fail: `raw-close` is an unsafe declaration.
(defstruct Handle
  (:cleanup close-handle)
  (fd i64 (:cleanup raw-close)))

(define (main) : i64
  (let
    [h : Handle (Handle 3)]
    (close-handle h)
    0))