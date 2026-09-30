;; doc_test_tests.tl - White-box tests for documentation tests: example
;; extraction, malformed and runnable examples, run reports and the session cache.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as doc_svec)
(import compiler_ast_types as ast)
(import compiler_diagnostic as cdiag)
(import compiler_load)
(import compiler_load_tests as load_tests)
(import build_run_core)
(import build_run_core_tests as build_run_tests)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.option)
(import (option.option i64) as option_i64)
(import compiler_builtin_ids as cbi)
(import (vector.vector doc_test.DocTestLine core) as doc_line_vec)
(import (vector.vector doc_test.DocTestExample core) as doc_example_vec)
(import (vector.vector doc_test.DocTestError core) as doc_error_vec)
(import (vector.vector doc_test.DocTestRunFailure core) as doc_run_failure_vec)
(import doc_test)

(define (doc-test-run-failure-path [failure : doc_test.DocTestRunFailure]) : String
  (match failure
    [(doc_test.DocTestRunFailure.Failure path _ _ _) path]))

(define (doc-test-run-failure-line [failure : doc_test.DocTestRunFailure]) : i64
  (match failure
    [(doc_test.DocTestRunFailure.Failure _ line _ _) line]))

(define (doc-test-run-failure-index [failure : doc_test.DocTestRunFailure]) : i64
  (match failure
    [(doc_test.DocTestRunFailure.Failure _ _ index _) index]))

(define (doc-test-run-failure-message [failure : doc_test.DocTestRunFailure]) : String
  (match failure
    [(doc_test.DocTestRunFailure.Failure _ _ _ message) message]))

;; Grow the generated error collection past its initial capacity while preserving
;; source order. The extraction path uses this same helper.
(define (doc-test-error-vector-growth-smoke-ok?) : bool
  (let
    [errors : doc_error_vec.Vec (doc_test.doc-test-error-list-empty)]
    [index : i64 1]
    (begin
      (while (<= index 5)
        (begin
          (doc_error_vec.push-ref!
            (&mut errors)
            (doc_test.DocTestError.Error index (string.int->string index)))
          (set! index (+ index 1))))
      (and
        (= (doc_test.doc-test-error-list-count errors) 5)
        (= (doc_error_vec.capacity (& errors)) 8)
        (=
          (doc_test.doc-test-error-line
            (doc_test.doc-test-error-list-ref errors 4))
          5)))))

;; Grow the generated line collection past its initial capacity while preserving
;; physical source-line order. Extraction uses this same helper.
(define (doc-test-line-vector-growth-smoke-ok?) : bool
  (let
    [lines : doc_line_vec.Vec (doc_line_vec.new)]
    [index : i64 1]
    (begin
      (while (<= index 5)
        (begin
          (doc_line_vec.push-ref!
            (&mut lines)
            (doc_test.DocTestLine.Line index (string.int->string index)))
          (set! index (+ index 1))))
      (and
        (= (doc_line_vec.len (& lines)) 5)
        (= (doc_line_vec.capacity (& lines)) 8)
        (=
          (doc_test.doc-test-line-number
            (doc_line_vec.get (& lines) 0 (doc_test.DocTestLine.Line 0 "")))
          1)
        (=
          (doc_test.doc-test-line-number
            (doc_line_vec.get (& lines) 4 (doc_test.DocTestLine.Line 0 "")))
          5)))))

;; Both doc-test collections contain move-only strings. Exercise canonical core
;; growth across the initial capacity without requiring clone/pop support, and
;; confirm that source order survives the move-based copy.
(define (doc-test-example-vector-growth-smoke-ok?) : bool
  (let
    [examples : doc_example_vec.Vec (doc_test.doc-test-example-list-empty)]
    [index : i64 1]
    (begin
      (while (<= index 5)
        (begin
          (doc_example_vec.push-ref!
            (&mut examples)
            (doc_test.DocTestExample.Example
              index
              (+ index 10)
              (doc_test.DocTestExpectation.Pass)
              (string.int->string index)))
          (set! index (+ index 1))))
      (and
        (= (doc_test.doc-test-example-list-count examples) 5)
        (= (doc_example_vec.capacity (& examples)) 8)
        (=
          (doc_test.doc-test-example-index
            (doc_test.doc-test-example-list-ref examples 0))
          1)
        (string.eq
          (doc_test.doc-test-example-code
            (doc_test.doc-test-example-list-ref examples 4))
          "5")))))

