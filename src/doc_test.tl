;; doc_test.tl - Self-hosted TypeLisp doctest extraction + runner.
;;
;; Extraction pulls TypeLisp fenced examples from public doc comments, mirroring
;; the public doc scanning policy: module docs (`;#`) are scanned as standalone
;; doc blocks, item docs (`;:`) attach only to the next supported top-level
;; declaration, blank physical lines are tolerated between doc comment lines,
;; ordinary comments are ignored, and unattached item docs are dropped.
;;
;; The runner checks extracted examples through the in-memory
;; virtual-source loader/typechecker (`compiler-check-source`), and runs
;; `typelisp run` / `tl run` examples through the self-hosted build/run
;; path where the target supports process execution. Each failure records the
;; source path, the fence's source line, the example index, and the rendered
;; diagnostic when one is available.
(import stdlib.io)
(import stdlib.process)
(import stdlib.vector)
(import (vector.vector String) as doc_svec)
(import "compiler_check_core.tl")
(import "compiler_load.tl")
(import "build_run_core.tl")
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.option)
(import (option.option i64) as option_i64)
(import compiler_builtin_ids as cbi)
(import sym_i64_env)

(defenum DocTestExpectation
  (Pass)
  (Error)
  (Run i64 String String))

(defenum DocTestFenceMode
  (Check DocTestExpectation)
  (Run))

(defenum DocTestLine
  (Line i64 String))

(import (vector.vector DocTestLine core) as doc_line_vec)

(defenum DocTestExample
  (Example i64 i64 DocTestExpectation String))

(import (vector.vector DocTestExample core) as doc_example_vec)

(defenum DocTestError
  (Error i64 String))

(import (vector.vector DocTestError core) as doc_error_vec)

(defenum DocTestExtraction
  (Extraction doc_example_vec.Vec doc_error_vec.Vec))

(defenum DocTestMaybeString
  (No)
  (Some String))

(defenum DocTestFenceInfo
  (Ignore)
  (TypeLisp DocTestFenceMode)
  (Malformed DocTestError))

(defenum DocTestCodeCollect
  (Collect i64 String doc_line_vec.Vec bool))

(defenum DocTestMaybeOutput
  (No String)
  (Some String))

(defenum DocTestRunMetadata
  (Metadata bool i64 bool String bool String doc_error_vec.Vec))

(defenum DocTestRunMetadataParse
  (Ok DocTestExpectation)
  (Err doc_error_vec.Vec))

(defenum DocTestScanState
  (State doc_example_vec.Vec doc_error_vec.Vec i64))

(define (doc-test-example-list-empty) : doc_example_vec.Vec
  (doc_example_vec.new))

(define (doc-test-example-list-count [examples : doc_example_vec.Vec]) : i64
  (doc_example_vec.len (& examples)))

(define (doc-test-example-list-ref
  [examples : doc_example_vec.Vec]
  [index : i64]) : DocTestExample
  (doc_example_vec.get
    (& examples)
    index
    (DocTestExample.Example 0 0 (DocTestExpectation.Pass) "")))

(define (doc-test-example-list-append
  [examples : doc_example_vec.Vec]
  [example : DocTestExample]) : doc_example_vec.Vec
  (begin
    (doc_example_vec.push (&mut examples) example)
    examples))

(define (doc-test-error-list-empty) : doc_error_vec.Vec
  (doc_error_vec.new))

(define (doc-test-error-list-count [errors : doc_error_vec.Vec]) : i64
  (doc_error_vec.len (& errors)))

(define (doc-test-error-list-ref [errors : doc_error_vec.Vec] [index : i64]) : DocTestError
  (doc_error_vec.get (& errors) index (DocTestError.Error 0 "")))

(define (doc-test-error-list-append
  [errors : doc_error_vec.Vec]
  [err : DocTestError]) : doc_error_vec.Vec
  (begin
    (doc_error_vec.push (&mut errors) err)
    errors))

(define (doc-test-error-list-append-all-from
  [errors : doc_error_vec.Vec]
  [more : doc_error_vec.Vec]
  [index : i64]) : doc_error_vec.Vec
  (if (>= index (doc-test-error-list-count more))
    errors
    (doc-test-error-list-append-all-from
      (doc-test-error-list-append errors (doc-test-error-list-ref more index))
      more
      (+ index 1))))

(define (doc-test-error-list-append-all
  [errors : doc_error_vec.Vec]
  [more : doc_error_vec.Vec]) : doc_error_vec.Vec
  (doc-test-error-list-append-all-from errors more 0))

(define (doc-test-line-number [line : DocTestLine]) : i64
  (match line
    [(DocTestLine.Line line-number _) line-number]))

(define (doc-test-line-text [line : DocTestLine]) : String
  (match line
    [(DocTestLine.Line _ text) text]))

(define (doc-test-example-index [example : DocTestExample]) : i64
  (match example
    [(DocTestExample.Example index _ _ _) index]))

(define (doc-test-example-source-line [example : DocTestExample]) : i64
  (match example
    [(DocTestExample.Example _ source-line _ _) source-line]))

(define (doc-test-example-expectation [example : DocTestExample]) : DocTestExpectation
  (match example
    [(DocTestExample.Example _ _ expectation _) expectation]))

(define (doc-test-example-code [example : DocTestExample]) : String
  (match example
    [(DocTestExample.Example _ _ _ code) code]))

(define (doc-test-error-line [err : DocTestError]) : i64
  (match err
    [(DocTestError.Error line-number _) line-number]))

(define (doc-test-error-message [err : DocTestError]) : String
  (match err
    [(DocTestError.Error _ message) message]))

(define (doc-test-expectation-error? [expectation : DocTestExpectation]) : bool
  (match expectation
    [(DocTestExpectation.Pass) false]
    [(DocTestExpectation.Error) true]
    [(DocTestExpectation.Run _ _ _) false]))

(define (doc-test-expectation-run? [expectation : DocTestExpectation]) : bool
  (match expectation
    [(DocTestExpectation.Run _ _ _) true]
    [_ false]))

(define (doc-test-expectation-run-exit [expectation : DocTestExpectation]) : i64
  (match expectation
    [(DocTestExpectation.Run expected-exit _ _) expected-exit]
    [_ -1]))

(define (doc-test-expectation-run-stdout [expectation : DocTestExpectation]) : String
  (match expectation
    [(DocTestExpectation.Run _ expected-stdout _) expected-stdout]
    [_ ""]))

(define (doc-test-expectation-run-stderr [expectation : DocTestExpectation]) : String
  (match expectation
    [(DocTestExpectation.Run _ _ expected-stderr) expected-stderr]
    [_ ""]))

