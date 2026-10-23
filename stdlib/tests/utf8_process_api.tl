(import stdlib.byte_buf)
(import stdlib.env)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.process)
(import stdlib.string)
(import stdlib.test)

(cfg windows (extern (get-active-code-page) : u32 (:symbol "GetACP")))

(define (assert-code-page) : unit
  (cfg
    windows
    (test.assert-i64-eq
      (cast (get-active-code-page) : i64)
      65001
      "every emitted Windows executable activates its UTF-8 manifest")
    unit))

(define (payload) : String
  "é_日本_😀 é with spaces \\\" end")

(define (child) : i64
  (test.assert-i64-eq (io.arg-count) 4 "Unicode child argv length")
  (cfg
    windows
    (test.assert-true
      (string.contains (io.arg 0) "é_日本_😀.exe")
      "Unicode executable path in argv0")
    unit)
  (test.assert-string-eq (io.arg 2) (payload) "Unicode quoted command argument")
  (match (env.get "TYPELISP_UTF8_é_日本")
    [(EnvSomeString value)
      (test.assert-string-eq
        (& value)
        (payload)
        "Unicode environment name and value")]
    [_ (test.assert-true false "child Unicode environment is present")])
  (let
    [contents : String (byte_buf.to-string (io.read-file (io.arg 3)))]
    [cwd : String (fs.current-dir)]
    (test.assert-string-eq
      (& contents)
      (payload)
      "Unicode file path and file contents")
    (test.assert-true
      (string.contains (& cwd) "typelisp UTF8 é_日本_😀")
      "Unicode child working directory"))
  (io.print-format "{}" (payload))
  42)

(define (main) : i64
  (assert-code-page)
  (when
    (> (io.arg-count) 1)
    (test.assert-string-eq (io.arg 1) "--utf8-child" "child mode marker")
    (return (child)))
  (let
    [directory : String
      (match (fs.try-create-temp-dir "typelisp UTF8 é_日本_😀")
        [(OkIoString path) path]
        [(ErrIoString error) (io.panic (io.error-message error))])]
    [path : String (fs.path-join (& directory) "é_日本_😀.txt")]
    [contents : String (payload)]
    [original : String (io.arg 0)]
    [absolute : String
      (if (fs.path-absolute? (& original))
        (string.copy (& original))
        (fs.path-join (& (fs.current-dir)) (& original)))]
    [executable : String
      (cfg
        windows
        (fs.path-join (& directory) "é_日本_😀.exe")
        (string.copy (& absolute)))]
    (io.write-file (& path) (byte_buf.str-as-bytes (& contents)))
    (cfg
      windows
      (let
        [image : byte_buf.ByteBuf (io.read-file (string.copy (& absolute)))]
        (io.write-file (& executable) (byte_buf.as-bytes (& image))))
      unit)
    (match (process.output
      (process.command-with-cwd
        (process.command-with-env
          (process.command
            (string.copy (& executable))
            (process.args-cons
              "--utf8-child"
              (process.args-cons
                (payload)
                (process.args-single (string.copy (& path))))))
          "TYPELISP_UTF8_é_日本"
          (payload))
        (string.copy (& directory))))
      [(OkProcessOutput output)
        (test.assert-i64-eq
          (process.output-status output)
          42
          "Unicode child process status")
        (test.assert-string-eq
          (process.output-stdout output)
          (payload)
          "Unicode child stdout bytes")
        (test.assert-string-eq
          (process.output-stderr output)
          ""
          "Unicode child stderr")]
      [(ErrProcessOutput error) (io.panic (process.error-message error))])
    (test.assert-i64-eq
      (fs.remove-file-status (& path))
      0
      "remove own Unicode file")
    (cfg
      windows
      (test.assert-i64-eq
        (fs.remove-file-status (& executable))
        0
        "remove own Unicode child copy")
      unit)
    (test.assert-i64-eq
      (fs.remove-dir-status (& directory))
      0
      "remove own Unicode directory"))
  42)