(define (doc-test-run-failure-vector-growth-smoke-ok?) : bool
  (let
    [failures : doc_run_failure_vec.Vec
      (doc_test.doc-test-run-failure-list-empty)]
    [index : i64 1]
    (begin
      (while (<= index 5)
        (begin
          (doc_run_failure_vec.push-ref!
            (&mut failures)
            (doc_test.DocTestRunFailure.Failure
              (string.int->string index)
              (+ index 10)
              index
              (string.int->string index)))
          (set! index (+ index 1))))
      (and
        (= (doc_test.doc-test-run-failure-list-count failures) 5)
        (= (doc_run_failure_vec.capacity (& failures)) 8)
        (string.eq
          (doc-test-run-failure-path
            (doc_test.doc-test-run-failure-list-ref failures 0))
          "1")
        (=
          (doc-test-run-failure-index
            (doc_test.doc-test-run-failure-list-ref failures 4))
          5)))))

(define (doc-test-public-diagnostic-render-smoke-ok?) : bool
  (let
    [parse-diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-code
        (cdiag.compiler-diagnostic-simple
          "docs/parse.tl"
          1
          2
          "missing closing paren")
        (cdiag.compiler-diagnostic-code-parse))]
    [typecheck-diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-code
        (cdiag.compiler-diagnostic-simple "docs/type.tl" 3 4 "return mismatch")
        (cdiag.compiler-diagnostic-code-typecheck))]
    [uncoded : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-simple
        "docs/plain.tl"
        5
        6
        "typecheck: prefix text only")]
    [parse-rendered : String
      (doc_test.doc-test-public-diagnostic-render parse-diag)]
    [typecheck-rendered : String
      (doc_test.doc-test-public-diagnostic-render typecheck-diag)]
    [uncoded-rendered : String
      (doc_test.doc-test-public-diagnostic-render uncoded)]
    (and
      (string.contains parse-rendered "error[E0100]:")
      (string.contains typecheck-rendered "error[E0200]:")
      (string.contains uncoded-rendered "error: docs/plain.tl:5:6:")
      (not (string.contains uncoded-rendered "E0200")))))

(define (doc-test-runnable-supported?) : bool
  (doc_test.doc-test-runnable-target-supported?
    (build_run_core.source-tool-default-target)))

;; Extract and check every example in `source` (attributed to `path`). Extraction
;; errors are folded in as failures first, then each example is checked. A source
;; with no examples and no errors reports success with a zero count.
(define (doc-test-run-source [path : String] [source : String]) : doc_test.DocTestRunReport
  (doc_test.doc-test-run-source-with-roots path source (doc_svec.new)))

(define (doc-test-typecheck-source [path : String] [source : String]) : doc_test.DocTestRunReport
  (doc_test.doc-test-typecheck-source-with-roots path source (doc_svec.new)))

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
  (str_cat.str-cat
    ";# Runnable docs\n"
    ";# ```typelisp run\n"
    ";# ;; doctest-exit: 0\n"
    ";# ;; doctest-stdout: literal:hello\\n\n"
    ";# ;; doctest-stderr: literal:error\\tline\\r\n"
    ";# (import stdlib.io)\n"
    ";# (import stdlib.byte_buf)\n"
    ";# (define (main) : i64\n"
    ";#   (begin\n"
    ";#     (let [text : String \"hello\\n\"] (io.stdout-write (byte_buf.str-as-bytes (& text))))\n"
    ";#     (let [text : String \"error\\tline\\r\"] (io.stderr-write (byte_buf.str-as-bytes (& text))))\n"
    ";#     0))\n"
    ";# ```\n"
    ";# ```tl run\n"
    ";# ;; doctest-exit: 42\n"
    ";# (define (main) : i64 42)\n"
    ";# ```\n"))

