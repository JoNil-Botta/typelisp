;; #8681: a prebuilt stdlib function that stores an allocation through its
;; argument keeps that summary in stdlib.tli, so calling it inside a scoped
;; arena on outer storage is rejected exactly as for the source stdlib.
(import stdlib.process)

(define (main) : i64
  (let
    [env : process.ProcessEnvVec (process.env-vec-new)]
    (with-arena phase (process.env-vec-append! (&mut env) "A" "1"))
    0))