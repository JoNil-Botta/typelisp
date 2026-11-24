;; #9257: Core-mode `vector` does not emit `get` for non-Copy, non-String
;; aggregates such as `ProcessEnvList`.
(import stdlib.process)
(import stdlib.vector)
(import (vector.vector process.ProcessEnvList core) as evec)

(define (main) : i64
  (let
    [v : evec.Vec (evec.new)]
    (evec.push! v (process.env-cons "K" "v0" (process.env-empty)))
    (let
      [_got : process.ProcessEnvList (evec.get (& v) 0 (process.env-empty))]
      0)))