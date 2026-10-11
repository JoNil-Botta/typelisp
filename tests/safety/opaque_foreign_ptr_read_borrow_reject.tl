;; Borrowing a pointer-read temporary still reads the opaque value through the
;; pointer outside its family (#8734).
(import opaque_dep)

(define (peek [p : (Ptr opaque_dep.Connection)]) : i64
  (opaque_dep.connection-fd
    (&
      (unsafe
        (ptr-read p)))))

(define (main) : i64
  0)