(define (doc-test-example-ok?
  [example : doc_test.DocTestExample]
  [index : i64]
  [source-line : i64]
  [expect-error : bool]
  [code-fragment : String]) : bool
  (begin
    (unless
      (=
        (doc_test.doc-test-example-index
          (owned_view.compiler-owned-shared-view example))
        index)
      (return false))
    (unless
      (=
        (doc_test.doc-test-example-source-line
          (owned_view.compiler-owned-shared-view example))
        source-line)
      (return false))
    (unless
      (=
        (doc_test.doc-test-expectation-error?
          (doc_test.doc-test-example-expectation
            (owned_view.compiler-owned-shared-view example)))
        expect-error)
      (return false))
    (string.contains (doc_test.doc-test-example-code example) code-fragment)))

(define (doc-test-runnable-example-ok?
  [example : doc_test.DocTestExample]
  [index : i64]
  [source-line : i64]
  [expected-exit : i64]
  [expected-stdout : String]
  [expected-stderr : String]
  [code-fragment : String]) : bool
  (begin
    (unless
      (=
        (doc_test.doc-test-example-index
          (owned_view.compiler-owned-shared-view example))
        index)
      (return false))
    (unless
      (=
        (doc_test.doc-test-example-source-line
          (owned_view.compiler-owned-shared-view example))
        source-line)
      (return false))
    (match (doc_test.doc-test-example-expectation
      (owned_view.compiler-owned-shared-view example))
      [(doc_test.DocTestExpectation.Run actual-exit actual-stdout actual-stderr)
        (begin
          (unless (= actual-exit expected-exit) (return false))
          (unless (string.eq actual-stdout expected-stdout) (return false))
          (unless (string.eq actual-stderr expected-stderr) (return false))
          (string.contains
            (doc_test.doc-test-example-code example)
            code-fragment))]
      [_ false])))

(define (doc-test-error-list-has-from?
  [errors : (& errors doc_error_vec.Vec)]
  [index : i64]
  [line : i64]
  [message-fragment : String]) : bool
  (if (>= index (doc_test.doc-test-error-list-count errors))
    false
    (let
      [err : doc_test.DocTestError
        (doc_test.doc-test-error-list-ref errors index)]
      (if (=
        (doc_test.doc-test-error-line
          (owned_view.compiler-owned-shared-view err))
        line)
        (if (string.contains
          (doc_test.doc-test-error-message err)
          message-fragment)
          true
          (doc-test-error-list-has-from?
            errors
            (+ index 1)
            line
            message-fragment))
        (doc-test-error-list-has-from? errors (+ index 1) line message-fragment)))))

(define (doc-test-error-list-has?
  [errors : (& errors doc_error_vec.Vec)]
  [line : i64]
  [message-fragment : String]) : bool
  (doc-test-error-list-has-from? errors 0 line message-fragment))

(define (doc-test-smoke-examples-ok?
  [examples : (& examples doc_example_vec.Vec)]) : bool
  (if (= (doc_test.doc-test-example-list-count examples) 2)
    (let
      [first : doc_test.DocTestExample
        (doc_test.doc-test-example-list-ref examples 0)]
      [second : doc_test.DocTestExample
        (doc_test.doc-test-example-list-ref examples 1)]
      (if (doc-test-example-ok? first 1 2 false "(define (main)")
        (doc-test-example-ok? second 2 9 true "(define (bad)")
        false))
    false))

(define (doc-test-malformed-errors-ok? [errors : (& errors doc_error_vec.Vec)]) : bool
  (if (= (doc_test.doc-test-error-list-count errors) 3)
    (let
      [first : doc_test.DocTestError
        (doc_test.doc-test-error-list-ref errors 0)]
      [second : doc_test.DocTestError
        (doc_test.doc-test-error-list-ref errors 1)]
      [third : doc_test.DocTestError
        (doc_test.doc-test-error-list-ref errors 2)]
      (begin
        (unless
          (=
            (doc_test.doc-test-error-line
              (owned_view.compiler-owned-shared-view first))
            1)
          (return false))
        (unless
          (string.contains
            (doc_test.doc-test-error-message first)
            "unsupported TypeLisp doctest option")
          (return false))
        (unless
          (=
            (doc_test.doc-test-error-line
              (owned_view.compiler-owned-shared-view second))
            5)
          (return false))
        (unless
          (string.contains
            (doc_test.doc-test-error-message second)
            "empty TypeLisp doctest fence")
          (return false))
        (unless
          (=
            (doc_test.doc-test-error-line
              (owned_view.compiler-owned-shared-view third))
            8)
          (return false))
        (string.contains
          (doc_test.doc-test-error-message third)
          "unterminated TypeLisp doctest fence")))
    false))

