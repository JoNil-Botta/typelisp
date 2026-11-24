;; A cleanup hook may name another module's unsafe declaration (#9783).
(import cleanup_hook_unsafe_dep as dep)

(defstruct Handle
  (:cleanup close-handle)
  (fd i64 (:cleanup dep/raw-close)))

(define (main) : i64
  (let
    [h : Handle (Handle 3)]
    (close-handle h)
    0))