;; Outside its module family, a struct holding a pointer to an opaque
;; aggregate is constructed only in unsafe code (#9783).
(import sealed_handle_dep as dep)

(define (main) : i64
  (let
    [handle : dep.Handle (dep.Handle (ptr-null : (MutPtr dep.Storage)) 0)]
    handle.generation))