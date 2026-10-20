;; Deliberately synthetic inspector for the coordinator's protocol failure tests.
;; Source-graph tests always use inspect.tl instead.
(import compiler_dependency_trace as trace)
(import boundary_core as boundary)
(import stdlib.io)
(import stdlib.string)
(import stdlib.byte_buf)

(define (main) : i64
  (let
    [root : String (io.arg 1)]
    [facts : String (boundary.read-text (& root))]
    (trace.compiler-dependency-trace "source" "stdlib/runtime.tl")
    (trace.compiler-dependency-trace "source" "stdlib/core_macros.tl")
    (trace.compiler-dependency-trace "source" "stdlib/clone.tl")
    (trace.compiler-dependency-trace "source" "stdlib/comptime.tl")
    (trace.compiler-dependency-trace "source" root)
    (if (string.eq (& facts) "oversized\n")
      (io.print
        "{}"
        (byte_buf.to-string (byte_buf.from-array (__tl_make-array u8 8388609))))
      (io.print "{}" facts))
    0))