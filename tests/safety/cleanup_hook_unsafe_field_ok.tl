;; A field cleanup hook may name an unsafe declaration: the owner becomes a
;; sealed handle type, which its own module family still builds in safe code
;; (#9783).
(unsafe
  (define (raw-close [fd : i64]) : unit
    unit))

(defstruct Handle
  (:cleanup close-handle)
  (fd i64 (:cleanup raw-close)))

(define (main) : i64
  (let
    [h : Handle (Handle 3)]
    (close-handle h)
    0))