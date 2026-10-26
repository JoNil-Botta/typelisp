;; The twin of `storage_dead_inner_scope_used_reject` whose outer local is not
;; read after the inner scope. Rust accepts it (the loan is dead where the
;; inner `x` ends), and the ownership graph would too, but typing rejects the
;; store by its names, as main does: the same check decides escapes of arena
;; regions, which the graph does not track (docs/ownership-ir.md, #8890).
(define (outer) : i64
  (let
    [x : i64 1]
    [r (& x)]
    (let
      [x : i64 2]
      (set! r (& x))
      (deref r))))

(define (main) : i64
  (- (outer) 2))