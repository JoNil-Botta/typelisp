;; Raw-byte proof for the zero-template newline forms (#6985). The integration
;; harness drops carriage returns from Windows streams before comparing them,
;; so a manifest row cannot tell LF from CRLF there. This program runs itself
;; as a child, captures both streams through `stdlib.process`, and compares the
;; exact bytes: one 0x0a per empty form, no 0x0d, nothing on the other stream.
(import stdlib.io)
(import stdlib.process)
(import stdlib.string)

(define (child-stdout) : i64
  (begin
    (io.println)
    (io.print "o")
    (io.println)
    (io.println "{}" (cast 1 : i64))
    (io.println)
    0))

(define (child-stderr) : i64
  (begin
    (io.eprintln)
    (io.eprint "e")
    (io.eprintln)
    (io.eprintln "{}" (cast 2 : i64))
    (io.eprintln)
    0))

(define (has-carriage-return? [text : (& text str)]) : bool
  (>= (string.index-of-byte text 0 (cast 13 : u8)) 0))

(define (child-streams-match?
  [mode : String]
  [want-stdout : String]
  [want-stderr : String]) : bool
  (match (process.output
    (process.command (io.arg 0) (process.args-single mode)))
    [(process.OkProcessOutput output)
      (let
        [stdout : String (process.output-stdout output)]
        [stderr : String (process.output-stderr output)]
        (and
          (= (process.output-status output) 0)
          (not (has-carriage-return? (& stdout)))
          (not (has-carriage-return? (& stderr)))
          (=
            (string.string-length (& stdout))
            (string.string-length (& want-stdout)))
          (=
            (string.string-length (& stderr))
            (string.string-length (& want-stderr)))
          (string.eq (& stdout) (& want-stdout))
          (string.eq (& stderr) (& want-stderr))))]
    [(process.ErrProcessOutput _) false]))

(define (main) : i64
  (if (> (io.arg-count) 1)
    (if (string.eq (io.arg 1) "child-stdout")
      (child-stdout)
      (child-stderr))
    (if (and
      (child-streams-match? "child-stdout" "\no\n1\n\n" "")
      (child-streams-match? "child-stderr" "" "\ne\n2\n\n"))
      42
      1)))