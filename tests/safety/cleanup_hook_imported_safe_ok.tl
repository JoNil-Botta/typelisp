;; A cleanup hook naming another module's safe function is accepted; only an
;; unsafe declaration is rejected (#8267).
(import cleanup_hook_unsafe_dep as dep)

(defstruct Handle
  (:cleanup close-handle)
  (fd i64 (:cleanup dep/safe-close)))

(define (main) : i64
  (let
    [h : Handle (Handle 3)]
    (close-handle h)
    0))