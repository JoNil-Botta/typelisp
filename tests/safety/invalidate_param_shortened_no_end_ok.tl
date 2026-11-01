;; Refs #9503: shortening remains valid when the brand is never ended.
(define (exercise [x : (& r i64)]) : i64
  (let
    [k : i64 0]
    [alias : (& k i64) x]
    (deref alias)))

(define (main) : i64
  (let
    [seed : i64 42]
    (exercise (& seed))))