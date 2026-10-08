(module opaque_dep.inner)

(import opaque_dep)

;; A dotted descendant of opaque_dep is in its module family (#6999).
(define (make-and-read [fd : i64]) : i64
  (let
    [c : opaque_dep.Connection (opaque_dep.Connection fd)]
    [s : opaque_dep.State (opaque_dep.Busy 2)]
    (+
      c.fd
      (match s
        [(opaque_dep.Idle) 100]
        [(opaque_dep.Busy n) (- 0 n)]))))