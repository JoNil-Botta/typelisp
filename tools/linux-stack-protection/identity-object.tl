;; Build this unchanged tool against each compiler source tree for object
;; identity. Source roots under test are supplied separately from its backend.
(import build_run_core as build)
(import compiler_backend as backend)
(import stdlib.vector)
(import (vector.vector String) as roots)
(import sym_i64_env as cfg)
(import stdlib.io)
(import stdlib.byte_buf)
(import stdlib.string)

(define (main) : i64
  (when (not (= (io.arg-count) 7)) (return 2))
  (let
    [search : roots.Vec (roots.new)]
    [link-inputs : build.SourceToolLinkInputs
      (build.source-tool-link-inputs-empty)]
    [target : backend.CompilerBackendTarget
      (if (string.eq (io.arg 1) "windows")
        (backend.CompilerBackendTarget.Windows)
        (backend.CompilerBackendTarget.Linux))]
    (roots.push-ref! (&mut search) (io.arg 5))
    (roots.push-ref! (&mut search) (io.arg 6))
    (match (build.source-tool-emit-object
      (io.arg 2)
      (build.SourceToolProgram.Source search (cfg.sym-i64-empty))
      target
      (string.>int (io.arg 3))
      (backend.CompilerBackendMode.Scalar)
      (& link-inputs))
      [(Ok bytes)
        (io.write-file (io.arg 4) (byte_buf.str-as-bytes (& bytes)))
        0]
      [(Err message)
        (io.eprintln "{}" message)
        1])))