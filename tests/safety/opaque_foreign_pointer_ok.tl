;; Outside the module family an opaque type is usable behind references and
;; pointers, through the defining module's functions (#6999).
(import opaque_dep)

(define (read [c : (& a opaque_dep.Connection)]) : i64
  (opaque_dep.connection-fd c))

(define (hold
  [_p : (Ptr opaque_dep.Connection)]
  [_q : (MutPtr opaque_dep.State)]) : i64
  0)

(define (main) : i64
  (+
    (opaque_dep.with-connection 42 read)
    (hold
      (ptr-null : (Ptr opaque_dep.Connection))
      (ptr-null : (MutPtr opaque_dep.State)))))