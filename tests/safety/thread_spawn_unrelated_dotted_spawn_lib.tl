(module local.worker)

(defenum SpawnResult
  (SpawnOk i64))

(define (spawn [value : i64]) : SpawnResult
  (SpawnOk (+ value 1)))