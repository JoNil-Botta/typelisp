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

(define (compile-cli-windows-batch-entry-at?
  [entries : (& entries cli_svec.Vec)]
  [index : i64]
  [input-path : String]
  [object-path : String]
  [assembly-path : String]
  [mode : String]) : bool
  (let
    [slot : i64 (* index 4)]
    (and
      (string.eq (cli_svec.get entries slot "") input-path)
      (string.eq (cli_svec.get entries (+ slot 1) "") object-path)
      (string.eq (cli_svec.get entries (+ slot 2) "") assembly-path)
      (string.eq (cli_svec.get entries (+ slot 3) "") mode))))

(define (compile-cli-windows-batch-vector-contract-ok?) : bool
  (let
    [source : String
      "auto.tl|auto.obj|auto.s\r\nforced.tl|forced.obj|forced.s|force-assembly"]
    [entries : cli_svec.Vec (cli_svec.new)]
    [status : i64
      (compile-cli-windows-batch-parse-entries-into!
        source
        0
        1
        (string.string-length source)
        (&mut entries))]
    [results : cli_svec.Vec (cli_svec.new)]
    (begin
      (cli_svec.push (&mut results) "auto.tl")
      (cli_svec.push (&mut results) "coff-object")
      (cli_svec.push (&mut results) "auto.obj")
      (cli_svec.push (&mut results) "none")
      (cli_svec.push (&mut results) "forced.tl")
      (cli_svec.push (&mut results) "assembly")
      (cli_svec.push (&mut results) "forced.s")
      (cli_svec.push (&mut results) "forced-assembly")
      (and
        (= status 0)
        (= (cli_svec.len (& entries)) 8)
        (compile-cli-windows-batch-entry-at?
          (& entries)
          0
          "auto.tl"
          "auto.obj"
          "auto.s"
          "auto")
        (compile-cli-windows-batch-entry-at?
          (& entries)
          1
          "forced.tl"
          "forced.obj"
          "forced.s"
          "force-assembly")
        (string.eq
          (compile-cli-windows-batch-result-plan (& results))
          "auto.tl|coff-object|auto.obj|none\nforced.tl|assembly|forced.s|forced-assembly\n")))))

(test
  compile-cli-batch-entry-generated-vector-growth-order
  (unless
    (compile-cli-batch-vector-growth-order-ok?)
    (panic "compile: batch entry generated vector growth/order smoke failed")))

(test
  compile-cli-windows-batch-plan-contract
  (unless
    (compile-cli-windows-batch-vector-contract-ok?)
    (panic "compile: Windows batch plan contract smoke failed")))