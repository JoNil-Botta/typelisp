;; A pointer to a reference to an opaque type holds no representation by
;; value: writing, offsetting and reading through it stay usable outside the
;; family (#8734).
(import opaque_dep)

(define (through [c : (& a opaque_dep.Connection)]) : i64
  (let
    [slot : (& a opaque_dep.Connection) c]
    [p : (MutPtr (& a opaque_dep.Connection))
      (unsafe
        (ptr-addr-of slot))]
    [_written : unit
      (unsafe
        (ptr-write! p c))]
    [q : (MutPtr (& a opaque_dep.Connection))
      (unsafe
        (ptr-offset p 0))]
    (opaque_dep.connection-fd
      (unsafe
        (ptr-read q)))))

(define (main) : i64
  (opaque_dep.with-connection 42 through))