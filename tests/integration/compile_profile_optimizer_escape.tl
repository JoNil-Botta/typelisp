;; compile_profile_optimizer_escape.tl - Fixture for optimizer escape profile rows.
(define (profile-escape-helper [x : i64]) : i64
  (+ x 1))

(define (main) : i64
  (profile-escape-helper 41))