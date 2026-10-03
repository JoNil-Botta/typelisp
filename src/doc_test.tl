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
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.process)
(import stdlib.vector)
(import (vector.vector String) as doc_svec)
(import compiler_check_core)
(import compiler_backend as backend)
(import compiler_ast_types as ast)
(import compiler_diagnostic as cdiag)
(import compiler_driver_core as driver)
(import compiler_cfg_core as cfg_core)
(import compiler_lower as lower)
(import compiler_optimize as opt)
(import compiler_typecheck_core as tc)
(import compiler_load)
(import build_run_core)
(import stdlib.string)
(import source_text_core as source_text)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.option)
(import (option.option i64) as option_i64)
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

;; Extraction contains only scalar locations, expectations and owned strings.
;; Copy live rows explicitly; vector capacity can include uninitialized slots.
(define (doc-test-extraction-copy [extraction : DocTestExtraction]) : DocTestExtraction
  (match extraction
    [(Extraction examples errors)
      (let
        [out-examples : doc_example_vec.Vec (doc_example_vec.new)]
        [out-errors : doc_error_vec.Vec (doc_error_vec.new)]
        [index : i64 0]
        (while (< index (doc_example_vec.len (& examples)))
          (match (doc-test-example-list-ref examples index)
            [(Example ordinal line expectation code)
              (doc_example_vec.push-ref!
                (&mut out-examples)
                (Example
                  ordinal
                  line
                  (match expectation
                    [(Pass) (Pass)]
                    [(Error) (Error)]
                    [(Run status stdout stderr)
                      (Run status (string.copy stdout) (string.copy stderr))])
                  (string.copy code)))])
          (set! index (+ index 1)))
        (set! index 0)
        (while (< index (doc_error_vec.len (& errors)))
          (match (doc-test-error-list-ref errors index)
            [(Error line message)
              (doc_error_vec.push-ref!
                (&mut out-errors)
                (DocTestError.Error line (string.copy message)))])
          (set! index (+ index 1)))
        (Extraction out-examples out-errors))]))

;; Package discovery tolerates a path disappearing before checking.
;; The source bytes and line/fence scanner are disposable; only extracted code,
;; runnable output expectations and errors survive into compiler typechecking.
(define (doc-test-extract-package-file-text [path : String]) : DocTestExtraction
  (let
    [home : arena.Arena (arena.current)]
    (with-scratch
      (match (io.try-read-file (& path))
        [(ErrIoBytes _)
          (in-arena home (Extraction (doc_example_vec.new) (doc_error_vec.new)))]
        [(OkIoBytes contents)
          (let
            [extraction : DocTestExtraction
              (doc-test-extract-source (byte_buf.to-string contents))]
            (in-arena home (doc-test-extraction-copy extraction)))]))))

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

(define (doc-test-example-list-count
  [examples : (& examples doc_example_vec.Vec)]) : i64
  (doc_example_vec.len examples))

(define (doc-test-example-list-ref
  [examples : (& examples doc_example_vec.Vec)]
  [index : i64]) : DocTestExample
  (doc_example_vec.get examples index (Example 0 0 (Pass) "")))

(define (doc-test-example-list-append
  [examples : doc_example_vec.Vec]
  [example : DocTestExample]) : doc_example_vec.Vec
  (let
    [out : doc_example_vec.Vec examples]
    (doc_example_vec.push-ref! (&mut out) example)
    out))

(define (doc-test-error-list-empty) : doc_error_vec.Vec
  (doc_error_vec.new))

(define (doc-test-error-list-count [errors : (& errors doc_error_vec.Vec)]) : i64
  (doc_error_vec.len errors))

(define (doc-test-error-list-ref
  [errors : (& errors doc_error_vec.Vec)]
  [index : i64]) : DocTestError
  (doc_error_vec.get (& errors) index (DocTestError.Error 0 "")))

(define (doc-test-error-list-append
  [errors : doc_error_vec.Vec]
  [err : DocTestError]) : doc_error_vec.Vec
  (let
    [out : doc_error_vec.Vec errors]
    (doc_error_vec.push-ref! (&mut out) err)
    out))

(define (doc-test-error-list-append-all-from
  [errors : doc_error_vec.Vec]
  [more : (& more doc_error_vec.Vec)]
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
    [(Line line-number _) line-number]))

(define (doc-test-line-text [line : DocTestLine]) : String
  (match line
    [(Line _ text) text]))

(define (doc-test-example-index [example : DocTestExample]) : i64
  (match example
    [(Example index _ _ _) index]))

(define (doc-test-example-source-line [example : DocTestExample]) : i64
  (match example
    [(Example _ source-line _ _) source-line]))

(define (doc-test-example-expectation [example : DocTestExample]) : DocTestExpectation
  (match example
    [(Example _ _ expectation _) expectation]))

(define (doc-test-example-code [example : DocTestExample]) : String
  (match example
    [(Example _ _ _ code) code]))

(define (doc-test-error-line [err : DocTestError]) : i64
  (match err
    [(Error line-number _) line-number]))

(define (doc-test-error-message [err : DocTestError]) : String
  (match err
    [(Error _ message) message]))

(define (doc-test-expectation-error? [expectation : DocTestExpectation]) : bool
  (match expectation
    [(Pass) false]
    [(Error) true]
    [(Run _ _ _) false]))

(define (doc-test-expectation-run? [expectation : DocTestExpectation]) : bool
  (match expectation
    [(Run _ _ _) true]
    [_ false]))

(define (doc-test-expectation-run-exit [expectation : DocTestExpectation]) : i64
  (match expectation
    [(Run expected-exit _ _) expected-exit]
    [_ -1]))

(define (doc-test-expectation-run-stdout [expectation : DocTestExpectation]) : String
  (match expectation
    [(Run _ expected-stdout _) expected-stdout]
    [_ ""]))

(define (doc-test-expectation-run-stderr [expectation : DocTestExpectation]) : String
  (match expectation
    [(Run _ _ expected-stderr) expected-stderr]
    [_ ""]))