(define (doc-test-ordinary-comments-ok?) : bool
  (match (doc_test.doc-test-extract-source
    "; ```typelisp
; (define (bad) : i64 true)
; ```
;; ```typelisp
;; (define (also-bad) : i64 true)
;; ```
")
    [(doc_test.DocTestExtraction.Extraction ordinary-examples ordinary-errors)
      (if (= (doc_test.doc-test-example-list-count ordinary-examples) 0)
        (= (doc_test.doc-test-error-list-count ordinary-errors) 0)
        false)]))

(define (doc-test-legacy-item-smoke-ok?) : bool
  (match (doc_test.doc-test-extract-source
    ";: Legacy item docs
;: ```typelisp
;: (define legacy : i64 1)
;: ```
(define legacy : i64 1)")
    [(doc_test.DocTestExtraction.Extraction examples errors)
      (begin
        (unless
          (= (doc_test.doc-test-error-list-count errors) 0)
          (return false))
        (unless
          (= (doc_test.doc-test-example-list-count examples) 1)
          (return false))
        (let
          [example : doc_test.DocTestExample
            (doc_test.doc-test-example-list-ref examples 0)]
          (string.contains
            (doc_test.doc-test-example-code example)
            "(define legacy")))]))

(define (doc-test-malformed-smoke-ok?) : bool
  (match (doc_test.doc-test-extract-source (doc-test-malformed-source))
    [(doc_test.DocTestExtraction.Extraction malformed-examples malformed-errors)
      (if (= (doc_test.doc-test-example-list-count malformed-examples) 0)
        (if (= (doc_test.doc-test-error-list-count malformed-errors) 3)
          (doc-test-malformed-errors-ok? malformed-errors)
          false)
        false)]))

(define (doc-test-runnable-smoke-ok?) : bool
  (match (doc_test.doc-test-extract-source (doc-test-runnable-source))
    [(doc_test.DocTestExtraction.Extraction examples errors)
      (begin
        (unless
          (= (doc_test.doc-test-error-list-count errors) 0)
          (return false))
        (unless
          (= (doc_test.doc-test-example-list-count examples) 2)
          (return false))
        (let
          [first : doc_test.DocTestExample
            (doc_test.doc-test-example-list-ref examples 0)]
          [second : doc_test.DocTestExample
            (doc_test.doc-test-example-list-ref examples 1)]
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
              14
              42
              ""
              ""
              "(define (main)"))))]))

(define (doc-test-runnable-malformed-smoke-ok?) : bool
  (match (doc_test.doc-test-extract-source
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
    [(doc_test.DocTestExtraction.Extraction examples errors)
      (begin
        (unless
          (= (doc_test.doc-test-example-list-count examples) 0)
          (return false))
        (unless
          (= (doc_test.doc-test-error-list-count errors) 5)
          (return false))
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
  (match (doc_test.doc-test-extract-source (doc-test-smoke-source))
    [(doc_test.DocTestExtraction.Extraction examples errors)
      (begin
        (unless
          (= (doc_test.doc-test-error-list-count errors) 0)
          (return (io.panic "doc-test: unexpected extraction error")))
        (unless
          (= (doc_test.doc-test-example-list-count examples) 2)
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
      (doc_svec.push-ref! (&mut roots) "stdlib")
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
;# (import stdlib.byte_buf)
;# (define (main) : i64
;#   (begin
;#     (let [text : String \"actual\\n\"] (io.stdout-write (byte_buf.str-as-bytes (& text))))
;#     0))
;# ```
")

(define (doc-test-run-runnable-stderr-mismatch-source) : String
  ";# ```typelisp run
;# ;; doctest-exit: 0
;# ;; doctest-stderr: literal:expected-error\\n
;# (import stdlib.io)
;# (import stdlib.byte_buf)
;# (define (main) : i64
;#   (begin
;#     (let [text : String \"actual-error\\n\"] (io.stderr-write (byte_buf.str-as-bytes (& text))))
;#     0))
;# ```
")

;; The shared smoke source has one passing and one correctly-erroring
;; (`expect-error`) example, so it must run clean: two examples, no failures.
(define (doc-test-run-smoke-pass-ok?) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc-test-run-source "docs/ok.tl" (doc-test-smoke-source))]
    (if (=
      (doc_test.doc-test-run-report-count
        (owned_view.compiler-owned-shared-view report))
      2)
      (doc_test.doc-test-run-report-ok? report)
      false)))

;; A normal example that fails to check yields exactly one failure carrying the
;; fence line (1), example index (1), and the rendered diagnostic message.
(define (doc-test-run-smoke-unexpected-error-ok?) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc-test-run-source "docs/bad.tl" (doc-test-run-unexpected-error-source))]
    [failures : doc_run_failure_vec.Vec
      (doc_test.doc-test-run-report-failures report)]
    (if (= (doc_test.doc-test-run-failure-list-count failures) 1)
      (let
        [failure : doc_test.DocTestRunFailure
          (doc_test.doc-test-run-failure-list-ref failures 0)]
        (begin
          (unless
            (=
              (doc-test-run-failure-index
                (owned_view.compiler-owned-shared-view failure))
              1)
            (return false))
          (unless
            (=
              (doc-test-run-failure-line
                (owned_view.compiler-owned-shared-view failure))
              1)
            (return false))
          (unless
            (string.eq
              (doc-test-run-failure-path
                (owned_view.compiler-owned-shared-view failure))
              "docs/bad.tl")
            (return false))
          (string.contains
            (doc-test-run-failure-message failure)
            "return type mismatch")))
      false)))

