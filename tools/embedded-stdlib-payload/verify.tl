;; verify.tl - Prove every generated payload decodes to its exact source bytes.
(import compiler_embedded_stdlib as embedded)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(define (embedded-stdlib-verify-line-end [manifest : String] [start : i64]) : i64
  (let
    [index : i64 start]
    [length : i64 (string.string-length manifest)]
    (begin
      (while (and (< index length) (!= (string.string-ref manifest index) '\n'))
        (set! index (+ index 1)))
      index)))

(define (embedded-stdlib-verify-trim-cr [line : String]) : String
  (let
    [length : i64 (string.string-length line)]
    (if (and (> length 0) (= (string.string-ref line (- length 1)) '\r'))
      (string.substring line 0 (- length 1))
      line)))

(define (embedded-stdlib-verify-one [suffix : String]) : bool
  (let
    [expected : String (io.read-file (str_cat.str-cat "stdlib/" suffix))]
    (match (embedded.compiler-embedded-stdlib-lookup suffix)
      [(embedded.CompilerEmbeddedStdlibSomeSource actual)
        (string.eq expected actual)]
      [(embedded.CompilerEmbeddedStdlibNoSource) false])))

(define (embedded-stdlib-verify-lines [manifest : String] [start : i64]) : bool
  (if (>= start (string.string-length manifest))
    true
    (let
      [end : i64 (embedded-stdlib-verify-line-end manifest start)]
      [line : String
        (embedded-stdlib-verify-trim-cr
          (string.substring manifest start (- end start)))]
      [next : i64
        (if (< end (string.string-length manifest))
          (+ end 1)
          end)]
      (if (and
        (or (= (string.string-length line) 0) (embedded-stdlib-verify-one line))
        (embedded-stdlib-verify-lines manifest next))
        true
        (begin
          (when
            (> (string.string-length line) 0)
            (io.print-error
              (str_cat.str-cat "embedded stdlib exact-source mismatch: " line)))
          false)))))

(define (main) : i64
  (if (embedded-stdlib-verify-lines
    (io.read-file "tools/embedded-stdlib-payload/modules.txt")
    0)
    42
    1))