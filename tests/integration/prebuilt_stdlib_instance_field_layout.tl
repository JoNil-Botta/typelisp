;; Hydrated stdlib structs whose fields are generated-instance types
;; (`svec.Vec`) keep the layout the prebuilt archive was compiled with, so a
;; value an archive function returns fits the caller's storage.
(import stdlib.fs)
(import stdlib.process)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define (make-env) : process.ProcessEnvVec
  (let
    [env : process.ProcessEnvVec (process.env-vec-with-capacity 2)]
    (process.env-vec-append! (&mut env) "A" "1")
    (process.env-vec-append! (&mut env) "B" "2")
    env))

(define (make-paths) : fs.FsStringVector
  (fs.FsStringVector (svec.with-capacity 3)))

(define (main) : i64
  (let
    [env : process.ProcessEnvVec (make-env)]
    [paths : fs.FsStringVector (make-paths)]
    (svec.push-ref! (&mut paths.items) "a")
    (+
      (* 10 (svec.len (& env.names)))
      (* 10 (svec.len (& env.values)))
      (svec.len (& paths.items))
      1)))