;; An `expect-error` example that checks successfully is a failure.
(define (doc-test-run-smoke-unexpected-pass-ok?) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc-test-run-source "docs/bad.tl" (doc-test-run-unexpected-pass-source))]
    [failures : doc_run_failure_vec.Vec
      (doc_test.doc-test-run-report-failures report)]
    (if (= (doc_test.doc-test-run-failure-list-count failures) 1)
      (string.contains
        (doc-test-run-failure-message
          (doc_test.doc-test-run-failure-list-ref failures 0))
        "was expected to fail")
      false)))

;; Malformed fences (the shared malformed source's three extraction errors)
;; become three runner failures with no examples.
(define (doc-test-run-smoke-malformed-ok?) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc-test-run-source "docs/malformed.tl" (doc-test-malformed-source))]
    (if (=
      (doc_test.doc-test-run-report-count
        (owned_view.compiler-owned-shared-view report))
      0)
      (=
        (let
          [failures (doc_test.doc-test-run-report-failures report)]
          (doc_test.doc-test-run-failure-list-count failures))
        3)
      false)))

;; A source with no examples reports success with a zero count.
(define (doc-test-run-smoke-empty-ok?) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc-test-run-source "docs/empty.tl" (doc-test-run-empty-source))]
    (if (=
      (doc_test.doc-test-run-report-count
        (owned_view.compiler-owned-shared-view report))
      0)
      (doc_test.doc-test-run-report-ok? report)
      false)))

(define (doc-test-run-smoke-runnable-unsupported-ok?) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc_test.doc-test-run-source-with-roots
        "docs/run.tl"
        (doc-test-runnable-source)
        (doc-test-run-smoke-stdlib-roots))]
    [failures : doc_run_failure_vec.Vec
      (doc_test.doc-test-run-report-failures
        (owned_view.compiler-owned-shared-view report))]
    (if (= (doc_test.doc-test-run-report-count report) 2)
      (if (= (doc_test.doc-test-run-failure-list-count failures) 2)
        (let
          [first : doc_test.DocTestRunFailure
            (doc_test.doc-test-run-failure-list-ref failures 0)]
          [second : doc_test.DocTestRunFailure
            (doc_test.doc-test-run-failure-list-ref failures 1)]
          (if (string.contains
            (doc-test-run-failure-message first)
            "unsupported")
            (string.contains
              (doc-test-run-failure-message second)
              "unsupported")
            false))
        false)
      false)))