(define (doc-test-space? [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

(define (doc-test-inline-space? [c : char]) : bool
  (or (= c ' ') (= c '\t')))

(define (doc-test-trim-left [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [start : i64 0]
    [done : bool false]
    (while (< i n)
      (if done
        (set! i n)
        (if (doc-test-inline-space? (string.string-ref text i))
          (begin
            (set! start (+ i 1))
            (set! i (+ i 1)))
          (set! done true))))
    (string.substring text start (- n start))))

(define (doc-test-trim-right [text : String]) : String
  (let
    [end : i64 (string.string-length text)]
    [keep : bool true]
    (while keep
      (if (> end 0)
        (if (doc-test-inline-space? (string.string-ref text (- end 1)))
          (set! end (- end 1))
          (set! keep false))
        (set! keep false)))
    (string.substring text 0 end)))

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
      None
      (let
        [i : i64 0]
        [sign : i64 1]
        [value : i64 0]
        [ok : bool true]
        (when (= (string.string-ref trimmed 0) '-') (set! sign -1) (set! i 1))
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
          (Some (* sign value))
          None)))))

(define (doc-test-decode-output-literal [text : String]) : DocTestMaybeOutput
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [out : String ""]
    [message : String ""]
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
                  (set! out (str_cat.str-cat out "\n" ""))
                  (set! i (+ i 2))]
                [(= esc 't')
                  (set! out (str_cat.str-cat out "\t" ""))
                  (set! i (+ i 2))]
                [(= esc 'r')
                  (set! out (str_cat.str-cat out "\r" ""))
                  (set! i (+ i 2))]
                [(= esc '\\')
                  (set! out (str_cat.str-cat out "\\" ""))
                  (set! i (+ i 2))]
                [else
                  (set!
                    message
                    (str_cat.str-cat
                      "unsupported doctest output escape `\\"
                      (string.substring text (+ i 1) 1)
                      "`"))])))
          (begin
            (set! out (str_cat.str-cat out (string.substring text i 1) ""))
            (set! i (+ i 1))))))
    (if (= (string.string-length message) 0)
      (Some out)
      (No message))))

(define (doc-test-parse-output-spec [text : String]) : DocTestMaybeOutput
  (let
    [trimmed : String (doc-test-trim text)]
    (if (string.eq trimmed "-")
      (Some "")
      (if (source_text.starts-with? trimmed "literal:")
        (doc-test-decode-output-literal
          (string.substring trimmed 8 (- (string.string-length trimmed) 8)))
        (No "doctest output metadata must be '-' or 'literal:<escaped text>'")))))

(define (doc-test-string-blank? [text : (& text str)]) : bool
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [blank : bool true]
    (while (< i n)
      (if blank
        (if (doc-test-space? (string.string-ref text i))
          (set! i (+ i 1))
          (begin
            (set! blank false)
            (set! i n)))
        (set! i n)))
    blank))

(define (doc-test-word-end [text : (& text str)] [start : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 start]
    [keep : bool true]
    (while keep
      (if (< i n)
        (if (doc-test-space? (string.string-ref text i))
          (set! keep false)
          (set! i (+ i 1)))
        (set! keep false)))
    i))

(define (doc-test-doc-comment-body-with-prefix
  [line : String]
  [prefix : String]) : DocTestMaybeString
  (let
    [trimmed : String (doc-test-trim-left line)]
    (if (source_text.starts-with? trimmed prefix)
      (let
        [prefix-len : i64 (string.string-length prefix)]
        [trimmed-len : i64 (string.string-length trimmed)]
        [body : String
          (string.substring trimmed prefix-len (- trimmed-len prefix-len))]
        (if (> (string.string-length body) 0)
          (if (= (string.string-ref body 0) ' ')
            (Some (string.substring body 1 (- (string.string-length body) 1)))
            (Some body))
          (Some body)))
      (No))))

(define (doc-test-module-doc-comment-body [line : String]) : DocTestMaybeString
  (doc-test-doc-comment-body-with-prefix line ";#"))

(define (doc-test-item-doc-comment-body [line : String]) : DocTestMaybeString
  (doc-test-doc-comment-body-with-prefix line ";:"))

(define (doc-test-starts-with-form-head? [text : (& text str)] [head : String]) : bool
  (if (source_text.starts-with? text head)
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
      (TypeLisp mode)
      (let
        [end : i64 (doc-test-word-end trimmed 0)]
        [option : String (string.substring trimmed 0 end)]
        [rest : String
          (string.substring trimmed end (- (string.string-length trimmed) end))]
        (if (string.eq option "expect-error")
          (match mode
            [(Run)
              (Malformed
                (Error
                  line-number
                  "TypeLisp doctest options `run` and `expect-error` cannot be combined"))]
            [(Check _)
              (doc-test-parse-fence-options rest line-number (Check (Error)))])
          (if (string.eq option "run")
            (match (owned_view.compiler-owned-shared-view mode)
              [(Run) (doc-test-parse-fence-options rest line-number mode)]
              [(Check expectation)
                (if (doc-test-expectation-error? expectation)
                  (Malformed
                    (Error
                      line-number
                      "TypeLisp doctest options `run` and `expect-error` cannot be combined"))
                  (doc-test-parse-fence-options rest line-number (Run)))])
            (Malformed
              (Error
                line-number
                (str_cat.str-cat
                  "unsupported TypeLisp doctest option `"
                  option
                  "`")))))))))

(define (doc-test-parse-fence-info [info : String] [line-number : i64]) : DocTestFenceInfo
  (let
    [trimmed : String (doc-test-trim-left info)]
    (if (= (string.string-length trimmed) 0)
      (Ignore)
      (let
        [end : i64 (doc-test-word-end trimmed 0)]
        [language : String (string.substring trimmed 0 end)]
        [rest : String
          (string.substring trimmed end (- (string.string-length trimmed) end))]
        (if (or (string.eq language "typelisp") (string.eq language "tl"))
          (doc-test-parse-fence-options rest line-number (Check (Pass)))
          (Ignore))))))

(define (doc-test-skip-ignored-fence-from
  [lines : (& lines doc_line_vec.Vec)]
  [index : i64]) : i64
  (if (>= index (doc_line_vec.len (& lines)))
    (doc_line_vec.len (& lines))
    (let
      [line : DocTestLine (doc_line_vec.get (& lines) index (Line 0 ""))]
      (if (source_text.starts-with?
        (doc-test-trim-left (doc-test-line-text line))
        "```")
        (+ index 1)
        (doc-test-skip-ignored-fence-from lines (+ index 1))))))

