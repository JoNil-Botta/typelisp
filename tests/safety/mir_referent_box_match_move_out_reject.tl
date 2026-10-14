;; Box contents reached through a shared reference are a view as well:
;; returning a payload bound from them moves it out from behind the reference.
(import stdlib.string)

(defenum Reason
  (No)
  (Some String))

(defstruct Meta
  (value (Box Reason)))

(define (text [meta : (& meta Meta)]) : String
  (match (deref meta.value)
    [(Reason.No) (string.copy "")]
    [(Reason.Some found) found]))

(define (main) : i64
  (let
    [meta : Meta (Meta (box (Reason.Some (string.copy "abc"))))]
    (string.string-length (text (& meta)))))