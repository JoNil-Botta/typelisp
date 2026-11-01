(import stdlib.byte_buf_core)
(import stdlib.io)
(import stdlib.fs)
(import stdlib.process)
(import stdlib.process_runtime)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.test)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define (goldens) : (Array String 42)
  (array
    ""
    "\"\""
    ""
    "\"\""
    "plain"
    "plain"
    "a b"
    "\"a b\""
    "a\tb"
    "\"a\tb\""
    "\""
    "\"\\\"\""
    "\\"
    "\\"
    "a\\\"b"
    "\"a\\\\\\\"b\""
    "a\\\\\"b"
    "\"a\\\\\\\\\\\"b\""
    "a \\"
    "\"a \\\\\""
    "a \\\\"
    "\"a \\\\\\\\\""
    "a\\b"
    "a\\b"
    " a"
    "\" a\""
    "a "
    "\"a \""
    "\t"
    "\"\t\""
    "\n"
    "\n"
    "\"\""
    "\"\\\"\\\"\""
    "a\"b\"c"
    "\"a\\\"b\\\"c\""
    "é_日本_😀"
    "é_日本_😀"
    "é"
    "é"
    "with spaces \\\" end"
    "\"with spaces \\\\\\\" end\""))

(define (repeat-a [count : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity count)]
    [i : i64 0]
    (while (< i count)
      (byte_buf_core.byte-buf-builder-push (&mut out) (cast 97 : u8))
      (set! i (+ i 1)))
    (byte_buf_core.byte-buf-builder-to-string (& out))))

(define (check-goldens) : unit
  (let
    [rows : (Array String 42) (goldens)]
    [i : i64 0]
    (while (< i (array-length rows))
      (let
        [raw : String (string.copy (& (array-ref rows i)))]
        [expected : String (string.copy (& (array-ref rows (+ i 1))))]
        [command : process.ProcessCommand
          (process.command "tool" (process.args-single (string.copy (& raw))))]
        [actual : String
          (process_runtime.windows-cmdline (process.runtime-command command))]
        [line : String (str_cat.str-cat "tool " (string.copy (& expected)))]
        (test.assert-string-eq (& actual) (& line) "Microsoft C argv encoding")
        (test.assert-i64-eq
          (process_runtime.windows-arg-encoded-size (& raw) false)
          (string.string-length (& expected))
          "encoded-size agrees with exact golden bytes"))
      (set! i (+ i 2))))
  (let
    [fit : process.ProcessCommand
      (process.command "x" (process.args-single (repeat-a 32764)))]
    [large : process.ProcessCommand
      (process.command "x" (process.args-single (repeat-a 32765)))]
    [bad-path : process.ProcessCommand
      (process.command "bad\"path" (process.args-empty))]
    [fit-raw : process_runtime.ProcessRuntimeCommand
      (process.runtime-command fit)]
    [large-raw : process_runtime.ProcessRuntimeCommand
      (process.runtime-command large)]
    [bad-raw : process_runtime.ProcessRuntimeCommand
      (process.runtime-command bad-path)]
    [fit-error : process_runtime.ProcessRuntimeMaybeString
      (process_runtime.windows-cmdline-error (& fit-raw))]
    [large-error : process_runtime.ProcessRuntimeMaybeString
      (process_runtime.windows-cmdline-error (& large-raw))]
    [bad-error : process_runtime.ProcessRuntimeMaybeString
      (process_runtime.windows-cmdline-error (& bad-raw))]
    (test.assert-true (not fit-error.present) "32767 bytes including NUL fits")
    (test.assert-true large-error.present "one byte beyond Windows cap rejects")
    (test.assert-string-eq
      (& large-error.value)
      "process: Windows command line exceeds 32767-byte limit"
      "size diagnostic")
    (test.assert-string-eq
      (& bad-error.value)
      "process: Windows executable path contains quote"
      "program-name diagnostic")
    (cfg
      windows
      (begin
        (match (process.output large)
          [(ErrProcessOutput error)
            (test.assert-true
              (process.error-invalid-command? error)
              "capture rejects before spawn")]
          [_ (test.assert-true false "oversized capture must not start")])
        (match (process.inherit bad-path)
          [(ErrProcessOutput error)
            (test.assert-true
              (process.error-invalid-command? error)
              "inherit rejects before spawn")]
          [_ (test.assert-true false "quoted program path must not start")]))
      unit)))

