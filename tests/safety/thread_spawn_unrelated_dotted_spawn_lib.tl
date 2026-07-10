;; This intentional dotted identity is unrelated to the filename; the safety
;; fixture verifies that spawned imports preserve the declared module path.
(module local.worker)

(defenum SpawnResult
  (SpawnOk i64))

(define (spawn [value : i64]) : SpawnResult
  (SpawnOk (+ value 1)))