;; compile_cli_batch_vector_smoke.tl - Batch-entry generated-vector regression.
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import "../compile_cli_core.tl")

(define (compile-cli-batch-vector-entry-at?
  [entries : (& entries cli_svec.Vec)]
  [index : i64]
  [input-path : String]
  [output-path : String]) : bool
  (let
    [slot : i64 (* index 2)]
    (and
      (string.eq (cli_svec.get entries slot "") input-path)
      (string.eq (cli_svec.get entries (+ slot 1) "") output-path))))

(define (compile-cli-batch-vector-growth-order-ok?) : bool
  (let
    [source : String
      "a.tl|a.s\n\nb.tl|b.s\r\nc.tl|c.s\nd.tl|d.s\r\ne.tl|e.s\nf.tl|f.s"]
    ;; Each parsed batch entry occupies an adjacent input/output pair.
    [entries : cli_svec.Vec (cli_svec.new)]
    [status : i64
      (compile-cli-batch-parse-entries-into!
        source
        0
        1
        (string.string-length source)
        (&mut entries))]
    [empty : cli_svec.Vec (cli_svec.new)]
    [empty-status : i64
      (compile-cli-batch-parse-entries-into! "" 0 1 0 (&mut empty))]
    (and
      (= status 0)
      (= (cli_svec.len (& entries)) 12)
      (>= (cli_svec.capacity (& entries)) 12)
      (compile-cli-batch-vector-entry-at? (& entries) 0 "a.tl" "a.s")
      (compile-cli-batch-vector-entry-at? (& entries) 1 "b.tl" "b.s")
      (compile-cli-batch-vector-entry-at? (& entries) 2 "c.tl" "c.s")
      (compile-cli-batch-vector-entry-at? (& entries) 3 "d.tl" "d.s")
      (compile-cli-batch-vector-entry-at? (& entries) 4 "e.tl" "e.s")
      (compile-cli-batch-vector-entry-at? (& entries) 5 "f.tl" "f.s")
      (= empty-status 0)
      (= (cli_svec.len (& empty)) 0))))

(test
  compile-cli-batch-entry-generated-vector-growth-order
  (unless
    (compile-cli-batch-vector-growth-order-ok?)
    (panic "compile: batch entry generated vector growth/order smoke failed")))