(define (doc-test-collect-code-inner
  [lines : (& lines doc_line_vec.Vec)]
  [index : i64]
  [code : String]
  [collected : doc_line_vec.Vec]) : DocTestCodeCollect
  (if (>= index (doc_line_vec.len (& lines)))
    (Collect (doc_line_vec.len (& lines)) code collected false)
    (let
      [line : DocTestLine (doc_line_vec.get (& lines) index (Line 0 ""))]
      (if (source_text.starts-with?
        (doc-test-trim-left
          (doc-test-line-text (owned_view.compiler-owned-shared-view line)))
        "```")
        (Collect (+ index 1) code collected true)
        (let
          [out : doc_line_vec.Vec collected]
          (doc_line_vec.push-ref!
            (&mut out)
            (owned_view.compiler-owned-shared-view line))
          (doc-test-collect-code-inner
            lines
            (+ index 1)
            (str_cat.str-cat code (doc-test-line-text line) "\n")
            out))))))

(define (doc-test-collect-code
  [lines : (& lines doc_line_vec.Vec)]
  [index : i64]) : DocTestCodeCollect
  (doc-test-collect-code-inner lines index "" (doc_line_vec.new)))

(define (doc-test-metadata-value [line : DocTestLine] [prefix : String]) : DocTestMaybeString
  (let
    [trimmed : String (doc-test-trim-left (doc-test-line-text line))]
    (if (source_text.starts-with? trimmed prefix)
      (Some
        (doc-test-trim
          (string.substring
            trimmed
            (string.string-length prefix)
            (- (string.string-length trimmed) (string.string-length prefix)))))
      (No))))

(define (doc-test-metadata-line? [line : DocTestLine]) : bool
  (source_text.starts-with?
    (doc-test-trim-left (doc-test-line-text line))
    ";; doctest-"))

(define (doc-test-run-metadata-append-error
  [metadata : DocTestRunMetadata]
  [err : DocTestError]) : DocTestRunMetadata
  (match metadata
    [(Metadata
        has-exit
        expected-exit
        has-stdout
        expected-stdout
        has-stderr
        expected-stderr
        errors)
      (Metadata
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
  (match (owned_view.compiler-owned-shared-view metadata)
    [(Metadata
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
          (Error (doc-test-line-number line) "duplicate doctest-exit metadata"))
        (match (doc-test-parse-i64 text)
          [(Some parsed)
            (Metadata
              true
              parsed
              has-stdout
              expected-stdout
              has-stderr
              expected-stderr
              errors)]
          [None
            (doc-test-run-metadata-append-error
              (Metadata
                true
                expected-exit
                has-stdout
                expected-stdout
                has-stderr
                expected-stderr
                errors)
              (Error
                (doc-test-line-number line)
                "doctest-exit metadata must be an integer"))]))]))

(define (doc-test-run-metadata-set-stdout
  [metadata : DocTestRunMetadata]
  [line : DocTestLine]
  [text : String]) : DocTestRunMetadata
  (match (owned_view.compiler-owned-shared-view metadata)
    [(Metadata
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
          (Error
            (doc-test-line-number line)
            "duplicate doctest-stdout metadata"))
        (match (doc-test-parse-output-spec text)
          [(Some parsed)
            (Metadata
              has-exit
              expected-exit
              true
              parsed
              has-stderr
              expected-stderr
              errors)]
          [(No message)
            (doc-test-run-metadata-append-error
              metadata
              (Error (doc-test-line-number line) message))]))]))

(define (doc-test-run-metadata-set-stderr
  [metadata : DocTestRunMetadata]
  [line : DocTestLine]
  [text : String]) : DocTestRunMetadata
  (match (owned_view.compiler-owned-shared-view metadata)
    [(Metadata
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
          (Error
            (doc-test-line-number line)
            "duplicate doctest-stderr metadata"))
        (match (doc-test-parse-output-spec text)
          [(Some parsed)
            (Metadata
              has-exit
              expected-exit
              has-stdout
              expected-stdout
              true
              parsed
              errors)]
          [(No message)
            (doc-test-run-metadata-append-error
              metadata
              (Error (doc-test-line-number line) message))]))]))

(define (doc-test-run-metadata-parse-line
  [metadata : DocTestRunMetadata]
  [line : DocTestLine]) : DocTestRunMetadata
  (match (doc-test-metadata-value
    (owned_view.compiler-owned-shared-view line)
    ";; doctest-exit:")
    [(Some value) (doc-test-run-metadata-set-exit metadata line value)]
    [(No)
      (match (doc-test-metadata-value
        (owned_view.compiler-owned-shared-view line)
        ";; doctest-stdout:")
        [(Some value) (doc-test-run-metadata-set-stdout metadata line value)]
        [(No)
          (match (doc-test-metadata-value
            (owned_view.compiler-owned-shared-view line)
            ";; doctest-stderr:")
            [(Some value)
              (doc-test-run-metadata-set-stderr metadata line value)]
            [(No)
              (if (doc-test-metadata-line?
                (owned_view.compiler-owned-shared-view line))
                (doc-test-run-metadata-append-error
                  metadata
                  (Error
                    (doc-test-line-number line)
                    "unsupported runnable doctest metadata"))
                metadata)])])]))

(define (doc-test-run-metadata-parse-lines-from
  [lines : (& lines doc_line_vec.Vec)]
  [metadata : DocTestRunMetadata]
  [index : i64]) : DocTestRunMetadata
  (if (>= index (doc_line_vec.len (& lines)))
    metadata
    (doc-test-run-metadata-parse-lines-from
      lines
      (doc-test-run-metadata-parse-line
        metadata
        (doc_line_vec.get (& lines) index (Line 0 "")))
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
    (Metadata false 0 false "" false "" (doc-test-error-list-empty)))
    [(Metadata
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
              (Error
                source-line
                "runnable TypeLisp doctest requires doctest-exit metadata")))]
        (if (= (doc-test-error-list-count all-errors) 0)
          (Ok (Run expected-exit expected-stdout expected-stderr))
          (Err all-errors)))]))