(define (doc-test-run-smoke-runnable-exec-pass-ok?) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc_test.doc-test-run-source-with-roots
        "docs/run.tl"
        (doc-test-runnable-source)
        (doc-test-run-smoke-stdlib-roots))]
    (if (=
      (doc_test.doc-test-run-report-count
        (owned_view.compiler-owned-shared-view report))
      2)
      (doc_test.doc-test-run-report-ok? report)
      false)))

;; A runnable block needs its own `main`: none is synthesized (#7071).
(define (doc-test-run-smoke-runnable-missing-main-ok?) : bool
  (doc-test-run-single-failure-message-contains?
    ";# ```typelisp run
;# ;; doctest-exit: 0
;# (define answer : i64 1)
;# ```
"
    "executable has no `main`"))

(define (doc-test-run-single-failure-message-contains?
  [source : String]
  [fragment : String]) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc_test.doc-test-run-source-with-roots
        "docs/run.tl"
        source
        (doc-test-run-smoke-stdlib-roots))]
    [failures : doc_run_failure_vec.Vec
      (doc_test.doc-test-run-report-failures
        (owned_view.compiler-owned-shared-view report))]
    (if (= (doc_test.doc-test-run-report-count report) 1)
      (if (= (doc_test.doc-test-run-failure-list-count failures) 1)
        (string.contains
          (doc-test-run-failure-message
            (doc_test.doc-test-run-failure-list-ref failures 0))
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
        ";# ```typelisp run
;# ;; doctest-exit: 0
;# (define (main) : i64 true)
;# ```
"
        "runnable compile failed")
      (return false))
    true))

(define (doc-test-typecheck-smoke-runnable-only-ok?) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc_test.doc-test-typecheck-source-with-roots
        "docs/run.tl"
        (doc-test-run-runnable-wrong-exit-source)
        (doc-test-run-smoke-stdlib-roots))]
    (if (=
      (doc_test.doc-test-run-report-count
        (owned_view.compiler-owned-shared-view report))
      1)
      (doc_test.doc-test-run-report-ok? report)
      false)))

(define (doc-test-typecheck-smoke-unexpected-pass-ok?) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc-test-typecheck-source
        "docs/bad.tl"
        (doc-test-run-unexpected-pass-source))]
    [failures : doc_run_failure_vec.Vec
      (doc_test.doc-test-run-report-failures report)]
    (if (= (doc_test.doc-test-run-failure-list-count failures) 1)
      (string.contains
        (doc-test-run-failure-message
          (doc_test.doc-test-run-failure-list-ref failures 0))
        "was expected to fail")
      false)))

(define (doc-test-typecheck-smoke-malformed-ok?) : bool
  (let
    [report : doc_test.DocTestRunReport
      (doc-test-typecheck-source
        "docs/malformed.tl"
        (doc-test-malformed-source))]
    (if (=
      (doc_test.doc-test-run-report-count
        (owned_view.compiler-owned-shared-view report))
      0)
      (=
        (let
          [failures (doc_test.doc-test-run-report-failures report)]
          (doc_test.doc-test-run-failure-list-count failures))
        3)
      false)))

(define (doc-test-run-smoke-runnable-ok?) : bool
  (if (doc-test-runnable-supported?)
    (begin
      (unless (doc-test-run-smoke-runnable-exec-pass-ok?) (return false))
      (unless (doc-test-run-smoke-runnable-missing-main-ok?) (return false))
      (doc-test-run-smoke-runnable-failures-ok?))
    (doc-test-run-smoke-runnable-unsupported-ok?)))