(define (doc-test-space? [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

(define (doc-test-inline-space? [c : char]) : bool
  (or (= c ' ') (= c '\t')))

(define (doc-test-newline? [c : char]) : bool
  (or (= c '\n') (= c '\r')))

(define (doc-test-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (begin
            (while ok
              (if (< i prefix-len)
                (if (=
                  (string.string-ref text (+ start i))
                  (string.string-ref prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (doc-test-string-prefix? [text : String] [prefix : String]) : bool
  (doc-test-string-prefix-at? text prefix 0))

(define (doc-test-string-contains? [text : String] [needle : String]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [needle-len : i64 (string.string-length needle)]
    (if (= needle-len 0)
      true
      (let
        [i : i64 0]
        [found : bool false]
        [done : bool false]
        (begin
          (while (not done)
            (if (<= (+ i needle-len) text-len)
              (if (doc-test-string-prefix-at? text needle i)
                (begin
                  (set! found true)
                  (set! done true))
                (set! i (+ i 1)))
              (set! done true)))
          found)))))

(define (doc-test-trim-left [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [start : i64 0]
    [done : bool false]
    (begin
      (while (< i n)
        (if done
          (set! i n)
          (if (doc-test-inline-space? (string.string-ref text i))
            (begin
              (set! start (+ i 1))
              (set! i (+ i 1)))
            (set! done true))))
      (string.substring text start (- n start)))))

(define (doc-test-trim-right [text : String]) : String
  (let
    [end : i64 (string.string-length text)]
    [keep : bool true]
    (begin
      (while keep
        (if (> end 0)
          (if (doc-test-inline-space? (string.string-ref text (- end 1)))
            (set! end (- end 1))
            (set! keep false))
          (set! keep false)))
      (string.substring text 0 end))))

(define (doc-test-trim [text : String]) : String
  (doc-test-trim-right (doc-test-trim-left text)))

(define (doc-test-char-code [c : char]) : i64
  (cast c : i64))

(define (doc-test-decimal-digit-value [c : char]) : i64
  (let
    [code : i64 (doc-test-char-code c)]
    (if (and (>= code 48) (<= code 57))
      (- code 48)
      -1)))

(define (doc-test-parse-i64 [text : String]) : option_i64.Option
  (let
    [trimmed : String (doc-test-trim text)]
    [n : i64 (string.string-length trimmed)]
    (if (= n 0)
      option_i64.None
      (let
        [i : i64 0]
        [sign : i64 1]
        [value : i64 0]
        [ok : bool true]
        (begin
          (if (= (string.string-ref trimmed 0) '-')
            (begin
              (set! sign -1)
              (set! i 1))
            unit)
          (if (= i n)
            (set! ok false)
            unit)
          (while (and ok (< i n))
            (let
              [digit : i64
                (doc-test-decimal-digit-value (string.string-ref trimmed i))]
              (if (< digit 0)
                (set! ok false)
                (begin
                  (set! value (+ (* value 10) digit))
                  (set! i (+ i 1))))))
          (if ok
            (option_i64.Some (* sign value))
            option_i64.None))))))

(define (doc-test-decode-output-literal [text : String]) : DocTestMaybeOutput
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [out : String ""]
    [message : String ""]
    (begin
      (while (and (= (string.string-length message) 0) (< i n))
        (let
          [c : char (string.string-ref text i)]
          (if (= c '\\')
            (if (>= (+ i 1) n)
              (set! message "trailing escape in doctest output metadata")
              (let
                [esc : char (string.string-ref text (+ i 1))]
                (cond
                  [(= esc 'n')
                    (begin
                      (set! out (string.concat3 out "\n" ""))
                      (set! i (+ i 2)))]
                  [(= esc 't')
                    (begin
                      (set! out (string.concat3 out "\t" ""))
                      (set! i (+ i 2)))]
                  [(= esc 'r')
                    (begin
                      (set! out (string.concat3 out "\r" ""))
                      (set! i (+ i 2)))]
                  [(= esc '\\')
                    (begin
                      (set! out (string.concat3 out "\\" ""))
                      (set! i (+ i 2)))]
                  [else
                    (set!
                      message
                      (str_cat.str-cat
                        "unsupported doctest output escape `\\"
                        (string.substring text (+ i 1) 1)
                        "`"))])))
            (begin
              (set! out (string.concat3 out (string.substring text i 1) ""))
              (set! i (+ i 1))))))
      (if (= (string.string-length message) 0)
        (DocTestMaybeOutput.Some out)
        (DocTestMaybeOutput.No message)))))

(define (doc-test-parse-output-spec [text : String]) : DocTestMaybeOutput
  (let
    [trimmed : String (doc-test-trim text)]
    (if (string.eq trimmed "-")
      (DocTestMaybeOutput.Some "")
      (if (doc-test-string-prefix? trimmed "literal:")
        (doc-test-decode-output-literal
          (string.substring trimmed 8 (- (string.string-length trimmed) 8)))
        (DocTestMaybeOutput.No
          "doctest output metadata must be '-' or 'literal:<escaped text>'")))))

(define (doc-test-string-blank? [text : String]) : bool
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [blank : bool true]
    (begin
      (while (< i n)
        (if blank
          (if (doc-test-space? (string.string-ref text i))
            (set! i (+ i 1))
            (begin
              (set! blank false)
              (set! i n)))
          (set! i n)))
      blank)))

(define (doc-test-word-end [text : String] [start : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (if (doc-test-space? (string.string-ref text i))
            (set! keep false)
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (doc-test-line-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (if (doc-test-newline? (string.string-ref src i))
            (set! keep false)
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (doc-test-next-line-start [src : String] [line-end : i64] [n : i64]) : i64
  (begin
    (unless (< line-end n) (return line-end))
    (let
      [c : char (string.string-ref src line-end)]
      (begin
        (unless (= c '\r') (return (+ line-end 1)))
        (unless (< (+ line-end 1) n) (return (+ line-end 1)))
        (if (= (string.string-ref src (+ line-end 1)) '\n')
          (+ line-end 2)
          (+ line-end 1))))))

(define (doc-test-doc-comment-body-with-prefix
  [line : String]
  [prefix : String]) : DocTestMaybeString
  (let
    [trimmed : String (doc-test-trim-left line)]
    (if (doc-test-string-prefix? trimmed prefix)
      (let
        [prefix-len : i64 (string.string-length prefix)]
        [trimmed-len : i64 (string.string-length trimmed)]
        [body : String
          (string.substring trimmed prefix-len (- trimmed-len prefix-len))]
        (if (> (string.string-length body) 0)
          (if (= (string.string-ref body 0) ' ')
            (DocTestMaybeString.Some
              (string.substring body 1 (- (string.string-length body) 1)))
            (DocTestMaybeString.Some body))
          (DocTestMaybeString.Some body)))
      (DocTestMaybeString.No))))

(define (doc-test-module-doc-comment-body [line : String]) : DocTestMaybeString
  (doc-test-doc-comment-body-with-prefix line ";#"))

(define (doc-test-item-doc-comment-body [line : String]) : DocTestMaybeString
  (doc-test-doc-comment-body-with-prefix line ";:"))

(define (doc-test-starts-with-form-head? [text : String] [head : String]) : bool
  (if (doc-test-string-prefix? text head)
    (let
      [head-len : i64 (string.string-length head)]
      [text-len : i64 (string.string-length text)]
      (if (= head-len text-len)
        true
        (let
          [c : char (string.string-ref text head-len)]
          (or (doc-test-space? c) (= c '(') (= c ')')))))
    false))

(define (doc-test-supported-item-declaration? [line : String]) : bool
  (let
    [trimmed : String (doc-test-trim-left line)]
    (if (> (string.string-length trimmed) 0)
      (if (= (string.string-ref trimmed 0) '(')
        (let
          [rest : String
            (doc-test-trim-left
              (string.substring trimmed 1 (- (string.string-length trimmed) 1)))]
          (or
            (doc-test-starts-with-form-head? rest "define")
            (doc-test-starts-with-form-head? rest "extern")
            (doc-test-starts-with-form-head? rest "defenum")
            (doc-test-starts-with-form-head? rest "defstruct")))
        false)
      false)))

(define (doc-test-parse-fence-options
  [text : String]
  [line-number : i64]
  [mode : DocTestFenceMode]) : DocTestFenceInfo
  (let
    [trimmed : String (doc-test-trim-left text)]
    (if (= (string.string-length trimmed) 0)
      (DocTestFenceInfo.TypeLisp mode)
      (let
        [end : i64 (doc-test-word-end trimmed 0)]
        [option : String (string.substring trimmed 0 end)]
        [rest : String
          (string.substring trimmed end (- (string.string-length trimmed) end))]
        (if (string.eq option "expect-error")
          (match mode
            [(DocTestFenceMode.Run)
              (DocTestFenceInfo.Malformed
                (DocTestError.Error
                  line-number
                  "TypeLisp doctest options `run` and `expect-error` cannot be combined"))]
            [(DocTestFenceMode.Check _)
              (doc-test-parse-fence-options
                rest
                line-number
                (DocTestFenceMode.Check (DocTestExpectation.Error)))])
          (if (string.eq option "run")
            (match mode
              [(DocTestFenceMode.Run)
                (doc-test-parse-fence-options rest line-number mode)]
              [(DocTestFenceMode.Check expectation)
                (if (doc-test-expectation-error? expectation)
                  (DocTestFenceInfo.Malformed
                    (DocTestError.Error
                      line-number
                      "TypeLisp doctest options `run` and `expect-error` cannot be combined"))
                  (doc-test-parse-fence-options
                    rest
                    line-number
                    (DocTestFenceMode.Run)))])
            (DocTestFenceInfo.Malformed
              (DocTestError.Error
                line-number
                (str_cat.str-cat
                  "unsupported TypeLisp doctest option `"
                  option
                  "`")))))))))

(define (doc-test-parse-fence-info [info : String] [line-number : i64]) : DocTestFenceInfo
  (let
    [trimmed : String (doc-test-trim-left info)]
    (if (= (string.string-length trimmed) 0)
      (DocTestFenceInfo.Ignore)
      (let
        [end : i64 (doc-test-word-end trimmed 0)]
        [language : String (string.substring trimmed 0 end)]
        [rest : String
          (string.substring trimmed end (- (string.string-length trimmed) end))]
        (if (or (string.eq language "typelisp") (string.eq language "tl"))
          (doc-test-parse-fence-options
            rest
            line-number
            (DocTestFenceMode.Check (DocTestExpectation.Pass)))
          (DocTestFenceInfo.Ignore))))))

(define (doc-test-skip-ignored-fence-from
  [lines : doc_line_vec.Vec]
  [index : i64]) : i64
  (if (>= index (doc_line_vec.len (& lines)))
    (doc_line_vec.len (& lines))
    (let
      [line : DocTestLine
        (doc_line_vec.get (& lines) index (DocTestLine.Line 0 ""))]
      (if (doc-test-string-prefix?
        (doc-test-trim-left (doc-test-line-text line))
        "```")
        (+ index 1)
        (doc-test-skip-ignored-fence-from lines (+ index 1))))))

(define (doc-test-collect-code-inner
  [lines : doc_line_vec.Vec]
  [index : i64]
  [code : String]
  [collected : doc_line_vec.Vec]) : DocTestCodeCollect
  (if (>= index (doc_line_vec.len (& lines)))
    (DocTestCodeCollect.Collect
      (doc_line_vec.len (& lines))
      code
      collected
      false)
    (let
      [line : DocTestLine
        (doc_line_vec.get (& lines) index (DocTestLine.Line 0 ""))]
      (if (doc-test-string-prefix?
        (doc-test-trim-left (doc-test-line-text line))
        "```")
        (DocTestCodeCollect.Collect (+ index 1) code collected true)
        (begin
          (doc_line_vec.push (&mut collected) line)
          (doc-test-collect-code-inner
            lines
            (+ index 1)
            (string.append code (string.append (doc-test-line-text line) "\n"))
            collected))))))

(define (doc-test-collect-code [lines : doc_line_vec.Vec] [index : i64]) : DocTestCodeCollect
  (doc-test-collect-code-inner lines index "" (doc_line_vec.new)))

(define (doc-test-metadata-value [line : DocTestLine] [prefix : String]) : DocTestMaybeString
  (let
    [trimmed : String (doc-test-trim-left (doc-test-line-text line))]
    (if (doc-test-string-prefix? trimmed prefix)
      (DocTestMaybeString.Some
        (doc-test-trim
          (string.substring
            trimmed
            (string.string-length prefix)
            (- (string.string-length trimmed) (string.string-length prefix)))))
      (DocTestMaybeString.No))))

(define (doc-test-metadata-line? [line : DocTestLine]) : bool
  (doc-test-string-prefix?
    (doc-test-trim-left (doc-test-line-text line))
    ";; doctest-"))

(define (doc-test-run-metadata-append-error
  [metadata : DocTestRunMetadata]
  [err : DocTestError]) : DocTestRunMetadata
  (match metadata
    [(DocTestRunMetadata.Metadata
        has-exit
        expected-exit
        has-stdout
        expected-stdout
        has-stderr
        expected-stderr
        errors)
      (DocTestRunMetadata.Metadata
        has-exit
        expected-exit
        has-stdout
        expected-stdout
        has-stderr
        expected-stderr
        (doc-test-error-list-append errors err))]))

(define (doc-test-run-metadata-set-exit
  [metadata : DocTestRunMetadata]
  [line : DocTestLine]
  [text : String]) : DocTestRunMetadata
  (match metadata
    [(DocTestRunMetadata.Metadata
        has-exit
        expected-exit
        has-stdout
        expected-stdout
        has-stderr
        expected-stderr
        errors)
      (if has-exit
        (doc-test-run-metadata-append-error
          metadata
          (DocTestError.Error
            (doc-test-line-number line)
            "duplicate doctest-exit metadata"))
        (match (doc-test-parse-i64 text)
          [(option_i64.Some parsed)
            (DocTestRunMetadata.Metadata
              true
              parsed
              has-stdout
              expected-stdout
              has-stderr
              expected-stderr
              errors)]
          [option_i64.None
            (doc-test-run-metadata-append-error
              (DocTestRunMetadata.Metadata
                true
                expected-exit
                has-stdout
                expected-stdout
                has-stderr
                expected-stderr
                errors)
              (DocTestError.Error
                (doc-test-line-number line)
                "doctest-exit metadata must be an integer"))]))]))

(define (doc-test-run-metadata-set-stdout
  [metadata : DocTestRunMetadata]
  [line : DocTestLine]
  [text : String]) : DocTestRunMetadata
  (match metadata
    [(DocTestRunMetadata.Metadata
        has-exit
        expected-exit
        has-stdout
        expected-stdout
        has-stderr
        expected-stderr
        errors)
      (if has-stdout
        (doc-test-run-metadata-append-error
          metadata
          (DocTestError.Error
            (doc-test-line-number line)
            "duplicate doctest-stdout metadata"))
        (match (doc-test-parse-output-spec text)
          [(DocTestMaybeOutput.Some parsed)
            (DocTestRunMetadata.Metadata
              has-exit
              expected-exit
              true
              parsed
              has-stderr
              expected-stderr
              errors)]
          [(DocTestMaybeOutput.No message)
            (doc-test-run-metadata-append-error
              metadata
              (DocTestError.Error (doc-test-line-number line) message))]))]))

(define (doc-test-run-metadata-set-stderr
  [metadata : DocTestRunMetadata]
  [line : DocTestLine]
  [text : String]) : DocTestRunMetadata
  (match metadata
    [(DocTestRunMetadata.Metadata
        has-exit
        expected-exit
        has-stdout
        expected-stdout
        has-stderr
        expected-stderr
        errors)
      (if has-stderr
        (doc-test-run-metadata-append-error
          metadata
          (DocTestError.Error
            (doc-test-line-number line)
            "duplicate doctest-stderr metadata"))
        (match (doc-test-parse-output-spec text)
          [(DocTestMaybeOutput.Some parsed)
            (DocTestRunMetadata.Metadata
              has-exit
              expected-exit
              has-stdout
              expected-stdout
              true
              parsed
              errors)]
          [(DocTestMaybeOutput.No message)
            (doc-test-run-metadata-append-error
              metadata
              (DocTestError.Error (doc-test-line-number line) message))]))]))

(define (doc-test-run-metadata-parse-line
  [metadata : DocTestRunMetadata]
  [line : DocTestLine]) : DocTestRunMetadata
  (match (doc-test-metadata-value line ";; doctest-exit:")
    [(DocTestMaybeString.Some value)
      (doc-test-run-metadata-set-exit metadata line value)]
    [(DocTestMaybeString.No)
      (match (doc-test-metadata-value line ";; doctest-stdout:")
        [(DocTestMaybeString.Some value)
          (doc-test-run-metadata-set-stdout metadata line value)]
        [(DocTestMaybeString.No)
          (match (doc-test-metadata-value line ";; doctest-stderr:")
            [(DocTestMaybeString.Some value)
              (doc-test-run-metadata-set-stderr metadata line value)]
            [(DocTestMaybeString.No)
              (if (doc-test-metadata-line? line)
                (doc-test-run-metadata-append-error
                  metadata
                  (DocTestError.Error
                    (doc-test-line-number line)
                    "unsupported runnable doctest metadata"))
                metadata)])])]))

(define (doc-test-run-metadata-parse-lines-from
  [lines : doc_line_vec.Vec]
  [metadata : DocTestRunMetadata]
  [index : i64]) : DocTestRunMetadata
  (if (>= index (doc_line_vec.len (& lines)))
    metadata
    (doc-test-run-metadata-parse-lines-from
      lines
      (doc-test-run-metadata-parse-line
        metadata
        (doc_line_vec.get (& lines) index (DocTestLine.Line 0 "")))
      (+ index 1))))

(define (doc-test-run-metadata-parse-lines
  [lines : doc_line_vec.Vec]
  [metadata : DocTestRunMetadata]) : DocTestRunMetadata
  (doc-test-run-metadata-parse-lines-from lines metadata 0))

(define (doc-test-parse-run-metadata
  [source-line : i64]
  [lines : doc_line_vec.Vec]) : DocTestRunMetadataParse
  (match (doc-test-run-metadata-parse-lines
    lines
    (DocTestRunMetadata.Metadata
      false
      0
      false
      ""
      false
      ""
      (doc-test-error-list-empty)))
    [(DocTestRunMetadata.Metadata
        has-exit
        expected-exit
        _
        expected-stdout
        _
        expected-stderr
        errors)
      (let
        [all-errors : doc_error_vec.Vec
          (if has-exit
            errors
            (doc-test-error-list-append
              errors
              (DocTestError.Error
                source-line
                "runnable TypeLisp doctest requires doctest-exit metadata")))]
        (if (= (doc-test-error-list-count all-errors) 0)
          (DocTestRunMetadataParse.Ok
            (DocTestExpectation.Run
              expected-exit
              expected-stdout
              expected-stderr))
          (DocTestRunMetadataParse.Err all-errors)))]))

(define (doc-test-scan-type-lisp-fence
  [lines : doc_line_vec.Vec]
  [index : i64]
  [state : DocTestScanState]
  [source-line : i64]
  [mode : DocTestFenceMode]) : DocTestScanState
  (match (doc-test-collect-code lines index)
    [(DocTestCodeCollect.Collect remaining code code-lines closed)
      (match state
        [(DocTestScanState.State examples errors next-index)
          (if closed
            (if (doc-test-string-blank? code)
              (doc-test-scan-doc-block-from
                lines
                remaining
                (DocTestScanState.State
                  examples
                  (doc-test-error-list-append
                    errors
                    (DocTestError.Error
                      source-line
                      "empty TypeLisp doctest fence"))
                  next-index))
              (doc-test-scan-doc-block-from
                lines
                remaining
                (match mode
                  [(DocTestFenceMode.Check expectation)
                    (DocTestScanState.State
                      (doc-test-example-list-append
                        examples
                        (DocTestExample.Example
                          next-index
                          source-line
                          expectation
                          code))
                      errors
                      (+ next-index 1))]
                  [(DocTestFenceMode.Run)
                    (match (doc-test-parse-run-metadata source-line code-lines)
                      [(DocTestRunMetadataParse.Ok expectation)
                        (DocTestScanState.State
                          (doc-test-example-list-append
                            examples
                            (DocTestExample.Example
                              next-index
                              source-line
                              expectation
                              code))
                          errors
                          (+ next-index 1))]
                      [(DocTestRunMetadataParse.Err metadata-errors)
                        (DocTestScanState.State
                          examples
                          (doc-test-error-list-append-all
                            errors
                            metadata-errors)
                          next-index)])])))
            (DocTestScanState.State
              examples
              (doc-test-error-list-append
                errors
                (DocTestError.Error
                  source-line
                  "unterminated TypeLisp doctest fence"))
              next-index))])]))

(define (doc-test-scan-doc-block-from
  [lines : doc_line_vec.Vec]
  [index : i64]
  [state : DocTestScanState]) : DocTestScanState
  (if (>= index (doc_line_vec.len (& lines)))
    state
    (let
      [line : DocTestLine
        (doc_line_vec.get (& lines) index (DocTestLine.Line 0 ""))]
      [trimmed : String (doc-test-trim-left (doc-test-line-text line))]
      (if (doc-test-string-prefix? trimmed "```")
        (let
          [info : String
            (string.substring trimmed 3 (- (string.string-length trimmed) 3))]
          (match (doc-test-parse-fence-info info (doc-test-line-number line))
            [(DocTestFenceInfo.Ignore)
              (doc-test-scan-doc-block-from
                lines
                (doc-test-skip-ignored-fence-from lines (+ index 1))
                state)]
            [(DocTestFenceInfo.Malformed err)
              (match state
                [(DocTestScanState.State examples errors next-index)
                  (doc-test-scan-doc-block-from
                    lines
                    (doc-test-skip-ignored-fence-from lines (+ index 1))
                    (DocTestScanState.State
                      examples
                      (doc-test-error-list-append errors err)
                      next-index))])]
            [(DocTestFenceInfo.TypeLisp expectation)
              (doc-test-scan-type-lisp-fence
                lines
                (+ index 1)
                state
                (doc-test-line-number line)
                expectation)]))
        (doc-test-scan-doc-block-from lines (+ index 1) state)))))

(define (doc-test-scan-doc-block
  [lines : doc_line_vec.Vec]
  [state : DocTestScanState]) : DocTestScanState
  (doc-test-scan-doc-block-from lines 0 state))

(define (doc-test-extract-source [src : String]) : DocTestExtraction
  (let
    [n : i64 (string.string-length src)]
    [pos : i64 0]
    [line-number : i64 1]
    [module-lines : doc_line_vec.Vec (doc_line_vec.new)]
    [pending-lines : doc_line_vec.Vec (doc_line_vec.new)]
    [state : DocTestScanState
      (DocTestScanState.State
        (doc-test-example-list-empty)
        (doc-test-error-list-empty)
        1)]
    (begin
      (while (< pos n)
        (let
          [line-end : i64 (doc-test-line-end src pos n)]
          [line : String (string.substring src pos (- line-end pos))]
          (begin
            (match (doc-test-module-doc-comment-body line)
              [(DocTestMaybeString.Some body)
                (begin
                  (set! pending-lines (doc_line_vec.new))
                  (doc_line_vec.push
                    (&mut module-lines)
                    (DocTestLine.Line line-number body)))]
              [(DocTestMaybeString.No)
                (if (doc-test-string-blank? line)
                  unit
                  (begin
                    (set! state (doc-test-scan-doc-block module-lines state))
                    (set! module-lines (doc_line_vec.new))
                    (match (doc-test-item-doc-comment-body line)
                      [(DocTestMaybeString.Some body)
                        (doc_line_vec.push
                          (&mut pending-lines)
                          (DocTestLine.Line line-number body))]
                      [(DocTestMaybeString.No)
                        (if (doc-test-supported-item-declaration? line)
                          (begin
                            (set!
                              state
                              (doc-test-scan-doc-block pending-lines state))
                            (set! pending-lines (doc_line_vec.new)))
                          (set! pending-lines (doc_line_vec.new)))])))])
            (set! pos (doc-test-next-line-start src line-end n))
            (set! line-number (+ line-number 1)))))
      (set! state (doc-test-scan-doc-block module-lines state))
      (match state
        [(DocTestScanState.State examples errors _)
          (DocTestExtraction.Extraction examples errors)]))))

;; --- runner --------------------------------------------------------------------
;; A single doctest failure: the doc'd source path, the fence's 1-based source
;; line, the example index (`-1` for a fence-level extraction error that has no
;; example), and a human-readable reason (the rendered diagnostic when one is
;; available).
(defenum DocTestRunFailure
  (Failure String i64 i64 String))

(import (vector.vector DocTestRunFailure core) as doc_run_failure_vec)

;; Outcome of running a source: how many examples were checked and which failed.
(defenum DocTestRunReport
  (Report i64 doc_run_failure_vec.Vec))

(defenum DocTestMaybeFailure
  (No)
  (Some DocTestRunFailure))

(define (doc-test-run-failure-path [failure : DocTestRunFailure]) : String
  (match failure
    [(DocTestRunFailure.Failure path _ _ _) path]))

(define (doc-test-run-failure-line [failure : DocTestRunFailure]) : i64
  (match failure
    [(DocTestRunFailure.Failure _ line _ _) line]))

(define (doc-test-run-failure-index [failure : DocTestRunFailure]) : i64
  (match failure
    [(DocTestRunFailure.Failure _ _ index _) index]))

(define (doc-test-run-failure-message [failure : DocTestRunFailure]) : String
  (match failure
    [(DocTestRunFailure.Failure _ _ _ message) message]))

(define (doc-test-run-report-count [report : DocTestRunReport]) : i64
  (match report
    [(DocTestRunReport.Report count _) count]))

(define (doc-test-run-report-failures [report : DocTestRunReport]) : doc_run_failure_vec.Vec
  (match report
    [(DocTestRunReport.Report _ failures) failures]))

(define (doc-test-run-failure-list-empty) : doc_run_failure_vec.Vec
  (doc_run_failure_vec.new))

(define (doc-test-run-failure-list-count [failures : doc_run_failure_vec.Vec]) : i64
  (doc_run_failure_vec.len (& failures)))

(define (doc-test-run-failure-list-ref
  [failures : doc_run_failure_vec.Vec]
  [index : i64]) : DocTestRunFailure
  (doc_run_failure_vec.get
    (& failures)
    index
    (DocTestRunFailure.Failure "" 0 0 "")))

(define (doc-test-run-report-ok? [report : DocTestRunReport]) : bool
  (= (doc-test-run-failure-list-count (doc-test-run-report-failures report)) 0))

(define (doc-test-run-report-add-prefix-count
  [prefix-count : i64]
  [report : DocTestRunReport]) : DocTestRunReport
  (DocTestRunReport.Report
    (+ prefix-count (doc-test-run-report-count report))
    (doc-test-run-report-failures report)))

(define (doc-test-run-failure-list-append
  [failures : doc_run_failure_vec.Vec]
  [failure : DocTestRunFailure]) : doc_run_failure_vec.Vec
  (begin
    (doc_run_failure_vec.push (&mut failures) failure)
    failures))

;; Grow the generated error collection past its initial capacity while preserving
;; source order. The extraction path uses this same helper.
(define (doc-test-error-vector-growth-smoke-ok?) : bool
  (let
    [errors : doc_error_vec.Vec (doc-test-error-list-empty)]
    [index : i64 1]
    (begin
      (while (<= index 5)
        (begin
          (set!
            errors
            (doc-test-error-list-append
              errors
              (DocTestError.Error index (string.int->string index))))
          (set! index (+ index 1))))
      (and
        (= (doc-test-error-list-count errors) 5)
        (= (doc_error_vec.capacity (& errors)) 8)
        (= (doc-test-error-line (doc-test-error-list-ref errors 4)) 5)))))

;; Grow the generated line collection past its initial capacity while preserving
;; physical source-line order. Extraction uses this same helper.
(define (doc-test-line-vector-growth-smoke-ok?) : bool
  (let
    [lines : doc_line_vec.Vec (doc_line_vec.new)]
    [index : i64 1]
    (begin
      (while (<= index 5)
        (begin
          (doc_line_vec.push
            (&mut lines)
            (DocTestLine.Line index (string.int->string index)))
          (set! index (+ index 1))))
      (and
        (= (doc_line_vec.len (& lines)) 5)
        (= (doc_line_vec.capacity (& lines)) 8)
        (=
          (doc-test-line-number
            (doc_line_vec.get (& lines) 0 (DocTestLine.Line 0 "")))
          1)
        (=
          (doc-test-line-number
            (doc_line_vec.get (& lines) 4 (DocTestLine.Line 0 "")))
          5)))))

;; The two formerly hand-written collections also contain move-only strings.
;; Exercise canonical core growth across the initial capacity without requiring
;; clone/pop support, and confirm that source order survives the move-based copy.
(define (doc-test-example-vector-growth-smoke-ok?) : bool
  (let
    [examples : doc_example_vec.Vec (doc-test-example-list-empty)]
    [index : i64 1]
    (begin
      (while (<= index 5)
        (begin
          (set!
            examples
            (doc-test-example-list-append
              examples
              (DocTestExample.Example
                index
                (+ index 10)
                (DocTestExpectation.Pass)
                (string.int->string index))))
          (set! index (+ index 1))))
      (and
        (= (doc-test-example-list-count examples) 5)
        (= (doc_example_vec.capacity (& examples)) 8)
        (= (doc-test-example-index (doc-test-example-list-ref examples 0)) 1)
        (string.eq
          (doc-test-example-code (doc-test-example-list-ref examples 4))
          "5")))))

(define (doc-test-run-failure-vector-growth-smoke-ok?) : bool
  (let
    [failures : doc_run_failure_vec.Vec (doc-test-run-failure-list-empty)]
    [index : i64 1]
    (begin
      (while (<= index 5)
        (begin
          (set!
            failures
            (doc-test-run-failure-list-append
              failures
              (DocTestRunFailure.Failure
                (string.int->string index)
                (+ index 10)
                index
                (string.int->string index))))
          (set! index (+ index 1))))
      (and
        (= (doc-test-run-failure-list-count failures) 5)
        (= (doc_run_failure_vec.capacity (& failures)) 8)
        (string.eq
          (doc-test-run-failure-path (doc-test-run-failure-list-ref failures 0))
          "1")
        (=
          (doc-test-run-failure-index
            (doc-test-run-failure-list-ref failures 4))
          5)))))

;; Render a failure as `path:line: message`. Fence-level extraction
;; errors use index `-1`; example failures include the example number in their
;; message so the public CLI text matches the stage0 Rust runner.
(define (doc-test-run-failure-render [failure : DocTestRunFailure]) : String
  (match failure
    [(DocTestRunFailure.Failure path line index message)
      (let
        [location : String
          (string.append
            path
            (string.append ":" (string.append (string.int->string line) ": ")))]
        (string.append location message))]))

(define (doc-test-unexpected-pass-message [index : i64]) : String
  (string.append
    "doctest example "
    (string.append
      (string.int->string index)
      " was expected to fail but passed")))

(define (doc-test-public-diagnostic-render [diag : CompilerDiagnostic]) : String
  (match (compiler-diagnostic-code diag)
    [(CompilerDiagnosticSomeString code)
      (string.append
        "error["
        (string.append
          code
          (string.append "]: " (compiler-diagnostic-render diag))))]
    [CompilerDiagnosticNoString
      (string.append "error: " (compiler-diagnostic-render diag))]))

(define (doc-test-public-diagnostic-render-smoke-ok?) : bool
  (let
    [parse-diag : CompilerDiagnostic
      (compiler-diagnostic-with-code
        (compiler-diagnostic-simple "docs/parse.tl" 1 2 "missing closing paren")
        (compiler-diagnostic-code-parse))]
    [typecheck-diag : CompilerDiagnostic
      (compiler-diagnostic-with-code
        (compiler-diagnostic-simple "docs/type.tl" 3 4 "return mismatch")
        (compiler-diagnostic-code-typecheck))]
    [uncoded : CompilerDiagnostic
      (compiler-diagnostic-simple
        "docs/plain.tl"
        5
        6
        "typecheck: prefix text only")]
    [parse-rendered : String (doc-test-public-diagnostic-render parse-diag)]
    [typecheck-rendered : String
      (doc-test-public-diagnostic-render typecheck-diag)]
    [uncoded-rendered : String (doc-test-public-diagnostic-render uncoded)]
    (and
      (doc-test-string-contains? parse-rendered "error[E0100]:")
      (doc-test-string-contains? typecheck-rendered "error[E0200]:")
      (doc-test-string-contains? uncoded-rendered "error: docs/plain.tl:5:6:")
      (not (doc-test-string-contains? uncoded-rendered "E0200")))))

(define (doc-test-unexpected-error-message
  [index : i64]
  [diag : CompilerDiagnostic]) : String
  (string.append
    "doctest example "
    (string.append
      (string.int->string index)
      (string.append
        " was expected to pass\n"
        (doc-test-public-diagnostic-render diag)))))

;; Runnable doctests spawn nested build/run commands from a generated test
;; binary. This is a required gate on both Linux and Windows because skipped
;; runnable doctests can hide target-specific compiler/runtime bugs.
(define (doc-test-runnable-target-supported? [target : CompilerBackendTarget]) : bool
  (match target
    [(CompilerBackendTarget.Linux) true]
    [(CompilerBackendTarget.Windows) true]))

(define (doc-test-runnable-supported?) : bool
  (doc-test-runnable-target-supported? (source-tool-default-target)))

(define (doc-test-runnable-unsupported-message
  [index : i64]
  [target : CompilerBackendTarget]) : String
  (string.append
    "doctest example "
    (string.append
      (string.int->string index)
      (string.append
        " is a runnable doctest, but runnable doctests are unsupported on target "
        (source-tool-target-name target)))))

(define (doc-test-runnable-compile-message [index : i64] [message : String]) : String
  (string.append
    "doctest example "
    (string.append
      (string.int->string index)
      (string.append " runnable compile failed\n" message))))

(define (doc-test-runnable-build-message [index : i64] [message : String]) : String
  (string.append
    "doctest example "
    (string.append
      (string.int->string index)
      (string.append " runnable build failed\n" message))))

(define (doc-test-runnable-exec-message [index : i64] [message : String]) : String
  (string.append
    "doctest example "
    (string.append
      (string.int->string index)
      (string.append " runnable execution failed: " message))))

(define (doc-test-output-comparison-message
  [name : String]
  [expected : String]
  [actual : String]) : String
  (string.append
    "expected "
    (string.append
      name
      (string.append
        ":\n"
        (string.append
          expected
          (string.append
            "\nactual "
            (string.append name (string.append ":\n" actual))))))))

(define (doc-test-normalize-windows-crlf [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (if (and
          (= (string.string-ref text i) '\r')
          (< (+ i 1) n)
          (= (string.string-ref text (+ i 1)) '\n'))
          (begin
            (set! out (string.concat3 out "\n" ""))
            (set! i (+ i 2)))
          (begin
            (set! out (string.concat3 out (string.substring text i 1) ""))
            (set! i (+ i 1)))))
      out)))

(define (doc-test-normalize-output-for-target
  [target : CompilerBackendTarget]
  [text : String]) : String
  (match target
    [(CompilerBackendTarget.Linux) text]
    [(CompilerBackendTarget.Windows) (doc-test-normalize-windows-crlf text)]))

(define (doc-test-runnable-mismatch-message
  [index : i64]
  [expectation : DocTestExpectation]
  [target : CompilerBackendTarget]
  [output : process.ProcessOutput]) : String
  (let
    [expected-exit : i64 (doc-test-expectation-run-exit expectation)]
    [expected-stdout : String (doc-test-expectation-run-stdout expectation)]
    [expected-stderr : String (doc-test-expectation-run-stderr expectation)]
    [actual-exit : i64 (process.output-status output)]
    [actual-stdout : String
      (doc-test-normalize-output-for-target
        target
        (process.output-stdout output))]
    [actual-stderr : String
      (doc-test-normalize-output-for-target
        target
        (process.output-stderr output))]
    (string.append
      "doctest example "
      (string.append
        (string.int->string index)
        (string.append
          " runnable output mismatch\nexpected exit: "
          (string.append
            (string.int->string expected-exit)
            (string.append
              "\nactual exit: "
              (string.append
                (string.int->string actual-exit)
                (string.append
                  "\n"
                  (string.append
                    (doc-test-output-comparison-message
                      "stdout"
                      expected-stdout
                      actual-stdout)
                    (string.append
                      "\n"
                      (doc-test-output-comparison-message
                        "stderr"
                        expected-stderr
                        actual-stderr))))))))))))

(define (doc-test-runnable-output-matches?
  [expectation : DocTestExpectation]
  [target : CompilerBackendTarget]
  [output : process.ProcessOutput]) : bool
  (if (=
    (doc-test-expectation-run-exit expectation)
    (process.output-status output))
    (if (string.eq
      (doc-test-expectation-run-stdout expectation)
      (doc-test-normalize-output-for-target
        target
        (process.output-stdout output)))
      (string.eq
        (doc-test-expectation-run-stderr expectation)
        (doc-test-normalize-output-for-target
          target
          (process.output-stderr output)))
      false)
    false))

(define (doc-test-assemble-and-link-captured
  [target : CompilerBackendTarget]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]) : SourceToolCommandStatus
  (source-tool-assemble-and-link
    target
    asm-path
    obj-path
    bin-path
    (source-tool-link-inputs-empty)))

(define (doc-test-emit-runnable-assembly
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]
  [target : CompilerBackendTarget]) : ResultSourceToolString
  (begin
    (compiler-driver-reset-file-state!)
    (compiler-driver-state-clear-pool-backed-caches!)
    (let
      [index : i64 (doc-test-example-index example)]
      [virtual-path : String (doc-test-example-virtual-path path index)]
      [code : String (doc-test-example-code example)]
      [cfgs : sym_i64_env.SymI64Env
        (compiler-driver-target-cfgs target (compiler-cfg-empty))]
      [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
      [result : ResultSourceToolString
        (match (compiler-driver-load-source-with-runtime-with-pools
          virtual-path
          code
          stdlib-roots
          cfgs
          pools)
          [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (match (lower-compiler-program-with-decl-paths-mode-cache-and-pools
              virtual-path
              (ast-program decls)
              paths
              (CompilerLowerMode.Scalar)
              stdlib-roots
              (tc-prefix-default-cache-scope)
              pools)
              [(ResultCompilerLower.Ok program spans)
                (match (compiler-driver-emit-lowered-with-level
                  virtual-path
                  program
                  spans
                  target
                  true
                  (compiler-optimize-default-level))
                  [(ResultCompilerDriver.Ok asm)
                    (ResultSourceToolString.Ok
                      (source-tool-augment-assembly-for-target asm target))]
                  [(ResultCompilerDriver.Err diag)
                    (ResultSourceToolString.Err
                      (compiler-diagnostic-render (box-get diag)))])]
              [(ResultCompilerLower.Err diag)
                (ResultSourceToolString.Err
                  (compiler-diagnostic-render (box-get diag)))])]
          [(ResultCompilerLoadWithPaths.Err diag)
            (ResultSourceToolString.Err
              (compiler-diagnostic-render (box-get diag)))])]
      (begin
        (compiler-driver-state-clear-pool-backed-caches!)
        (compiler-driver-reset-file-state!)
        result))))

(define (doc-test-runnable-failure
  [path : String]
  [source-line : i64]
  [index : i64]
  [message : String]) : DocTestMaybeFailure
  (DocTestMaybeFailure.Some
    (DocTestRunFailure.Failure path source-line index message)))

(define (doc-test-run-runnable-process-output
  [path : String]
  [source-line : i64]
  [index : i64]
  [expectation : DocTestExpectation]
  [target : CompilerBackendTarget]
  [temp-dir : String]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]) : DocTestMaybeFailure
  (match (source-tool-run-executable bin-path target (process.args-empty))
    [(process.OkProcessOutput output)
      (begin
        (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
        (if (doc-test-runnable-output-matches? expectation target output)
          (DocTestMaybeFailure.No)
          (doc-test-runnable-failure
            path
            source-line
            index
            (doc-test-runnable-mismatch-message index expectation target output))))]
    [(process.ErrProcessOutput error)
      (begin
        (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
        (doc-test-runnable-failure
          path
          source-line
          index
          (doc-test-runnable-exec-message index (process.error-message error))))]))

(define (doc-test-link-and-run-runnable
  [path : String]
  [source-line : i64]
  [index : i64]
  [expectation : DocTestExpectation]
  [target : CompilerBackendTarget]
  [temp-dir : String]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]) : DocTestMaybeFailure
  (match (doc-test-assemble-and-link-captured target asm-path obj-path bin-path)
    [(SourceToolCommandStatus.Err message)
      (begin
        (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
        (doc-test-runnable-failure
          path
          source-line
          index
          (doc-test-runnable-build-message index message)))]
    [(SourceToolCommandStatus.Ok)
      (doc-test-run-runnable-process-output
        path
        source-line
        index
        expectation
        target
        temp-dir
        asm-path
        obj-path
        bin-path)]))

(define (doc-test-write-link-and-run-runnable
  [path : String]
  [source-line : i64]
  [index : i64]
  [expectation : DocTestExpectation]
  [target : CompilerBackendTarget]
  [temp-dir : String]
  [asm-path : String]
  [obj-path : String]
  [bin-path : String]
  [asm : String]) : DocTestMaybeFailure
  (match (source-tool-write-file
    asm-path
    asm
    "doctest: failed to write assembly artifact")
    [(SourceToolCommandStatus.Err message)
      (begin
        (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
        (doc-test-runnable-failure
          path
          source-line
          index
          (doc-test-runnable-build-message index message)))]
    [(SourceToolCommandStatus.Ok)
      (doc-test-link-and-run-runnable
        path
        source-line
        index
        expectation
        target
        temp-dir
        asm-path
        obj-path
        bin-path)]))

(define (doc-test-run-runnable-output
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]
  [target : CompilerBackendTarget]
  [temp-dir : String]) : DocTestMaybeFailure
  (let
    [index : i64 (doc-test-example-index example)]
    [source-line : i64 (doc-test-example-source-line example)]
    [expectation : DocTestExpectation (doc-test-example-expectation example)]
    [virtual-path : String (doc-test-example-virtual-path path index)]
    [asm-path : String (source-tool-asm-path temp-dir virtual-path)]
    [obj-path : String (source-tool-obj-path temp-dir virtual-path target)]
    [bin-path : String (source-tool-temp-bin-path temp-dir virtual-path target)]
    (match (doc-test-emit-runnable-assembly path example stdlib-roots target)
      [(ResultSourceToolString.Err message)
        (begin
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
          (doc-test-runnable-failure
            path
            source-line
            index
            (doc-test-runnable-compile-message index message)))]
      [(ResultSourceToolString.Ok asm)
        (doc-test-write-link-and-run-runnable
          path
          source-line
          index
          expectation
          target
          temp-dir
          asm-path
          obj-path
          bin-path
          asm)])))

(define (doc-test-run-runnable-example-with-roots
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]) : DocTestMaybeFailure
  (let
    [index : i64 (doc-test-example-index example)]
    [source-line : i64 (doc-test-example-source-line example)]
    [target : CompilerBackendTarget (source-tool-default-target)]
    (if (doc-test-runnable-target-supported? target)
      (match (source-tool-create-temp-dir "typelisp-doctest")
        [(ResultSourceToolString.Ok temp-dir)
          (doc-test-run-runnable-output
            path
            example
            stdlib-roots
            target
            temp-dir)]
        [(ResultSourceToolString.Err message)
          (DocTestMaybeFailure.Some
            (DocTestRunFailure.Failure
              path
              source-line
              index
              (doc-test-runnable-build-message
                index
                (string.append "doctest: failed to create temp dir: " message))))])
      (DocTestMaybeFailure.Some
        (DocTestRunFailure.Failure
          path
          source-line
          index
          (doc-test-runnable-unsupported-message index target))))))

;; Check one extracted example through the virtual-source typechecker, comparing
;; the outcome against its expectation. Imports inside the example resolve
;; relative to a sibling of `path` (the doc'd source file), so examples may
;; import the doc'd file without colliding with the virtual source root.
(define (doc-test-example-virtual-path [path : String] [index : i64]) : String
  (string.append path (string.append ".doctest." (string.int->string index))))

(define (doc-test-typecheck-example-with-roots-and-cfg
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestMaybeFailure
  (let
    [index : i64 (doc-test-example-index example)]
    [source-line : i64 (doc-test-example-source-line example)]
    [expectation : DocTestExpectation (doc-test-example-expectation example)]
    [expect-error : bool (doc-test-expectation-error? expectation)]
    [code : String (doc-test-example-code example)]
    (match (compiler-check-source-with-roots-and-cfg
      (doc-test-example-virtual-path path index)
      code
      stdlib-roots
      cfgs)
      [(ResultCompilerCheck.Ok _)
        (if expect-error
          (DocTestMaybeFailure.Some
            (DocTestRunFailure.Failure
              path
              source-line
              index
              (doc-test-unexpected-pass-message index)))
          (DocTestMaybeFailure.No))]
      [(ResultCompilerCheck.Err diag)
        (if expect-error
          (DocTestMaybeFailure.No)
          (DocTestMaybeFailure.Some
            (DocTestRunFailure.Failure
              path
              source-line
              index
              (doc-test-unexpected-error-message index (box-get diag)))))])))

(define (doc-test-typecheck-example-with-roots
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]) : DocTestMaybeFailure
  (doc-test-typecheck-example-with-roots-and-cfg
    path
    example
    stdlib-roots
    (compiler-check-language-cfgs)))

(define (doc-test-typecheck-package-example-with-roots-and-cfg
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestMaybeFailure
  (let
    [index : i64 (doc-test-example-index example)]
    [source-line : i64 (doc-test-example-source-line example)]
    [expectation : DocTestExpectation (doc-test-example-expectation example)]
    [expect-error : bool (doc-test-expectation-error? expectation)]
    [code : String (doc-test-example-code example)]
    (match (compiler-check-package-source-with-roots-and-cfg
      (doc-test-example-virtual-path path index)
      code
      stdlib-roots
      manifest-dir
      deps
      cfgs)
      [(ResultCompilerCheck.Ok _)
        (if expect-error
          (DocTestMaybeFailure.Some
            (DocTestRunFailure.Failure
              path
              source-line
              index
              (doc-test-unexpected-pass-message index)))
          (DocTestMaybeFailure.No))]
      [(ResultCompilerCheck.Err diag)
        (if expect-error
          (DocTestMaybeFailure.No)
          (DocTestMaybeFailure.Some
            (DocTestRunFailure.Failure
              path
              source-line
              index
              (doc-test-unexpected-error-message index (box-get diag)))))])))

(define (doc-test-check-example-with-roots
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]) : DocTestMaybeFailure
  (if (doc-test-expectation-run? (doc-test-example-expectation example))
    (doc-test-run-runnable-example-with-roots path example stdlib-roots)
    (doc-test-typecheck-example-with-roots path example stdlib-roots)))

(define (doc-test-run-examples-with-roots-from
  [path : String]
  [examples : doc_example_vec.Vec]
  [index : i64]
  [failures : doc_run_failure_vec.Vec]
  [stdlib-roots : doc_svec.Vec]) : doc_run_failure_vec.Vec
  (if (>= index (doc-test-example-list-count examples))
    failures
    (let
      [example : DocTestExample (doc-test-example-list-ref examples index)]
      (match (doc-test-check-example-with-roots path example stdlib-roots)
        [(DocTestMaybeFailure.No)
          (doc-test-run-examples-with-roots-from
            path
            examples
            (+ index 1)
            failures
            stdlib-roots)]
        [(DocTestMaybeFailure.Some failure)
          (doc-test-run-examples-with-roots-from
            path
            examples
            (+ index 1)
            (doc-test-run-failure-list-append failures failure)
            stdlib-roots)]))))

(define (doc-test-run-examples-with-roots
  [path : String]
  [examples : doc_example_vec.Vec]
  [failures : doc_run_failure_vec.Vec]
  [stdlib-roots : doc_svec.Vec]) : doc_run_failure_vec.Vec
  (doc-test-run-examples-with-roots-from path examples 0 failures stdlib-roots))

(define (doc-test-typecheck-examples-with-roots-from
  [path : String]
  [examples : doc_example_vec.Vec]
  [index : i64]
  [failures : doc_run_failure_vec.Vec]
  [stdlib-roots : doc_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : doc_run_failure_vec.Vec
  (if (>= index (doc-test-example-list-count examples))
    failures
    (let
      [example : DocTestExample (doc-test-example-list-ref examples index)]
      (match (doc-test-typecheck-example-with-roots-and-cfg
        path
        example
        stdlib-roots
        cfgs)
        [(DocTestMaybeFailure.No)
          (doc-test-typecheck-examples-with-roots-from
            path
            examples
            (+ index 1)
            failures
            stdlib-roots
            cfgs)]
        [(DocTestMaybeFailure.Some failure)
          (doc-test-typecheck-examples-with-roots-from
            path
            examples
            (+ index 1)
            (doc-test-run-failure-list-append failures failure)
            stdlib-roots
            cfgs)]))))

(define (doc-test-typecheck-examples-with-roots-and-cfg
  [path : String]
  [examples : doc_example_vec.Vec]
  [failures : doc_run_failure_vec.Vec]
  [stdlib-roots : doc_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : doc_run_failure_vec.Vec
  (doc-test-typecheck-examples-with-roots-from
    path
    examples
    0
    failures
    stdlib-roots
    cfgs))

(define (doc-test-typecheck-package-examples-with-roots-from
  [path : String]
  [examples : doc_example_vec.Vec]
  [index : i64]
  [failures : doc_run_failure_vec.Vec]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : doc_run_failure_vec.Vec
  (if (>= index (doc-test-example-list-count examples))
    failures
    (let
      [example : DocTestExample (doc-test-example-list-ref examples index)]
      (match (doc-test-typecheck-package-example-with-roots-and-cfg
        path
        example
        stdlib-roots
        manifest-dir
        deps
        cfgs)
        [(DocTestMaybeFailure.No)
          (doc-test-typecheck-package-examples-with-roots-from
            path
            examples
            (+ index 1)
            failures
            stdlib-roots
            manifest-dir
            deps
            cfgs)]
        [(DocTestMaybeFailure.Some failure)
          (doc-test-typecheck-package-examples-with-roots-from
            path
            examples
            (+ index 1)
            (doc-test-run-failure-list-append failures failure)
            stdlib-roots
            manifest-dir
            deps
            cfgs)]))))

(define (doc-test-typecheck-package-examples-with-roots-and-cfg
  [path : String]
  [examples : doc_example_vec.Vec]
  [failures : doc_run_failure_vec.Vec]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : doc_run_failure_vec.Vec
  (doc-test-typecheck-package-examples-with-roots-from
    path
    examples
    0
    failures
    stdlib-roots
    manifest-dir
    deps
    cfgs))

;; A malformed/empty/unterminated fence is a runner failure too; it has no
;; example index, so it is recorded with index `-1`.
(define (doc-test-errors-to-failures-from
  [path : String]
  [errors : doc_error_vec.Vec]
  [index : i64]
  [failures : doc_run_failure_vec.Vec]) : doc_run_failure_vec.Vec
  (if (>= index (doc-test-error-list-count errors))
    failures
    (let
      [err : DocTestError (doc-test-error-list-ref errors index)]
      (doc-test-errors-to-failures-from
        path
        errors
        (+ index 1)
        (doc-test-run-failure-list-append
          failures
          (DocTestRunFailure.Failure
            path
            (doc-test-error-line err)
            -1
            (doc-test-error-message err)))))))

(define (doc-test-errors-to-failures
  [path : String]
  [errors : doc_error_vec.Vec]
  [failures : doc_run_failure_vec.Vec]) : doc_run_failure_vec.Vec
  (doc-test-errors-to-failures-from path errors 0 failures))

;; Extract and check every example in `source` (attributed to `path`). Extraction
;; errors are folded in as failures first, then each example is checked. A source
;; with no examples and no errors reports success with a zero count.
(define (doc-test-run-source [path : String] [source : String]) : DocTestRunReport
  (doc-test-run-source-with-roots path source (doc_svec.new)))

(define (doc-test-run-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : doc_svec.Vec]) : DocTestRunReport
  (match (doc-test-extract-source source)
    [(DocTestExtraction.Extraction examples errors)
      (DocTestRunReport.Report
        (doc-test-example-list-count examples)
        (doc-test-run-examples-with-roots
          path
          examples
          (doc-test-errors-to-failures
            path
            errors
            (doc-test-run-failure-list-empty))
          stdlib-roots))]))

(define (doc-test-run-file-with-roots
  [path : String]
  [stdlib-roots : doc_svec.Vec]) : DocTestRunReport
  (doc-test-run-source-with-roots path (io.read-file path) stdlib-roots))

(define (doc-test-typecheck-source [path : String] [source : String]) : DocTestRunReport
  (doc-test-typecheck-source-with-roots path source (doc_svec.new)))

(define (doc-test-typecheck-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : doc_svec.Vec]) : DocTestRunReport
  (doc-test-typecheck-source-with-roots-and-cfg
    path
    source
    stdlib-roots
    (compiler-check-language-cfgs)))

(define (doc-test-typecheck-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : doc_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestRunReport
  (match (doc-test-extract-source source)
    [(DocTestExtraction.Extraction examples errors)
      (DocTestRunReport.Report
        (doc-test-example-list-count examples)
        (doc-test-typecheck-examples-with-roots-and-cfg
          path
          examples
          (doc-test-errors-to-failures
            path
            errors
            (doc-test-run-failure-list-empty))
          stdlib-roots
          cfgs))]))

(define (doc-test-typecheck-package-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestRunReport
  (match (doc-test-extract-source source)
    [(DocTestExtraction.Extraction examples errors)
      (DocTestRunReport.Report
        (doc-test-example-list-count examples)
        (doc-test-typecheck-package-examples-with-roots-and-cfg
          path
          examples
          (doc-test-errors-to-failures
            path
            errors
            (doc-test-run-failure-list-empty))
          stdlib-roots
          manifest-dir
          deps
          cfgs))]))

(define (doc-test-typecheck-file-with-roots-and-cfg
  [path : String]
  [stdlib-roots : doc_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestRunReport
  (doc-test-typecheck-source-with-roots-and-cfg
    path
    (io.read-file path)
    stdlib-roots
    cfgs))

(define (doc-test-path-under-root? [path : String] [root : String]) : bool
  (let
    [normalized-path : String (compiler-load-normalize-path path)]
    [normalized-root : String (compiler-load-normalize-path root)]
    (and
      (> (string.string-length normalized-root) 0)
      (if (string.eq normalized-root ".")
        (not (compiler-load-path-escapes? normalized-path))
        (compiler-load-path-under-root? normalized-path normalized-root)))))

(define (doc-test-dep-list-path?
  [path : String]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [index : i64]) : bool
  (if (>= index (compiler-pkg-dep-list-count deps))
    false
    (let
      [dep : CompilerPkgDep (compiler-pkg-dep-list-at deps index)]
      [dep-path : String (struct-get dep path)]
      [dep-root : String
        (compiler-load-normalize-path
          (if (compiler-load-absolute-path? dep-path)
            dep-path
            (compiler-load-join-root-path manifest-dir dep-path)))]
      (if (and
        (not (compiler-load-github-dependency-path? dep-path))
        (doc-test-path-under-root? path dep-root))
        true
        (doc-test-dep-list-path? path manifest-dir deps (+ index 1))))))

(define (doc-test-typecheck-package-path-list-with-roots-from
  [paths : AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [last-path : String]
  [count : i64]) : DocTestRunReport
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Nil)
      (DocTestRunReport.Report count (doc-test-run-failure-list-empty))]
    [(AstDeclPathListStep.Cons path rest)
      (let
        [rest : AstDeclPathList rest]
        [normalized : String (compiler-load-normalize-path path)]
        [rooted : String
          (if (or
            (compiler-load-absolute-path? path)
            (doc-test-path-under-root? normalized manifest-dir))
            normalized
            (compiler-load-normalize-path
              (compiler-load-join-root-path manifest-dir normalized)))]
        [stdlib-path : String
          (if (compiler-load-stdlib-import? normalized)
            normalized
            (compiler-load-stdlib-owned-path-from-roots rooted stdlib-roots))]
        [manifest-stdlib-root : String
          (compiler-load-normalize-path
            (compiler-load-join-root-path manifest-dir "stdlib"))]
        [manifest-root : String (compiler-load-normalize-path manifest-dir)]
        [manifest-local : bool
          (if (string.eq manifest-root ".")
            (and
              (not (compiler-load-absolute-path? rooted))
              (doc-test-path-under-root? rooted manifest-dir))
            (doc-test-path-under-root? rooted manifest-dir))]
        [package-local : bool
          (and
            (> (string.string-length path) 0)
            (not (compiler-load-stdlib-import? stdlib-path))
            (not (doc-test-path-under-root? rooted manifest-stdlib-root))
            (not
              (doc-test-dep-list-path?
                rooted
                manifest-dir
                (compiler-pkg-deps-list deps)
                0))
            manifest-local)]
        (if (and package-local (not (string.eq rooted last-path)))
          (let
            [report : DocTestRunReport
              (doc-test-typecheck-package-file-text-with-roots
                rooted
                stdlib-roots
                manifest-dir
                deps
                cfgs)]
            (if (doc-test-run-report-ok? report)
              (doc-test-typecheck-package-path-list-with-roots-from
                rest
                stdlib-roots
                manifest-dir
                deps
                cfgs
                rooted
                (+ count (doc-test-run-report-count report)))
              (doc-test-run-report-add-prefix-count count report)))
          (doc-test-typecheck-package-path-list-with-roots-from
            rest
            stdlib-roots
            manifest-dir
            deps
            cfgs
            last-path
            count)))]))

(define (doc-test-typecheck-package-file-text-with-roots
  [path : String]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestRunReport
  (match (io.try-read-file (& path))
    [(io.ErrIoString _)
      (DocTestRunReport.Report 0 (doc-test-run-failure-list-empty))]
    [(io.OkIoString text)
      (doc-test-typecheck-package-source-with-roots-and-cfg
        path
        text
        stdlib-roots
        manifest-dir
        deps
        cfgs)]))

(define (doc-test-typecheck-package-paths-with-roots
  [paths : AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : DocTestRunReport
  (doc-test-typecheck-package-paths-with-roots-and-cfg
    paths
    stdlib-roots
    manifest-dir
    deps
    (compiler-check-language-cfgs)))

(define (doc-test-typecheck-package-paths-with-roots-and-cfg
  [paths : AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestRunReport
  (doc-test-typecheck-package-path-list-with-roots-from
    paths
    stdlib-roots
    manifest-dir
    deps
    cfgs
    ""
    0))

;; Exit status for a report: 0 when every example passed (or there were none),
;; 1 otherwise. Callers turn this directly into a process exit code.
(define (doc-test-run-report-status [report : DocTestRunReport]) : i64
  (if (doc-test-run-report-ok? report)
    0
    1))

;; Render every failure as `path:line: ...`, one per line, in extraction order.
(define (doc-test-run-failures-render-from
  [failures : doc_run_failure_vec.Vec]
  [index : i64]) : String
  (if (>= index (doc-test-run-failure-list-count failures))
    ""
    (string.append
      (string.append
        (doc-test-run-failure-render
          (doc-test-run-failure-list-ref failures index))
        "\n")
      (doc-test-run-failures-render-from failures (+ index 1)))))

(define (doc-test-run-failures-render [failures : doc_run_failure_vec.Vec]) : String
  (doc-test-run-failures-render-from failures 0))

;; Human-readable report text. Success mirrors the Rust CLI's
;; `Doc tests passed: N example(s)` line; failure mirrors its
;; `doc tests failed: M failure(s) across N example(s)` summary followed by each
;; rendered failure.
(define (doc-test-run-report-render [report : DocTestRunReport]) : String
  (match report
    [(DocTestRunReport.Report count failures)
      (if (= (doc-test-run-failure-list-count failures) 0)
        (string.append
          "Doc tests passed: "
          (string.append (string.int->string count) " example(s)"))
        (string.append
          (str_cat.str-cat
            "doc tests failed: "
            (string.int->string (doc-test-run-failure-list-count failures))
            " failure(s) across "
            (string.int->string count)
            " example(s)\n")
          (doc-test-run-failures-render failures)))]))

(define (doc-test-smoke-source) : String
  ";# Module docs
;# ```typelisp

;# (define (main) : i64 0)

;# ```

;: Item docs
;: ```tl expect-error

;: (define (bad) : i64 true)

;: ```
(define good : i64 1)

;: Unattached docs are ignored
")

(define (doc-test-ordinary-comment-source) : String
  "; ```typelisp
; (define (bad) : i64 true)
; ```
;; ```typelisp
;; (define (also-bad) : i64 true)
;; ```
")

(define (doc-test-malformed-source) : String
  ";# ```typelisp maybe
;# (define (main) : i64 0)
;# ```

;# ```tl
;# ```

;# ```typelisp
;# (define (open) : i64 0)
")

(define (doc-test-runnable-source) : String
  (string.append
    ";# Runnable docs\n"
    (string.append
      ";# ```typelisp run\n"
      (string.append
        ";# ;; doctest-exit: 0\n"
        (string.append
          ";# ;; doctest-stdout: literal:hello\\n\n"
          (string.append
            ";# ;; doctest-stderr: literal:error\\tline\\r\n"
            (string.append
              ";# (import stdlib.io)\n"
              (string.append
                ";# (define (main) : i64\n"
                (string.append
                  ";#   (begin\n"
                  (string.append
                    ";#     (let [text : String \"hello\\n\"] (io.stdout-write (& text)))\n"
                    (string.append
                      ";#     (let [text : String \"error\\tline\\r\"] (io.stderr-write (& text)))\n"
                      (string.append
                        ";#     0))\n"
                        (string.append
                          ";# ```\n"
                          (string.append
                            ";# ```tl run\n"
                            (string.append
                              ";# ;; doctest-exit: 42\n"
                              (string.append
                                ";# (define (main) : i64 42)\n"
                                ";# ```\n"))))))))))))))))

(define (doc-test-runnable-malformed-source) : String
  ";# ```typelisp run expect-error
;# ;; doctest-exit: 0
;# ```
;# ```typelisp expect-error run
;# ;; doctest-exit: 0
;# ```
;# ```typelisp run
;# ;; doctest-exit: nope
;# ```
;# ```typelisp run
;# ;; doctest-exit: 0
;# ;; doctest-stdout: nope
;# ```
;# ```typelisp run
;# ;; doctest-stdout: -
;# ```
")

(define (doc-test-example-ok?
  [example : DocTestExample]
  [index : i64]
  [source-line : i64]
  [expect-error : bool]
  [code-fragment : String]) : bool
  (begin
    (unless (= (doc-test-example-index example) index) (return false))
    (unless
      (= (doc-test-example-source-line example) source-line)
      (return false))
    (unless
      (=
        (doc-test-expectation-error? (doc-test-example-expectation example))
        expect-error)
      (return false))
    (doc-test-string-contains? (doc-test-example-code example) code-fragment)))

(define (doc-test-runnable-example-ok?
  [example : DocTestExample]
  [index : i64]
  [source-line : i64]
  [expected-exit : i64]
  [expected-stdout : String]
  [expected-stderr : String]
  [code-fragment : String]) : bool
  (begin
    (unless (= (doc-test-example-index example) index) (return false))
    (unless
      (= (doc-test-example-source-line example) source-line)
      (return false))
    (match (doc-test-example-expectation example)
      [(DocTestExpectation.Run actual-exit actual-stdout actual-stderr)
        (begin
          (unless (= actual-exit expected-exit) (return false))
          (unless (string.eq actual-stdout expected-stdout) (return false))
          (unless (string.eq actual-stderr expected-stderr) (return false))
          (doc-test-string-contains?
            (doc-test-example-code example)
            code-fragment))]
      [_ false])))

(define (doc-test-error-list-has-from?
  [errors : doc_error_vec.Vec]
  [index : i64]
  [line : i64]
  [message-fragment : String]) : bool
  (if (>= index (doc-test-error-list-count errors))
    false
    (let
      [err : DocTestError (doc-test-error-list-ref errors index)]
      (if (= (doc-test-error-line err) line)
        (if (doc-test-string-contains?
          (doc-test-error-message err)
          message-fragment)
          true
          (doc-test-error-list-has-from?
            errors
            (+ index 1)
            line
            message-fragment))
        (doc-test-error-list-has-from? errors (+ index 1) line message-fragment)))))

(define (doc-test-error-list-has?
  [errors : doc_error_vec.Vec]
  [line : i64]
  [message-fragment : String]) : bool
  (doc-test-error-list-has-from? errors 0 line message-fragment))

(define (doc-test-smoke-examples-ok? [examples : doc_example_vec.Vec]) : bool
  (if (= (doc-test-example-list-count examples) 2)
    (let
      [first : DocTestExample (doc-test-example-list-ref examples 0)]
      [second : DocTestExample (doc-test-example-list-ref examples 1)]
      (if (doc-test-example-ok? first 1 2 false "(define (main)")
        (doc-test-example-ok? second 2 9 true "(define (bad)")
        false))
    false))

(define (doc-test-malformed-errors-ok? [errors : doc_error_vec.Vec]) : bool
  (if (= (doc-test-error-list-count errors) 3)
    (let
      [first : DocTestError (doc-test-error-list-ref errors 0)]
      [second : DocTestError (doc-test-error-list-ref errors 1)]
      [third : DocTestError (doc-test-error-list-ref errors 2)]
      (begin
        (unless (= (doc-test-error-line first) 1) (return false))
        (unless
          (doc-test-string-contains?
            (doc-test-error-message first)
            "unsupported TypeLisp doctest option")
          (return false))
        (unless (= (doc-test-error-line second) 5) (return false))
        (unless
          (doc-test-string-contains?
            (doc-test-error-message second)
            "empty TypeLisp doctest fence")
          (return false))
        (unless (= (doc-test-error-line third) 8) (return false))
        (doc-test-string-contains?
          (doc-test-error-message third)
          "unterminated TypeLisp doctest fence")))
    false))

(define (doc-test-ordinary-comments-ok?) : bool
  (match (doc-test-extract-source (doc-test-ordinary-comment-source))
    [(DocTestExtraction.Extraction ordinary-examples ordinary-errors)
      (if (= (doc-test-example-list-count ordinary-examples) 0)
        (= (doc-test-error-list-count ordinary-errors) 0)
        false)]))

(define (doc-test-legacy-item-source) : String
  ";: Legacy item docs
;: ```typelisp
;: (define legacy : i64 1)
;: ```
(define legacy : i64 1)")

(define (doc-test-legacy-item-smoke-ok?) : bool
  (match (doc-test-extract-source (doc-test-legacy-item-source))
    [(DocTestExtraction.Extraction examples errors)
      (begin
        (unless (= (doc-test-error-list-count errors) 0) (return false))
        (unless (= (doc-test-example-list-count examples) 1) (return false))
        (let
          [example : DocTestExample (doc-test-example-list-ref examples 0)]
          (doc-test-string-contains?
            (doc-test-example-code example)
            "(define legacy")))]))

(define (doc-test-malformed-smoke-ok?) : bool
  (match (doc-test-extract-source (doc-test-malformed-source))
    [(DocTestExtraction.Extraction malformed-examples malformed-errors)
      (if (= (doc-test-example-list-count malformed-examples) 0)
        (if (= (doc-test-error-list-count malformed-errors) 3)
          (doc-test-malformed-errors-ok? malformed-errors)
          false)
        false)]))

(define (doc-test-runnable-smoke-ok?) : bool
  (match (doc-test-extract-source (doc-test-runnable-source))
    [(DocTestExtraction.Extraction examples errors)
      (begin
        (unless (= (doc-test-error-list-count errors) 0) (return false))
        (unless (= (doc-test-example-list-count examples) 2) (return false))
        (let
          [first : DocTestExample (doc-test-example-list-ref examples 0)]
          [second : DocTestExample (doc-test-example-list-ref examples 1)]
          (begin
            (unless
              (doc-test-runnable-example-ok?
                first
                1
                2
                0
                "hello\n"
                "error\tline\r"
                "(define (main)")
              (return false))
            (doc-test-runnable-example-ok?
              second
              2
              13
              42
              ""
              ""
              "(define (main)"))))]))

(define (doc-test-runnable-malformed-smoke-ok?) : bool
  (match (doc-test-extract-source (doc-test-runnable-malformed-source))
    [(DocTestExtraction.Extraction examples errors)
      (begin
        (unless (= (doc-test-example-list-count examples) 0) (return false))
        (unless (= (doc-test-error-list-count errors) 5) (return false))
        (unless
          (doc-test-error-list-has? errors 1 "cannot be combined")
          (return false))
        (unless
          (doc-test-error-list-has? errors 4 "cannot be combined")
          (return false))
        (unless
          (doc-test-error-list-has? errors 8 "must be an integer")
          (return false))
        (unless
          (doc-test-error-list-has? errors 12 "output metadata")
          (return false))
        (doc-test-error-list-has? errors 14 "requires doctest-exit"))]))

(define (doc-test-smoke) : i64
  (match (doc-test-extract-source (doc-test-smoke-source))
    [(DocTestExtraction.Extraction examples errors)
      (begin
        (unless
          (= (doc-test-error-list-count errors) 0)
          (return (io.panic "doc-test: unexpected extraction error")))
        (unless
          (= (doc-test-example-list-count examples) 2)
          (return (io.panic "doc-test: example count mismatch")))
        (unless
          (doc-test-smoke-examples-ok? examples)
          (return (io.panic "doc-test: example metadata mismatch")))
        (unless
          (doc-test-ordinary-comments-ok?)
          (return (io.panic "doc-test: ordinary comment smoke mismatch")))
        (unless
          (doc-test-legacy-item-smoke-ok?)
          (return (io.panic "doc-test: legacy item smoke mismatch")))
        (unless
          (doc-test-malformed-smoke-ok?)
          (return (io.panic "doc-test: malformed smoke mismatch")))
        (unless
          (doc-test-runnable-smoke-ok?)
          (return (io.panic "doc-test: runnable smoke mismatch")))
        (unless
          (doc-test-runnable-malformed-smoke-ok?)
          (return (io.panic "doc-test: runnable malformed smoke mismatch")))
        42)]))

;; --- runner self-test -----------------------------------------------------------
;; A normal example whose body fails to typecheck (i64 return, bool body).
(define (doc-test-run-unexpected-error-source) : String
  ";# ```typelisp
;# (define (main) : i64 true)
;# ```
")

;; An `expect-error` example that actually checks successfully.
(define (doc-test-run-unexpected-pass-source) : String
  ";# ```typelisp expect-error
;# (define (main) : i64 0)
;# ```
")

;; A file with no doctest fences at all.
(define (doc-test-run-empty-source) : String
  ";; just an ordinary comment, no doctest fence
(define answer : i64 1)
")

(define (doc-test-run-smoke-stdlib-roots) : doc_svec.Vec
  (let
    [roots : doc_svec.Vec (doc_svec.new)]
    (begin
      (doc_svec.push (&mut roots) "stdlib")
      roots)))

(define (doc-test-run-runnable-wrong-exit-source) : String
  ";# ```typelisp run
;# ;; doctest-exit: 0
;# (define (main) : i64 7)
;# ```
")

(define (doc-test-run-runnable-stdout-mismatch-source) : String
  ";# ```typelisp run
;# ;; doctest-exit: 0
;# ;; doctest-stdout: literal:expected\\n
;# (import stdlib.io)
;# (define (main) : i64
;#   (begin
;#     (let [text : String \"actual\\n\"] (io.stdout-write (& text)))
;#     0))
;# ```
")

(define (doc-test-run-runnable-stderr-mismatch-source) : String
  ";# ```typelisp run
;# ;; doctest-exit: 0
;# ;; doctest-stderr: literal:expected-error\\n
;# (import stdlib.io)
;# (define (main) : i64
;#   (begin
;#     (let [text : String \"actual-error\\n\"] (io.stderr-write (& text)))
;#     0))
;# ```
")

(define (doc-test-run-runnable-compile-failure-source) : String
  ";# ```typelisp run
;# ;; doctest-exit: 0
;# (define (main) : i64 true)
;# ```
")

(define (doc-test-run-runnable-implicit-main-source) : String
  ";# ```typelisp run
;# ;; doctest-exit: 0
;# (define answer : i64 1)
;# ```
")

;; The shared smoke source has one passing and one correctly-erroring
;; (`expect-error`) example, so it must run clean: two examples, no failures.
(define (doc-test-run-smoke-pass-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-run-source "docs/ok.tl" (doc-test-smoke-source))]
    (if (= (doc-test-run-report-count report) 2)
      (doc-test-run-report-ok? report)
      false)))

;; A normal example that fails to check yields exactly one failure carrying the
;; fence line (1), example index (1), and the rendered diagnostic message.
(define (doc-test-run-smoke-unexpected-error-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-run-source "docs/bad.tl" (doc-test-run-unexpected-error-source))]
    [failures : doc_run_failure_vec.Vec (doc-test-run-report-failures report)]
    (if (= (doc-test-run-failure-list-count failures) 1)
      (let
        [failure : DocTestRunFailure (doc-test-run-failure-list-ref failures 0)]
        (begin
          (unless (= (doc-test-run-failure-index failure) 1) (return false))
          (unless (= (doc-test-run-failure-line failure) 1) (return false))
          (unless
            (string.eq (doc-test-run-failure-path failure) "docs/bad.tl")
            (return false))
          (doc-test-string-contains?
            (doc-test-run-failure-message failure)
            "return type mismatch")))
      false)))

;; An `expect-error` example that checks successfully is a failure.
(define (doc-test-run-smoke-unexpected-pass-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-run-source "docs/bad.tl" (doc-test-run-unexpected-pass-source))]
    [failures : doc_run_failure_vec.Vec (doc-test-run-report-failures report)]
    (if (= (doc-test-run-failure-list-count failures) 1)
      (doc-test-string-contains?
        (doc-test-run-failure-message
          (doc-test-run-failure-list-ref failures 0))
        "was expected to fail")
      false)))

;; Malformed fences (the shared malformed source's three extraction errors)
;; become three runner failures with no examples.
(define (doc-test-run-smoke-malformed-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-run-source "docs/malformed.tl" (doc-test-malformed-source))]
    (if (= (doc-test-run-report-count report) 0)
      (=
        (doc-test-run-failure-list-count (doc-test-run-report-failures report))
        3)
      false)))

;; A source with no examples reports success with a zero count.
(define (doc-test-run-smoke-empty-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-run-source "docs/empty.tl" (doc-test-run-empty-source))]
    (if (= (doc-test-run-report-count report) 0)
      (doc-test-run-report-ok? report)
      false)))

(define (doc-test-run-smoke-runnable-unsupported-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-run-source-with-roots
        "docs/run.tl"
        (doc-test-runnable-source)
        (doc-test-run-smoke-stdlib-roots))]
    [failures : doc_run_failure_vec.Vec (doc-test-run-report-failures report)]
    (if (= (doc-test-run-report-count report) 2)
      (if (= (doc-test-run-failure-list-count failures) 2)
        (let
          [first : DocTestRunFailure (doc-test-run-failure-list-ref failures 0)]
          [second : DocTestRunFailure
            (doc-test-run-failure-list-ref failures 1)]
          (if (doc-test-string-contains?
            (doc-test-run-failure-message first)
            "unsupported")
            (doc-test-string-contains?
              (doc-test-run-failure-message second)
              "unsupported")
            false))
        false)
      false)))

(define (doc-test-run-smoke-runnable-exec-pass-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-run-source-with-roots
        "docs/run.tl"
        (doc-test-runnable-source)
        (doc-test-run-smoke-stdlib-roots))]
    (if (= (doc-test-run-report-count report) 2)
      (doc-test-run-report-ok? report)
      false)))

(define (doc-test-run-smoke-runnable-implicit-main-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-run-source-with-roots
        "docs/run.tl"
        (doc-test-run-runnable-implicit-main-source)
        (doc-test-run-smoke-stdlib-roots))]
    (if (= (doc-test-run-report-count report) 1)
      (doc-test-run-report-ok? report)
      false)))

(define (doc-test-run-single-failure-message-contains?
  [source : String]
  [fragment : String]) : bool
  (let
    [report : DocTestRunReport
      (doc-test-run-source-with-roots
        "docs/run.tl"
        source
        (doc-test-run-smoke-stdlib-roots))]
    [failures : doc_run_failure_vec.Vec (doc-test-run-report-failures report)]
    (if (= (doc-test-run-report-count report) 1)
      (if (= (doc-test-run-failure-list-count failures) 1)
        (doc-test-string-contains?
          (doc-test-run-failure-message
            (doc-test-run-failure-list-ref failures 0))
          fragment)
        false)
      false)))

(define (doc-test-run-smoke-runnable-failures-ok?) : bool
  (begin
    (unless
      (doc-test-run-single-failure-message-contains?
        (doc-test-run-runnable-wrong-exit-source)
        "expected exit: 0")
      (return false))
    (unless
      (doc-test-run-single-failure-message-contains?
        (doc-test-run-runnable-wrong-exit-source)
        "actual exit: 7")
      (return false))
    (unless
      (doc-test-run-single-failure-message-contains?
        (doc-test-run-runnable-stdout-mismatch-source)
        "expected stdout:")
      (return false))
    (unless
      (doc-test-run-single-failure-message-contains?
        (doc-test-run-runnable-stdout-mismatch-source)
        "actual\n")
      (return false))
    (unless
      (doc-test-run-single-failure-message-contains?
        (doc-test-run-runnable-stderr-mismatch-source)
        "expected stderr:")
      (return false))
    (unless
      (doc-test-run-single-failure-message-contains?
        (doc-test-run-runnable-stderr-mismatch-source)
        "actual-error\n")
      (return false))
    (unless
      (doc-test-run-single-failure-message-contains?
        (doc-test-run-runnable-compile-failure-source)
        "runnable compile failed")
      (return false))
    true))

(define (doc-test-typecheck-smoke-runnable-only-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-typecheck-source-with-roots
        "docs/run.tl"
        (doc-test-run-runnable-wrong-exit-source)
        (doc-test-run-smoke-stdlib-roots))]
    (if (= (doc-test-run-report-count report) 1)
      (doc-test-run-report-ok? report)
      false)))

(define (doc-test-typecheck-smoke-unexpected-pass-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-typecheck-source
        "docs/bad.tl"
        (doc-test-run-unexpected-pass-source))]
    [failures : doc_run_failure_vec.Vec (doc-test-run-report-failures report)]
    (if (= (doc-test-run-failure-list-count failures) 1)
      (doc-test-string-contains?
        (doc-test-run-failure-message
          (doc-test-run-failure-list-ref failures 0))
        "was expected to fail")
      false)))

(define (doc-test-typecheck-smoke-malformed-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-typecheck-source
        "docs/malformed.tl"
        (doc-test-malformed-source))]
    (if (= (doc-test-run-report-count report) 0)
      (=
        (doc-test-run-failure-list-count (doc-test-run-report-failures report))
        3)
      false)))

(define (doc-test-run-smoke-runnable-ok?) : bool
  (if (doc-test-runnable-supported?)
    (begin
      (unless (doc-test-run-smoke-runnable-exec-pass-ok?) (return false))
      (unless (doc-test-run-smoke-runnable-implicit-main-ok?) (return false))
      (doc-test-run-smoke-runnable-failures-ok?))
    (doc-test-run-smoke-runnable-unsupported-ok?)))

;; The rendered failure carries the path, line, and message.
(define (doc-test-run-smoke-render-ok?) : bool
  (let
    [rendered : String
      (doc-test-run-failure-render
        (DocTestRunFailure.Failure
          "docs/bad.tl"
          4
          2
          "doctest example 2 was expected to pass
typecheck: return type mismatch"))]
    (if (doc-test-string-contains? rendered "docs/bad.tl:4:")
      (if (doc-test-string-contains? rendered "doctest example 2")
        (doc-test-string-contains? rendered "return type mismatch")
        false)
      false)))

;; The report-level text mirrors the Rust CLI: a clean run renders the
;; `Doc tests passed: N example(s)` line with status 0, and a failing run renders
;; the `doc tests failed: M failure(s) across N example(s)` summary with status 1.
(define (doc-test-run-smoke-report-render-ok?) : bool
  (let
    [pass-report : DocTestRunReport
      (doc-test-run-source "docs/ok.tl" (doc-test-smoke-source))]
    [fail-report : DocTestRunReport
      (doc-test-run-source "docs/bad.tl" (doc-test-run-unexpected-error-source))]
    (begin
      (unless (= (doc-test-run-report-status pass-report) 0) (return false))
      (unless
        (string.eq
          (doc-test-run-report-render pass-report)
          "Doc tests passed: 2 example(s)")
        (return false))
      (unless (= (doc-test-run-report-status fail-report) 1) (return false))
      (unless
        (doc-test-string-contains?
          (doc-test-run-report-render fail-report)
          "doc tests failed: 1 failure(s) across 1 example(s)")
        (return false))
      (doc-test-string-contains?
        (doc-test-run-report-render fail-report)
        "return type mismatch"))))

(define (doc-test-session-cache-source) : String
  ";# ```typelisp
;# (import \"stdlib/dep.tl\")
;# (define (main) : i64 shared-value)
;# ```
;# ```typelisp
;# (import \"stdlib/dep.tl\")
;# (define (main) : i64 shared-value)
;# ```
")

(define (doc-test-session-cache-smoke-ok?) : bool
  (let
    [root : String "target/doc_test_session_cache"]
    [dep-file : String "target/doc_test_session_cache/dep.tl"]
    [doc-file : String "target/doc_test_session_cache/docs.tl"]
    [roots : doc_svec.Vec
      (let
        [items : doc_svec.Vec (doc_svec.new)]
        (begin
          (doc_svec.push (&mut items) "target/doc_test_session_cache")
          items))]
    (begin
      (compiler-load-test-mkdir "target")
      (compiler-load-test-mkdir root)
      (io.write-file dep-file "(define shared-value : i64 7)")
      (compiler-load-session-cache-enable!)
      (compiler-load-program-cache-clear!)
      (let
        [report : DocTestRunReport
          (doc-test-typecheck-source-with-roots
            doc-file
            (doc-test-session-cache-source)
            roots)]
        [hits : i64 (compiler-load-program-cache-hit-count-value)]
        (begin
          (compiler-load-session-cache-disable-for-test!)
          (and (doc-test-run-report-ok? report) (> hits 0)))))))

(define (doc-test-package-walk-example-source [value : i64]) : String
  (string.append
    ";# ```typelisp
;# (define (main) : i64 "
    (string.append (string.int->string value) ")
;# ```
")))

(define (doc-test-package-walk-numbered-path
  [root : String]
  [prefix : String]
  [index : i64]) : String
  (string.append
    root
    (string.append
      "/"
      (string.append prefix (string.append (string.int->string index) ".tl")))))

(define (doc-test-package-walk-write-empty-paths
  [root : String]
  [count : i64]
  [paths : AstDeclPathList]) : AstDeclPathList
  (let
    [i : i64 0]
    [out : AstDeclPathList paths]
    (begin
      (while (< i count)
        (let
          [path : String (doc-test-package-walk-numbered-path root "empty_" i)]
          (begin
            (io.write-file path ";; no doctest fence
")
            (set!
              out
              (ast-decl-path-list-prepend-builder-with-owner-id
                path
                cbi.compiler-builtin-id-fix-empty
                out))
            (set! i (+ i 1)))))
      out)))

(define (doc-test-package-walk-long-list-smoke-ok?) : bool
  (let
    [root : String "target/doc_test_package_walk"]
    [example-a : String (doc-test-package-walk-numbered-path root "example_" 1)]
    [example-b : String (doc-test-package-walk-numbered-path root "example_" 2)]
    [example-c : String (doc-test-package-walk-numbered-path root "example_" 3)]
    (begin
      (compiler-load-test-mkdir "target")
      (compiler-load-test-mkdir root)
      (io.write-file example-a (doc-test-package-walk-example-source 1))
      (io.write-file example-b (doc-test-package-walk-example-source 2))
      (io.write-file example-c (doc-test-package-walk-example-source 3))
      (let
        [paths : AstDeclPathList
          (doc-test-package-walk-write-empty-paths
            root
            128
            (ast-decl-root-path-cons
              example-a
              (ast-decl-root-path-cons
                example-a
                (ast-decl-root-path-cons
                  example-b
                  (ast-decl-root-path-cons example-c (ast-decl-path-list-new))))))]
        [report : DocTestRunReport
          (doc-test-typecheck-package-paths-with-roots
            paths
            (doc-test-run-smoke-stdlib-roots)
            root
            (compiler-pkg-deps-empty))]
        (and
          (doc-test-run-report-ok? report)
          (= (doc-test-run-report-count report) 3))))))

(define (doc-test-run-smoke) : i64
  (begin
    (unless
      (doc-test-error-vector-growth-smoke-ok?)
      (return (io.panic "doc-test-run: generated error vector growth mismatch")))
    (unless
      (doc-test-line-vector-growth-smoke-ok?)
      (return (io.panic "doc-test-run: generated line vector growth mismatch")))
    (unless
      (doc-test-example-vector-growth-smoke-ok?)
      (return
        (io.panic "doc-test-run: generated example vector growth mismatch")))
    (unless
      (doc-test-run-failure-vector-growth-smoke-ok?)
      (return
        (io.panic "doc-test-run: generated failure vector growth mismatch")))
    (unless
      (doc-test-run-smoke-pass-ok?)
      (return (io.panic "doc-test-run: pass-case mismatch")))
    (unless
      (doc-test-run-smoke-unexpected-error-ok?)
      (return (io.panic "doc-test-run: unexpected-error mismatch")))
    (unless
      (doc-test-run-smoke-unexpected-pass-ok?)
      (return (io.panic "doc-test-run: unexpected-pass mismatch")))
    (unless
      (doc-test-run-smoke-malformed-ok?)
      (return (io.panic "doc-test-run: malformed mismatch")))
    (unless
      (doc-test-run-smoke-empty-ok?)
      (return (io.panic "doc-test-run: empty-source mismatch")))
    (unless
      (doc-test-run-smoke-runnable-ok?)
      (return (io.panic "doc-test-run: runnable execution mismatch")))
    (unless
      (doc-test-typecheck-smoke-runnable-only-ok?)
      (return (io.panic "doc-test-typecheck: runnable typecheck mismatch")))
    (unless
      (doc-test-typecheck-smoke-unexpected-pass-ok?)
      (return (io.panic "doc-test-typecheck: unexpected-pass mismatch")))
    (unless
      (doc-test-typecheck-smoke-malformed-ok?)
      (return (io.panic "doc-test-typecheck: malformed mismatch")))
    (unless
      (doc-test-public-diagnostic-render-smoke-ok?)
      (return (io.panic "doc-test-run: public diagnostic render mismatch")))
    (unless
      (doc-test-run-smoke-render-ok?)
      (return (io.panic "doc-test-run: render mismatch")))
    (unless
      (doc-test-run-smoke-report-render-ok?)
      (return (io.panic "doc-test-run: report render mismatch")))
    (unless
      (doc-test-session-cache-smoke-ok?)
      (return (io.panic "doc-test-run: session cache smoke mismatch")))
    (unless
      (doc-test-package-walk-long-list-smoke-ok?)
      (return (io.panic "doc-test-run: package walk long-list mismatch")))
    42))

;; Combined smoke: extraction then runner. Returns 42 iff both
;; self-test batteries pass.
(define (doc-test-smoke-all) : i64
  (begin
    (unless
      (= (doc-test-smoke) 42)
      (return (io.panic "doc-test: extraction smoke regressed")))
    (unless
      (source-tool-link-inputs-dedupe-smoke-ok?)
      (return (io.panic "source-tool: link input dedupe smoke regressed")))
    (unless
      (source-tool-windows-stack-reserve-smoke-ok?)
      (return (io.panic "source-tool: windows stack reserve smoke regressed")))
    (unless
      (source-tool-linux-direct-object-linkability-smoke-ok?)
      (return (io.panic "source-tool: linux direct object smoke regressed")))
    (unless
      (source-tool-windows-direct-object-linkability-smoke-ok?)
      (return (io.panic "source-tool: windows direct object smoke regressed")))
    (unless
      (source-tool-windows-direct-object-runtime-fallback-smoke-ok?)
      (return
        (io.panic "source-tool: windows direct object fallback smoke regressed")))
    (unless
      (source-tool-windows-direct-object-relocation-gate-smoke-ok?)
      (return
        (io.panic
          "source-tool: windows direct object relocation gate smoke regressed")))
    (doc-test-run-smoke)))