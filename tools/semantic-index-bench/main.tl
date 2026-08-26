;; main.tl - Build and release one complete owned semantic source index.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_semantic_index as semantic_index)

(define (semantic-index-bench-run
  [path : String]
  [stdlib-root : String]
  [source-root : String]) : i64
  (let
    [source : String (byte_buf.to-string (io.read-file path))]
    [roots : svec.Vec (svec.new)]
    (begin
      (svec.push-ref! (&mut roots) stdlib-root)
      (svec.push-ref! (&mut roots) source-root)
      (match (semantic_index.compiler-check-source-index-with-roots
        path
        source
        roots)
        [(semantic_index.ResultCompilerCheckWithSemanticIndex.Ok _ index)
          (let
            [record-count : i64
              (semantic_index.compiler-semantic-source-index-len (& index))]
            (begin
              (semantic_index.compiler-semantic-source-index-release!
                (&mut index))
              (io.println "semantic_record_count={}" record-count)
              0))]
        [(semantic_index.ResultCompilerCheckWithSemanticIndex.Partial _ index)
          (begin
            (semantic_index.compiler-semantic-source-index-release!
              (&mut index))
            (io.print-error
              "semantic-index-bench: workload produced a partial index\n")
            1)]
        [(semantic_index.ResultCompilerCheckWithSemanticIndex.Err _)
          (begin
            (io.print-error
              "semantic-index-bench: workload failed before index construction\n")
            1)]))))

(define (main) : i64
  (if (= (io.arg-count) 4)
    (semantic-index-bench-run (io.arg 1) (io.arg 2) (io.arg 3))
    (begin
      (io.print-error
        "usage: semantic-index-bench <input.tl> <stdlib-root> <source-root>\n")
      2)))