(define (doc-test-scan-type-lisp-fence
  [lines : (& lines doc_line_vec.Vec)]
  [index : i64]
  [state : DocTestScanState]
  [source-line : i64]
  [mode : DocTestFenceMode]) : DocTestScanState
  (match (doc-test-collect-code lines index)
    [(Collect remaining code code-lines closed)
      (match state
        [(State examples errors next-index)
          (if closed
            (if (doc-test-string-blank? code)
              (doc-test-scan-doc-block-from
                lines
                remaining
                (State
                  examples
                  (doc-test-error-list-append
                    errors
                    (Error source-line "empty TypeLisp doctest fence"))
                  next-index))
              (doc-test-scan-doc-block-from
                lines
                remaining
                (match mode
                  [(Check expectation)
                    (State
                      (doc-test-example-list-append
                        examples
                        (Example next-index source-line expectation code))
                      errors
                      (+ next-index 1))]
                  [(Run)
                    (match (doc-test-parse-run-metadata source-line code-lines)
                      [(Ok expectation)
                        (State
                          (doc-test-example-list-append
                            examples
                            (Example next-index source-line expectation code))
                          errors
                          (+ next-index 1))]
                      [(Err metadata-errors)
                        (State
                          examples
                          (doc-test-error-list-append-all
                            errors
                            metadata-errors)
                          next-index)])])))
            (State
              examples
              (doc-test-error-list-append
                errors
                (Error source-line "unterminated TypeLisp doctest fence"))
              next-index))])]))

(define (doc-test-scan-doc-block-from
  [lines : (& lines doc_line_vec.Vec)]
  [index : i64]
  [state : DocTestScanState]) : DocTestScanState
  (if (>= index (doc_line_vec.len (& lines)))
    state
    (let
      [line : DocTestLine (doc_line_vec.get (& lines) index (Line 0 ""))]
      [trimmed : String
        (doc-test-trim-left
          (doc-test-line-text (owned_view.compiler-owned-shared-view line)))]
      (if (source_text.starts-with? trimmed "```")
        (let
          [info : String
            (string.substring trimmed 3 (- (string.string-length trimmed) 3))]
          (match (doc-test-parse-fence-info
            info
            (doc-test-line-number (owned_view.compiler-owned-shared-view line)))
            [(Ignore)
              (doc-test-scan-doc-block-from
                lines
                (doc-test-skip-ignored-fence-from lines (+ index 1))
                state)]
            [(Malformed err)
              (match state
                [(State examples errors next-index)
                  (doc-test-scan-doc-block-from
                    lines
                    (doc-test-skip-ignored-fence-from lines (+ index 1))
                    (State
                      examples
                      (doc-test-error-list-append errors err)
                      next-index))])]
            [(TypeLisp expectation)
              (doc-test-scan-type-lisp-fence
                lines
                (+ index 1)
                state
                (doc-test-line-number line)
                expectation)]))
        (doc-test-scan-doc-block-from lines (+ index 1) state)))))

(define (doc-test-scan-doc-block
  [lines : (& lines doc_line_vec.Vec)]
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
      (State (doc-test-example-list-empty) (doc-test-error-list-empty) 1)]
    (while (< pos n)
      (let
        [line-end : i64 (source_text.line-end src pos)]
        [line : String (string.substring src pos (- line-end pos))]
        (match (doc-test-module-doc-comment-body
          (owned_view.compiler-owned-shared-view line))
          [(Some body)
            (set! pending-lines (doc_line_vec.new))
            (doc_line_vec.push-ref! (&mut module-lines) (Line line-number body))]
          [(No)
            (unless
              (doc-test-string-blank? line)
              (set! state (doc-test-scan-doc-block module-lines state))
              (set! module-lines (doc_line_vec.new))
              (match (doc-test-item-doc-comment-body
                (owned_view.compiler-owned-shared-view line))
                [(Some body)
                  (doc_line_vec.push-ref!
                    (&mut pending-lines)
                    (Line line-number body))]
                [(No)
                  (if (doc-test-supported-item-declaration? line)
                    (begin
                      (set! state (doc-test-scan-doc-block pending-lines state))
                      (set! pending-lines (doc_line_vec.new)))
                    (set! pending-lines (doc_line_vec.new)))]))])
        (set! pos (source_text.next-line-start src line-end))
        (set! line-number (+ line-number 1))))
    (set! state (doc-test-scan-doc-block module-lines state))
    (match state
      [(State examples errors _) (Extraction examples errors)])))

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

(define (doc-test-run-report-count [report : DocTestRunReport]) : i64
  (match report
    [(Report count _) count]))

(define (doc-test-run-report-failures [report : DocTestRunReport]) : doc_run_failure_vec.Vec
  (match report
    [(Report _ failures) failures]))

(define (doc-test-run-failure-list-empty) : doc_run_failure_vec.Vec
  (doc_run_failure_vec.new))

(define (doc-test-run-failure-list-count
  [failures : (& failures doc_run_failure_vec.Vec)]) : i64
  (doc_run_failure_vec.len (& failures)))

(define (doc-test-run-failure-list-ref
  [failures : (& failures doc_run_failure_vec.Vec)]
  [index : i64]) : DocTestRunFailure
  (doc_run_failure_vec.get (& failures) index (Failure "" 0 0 "")))

(define (doc-test-run-report-ok? [report : DocTestRunReport]) : bool
  (=
    (let
      [failures (doc-test-run-report-failures report)]
      (doc-test-run-failure-list-count failures))
    0))

(define (doc-test-run-report-add-prefix-count
  [prefix-count : i64]
  [report : DocTestRunReport]) : DocTestRunReport
  (Report
    (+
      prefix-count
      (doc-test-run-report-count (owned_view.compiler-owned-shared-view report)))
    (doc-test-run-report-failures report)))

(define (doc-test-run-failure-list-append
  [failures : doc_run_failure_vec.Vec]
  [failure : DocTestRunFailure]) : doc_run_failure_vec.Vec
  (let
    [out : doc_run_failure_vec.Vec failures]
    (doc_run_failure_vec.push-ref! (&mut out) failure)
    out))

;; Render a failure as `path:line: message`. Fence-level extraction
;; errors use index `-1`; example failures include the example number in their
;; message.
(define (doc-test-run-failure-render [failure : DocTestRunFailure]) : String
  (match failure
    [(Failure path line index message)
      (let
        [location : String
          (str_cat.str-cat path ":" (string.int->string line) ": ")]
        (str_cat.str-cat location message))]))

(define (doc-test-unexpected-pass-message [index : i64]) : String
  (str_cat.str-cat
    "doctest example "
    (string.int->string index)
    " was expected to fail but passed"))

(define (doc-test-public-diagnostic-render [diag : cdiag.CompilerDiagnostic]) : String
  (match (cdiag.compiler-diagnostic-code diag)
    [(CompilerDiagnosticSomeString code)
      (str_cat.str-cat
        "error["
        code
        "]: "
        (cdiag.compiler-diagnostic-render diag))]
    [CompilerDiagnosticNoString
      (str_cat.str-cat "error: " (cdiag.compiler-diagnostic-render diag))]))

