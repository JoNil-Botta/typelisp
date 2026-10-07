;; A cleanup hook naming another module's unsafe declaration is rejected the
;; same way (#8267).
(import cleanup_hook_unsafe_dep as dep)

; Must fail: `dep/raw-close` is an unsafe declaration.
(defstruct Handle
  (:cleanup close-handle)
  (fd i64 (:cleanup dep/raw-close)))

(define (main) : i64
  (let
    [h : Handle (Handle 3)]
    (close-handle h)
    0))