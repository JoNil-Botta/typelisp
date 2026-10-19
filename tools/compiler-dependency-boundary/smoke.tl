;; End-to-end source fixtures use the same native inspector and coordinator as
;; the real gate. Deliberately invalid language inputs live in fixtures.json.
(import boundary_core as boundary)
(import stdlib.io)
(import stdlib.fs)
(import stdlib.json)
(import stdlib.string)
(import stdlib.byte_buf)
(import stdlib.process)

(define (item [items : (& items json.JsonSeq)] [index : i64]) : json.Json
  (clone (array-ref items.slots index)))

(define (text-item [items : (& items json.JsonSeq)] [index : i64]) : String
  (boundary.json-string (item items index)))

(define (directory! [path : (& path str)]) : unit
  (match (fs.try-mkdir-if-missing path)
    [io.OkIoUnit unit]
    [(io.ErrIoUnit error) (boundary.fail (io.error-message error))]))

(define (policy-row [path : String] [role : String]) : json.Json
  (json.JsonArray
    (box
      (json.list-cons
        (json.JsonString (fs.path-normalize (& path)))
        (json.list-cons
          (json.JsonString role)
          (json.list-cons
            (json.JsonString "Explicit test classification.")
            (json.list-empty)))))))

(define (prelude-policy) : json.JsonSeq
  (json.list-cons
    (policy-row "stdlib/runtime.tl" "support")
    (json.list-cons
      (policy-row "stdlib/core_macros.tl" "support")
      (json.list-cons
        (policy-row "stdlib/clone.tl" "support")
        (json.list-cons
          (policy-row "stdlib/comptime.tl" "support")
          (json.list-empty))))))

(define (run-case
  [checker : (& checker str)]
  [inspector : (& inspector str)]
  [work : (& work str)]
  [fixture : json.JsonSeq]) : unit
  (let
    [name : String (text-item (& fixture) 0)]
    [expect : String (text-item (& fixture) 1)]
    [needle : String (text-item (& fixture) 2)]
    [files : json.JsonSeq (boundary.json-array (item (& fixture) 3))]
    [dir : String (fs.path-join work (& name))]
    [root-path : String (fs.path-join (& dir) "root.tl")]
    [root : String (fs.path-normalize (& root-path))]
    [policy-path : String (fs.path-join (& dir) "policy.json")]
    [policy : json.JsonSeq (prelude-policy)]
    [index : i64 0]
    (directory! (& dir))
    (while (< index files.len)
      (let
        [file : json.JsonSeq (boundary.json-array (item (& files) index))]
        [filename : String (text-item (& file) 0)]
        [source : String (text-item (& file) 1)]
        [role : String (text-item (& file) 2)]
        [mode : String (text-item (& file) 3)]
        [path : String (fs.path-join (& dir) (& filename))]
        (boundary.require
          (fs.path-safe-relative? (& filename))
          "unsafe fixture file")
        (if (string.eq (& mode) "write")
          (io.write-file (& path) (byte_buf.str-as-bytes (& source)))
          (boundary.require
            (string.eq (& mode) "missing")
            "unknown fixture file mode"))
        (if (> (string.string-length (& role)) 0)
          (set! policy (json.list-cons (policy-row path role) policy))
          unit)
        (set! index (+ index 1))))
    (let
      [encoded : String (json.stringify (json.JsonArray (box policy)))]
      (io.write-file (& policy-path) (byte_buf.str-as-bytes (& encoded))))
    (match (process.run
      (process.command-with-arg
        (process.command-with-arg
          (process.command
            (string.copy checker)
            (process.args-single (string.copy inspector)))
          root)
        policy-path))
      [(process.OkProcessOutput output)
        (let
          [status : i64 (process.output-status (& output))]
          [passed : bool (string.eq (& expect) "pass")]
          [expected-status : i64
            (if passed
              0
              1)]
          [diagnostic : String
            (if passed
              (string.copy (& output.stdout))
              (string.copy (& output.stderr)))]
          (if (and
            (= status expected-status)
            (string.contains (& diagnostic) (& needle)))
            (io.println "dependency fixture passed: {}" (& name))
            (begin
              (io.eprintln
                "dependency fixture failed: {} (exit {}, expected {})"
                (& name)
                status
                expected-status)
              (io.print-error (process.output-stdout (& output)))
              (io.print-error (process.output-stderr (& output)))
              (boundary.fail "dependency fixture expectation failed"))))]
      [(process.ErrProcessOutput error)
        (boundary.fail (process.error-message error))])))

(define (main) : i64
  (if (= (io.arg-count) 5)
    (let
      [checker : String (io.arg 1)]
      [inspector : String (io.arg 2)]
      [work : String (io.arg 3)]
      [path : String (io.arg 4)]
      [text : String (boundary.read-text (& path))]
      [fixtures : json.JsonSeq
        (boundary.json-array (boundary.parse-json (& text)))]
      [index : i64 0]
      (boundary.require
        (> fixtures.len 0)
        "dependency fixtures must not be empty")
      (directory! (& work))
      (while (< index fixtures.len)
        (begin
          (run-case
            (& checker)
            (& inspector)
            (& work)
            (boundary.json-array (item (& fixtures) index)))
          (set! index (+ index 1))))
      (io.println "dependency boundary source fixtures passed: {}" fixtures.len)
      0)
    (begin
      (io.print-error
        "usage: dependency-smoke CHECKER INSPECTOR WORK FIXTURES.json\n")
      2)))