(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.string)

(define (format-ok? [result : format.FormatResult]) : bool
  (match result
    [(FormatOk) true]
    [(FormatErr _) false]))

(define (close-ok? [result : io.ResultIoUnit]) : bool
  (match result
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

(define (cleanup [path : (& path str)]) : bool
  (match (fs.try-remove-file-if-exists path)
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

(define (main) : i64
  (let
    [path : String ".typelisp-format-file-writer-test.tmp"]
    (begin
      (cleanup (& path))
      (match (io.file-open (& path) (OpenWriteTruncate))
        [(OkIoFile handle)
          (let
            [write-result : format.FormatResult
              (format.writeln! handle "file={}" (cast 42 : i64))]
            [close-result : io.ResultIoUnit (io.file-close handle)]
            [closed-write-result : format.FormatResult
              (format.write! handle "after-close")]
            [contents : io.ResultIoBytes (io.try-read-file (& path))]
            [contents-ok : bool
              (match contents
                [(OkIoBytes bytes)
                  (let
                    [text : String (byte_buf.to-string bytes)]
                    (string.eq (& text) "file=42\n"))]
                [(ErrIoBytes _) false])]
            [cleanup-ok : bool (cleanup (& path))]
            (if (and
              (format-ok? write-result)
              (close-ok? close-result)
              (not (format-ok? closed-write-result))
              contents-ok
              cleanup-ok)
              42
              1))]
        [(ErrIoFile _) 1]))))