(define (doc-test-unexpected-error-message
  [index : i64]
  [diag : cdiag.CompilerDiagnostic]) : String
  (str_cat.str-cat
    "doctest example "
    (string.int->string index)
    " was expected to pass\n"
    (doc-test-public-diagnostic-render diag)))

;; Runnable doctests spawn nested build/run commands from a generated test
;; binary. This is a required gate on both Linux and Windows because skipped
;; runnable doctests can hide target-specific compiler/runtime bugs.
(define (doc-test-runnable-target-supported?
  [target : backend.CompilerBackendTarget]) : bool
  (match target
    [(Linux) true]
    [(Windows) true]))

(define (doc-test-runnable-unsupported-message
  [index : i64]
  [target : backend.CompilerBackendTarget]) : String
  (str_cat.str-cat
    "doctest example "
    (string.int->string index)
    " is a runnable doctest, but runnable doctests are unsupported on target "
    (build_run_core.source-tool-target-name target)))

(define (doc-test-runnable-compile-message [index : i64] [message : String]) : String
  (str_cat.str-cat
    "doctest example "
    (string.int->string index)
    " runnable compile failed\n"
    message))

(define (doc-test-runnable-build-message [index : i64] [message : String]) : String
  (str_cat.str-cat
    "doctest example "
    (string.int->string index)
    " runnable build failed\n"
    message))

(define (doc-test-runnable-exec-message [index : i64] [message : String]) : String
  (str_cat.str-cat
    "doctest example "
    (string.int->string index)
    " runnable execution failed: "
    message))

(define (doc-test-output-comparison-message
  [name : String]
  [expected : String]
  [actual : String]) : String
  (str_cat.str-cat
    "expected "
    (owned_view.compiler-owned-shared-view name)
    ":\n"
    expected
    "\nactual "
    name
    ":\n"
    actual))