(define (expected-output) : String
  (let
    [rows : (Array String 42) (goldens)]
    [i : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    (while (< i (array-length rows))
      (let
        [value : String (string.copy (& (array-ref rows i)))]
        (text_buf.append-int! out (string.string-length (& value)))
        (text_buf.append! out ":")
        (text_buf.append! out value)
        (text_buf.append! out "\n"))
      (set! i (+ i 2)))
    (text_buf.render out)))

(define (child [mode : String]) : i64
  (if (string.eq mode "--argv-large")
    (begin
      (test.assert-i64-eq
        (io.arg-count)
        4097
        "all4096 public arguments reach startup")
      (let
        [i : i64 2]
        (while (< i (io.arg-count))
          (test.assert-string-eq (io.arg i) "x" "large argument vector item")
          (set! i (+ i 1)))))
    (let
      [rows : (Array String 42) (goldens)]
      [i : i64 0]
      (test.assert-i64-eq
        (io.arg-count)
        (+ 2 (/ (array-length rows) 2))
        "exact argv cardinality")
      (while (< i (array-length rows))
        (let
          [expected : String (string.copy (& (array-ref rows i)))]
          (test.assert-string-eq
            (io.arg (+ 2 (/ i 2)))
            (& expected)
            "native child argument bytes"))
        (set! i (+ i 2)))
      (when
        (string.eq mode "--argv-capture")
        (io.print-format "{}" (expected-output)))))
  42)

(define (main) : i64
  (when (> (io.arg-count) 1) (return (child (io.arg 1))))
  (check-goldens)
  (let
    [rows : (Array String 42) (goldens)]
    [exe : String (io.arg 0)]
    [absolute : String
      (if (fs.path-absolute? (& exe))
        (string.copy (& exe))
        (fs.path-join (& (fs.current-dir)) (& exe)))]
    [args : svec.Vec (svec.with-capacity 32)]
    [i : i64 0]
    (svec.push-ref! (&mut args) "--argv-capture")
    (while (< i (array-length rows))
      (svec.push-ref! (&mut args) (string.copy (& (array-ref rows i))))
      (set! i (+ i 2)))
    (match (process.output
      (process.command-from-argv-vec (string.copy (& absolute)) (& args)))
      [(OkProcessOutput output)
        (when
          (not (= (process.output-status output) 42))
          (io.print-error (process.output-stderr output)))
        (test.assert-i64-eq
          (process.output-status output)
          42
          "native capture argv roundtrip")
        (test.assert-string-eq
          (process.output-stdout output)
          (expected-output)
          "length-framed captured bytes")
        (test.assert-string-eq
          (process.output-stderr output)
          ""
          "capture stderr")]
      [(ErrProcessOutput error) (io.panic (process.error-message error))])
    (let
      [inherited : svec.Vec (svec.with-capacity 32)]
      [j : i64 0]
      (svec.push-ref! (&mut inherited) "--argv-inherit")
      (while (< j (array-length rows))
        (svec.push-ref! (&mut inherited) (string.copy (& (array-ref rows j))))
        (set! j (+ j 2)))
      (match (process.inherit
        (process.command-from-argv-vec (string.copy (& absolute)) (& inherited)))
        [(OkProcessOutput output)
          (test.assert-i64-eq
            (process.output-status output)
            42
            "native inherited argv roundtrip")]
        [(ErrProcessOutput error) (io.panic (process.error-message error))]))
    (let
      [large : svec.Vec (svec.with-capacity 4096)]
      [j : i64 1]
      (svec.push-ref! (&mut large) "--argv-large")
      (while (< j 4096)
        (svec.push-ref! (&mut large) "x")
        (set! j (+ j 1)))
      (match (process.output
        (process.command-from-argv-vec (string.copy (& absolute)) (& large)))
        [(OkProcessOutput output)
          (test.assert-i64-eq
            (process.output-status output)
            42
            "maximum public argv count")]
        [(ErrProcessOutput error) (io.panic (process.error-message error))])))
  42)