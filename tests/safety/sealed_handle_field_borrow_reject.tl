;; Outside its module family, a field of a sealed handle type is mutably
;; borrowed only in unsafe code (#9783).
(import sealed_handle_dep as dep)

(define (reset! [n : (&mut i64)]) : unit
  (set! (deref n) 0))

(define (main) : i64
  (let
    [handle : dep.Handle (dep.null-handle)]
    (reset! (&mut handle.generation))
    handle.generation))