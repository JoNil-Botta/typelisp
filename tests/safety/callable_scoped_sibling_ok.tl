;; The nested-only shared a is fixed in both callbacks and in this annotation.
(define (same [first : (-> (& a i64) i64)] [second : (-> (& a i64) i64)]) : i64
  (let [alias : (-> (& a i64) i64) first]
    0))

(define (identity [p : (& value i64)]) : i64 (deref p))
(define (main) : i64 (same identity identity))
