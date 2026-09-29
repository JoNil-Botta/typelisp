;; Check-only: the unsafe publication helper cannot become a plain function
;; value, even inside unsafe (#7658, SPEC 4.3.1).
(import stdlib.env)

(define (main) : i64
  (unsafe
    (let
      [_publish : (-> (& str) (& str) bool unit) env.linux-rebuild!]
      42)))