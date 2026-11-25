;; Sealed handle types (#9783): holding, passing, returning, moving, reading
;; fields and implicit cleanup stay safe; unsafe code may construct and
;; mutate; an (:owned) field does not seal its owner.
(import sealed_handle_dep as dep)

(define (generation [handle : dep.Handle]) : i64
  handle.generation)

(define (pass [owner : dep.Owner]) : dep.Owner
  owner)

(define (main) : i64
  (let
    [handle : dep.Handle (dep.null-handle)]
    [forged : dep.Handle
      (unsafe
        (dep.Handle (ptr-null : (MutPtr dep.Storage)) 30))]
    (unsafe
      (set! forged.generation (+ forged.generation 5)))
    (with
      ([owner (pass (dep.make-owner)) dep.close-owner]
        [hooked (dep.make-hooked 0) dep.close-hooked]
        [wrapper (dep.Wrapper (dep.make-owner)) dep.close-wrapper])
      (+
        (generation handle)
        (generation forged)
        hooked.fd
        (- wrapper.owner.handle.generation owner.handle.generation)))))