(define (doc-test-normalize-windows-crlf [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [out : String ""]
    (while (< i n)
      (if (and
        (= (string.string-ref text i) '\r')
        (< (+ i 1) n)
        (= (string.string-ref text (+ i 1)) '\n'))
        (begin
          (set! out (str_cat.str-cat out "\n" ""))
          (set! i (+ i 2)))
        (begin
          (set! out (str_cat.str-cat out (string.substring text i 1) ""))
          (set! i (+ i 1)))))
    out))

(define (doc-test-normalize-output-for-target
  [target : backend.CompilerBackendTarget]
  [text : String]) : String
  (match target
    [(Linux) text]
    [(Windows) (doc-test-normalize-windows-crlf text)]))

(define (doc-test-runnable-mismatch-message
  [index : i64]
  [expectation : DocTestExpectation]
  [target : backend.CompilerBackendTarget]
  [output : process.ProcessOutput]) : String
  (let
    [expected-exit : i64
      (doc-test-expectation-run-exit
        (owned_view.compiler-owned-shared-view expectation))]
    [expected-stdout : String
      (doc-test-expectation-run-stdout
        (owned_view.compiler-owned-shared-view expectation))]
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
    (str_cat.str-cat
      "doctest example "
      (string.int->string index)
      " runnable output mismatch\nexpected exit: "
      (string.int->string expected-exit)
      "\nactual exit: "
      (string.int->string actual-exit)
      "\n"
      (doc-test-output-comparison-message
        "stdout"
        expected-stdout
        actual-stdout)
      "\n"
      (doc-test-output-comparison-message
        "stderr"
        expected-stderr
        actual-stderr))))

(define (doc-test-runnable-output-matches?
  [expectation : DocTestExpectation]
  [target : backend.CompilerBackendTarget]
  [output : (& output process.ProcessOutput)]) : bool
  (if (=
    (doc-test-expectation-run-exit
      (owned_view.compiler-owned-shared-view expectation))
    (process.output-status output))
    (if (string.eq
      (doc-test-expectation-run-stdout
        (owned_view.compiler-owned-shared-view expectation))
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

(define (doc-test-emit-runnable-assembly
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]
  [target : backend.CompilerBackendTarget]) : build_run_core.ResultSourceToolString
  (driver.compiler-driver-reset-file-state!)
  (driver.compiler-driver-state-clear-pool-backed-caches!)
  (let
    [index : i64
      (doc-test-example-index (owned_view.compiler-owned-shared-view example))]
    [virtual-path : String (doc-test-example-virtual-path path index)]
    [code : String (doc-test-example-code example)]
    [cfgs : sym_i64_env.SymI64Env
      (driver.compiler-driver-target-cfgs target (cfg_core.compiler-cfg-empty))]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : build_run_core.ResultSourceToolString
      (match (driver.compiler-driver-load-source-with-runtime-with-pools
        (owned_view.compiler-owned-shared-view virtual-path)
        code
        (owned_view.compiler-owned-shared-view stdlib-roots)
        cfgs
        pools)
        [(Ok decls paths _ _)
          (match (lower.lower-compiler-program-with-decl-paths-mode-cache-and-pools
            (owned_view.compiler-owned-shared-view virtual-path)
            (ast.ast-program decls)
            paths
            (Scalar)
            stdlib-roots
            cfgs
            (tc.tc-prefix-default-cache-scope)
            pools)
            [(Ok program spans)
              (match (driver.compiler-driver-emit-lowered-with-level
                virtual-path
                program
                spans
                target
                true
                (opt.compiler-optimize-default-level))
                [(Ok asm advisories)
                  (driver.compiler-driver-print-advisories (& advisories))
                  (Ok
                    (build_run_core.source-tool-augment-assembly-for-target
                      asm
                      target))]
                [(Err diag advisories)
                  (driver.compiler-driver-print-advisories (& advisories))
                  (Err (cdiag.compiler-diagnostic-render (deref diag)))])]
            [(Err diag) (Err (cdiag.compiler-diagnostic-render (deref diag)))])]
        [(Err diag) (Err (cdiag.compiler-diagnostic-render (deref diag)))])]
    (driver.compiler-driver-state-clear-pool-backed-caches!)
    (driver.compiler-driver-reset-file-state!)
    result))

(define (doc-test-runnable-failure
  [path : String]
  [source-line : i64]
  [index : i64]
  [message : String]) : DocTestMaybeFailure
  (Some (Failure path source-line index message)))

(define (doc-test-run-runnable-output
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]
  [target : backend.CompilerBackendTarget]
  [temp-dir : String]) : DocTestMaybeFailure
  (let
    [index : i64
      (doc-test-example-index (owned_view.compiler-owned-shared-view example))]
    [source-line : i64
      (doc-test-example-source-line
        (owned_view.compiler-owned-shared-view example))]
    [expectation : DocTestExpectation
      (doc-test-example-expectation
        (owned_view.compiler-owned-shared-view example))]
    [virtual-path : String
      (doc-test-example-virtual-path
        (owned_view.compiler-owned-shared-view path)
        index)]
    [files : build_run_core.SourceToolTempFiles
      (build_run_core.source-tool-temp-files temp-dir virtual-path target)]
    [message : DocTestMaybeString
      (match (doc-test-emit-runnable-assembly
        (owned_view.compiler-owned-shared-view path)
        example
        stdlib-roots
        target)
        [(Err message) (Some (doc-test-runnable-compile-message index message))]
        [(Ok asm)
          (match (build_run_core.source-tool-link-and-run
            (build_run_core.SourceToolLinkRequest
              ""
              (Assembly asm)
              target
              (opt.compiler-optimize-default-level)
              (Scalar)
              (build_run_core.source-tool-link-inputs-empty)
              (owned_view.compiler-owned-shared-view files)
              "doctest: failed to write assembly artifact")
            (process.args-empty)
            (process.env-empty)
            false)
            [(LinkFailed message)
              (Some (doc-test-runnable-build-message index message))]
            [(Ran output)
              (if (doc-test-runnable-output-matches?
                (owned_view.compiler-owned-shared-view expectation)
                target
                output)
                (No)
                (Some
                  (doc-test-runnable-mismatch-message
                    index
                    expectation
                    target
                    output)))]
            [(SpawnFailed error)
              (Some
                (doc-test-runnable-exec-message
                  index
                  (process.error-message error)))])])]
    (build_run_core.source-tool-clean-temp-files files true)
    (match message
      [(No) (No)]
      [(Some text) (doc-test-runnable-failure path source-line index text)])))

(define (doc-test-run-runnable-example-with-roots
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]) : DocTestMaybeFailure
  (let
    [index : i64
      (doc-test-example-index (owned_view.compiler-owned-shared-view example))]
    [source-line : i64
      (doc-test-example-source-line
        (owned_view.compiler-owned-shared-view example))]
    [target : backend.CompilerBackendTarget
      (build_run_core.source-tool-default-target)]
    (if (doc-test-runnable-target-supported? target)
      (match (build_run_core.source-tool-create-temp-dir "typelisp-doctest")
        [(Ok temp-dir)
          (doc-test-run-runnable-output
            path
            example
            stdlib-roots
            target
            temp-dir)]
        [(Err message)
          (Some
            (Failure
              path
              source-line
              index
              (doc-test-runnable-build-message
                index
                (str_cat.str-cat "doctest: failed to create temp dir: " message))))])
      (Some
        (Failure
          path
          source-line
          index
          (doc-test-runnable-unsupported-message index target))))))

;; Check one extracted example through the virtual-source typechecker, comparing
;; the outcome against its expectation. Imports inside the example resolve
;; relative to a sibling of `path` (the doc'd source file), so examples may
;; import the doc'd file without colliding with the virtual source root.
(define (doc-test-example-virtual-path [path : String] [index : i64]) : String
  (str_cat.str-cat path ".doctest." (string.int->string index)))

(define (doc-test-typecheck-example-with-roots-and-cfg
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestMaybeFailure
  (let
    ;; Each check-only example is its own program. The check resets its pools
    ;; but not the interner, so reset that to the session floor first, as lint
    ;; does per file: otherwise an example inherits what the previous one
    ;; interned and generated, and after one instantiated
    ;; `(vector.vector i64)` the next one's `push!` lost `push-ref!` (#8580).
    ;; The session's program cache survives, so examples still share loaded
    ;; dependencies. Runnable examples get the full driver reset instead.
    [_reset : unit (compiler_check_core.compiler-check-reset-interns!)]
    [index : i64
      (doc-test-example-index (owned_view.compiler-owned-shared-view example))]
    [source-line : i64
      (doc-test-example-source-line
        (owned_view.compiler-owned-shared-view example))]
    [expectation : DocTestExpectation
      (doc-test-example-expectation
        (owned_view.compiler-owned-shared-view example))]
    [expect-error : bool (doc-test-expectation-error? expectation)]
    [code : String (doc-test-example-code example)]
    (match (compiler_check_core.compiler-check-source-with-roots-and-cfg
      (doc-test-example-virtual-path
        (owned_view.compiler-owned-shared-view path)
        index)
      code
      stdlib-roots
      cfgs)
      [(Ok _ advisories)
        (driver.compiler-driver-print-advisories (& advisories))
        (if expect-error
          (Some
            (Failure
              path
              source-line
              index
              (doc-test-unexpected-pass-message index)))
          (No))]
      [(Err diag advisories)
        (driver.compiler-driver-print-advisories (& advisories))
        (if expect-error
          (No)
          (Some
            (Failure
              path
              source-line
              index
              (doc-test-unexpected-error-message
                index
                (cdiag.compiler-diagnostic-list-first (deref diag))))))])))

(define (doc-test-typecheck-example-with-roots
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]) : DocTestMaybeFailure
  (doc-test-typecheck-example-with-roots-and-cfg
    path
    example
    stdlib-roots
    (compiler_check_core.compiler-check-language-cfgs)))

(define (doc-test-typecheck-package-example-with-roots-and-cfg
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestMaybeFailure
  (let
    [index : i64
      (doc-test-example-index (owned_view.compiler-owned-shared-view example))]
    [source-line : i64
      (doc-test-example-source-line
        (owned_view.compiler-owned-shared-view example))]
    [expectation : DocTestExpectation
      (doc-test-example-expectation
        (owned_view.compiler-owned-shared-view example))]
    [expect-error : bool (doc-test-expectation-error? expectation)]
    [code : String (doc-test-example-code example)]
    (match (compiler_check_core.compiler-check-package-source-with-roots-and-cfg
      (doc-test-example-virtual-path
        (owned_view.compiler-owned-shared-view path)
        index)
      code
      stdlib-roots
      manifest-dir
      deps
      cfgs)
      [(Ok _ advisories)
        (driver.compiler-driver-print-advisories (& advisories))
        (if expect-error
          (Some
            (Failure
              path
              source-line
              index
              (doc-test-unexpected-pass-message index)))
          (No))]
      [(Err diag advisories)
        (driver.compiler-driver-print-advisories (& advisories))
        (if expect-error
          (No)
          (Some
            (Failure
              path
              source-line
              index
              (doc-test-unexpected-error-message
                index
                (cdiag.compiler-diagnostic-list-first (deref diag))))))])))

(define (doc-test-check-example-with-roots
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : doc_svec.Vec]) : DocTestMaybeFailure
  (if (doc-test-expectation-run?
    (doc-test-example-expectation
      (owned_view.compiler-owned-shared-view example)))
    (doc-test-run-runnable-example-with-roots path example stdlib-roots)
    (doc-test-typecheck-example-with-roots path example stdlib-roots)))

(define (doc-test-run-examples-with-roots-from
  [path : String]
  [examples : (& examples doc_example_vec.Vec)]
  [index : i64]
  [failures : doc_run_failure_vec.Vec]
  [stdlib-roots : doc_svec.Vec]) : doc_run_failure_vec.Vec
  (if (>= index (doc-test-example-list-count examples))
    failures
    (let
      [example : DocTestExample (doc-test-example-list-ref examples index)]
      (match (doc-test-check-example-with-roots
        (owned_view.compiler-owned-shared-view path)
        example
        (owned_view.compiler-owned-shared-view stdlib-roots))
        [(No)
          (doc-test-run-examples-with-roots-from
            path
            examples
            (+ index 1)
            failures
            stdlib-roots)]
        [(Some failure)
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
  [examples : (& examples doc_example_vec.Vec)]
  [index : i64]
  [failures : doc_run_failure_vec.Vec]
  [stdlib-roots : doc_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : doc_run_failure_vec.Vec
  (if (>= index (doc-test-example-list-count examples))
    failures
    (let
      [example : DocTestExample (doc-test-example-list-ref examples index)]
      (match (doc-test-typecheck-example-with-roots-and-cfg
        (owned_view.compiler-owned-shared-view path)
        example
        (owned_view.compiler-owned-shared-view stdlib-roots)
        cfgs)
        [(No)
          (doc-test-typecheck-examples-with-roots-from
            path
            examples
            (+ index 1)
            failures
            stdlib-roots
            cfgs)]
        [(Some failure)
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
  [examples : (& examples doc_example_vec.Vec)]
  [index : i64]
  [failures : doc_run_failure_vec.Vec]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : doc_run_failure_vec.Vec
  (if (>= index (doc-test-example-list-count examples))
    failures
    (let
      [example : DocTestExample (doc-test-example-list-ref examples index)]
      (match (doc-test-typecheck-package-example-with-roots-and-cfg
        (owned_view.compiler-owned-shared-view path)
        example
        (owned_view.compiler-owned-shared-view stdlib-roots)
        (owned_view.compiler-owned-shared-view manifest-dir)
        (owned_view.compiler-owned-shared-view deps)
        cfgs)
        [(No)
          (doc-test-typecheck-package-examples-with-roots-from
            path
            examples
            (+ index 1)
            failures
            stdlib-roots
            manifest-dir
            deps
            cfgs)]
        [(Some failure)
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
  [deps : compiler_load.CompilerPkgDeps]
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
  [errors : (& errors doc_error_vec.Vec)]
  [index : i64]
  [failures : doc_run_failure_vec.Vec]) : doc_run_failure_vec.Vec
  (if (>= index (doc-test-error-list-count errors))
    failures
    (let
      [err : DocTestError (doc-test-error-list-ref errors index)]
      (doc-test-errors-to-failures-from
        (owned_view.compiler-owned-shared-view path)
        errors
        (+ index 1)
        (doc-test-run-failure-list-append
          failures
          (Failure
            path
            (doc-test-error-line (owned_view.compiler-owned-shared-view err))
            -1
            (doc-test-error-message err)))))))

(define (doc-test-errors-to-failures
  [path : String]
  [errors : doc_error_vec.Vec]
  [failures : doc_run_failure_vec.Vec]) : doc_run_failure_vec.Vec
  (doc-test-errors-to-failures-from path errors 0 failures))

(define (doc-test-run-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : doc_svec.Vec]) : DocTestRunReport
  (match (doc-test-extract-source source)
    [(Extraction examples errors)
      (Report
        (doc-test-example-list-count examples)
        (doc-test-run-examples-with-roots
          (owned_view.compiler-owned-shared-view path)
          examples
          (doc-test-errors-to-failures
            path
            errors
            (doc-test-run-failure-list-empty))
          stdlib-roots))]))

(define (doc-test-run-file-with-roots
  [path : String]
  [stdlib-roots : doc_svec.Vec]) : DocTestRunReport
  (doc-test-run-source-with-roots
    (owned_view.compiler-owned-shared-view path)
    (byte_buf.to-string (io.read-file path))
    stdlib-roots))

(define (doc-test-typecheck-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : doc_svec.Vec]) : DocTestRunReport
  (doc-test-typecheck-source-with-roots-and-cfg
    path
    source
    stdlib-roots
    (compiler_check_core.compiler-check-language-cfgs)))

(define (doc-test-typecheck-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : doc_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestRunReport
  (match (doc-test-extract-source source)
    [(Extraction examples errors)
      (Report
        (doc-test-example-list-count examples)
        (doc-test-typecheck-examples-with-roots-and-cfg
          (owned_view.compiler-owned-shared-view path)
          examples
          (doc-test-errors-to-failures
            path
            errors
            (doc-test-run-failure-list-empty))
          stdlib-roots
          cfgs))]))

(define (doc-test-typecheck-package-extraction-with-roots-and-cfg
  [path : String]
  [extraction : DocTestExtraction]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestRunReport
  (match extraction
    [(Extraction examples errors)
      (Report
        (doc-test-example-list-count examples)
        (doc-test-typecheck-package-examples-with-roots-and-cfg
          (owned_view.compiler-owned-shared-view path)
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
    (owned_view.compiler-owned-shared-view path)
    (byte_buf.to-string (io.read-file path))
    stdlib-roots
    cfgs))

(define (doc-test-path-under-root? [path : (& path str)] [root : (& root str)]) : bool
  (let
    [normalized-path : String (compiler_load.compiler-load-normalize-path path)]
    [normalized-root : String (compiler_load.compiler-load-normalize-path root)]
    (and
      (> (string.string-length normalized-root) 0)
      (if (string.eq normalized-root ".")
        (not (compiler_load.compiler-load-path-escapes? normalized-path))
        (compiler_load.compiler-load-path-under-root?
          normalized-path
          normalized-root)))))

(define (doc-test-dep-list-path?
  [path : (& path str)]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDepList]
  [index : i64]) : bool
  (if (>= index (compiler_load.compiler-pkg-dep-list-count deps))
    false
    (let
      [dep : compiler_load.CompilerPkgDep
        (compiler_load.compiler-pkg-dep-list-at deps index)]
      [dep-path : String dep.path]
      [dep-root : String
        (compiler_load.compiler-load-normalize-path
          (if (compiler_load.compiler-load-absolute-path? dep-path)
            dep-path
            (compiler_load.compiler-load-join-root-path
              (owned_view.compiler-owned-shared-view manifest-dir)
              (owned_view.compiler-owned-shared-view dep-path))))]
      (if (and
        (not (compiler_load.compiler-load-github-dependency-path? dep-path))
        (doc-test-path-under-root? path dep-root))
        true
        (doc-test-dep-list-path? path manifest-dir deps (+ index 1))))))

(define (doc-test-typecheck-package-path-list-with-roots-from
  [paths : ast.AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [last-path : String]
  [count : i64]) : DocTestRunReport
  (match (ast.ast-decl-path-list-step paths)
    [(Nil) (Report count (doc-test-run-failure-list-empty))]
    [(Cons path rest)
      (let
        [rest : ast.AstDeclPathList rest]
        [normalized : String (compiler_load.compiler-load-normalize-path path)]
        [rooted : String
          (if (or
            (compiler_load.compiler-load-absolute-path? path)
            (doc-test-path-under-root? normalized manifest-dir))
            (owned_view.compiler-owned-shared-view normalized)
            (compiler_load.compiler-load-normalize-path
              (compiler_load.compiler-load-join-root-path
                (owned_view.compiler-owned-shared-view manifest-dir)
                (owned_view.compiler-owned-shared-view normalized))))]
        [stdlib-path : String
          (if (compiler_load.compiler-load-stdlib-import? normalized)
            normalized
            (compiler_load.compiler-load-stdlib-owned-path-from-roots
              (owned_view.compiler-owned-shared-view rooted)
              (owned_view.compiler-owned-shared-view stdlib-roots)))]
        [manifest-stdlib-root : String
          (compiler_load.compiler-load-normalize-path
            (compiler_load.compiler-load-join-root-path
              (owned_view.compiler-owned-shared-view manifest-dir)
              "stdlib"))]
        [manifest-root : String
          (compiler_load.compiler-load-normalize-path manifest-dir)]
        [manifest-local : bool
          (if (string.eq manifest-root ".")
            (and
              (not (compiler_load.compiler-load-absolute-path? rooted))
              (doc-test-path-under-root? rooted manifest-dir))
            (doc-test-path-under-root? rooted manifest-dir))]
        [package-local : bool
          (and
            (> (string.string-length path) 0)
            (not (compiler_load.compiler-load-stdlib-import? stdlib-path))
            (not (doc-test-path-under-root? rooted manifest-stdlib-root))
            (not
              (doc-test-dep-list-path?
                rooted
                (owned_view.compiler-owned-shared-view manifest-dir)
                (compiler_load.compiler-pkg-deps-list
                  (owned_view.compiler-owned-shared-view deps))
                0))
            manifest-local)]
        (if (and package-local (not (string.eq rooted last-path)))
          (let
            [report : DocTestRunReport
              (doc-test-typecheck-package-file-text-with-roots
                (owned_view.compiler-owned-shared-view rooted)
                (owned_view.compiler-owned-shared-view stdlib-roots)
                (owned_view.compiler-owned-shared-view manifest-dir)
                (owned_view.compiler-owned-shared-view deps)
                cfgs)]
            (if (doc-test-run-report-ok?
              (owned_view.compiler-owned-shared-view report))
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
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : DocTestRunReport
  (doc-test-typecheck-package-extraction-with-roots-and-cfg
    (owned_view.compiler-owned-shared-view path)
    (doc-test-extract-package-file-text path)
    stdlib-roots
    manifest-dir
    deps
    cfgs))

(define (doc-test-typecheck-package-paths-with-roots
  [paths : ast.AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]) : DocTestRunReport
  (doc-test-typecheck-package-paths-with-roots-and-cfg
    paths
    stdlib-roots
    manifest-dir
    deps
    (compiler_check_core.compiler-check-language-cfgs)))

(define (doc-test-typecheck-package-paths-with-roots-and-cfg
  [paths : ast.AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
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
;; The exit status of a doctest run that another command (check, compile, build,
;; run) performs on its inputs: a failing report is printed to stderr.
(define (doc-test-report-status [report : DocTestRunReport]) : i64
  (if (doc-test-run-report-ok? (owned_view.compiler-owned-shared-view report))
    0
    (begin
      (io.print-error (doc-test-run-report-render report))
      1)))

;; Typecheck the doctests of the source file at `path` for another command; an
;; unreadable file has none (the command reports it).
(define (doc-test-typecheck-file-status
  [path : String]
  [stdlib-roots : doc_svec.Vec]) : i64
  (match (io.try-read-file (& path))
    [(ErrIoBytes _) 0]
    [(OkIoBytes contents)
      (doc-test-report-status
        (doc-test-typecheck-source-with-roots
          path
          (byte_buf.to-string contents)
          stdlib-roots))]))

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
    (str_cat.str-cat
      (doc-test-run-failure-render
        (doc-test-run-failure-list-ref failures index))
      "\n"
      (doc-test-run-failures-render-from failures (+ index 1)))))

(define (doc-test-run-failures-render [failures : doc_run_failure_vec.Vec]) : String
  (doc-test-run-failures-render-from failures 0))

;; Human-readable report text. Success renders the
;; `Doc tests passed: N example(s)` line; failure renders the
;; `doc tests failed: M failure(s) across N example(s)` summary followed by each
;; rendered failure.
(define (doc-test-run-report-render [report : DocTestRunReport]) : String
  (match report
    [(Report count failures)
      (if (= (doc-test-run-failure-list-count failures) 0)
        (str_cat.str-cat
          "Doc tests passed: "
          (string.int->string count)
          " example(s)")
        (str_cat.str-cat
          (str_cat.str-cat
            "doc tests failed: "
            (string.int->string (doc-test-run-failure-list-count failures))
            " failure(s) across "
            (string.int->string count)
            " example(s)\n")
          (doc-test-run-failures-render failures)))]))