;; A shadowing result must not discharge the outer owner with the same name.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(define (main) : i64
  (let
    [h : Handle (Handle 1)]
    (begin
      (cleanup-handle
        (let
          [h : Handle (Handle 2)]
          h))
      0)))