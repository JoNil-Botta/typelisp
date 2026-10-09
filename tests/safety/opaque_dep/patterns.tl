(module opaque_dep.patterns)

(import opaque_dep)

;; Or-patterns and by-name struct patterns read an opaque type's
;; representation, which its module family may do (#6999).
(define (weigh [fd : i64]) : i64
  (let
    [c : opaque_dep.Connection (opaque_dep.Connection fd)]
    [s : opaque_dep.State (opaque_dep.Busy 2)]
    (+
      (match c
        [(fields fd) fd])
      (match s
        [(or (opaque_dep.Idle) (opaque_dep.Busy _)) 1]))))