;; The rendered failure carries the path, line, and message.
(define (doc-test-run-smoke-render-ok?) : bool
  (let
    [rendered : String
      (doc_test.doc-test-run-failure-render
        (doc_test.DocTestRunFailure.Failure
          "docs/bad.tl"
          4
          2
          "doctest example 2 was expected to pass
typecheck: return type mismatch"))]
    (if (string.contains rendered "docs/bad.tl:4:")
      (if (string.contains rendered "doctest example 2")
        (string.contains rendered "return type mismatch")
        false)
      false)))

;; Report-level text: a clean run renders the `Doc tests passed: N example(s)`
;; line with status 0, and a failing run renders the
;; `doc tests failed: M failure(s) across N example(s)` summary with status 1.
(define (doc-test-run-smoke-report-render-ok?) : bool
  (let
    [pass-report : doc_test.DocTestRunReport
      (doc-test-run-source "docs/ok.tl" (doc-test-smoke-source))]
    [fail-report : doc_test.DocTestRunReport
      (doc-test-run-source "docs/bad.tl" (doc-test-run-unexpected-error-source))]
    (begin
      (unless
        (=
          (doc_test.doc-test-run-report-status
            (owned_view.compiler-owned-shared-view pass-report))
          0)
        (return false))
      (unless
        (string.eq
          (doc_test.doc-test-run-report-render pass-report)
          "Doc tests passed: 2 example(s)")
        (return false))
      (unless
        (=
          (doc_test.doc-test-run-report-status
            (owned_view.compiler-owned-shared-view fail-report))
          1)
        (return false))
      (unless
        (string.contains
          (doc_test.doc-test-run-report-render
            (owned_view.compiler-owned-shared-view fail-report))
          "doc tests failed: 1 failure(s) across 1 example(s)")
        (return false))
      (string.contains
        (doc_test.doc-test-run-report-render fail-report)
        "return type mismatch"))))

(define (doc-test-session-cache-smoke-ok?) : bool
  (let
    [root : String "target/doc_test_session_cache"]
    [dep-file : String "target/doc_test_session_cache/dep.tl"]
    [doc-file : String "target/doc_test_session_cache/docs.tl"]
    [roots : doc_svec.Vec
      (let
        [items : doc_svec.Vec (doc_svec.new)]
        (begin
          (doc_svec.push-ref! (&mut items) "target/doc_test_session_cache")
          items))]
    (begin
      (compiler_load.compiler-load-test-mkdir "target")
      (compiler_load.compiler-load-test-mkdir root)
      (let
        [contents : String "(define shared-value : i64 7)"]
        (io.write-file dep-file (byte_buf.str-as-bytes (& contents))))
      (compiler_load.compiler-load-session-cache-enable!)
      (compiler_load.compiler-load-program-cache-clear!)
      (let
        [report : doc_test.DocTestRunReport
          (doc_test.doc-test-typecheck-source-with-roots
            doc-file
            ";# ```typelisp
;# (import stdlib.dep)
;# (define (main) : i64 dep.shared-value)
;# ```
;# ```typelisp
;# (import stdlib.dep)
;# (define (main) : i64 dep.shared-value)
;# ```
"
            roots)]
        [hits : i64 (load_tests.compiler-load-program-cache-hit-count-value)]
        (begin
          (compiler_load.compiler-load-session-cache-disable-for-test!)
          (and (doc_test.doc-test-run-report-ok? report) (> hits 0)))))))

(define (doc-test-package-walk-example-source [value : i64]) : String
  (str_cat.str-cat
    ";# ```typelisp
;# (define (main) : i64 "
    (string.int->string value)
    ")
;# ```
"))

(define (doc-test-package-walk-numbered-path
  [root : String]
  [prefix : String]
  [index : i64]) : String
  (str_cat.str-cat root "/" prefix (string.int->string index) ".tl"))

(define (doc-test-package-walk-write-empty-paths
  [root : String]
  [count : i64]
  [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [i : i64 0]
    [out : ast.AstDeclPathList paths]
    (begin
      (while (< i count)
        (let
          [path : String
            (doc-test-package-walk-numbered-path
              (owned_view.compiler-owned-shared-view root)
              "empty_"
              i)]
          (begin
            (let
              [contents : String ";; no doctest fence
"]
              (io.write-file path (byte_buf.str-as-bytes (& contents))))
            (set!
              out
              (ast.ast-decl-path-list-prepend-builder-with-owner-id
                path
                cbi.compiler-builtin-id-fix-empty
                out))
            (set! i (+ i 1)))))
      out)))

(define (doc-test-package-walk-long-list-smoke-ok?) : bool
  (let
    [root : String "target/doc_test_package_walk"]
    [example-a : String
      (doc-test-package-walk-numbered-path
        (owned_view.compiler-owned-shared-view root)
        "example_"
        1)]
    [example-b : String
      (doc-test-package-walk-numbered-path
        (owned_view.compiler-owned-shared-view root)
        "example_"
        2)]
    [example-c : String
      (doc-test-package-walk-numbered-path
        (owned_view.compiler-owned-shared-view root)
        "example_"
        3)]
    (begin
      (compiler_load.compiler-load-test-mkdir "target")
      (compiler_load.compiler-load-test-mkdir
        (owned_view.compiler-owned-shared-view root))
      (let
        [contents-a : String (doc-test-package-walk-example-source 1)]
        [contents-b : String (doc-test-package-walk-example-source 2)]
        [contents-c : String (doc-test-package-walk-example-source 3)]
        (begin
          (io.write-file example-a (byte_buf.str-as-bytes (& contents-a)))
          (io.write-file example-b (byte_buf.str-as-bytes (& contents-b)))
          (io.write-file example-c (byte_buf.str-as-bytes (& contents-c)))))
      (let
        [paths : ast.AstDeclPathList
          (doc-test-package-walk-write-empty-paths
            (owned_view.compiler-owned-shared-view root)
            128
            (ast.ast-decl-root-path-cons
              (owned_view.compiler-owned-shared-view example-a)
              (ast.ast-decl-root-path-cons
                example-a
                (ast.ast-decl-root-path-cons
                  example-b
                  (ast.ast-decl-root-path-cons
                    example-c
                    (ast.ast-decl-path-list-new))))))]
        [report : doc_test.DocTestRunReport
          (doc_test.doc-test-typecheck-package-paths-with-roots
            paths
            (doc-test-run-smoke-stdlib-roots)
            root
            (compiler_load.compiler-pkg-deps-empty))]
        (and
          (doc_test.doc-test-run-report-ok?
            (owned_view.compiler-owned-shared-view report))
          (= (doc_test.doc-test-run-report-count report) 3))))))

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
      (build_run_tests.source-tool-link-inputs-dedupe-smoke-ok?)
      (return (io.panic "source-tool: link input dedupe smoke regressed")))
    (unless
      (build_run_tests.source-tool-link-dependency-section-smoke-ok?)
      (return (io.panic "source-tool: link dependency section smoke regressed")))
    (unless
      (build_run_tests.source-tool-windows-stack-reserve-smoke-ok?)
      (return (io.panic "source-tool: windows stack reserve smoke regressed")))
    (unless
      (build_run_tests.source-tool-windows-system-libs-smoke-ok?)
      (return (io.panic "source-tool: windows system libs smoke regressed")))
    (unless
      (build_run_tests.source-tool-windows-debug-linker-smoke-ok?)
      (return (io.panic "source-tool: windows debug linker smoke regressed")))
    (unless
      (build_run_tests.source-tool-windows-reproducible-linker-smoke-ok?)
      (return
        (io.panic "source-tool: windows reproducible linker smoke regressed")))
    (unless
      (build_run_tests.source-tool-linux-direct-object-linkability-smoke-ok?)
      (return (io.panic "source-tool: linux direct object smoke regressed")))
    (unless
      (build_run_tests.source-tool-windows-direct-object-linkability-smoke-ok?)
      (return (io.panic "source-tool: windows direct object smoke regressed")))
    (unless
      (build_run_tests.source-tool-windows-direct-object-runtime-fallback-smoke-ok?)
      (return
        (io.panic "source-tool: windows direct object fallback smoke regressed")))
    (unless
      (build_run_tests.source-tool-windows-direct-object-relocation-gate-smoke-ok?)
      (return
        (io.panic
          "source-tool: windows direct object relocation gate smoke regressed")))
    (doc-test-run-smoke)))