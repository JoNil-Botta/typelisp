;; A cleanup hook may name an unsafe declaration only of its owner's module
;; family: a foreign one would let safe code run it at scope exit (#9783).
(import cleanup_hook_unsafe_dep as dep)

; Must fail: `dep/raw-close` is a foreign unsafe declaration.
(defstruct Handle
  (:cleanup close-handle)
  (fd i64 (:cleanup dep/raw-close)))

(define (main) : i64
  (let
    [h : Handle (Handle 3)]
    (close-handle h)
    0))