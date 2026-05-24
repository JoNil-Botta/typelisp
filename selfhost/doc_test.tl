;; doc_test.tl - Self-hosted TypeLisp doctest extraction (#722) + runner (#724).

;;

;; Extraction pulls TypeLisp fenced examples from public doc comments, mirroring

;; the Rust doctest runner's source scanning policy: module docs (`;;;;`) are

;; scanned as standalone doc blocks, item docs (`;;;`) attach only to the next

;; supported top-level declaration, ordinary comments are ignored, and unattached

;; item docs are dropped.

;;

;; The runner (#724) checks each extracted example through the in-memory

;; virtual-source loader/typechecker (`compiler-check-source`, #723): normal

;; examples must check successfully, `expect-error` examples must fail, and a

;; malformed fence (an extraction error) is itself a failure. Each failure

;; records the source path, the fence's source line, the example index, and the

;; rendered diagnostic when one is available.

(import "compiler_check_core.tl")

(defenum DocTestExpectation
  (DocTestExpectPass)
  (DocTestExpectError))

(defenum DocTestLine
  (DocTestLine i64 String))

(defenum DocTestLineList
  (DocTestLineNil)
  (DocTestLineCons DocTestLine DocTestLineList))

(defenum DocTestExample
  (DocTestExample i64 i64 DocTestExpectation String))

(defenum DocTestExampleList
  (DocTestExampleNil)
  (DocTestExampleCons DocTestExample DocTestExampleList))

(defenum DocTestError
  (DocTestError i64 String))

(defenum DocTestErrorList
  (DocTestErrorNil)
  (DocTestErrorCons DocTestError DocTestErrorList))

(defenum DocTestExtraction
  (DocTestExtraction DocTestExampleList DocTestErrorList))

(defenum DocTestMaybeString
  (DocTestNoString)
  (DocTestSomeString String))

(defenum DocTestFenceInfo
  (DocTestFenceIgnore)
  (DocTestFenceTypeLisp DocTestExpectation)
  (DocTestFenceMalformed DocTestError))

(defenum DocTestCodeCollect
  (DocTestCodeCollect DocTestLineList String bool))

(defenum DocTestScanState
  (DocTestScanState DocTestExampleList DocTestErrorList i64))

(define (doc-test-line-number [line : DocTestLine]) : i64
  (match line
    [(DocTestLine line-number _) line-number]))

(define (doc-test-line-text [line : DocTestLine]) : String
  (match line
    [(DocTestLine _ text) text]))

(define (doc-test-example-index [example : DocTestExample]) : i64
  (match example
    [(DocTestExample index _ _ _) index]))

(define (doc-test-example-source-line [example : DocTestExample]) : i64
  (match example
    [(DocTestExample _ source-line _ _) source-line]))

(define (doc-test-example-expectation [example : DocTestExample]) : DocTestExpectation
  (match example
    [(DocTestExample _ _ expectation _) expectation]))

(define (doc-test-example-code [example : DocTestExample]) : String
  (match example
    [(DocTestExample _ _ _ code) code]))

(define (doc-test-error-line [err : DocTestError]) : i64
  (match err
    [(DocTestError line-number _) line-number]))

(define (doc-test-error-message [err : DocTestError]) : String
  (match err
    [(DocTestError _ message) message]))

(define (doc-test-extraction-examples [extraction : DocTestExtraction]) : DocTestExampleList
  (match extraction
    [(DocTestExtraction examples _) examples]))

(define (doc-test-extraction-errors [extraction : DocTestExtraction]) : DocTestErrorList
  (match extraction
    [(DocTestExtraction _ errors) errors]))

(define (doc-test-expectation-error? [expectation : DocTestExpectation]) : bool
  (match expectation
    [(DocTestExpectPass) false]
    [(DocTestExpectError) true]))

(define (doc-test-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (doc-test-space? [c : char]) : bool
  (or (= c #\space') (or (= c #\tab') (or (= c #\newline') (= c #\return')))))

(define (doc-test-inline-space? [c : char]) : bool
  (or (= c #\space') (= c #\tab')))

(define (doc-test-newline? [c : char]) : bool
  (or (= c #\newline') (= c #\return')))

(define (doc-test-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let ([text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)])
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let ([i : i64 0] [ok : bool true])
          (begin
            (while ok
              (if (< i prefix-len)
                (if (= (string-ref text (+ start i)) (string-ref prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (doc-test-string-prefix? [text : String] [prefix : String]) : bool
  (doc-test-string-prefix-at? text prefix 0))

(define (doc-test-string-contains? [text : String] [needle : String]) : bool
  (let ([text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)])
    (if (= needle-len 0)
      true
      (let ([i : i64 0] [found : bool false] [done : bool false])
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
  (let ([n : i64 (string-length text)]
    [i : i64 0]
    [start : i64 0]
    [done : bool false])
    (begin
      (while (< i n)
        (if done
          (set! i n)
          (if (doc-test-inline-space? (string-ref text i))
            (begin
              (set! start (+ i 1))
              (set! i (+ i 1)))
            (set! done true))))
      (substring text start (- n start)))))

(define (doc-test-string-blank? [text : String]) : bool
  (let ([n : i64 (string-length text)] [i : i64 0] [blank : bool true])
    (begin
      (while (< i n)
        (if blank
          (if (doc-test-space? (string-ref text i))
            (set! i (+ i 1))
            (begin
              (set! blank false)
              (set! i n)))
          (set! i n)))
      blank)))

(define (doc-test-word-end [text : String] [start : i64]) : i64
  (let ([n : i64 (string-length text)] [i : i64 start] [keep : bool true])
    (begin
      (while keep
        (if (< i n)
          (if (doc-test-space? (string-ref text i))
            (set! keep false)
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (doc-test-line-end [src : String] [start : i64] [n : i64]) : i64
  (let ([i : i64 start] [keep : bool true])
    (begin
      (while keep
        (if (< i n)
          (if (doc-test-newline? (string-ref src i))
            (set! keep false)
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (doc-test-next-line-start [src : String] [line-end : i64] [n : i64]) : i64
  (if (< line-end n)
    (let ([c : char (string-ref src line-end)])
      (if (= c #\return')
        (if (< (+ line-end 1) n)
          (if (= (string-ref src (+ line-end 1)) #\newline')
            (+ line-end 2)
            (+ line-end 1))
          (+ line-end 1))
        (+ line-end 1)))
    line-end))

(define (doc-test-line-list-reverse-into
  [lines : DocTestLineList]
  [acc : DocTestLineList]) : DocTestLineList
  (match lines
    [(DocTestLineNil) acc]
    [(DocTestLineCons line rest)
      (doc-test-line-list-reverse-into rest (DocTestLineCons line acc))]))

(define (doc-test-line-list-reverse [lines : DocTestLineList]) : DocTestLineList
  (doc-test-line-list-reverse-into lines DocTestLineNil))

(define (doc-test-example-list-append
  [examples : DocTestExampleList]
  [example : DocTestExample]) : DocTestExampleList
  (match examples
    [(DocTestExampleNil) (DocTestExampleCons example DocTestExampleNil)]
    [(DocTestExampleCons head rest)
      (DocTestExampleCons head (doc-test-example-list-append rest example))]))

(define (doc-test-error-list-append
  [errors : DocTestErrorList]
  [err : DocTestError]) : DocTestErrorList
  (match errors
    [(DocTestErrorNil) (DocTestErrorCons err DocTestErrorNil)]
    [(DocTestErrorCons head rest)
      (DocTestErrorCons head (doc-test-error-list-append rest err))]))

(define (doc-test-example-list-count [examples : DocTestExampleList]) : i64
  (match examples
    [(DocTestExampleNil) 0]
    [(DocTestExampleCons _ rest) (+ 1 (doc-test-example-list-count rest))]))

(define (doc-test-error-list-count [errors : DocTestErrorList]) : i64
  (match errors
    [(DocTestErrorNil) 0]
    [(DocTestErrorCons _ rest) (+ 1 (doc-test-error-list-count rest))]))

(define (doc-test-doc-comment-body [line : String] [prefix : String]) : DocTestMaybeString
  (let ([trimmed : String (doc-test-trim-left line)])
    (if (and (string-eq prefix ";;;") (doc-test-string-prefix? trimmed ";;;;"))
      (DocTestNoString)
      (if (doc-test-string-prefix? trimmed prefix)
        (let ([prefix-len : i64 (string-length prefix)]
          [trimmed-len : i64 (string-length trimmed)])
          (let ([body
              :
              String
              (substring trimmed prefix-len (- trimmed-len prefix-len))])
            (if (> (string-length body) 0)
              (if (= (string-ref body 0) #\space')
                (DocTestSomeString
                  (substring body 1 (- (string-length body) 1)))
                (DocTestSomeString body))
              (DocTestSomeString body))))
        (DocTestNoString)))))

(define (doc-test-starts-with-form-head? [text : String] [head : String]) : bool
  (if (doc-test-string-prefix? text head)
    (let ([head-len : i64 (string-length head)]
      [text-len : i64 (string-length text)])
      (if (= head-len text-len)
        true
        (let ([c : char (string-ref text head-len)])
          (or (doc-test-space? c) (or (= c #(') (= c #)'))))))
    false))

(define (doc-test-supported-item-declaration? [line : String]) : bool
  (let ([trimmed : String (doc-test-trim-left line)])
    (if (> (string-length trimmed) 0)
      (if (= (string-ref trimmed 0) #(')
        (let ([rest
            :
            String
            (doc-test-trim-left
              (substring trimmed 1 (- (string-length trimmed) 1)))])
          (or
            (doc-test-starts-with-form-head? rest "define")
            (or
              (doc-test-starts-with-form-head? rest "extern")
              (or
                (doc-test-starts-with-form-head? rest "defenum")
                (doc-test-starts-with-form-head? rest "defstruct")))))
        false)
      false)))

(define (doc-test-parse-fence-options
  [text : String]
  [line-number : i64]
  [expectation : DocTestExpectation]) : DocTestFenceInfo
  (let ([trimmed : String (doc-test-trim-left text)])
    (if (= (string-length trimmed) 0)
      (DocTestFenceTypeLisp expectation)
      (let ([end : i64 (doc-test-word-end trimmed 0)])
        (let ([option : String (substring trimmed 0 end)]
          [rest
            :
            String
            (substring trimmed end (- (string-length trimmed) end))])
          (if (string-eq option "expect-error")
            (doc-test-parse-fence-options rest line-number (DocTestExpectError))
            (DocTestFenceMalformed
              (DocTestError
                line-number
                (doc-test-cat3
                  "unsupported TypeLisp doctest option `"
                  option
                  "`")))))))))

(define (doc-test-parse-fence-info [info : String] [line-number : i64]) : DocTestFenceInfo
  (let ([trimmed : String (doc-test-trim-left info)])
    (if (= (string-length trimmed) 0)
      (DocTestFenceIgnore)
      (let ([end : i64 (doc-test-word-end trimmed 0)])
        (let ([language : String (substring trimmed 0 end)]
          [rest
            :
            String
            (substring trimmed end (- (string-length trimmed) end))])
          (if (or (string-eq language "typelisp") (string-eq language "tl"))
            (doc-test-parse-fence-options rest line-number (DocTestExpectPass))
            (DocTestFenceIgnore)))))))

(define (doc-test-skip-ignored-fence [lines : DocTestLineList]) : DocTestLineList
  (match lines
    [(DocTestLineNil) DocTestLineNil]
    [(DocTestLineCons line rest)
      (if (doc-test-string-prefix?
        (doc-test-trim-left (doc-test-line-text line))
        "```")
        rest
        (doc-test-skip-ignored-fence rest))]))

(define (doc-test-collect-code [lines : DocTestLineList] [code : String]) : DocTestCodeCollect
  (match lines
    [(DocTestLineNil) (DocTestCodeCollect DocTestLineNil code false)]
    [(DocTestLineCons line rest)
      (if (doc-test-string-prefix?
        (doc-test-trim-left (doc-test-line-text line))
        "```")
        (DocTestCodeCollect rest code true)
        (doc-test-collect-code
          rest
          (string-append code (string-append (doc-test-line-text line) "\n"))))]))

(define (doc-test-scan-type-lisp-fence
  [rest : DocTestLineList]
  [state : DocTestScanState]
  [source-line : i64]
  [expectation : DocTestExpectation]) : DocTestScanState
  (match (doc-test-collect-code rest "")
    [(DocTestCodeCollect remaining code closed)
      (match state
        [(DocTestScanState examples errors next-index)
          (if closed
            (if (doc-test-string-blank? code)
              (doc-test-scan-doc-block
                remaining
                (DocTestScanState
                  examples
                  (doc-test-error-list-append
                    errors
                    (DocTestError source-line "empty TypeLisp doctest fence"))
                  next-index))
              (doc-test-scan-doc-block
                remaining
                (DocTestScanState
                  (doc-test-example-list-append
                    examples
                    (DocTestExample next-index source-line expectation code))
                  errors
                  (+ next-index 1))))
            (DocTestScanState
              examples
              (doc-test-error-list-append
                errors
                (DocTestError source-line "unterminated TypeLisp doctest fence"))
              next-index))])]))

(define (doc-test-scan-doc-block
  [lines : DocTestLineList]
  [state : DocTestScanState]) : DocTestScanState
  (match lines
    [(DocTestLineNil) state]
    [(DocTestLineCons line rest)
      (let ([trimmed : String (doc-test-trim-left (doc-test-line-text line))])
        (if (doc-test-string-prefix? trimmed "```")
          (let ([info
              :
              String
              (substring trimmed 3 (- (string-length trimmed) 3))])
            (match (doc-test-parse-fence-info info (doc-test-line-number line))
              [(DocTestFenceIgnore)
                (doc-test-scan-doc-block
                  (doc-test-skip-ignored-fence rest)
                  state)]
              [(DocTestFenceMalformed err)
                (match state
                  [(DocTestScanState examples errors next-index)
                    (doc-test-scan-doc-block
                      rest
                      (DocTestScanState
                        examples
                        (doc-test-error-list-append errors err)
                        next-index))])]
              [(DocTestFenceTypeLisp expectation)
                (doc-test-scan-type-lisp-fence
                  rest
                  state
                  (doc-test-line-number line)
                  expectation)]))
          (doc-test-scan-doc-block rest state)))]))

(define (doc-test-scan-reversed-block
  [lines : DocTestLineList]
  [state : DocTestScanState]) : DocTestScanState
  (doc-test-scan-doc-block (doc-test-line-list-reverse lines) state))

(define (doc-test-extract-source [src : String]) : DocTestExtraction
  (let ([n : i64 (string-length src)]
    [pos : i64 0]
    [line-number : i64 1]
    [module-lines : DocTestLineList DocTestLineNil]
    [pending-lines : DocTestLineList DocTestLineNil]
    [state
      :
      DocTestScanState
      (DocTestScanState DocTestExampleNil DocTestErrorNil 1)])
    (begin
      (while (< pos n)
        (let ([line-end : i64 (doc-test-line-end src pos n)])
          (let ([line : String (substring src pos (- line-end pos))])
            (begin
              (match (doc-test-doc-comment-body line ";;;;")
                [(DocTestSomeString body)
                  (begin
                    (set! pending-lines DocTestLineNil)
                    (set!
                      module-lines
                      (DocTestLineCons
                        (DocTestLine line-number body)
                        module-lines)))]
                [(DocTestNoString)
                  (begin
                    (set!
                      state
                      (doc-test-scan-reversed-block module-lines state))
                    (set! module-lines DocTestLineNil)
                    (match (doc-test-doc-comment-body line ";;;")
                      [(DocTestSomeString body)
                        (set!
                          pending-lines
                          (DocTestLineCons
                            (DocTestLine line-number body)
                            pending-lines))]
                      [(DocTestNoString)
                        (if (doc-test-supported-item-declaration? line)
                          (begin
                            (set!
                              state
                              (doc-test-scan-reversed-block pending-lines state))
                            (set! pending-lines DocTestLineNil))
                          (set! pending-lines DocTestLineNil))]))])
              (set! pos (doc-test-next-line-start src line-end n))
              (set! line-number (+ line-number 1))))))
      (set! state (doc-test-scan-reversed-block module-lines state))
      (match state
        [(DocTestScanState examples errors _)
          (DocTestExtraction examples errors)]))))

(define (doc-test-extract-file [path : String]) : DocTestExtraction
  (doc-test-extract-source (read-file path)))

;; --- runner (#724) ----------------------------------------------------------

;; A single doctest failure: the doc'd source path, the fence's 1-based source

;; line, the example index (`-1` for a fence-level extraction error that has no

;; example), and a human-readable reason (the rendered diagnostic when one is

;; available).

(defenum DocTestRunFailure
  (DocTestRunFailure String i64 i64 String))

(defenum DocTestRunFailureList
  (DocTestRunFailureNil)
  (DocTestRunFailureCons DocTestRunFailure DocTestRunFailureList))

;; Outcome of running a source: how many examples were checked and which failed.

(defenum DocTestRunReport
  (DocTestRunReport i64 DocTestRunFailureList))

(defenum DocTestMaybeFailure
  (DocTestNoFailure)
  (DocTestSomeFailure DocTestRunFailure))

(define (doc-test-run-failure-path [failure : DocTestRunFailure]) : String
  (match failure
    [(DocTestRunFailure path _ _ _) path]))

(define (doc-test-run-failure-line [failure : DocTestRunFailure]) : i64
  (match failure
    [(DocTestRunFailure _ line _ _) line]))

(define (doc-test-run-failure-index [failure : DocTestRunFailure]) : i64
  (match failure
    [(DocTestRunFailure _ _ index _) index]))

(define (doc-test-run-failure-message [failure : DocTestRunFailure]) : String
  (match failure
    [(DocTestRunFailure _ _ _ message) message]))

(define (doc-test-run-report-count [report : DocTestRunReport]) : i64
  (match report
    [(DocTestRunReport count _) count]))

(define (doc-test-run-report-failures [report : DocTestRunReport]) : DocTestRunFailureList
  (match report
    [(DocTestRunReport _ failures) failures]))

(define (doc-test-run-failure-list-count [failures : DocTestRunFailureList]) : i64
  (match failures
    [(DocTestRunFailureNil) 0]
    [(DocTestRunFailureCons _ rest)
      (+ 1 (doc-test-run-failure-list-count rest))]))

(define (doc-test-run-report-ok? [report : DocTestRunReport]) : bool
  (match (doc-test-run-report-failures report)
    [(DocTestRunFailureNil) true]
    [(DocTestRunFailureCons _ _) false]))

(define (doc-test-run-failure-list-append
  [failures : DocTestRunFailureList]
  [failure : DocTestRunFailure]) : DocTestRunFailureList
  (match failures
    [(DocTestRunFailureNil)
      (DocTestRunFailureCons failure DocTestRunFailureNil)]
    [(DocTestRunFailureCons head rest)
      (DocTestRunFailureCons
        head
        (doc-test-run-failure-list-append rest failure))]))

;; Render a failure as `path:line: message`. Fence-level extraction

;; errors use index `-1`; example failures include the example number in their

;; message so the public CLI text matches the stage0 Rust runner.

(define (doc-test-run-failure-render [failure : DocTestRunFailure]) : String
  (match failure
    [(DocTestRunFailure path line index message)
      (let ([location
          :
          String
          (string-append
            path
            (string-append ":" (string-append (int->string line) ": ")))])
        (string-append location message))]))

(define (doc-test-unexpected-pass-message [index : i64]) : String
  (string-append
    "doctest example "
    (string-append (int->string index) " was expected to fail but passed")))

(define (doc-test-diagnostic-code [diag : CompilerDiagnostic]) : String
  (let ([message : String (compiler-diagnostic-message diag)])
    (if (or
      (doc-test-string-prefix? message "parse:")
      (doc-test-string-prefix? message "reader:"))
      "E0100"
      "E0200")))

(define (doc-test-public-diagnostic-render [diag : CompilerDiagnostic]) : String
  (string-append
    "error["
    (string-append
      (doc-test-diagnostic-code diag)
      (string-append "]: " (compiler-diagnostic-render diag)))))

(define (doc-test-unexpected-error-message
  [index : i64]
  [diag : CompilerDiagnostic]) : String
  (string-append
    "doctest example "
    (string-append
      (int->string index)
      (string-append
        " was expected to pass\n"
        (doc-test-public-diagnostic-render diag)))))

;; Check one extracted example through the virtual-source typechecker, comparing

;; the outcome against its expectation. Imports inside the example resolve

;; relative to `path` (the doc'd source file).

(define (doc-test-check-example [path : String] [example : DocTestExample]) : DocTestMaybeFailure
  (doc-test-check-example-with-roots path example CompilerLoadRootNil))

(define (doc-test-check-example-with-roots
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : CompilerLoadRootList]) : DocTestMaybeFailure
  (let ([index : i64 (doc-test-example-index example)]
    [source-line : i64 (doc-test-example-source-line example)]
    [expect-error
      :
      bool
      (doc-test-expectation-error? (doc-test-example-expectation example))]
    [code : String (doc-test-example-code example)])
    (match (compiler-check-source-with-roots path code stdlib-roots)
      [(OkCompilerCheck _)
        (if expect-error
          (DocTestSomeFailure
            (DocTestRunFailure
              path
              source-line
              index
              (doc-test-unexpected-pass-message index)))
          (DocTestNoFailure))]
      [(ErrCompilerCheck diag)
        (if expect-error
          (DocTestNoFailure)
          (DocTestSomeFailure
            (DocTestRunFailure
              path
              source-line
              index
              (doc-test-unexpected-error-message index diag))))])))

(define (doc-test-run-examples
  [path : String]
  [examples : DocTestExampleList]
  [failures : DocTestRunFailureList]) : DocTestRunFailureList
  (doc-test-run-examples-with-roots path examples failures CompilerLoadRootNil))

(define (doc-test-run-examples-with-roots
  [path : String]
  [examples : DocTestExampleList]
  [failures : DocTestRunFailureList]
  [stdlib-roots : CompilerLoadRootList]) : DocTestRunFailureList
  (match examples
    [(DocTestExampleNil) failures]
    [(DocTestExampleCons example rest)
      (match (doc-test-check-example-with-roots path example stdlib-roots)
        [(DocTestNoFailure)
          (doc-test-run-examples-with-roots path rest failures stdlib-roots)]
        [(DocTestSomeFailure failure)
          (doc-test-run-examples-with-roots
            path
            rest
            (doc-test-run-failure-list-append failures failure)
            stdlib-roots)])]))

;; A malformed/empty/unterminated fence is a runner failure too; it has no

;; example index, so it is recorded with index `-1`.

(define (doc-test-errors-to-failures
  [path : String]
  [errors : DocTestErrorList]
  [failures : DocTestRunFailureList]) : DocTestRunFailureList
  (match errors
    [(DocTestErrorNil) failures]
    [(DocTestErrorCons err rest)
      (doc-test-errors-to-failures
        path
        rest
        (doc-test-run-failure-list-append
          failures
          (DocTestRunFailure
            path
            (doc-test-error-line err)
            -1
            (doc-test-error-message err))))]))

;; Extract and check every example in `source` (attributed to `path`). Extraction

;; errors are folded in as failures first, then each example is checked. A source

;; with no examples and no errors reports success with a zero count.

(define (doc-test-run-source [path : String] [source : String]) : DocTestRunReport
  (doc-test-run-source-with-roots path source CompilerLoadRootNil))

(define (doc-test-run-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : CompilerLoadRootList]) : DocTestRunReport
  (match (doc-test-extract-source source)
    [(DocTestExtraction examples errors)
      (DocTestRunReport
        (doc-test-example-list-count examples)
        (doc-test-run-examples-with-roots
          path
          examples
          (doc-test-errors-to-failures path errors DocTestRunFailureNil)
          stdlib-roots))]))

(define (doc-test-run-file [path : String]) : DocTestRunReport
  (doc-test-run-source path (read-file path)))

(define (doc-test-run-file-with-roots
  [path : String]
  [stdlib-roots : CompilerLoadRootList]) : DocTestRunReport
  (doc-test-run-source-with-roots path (read-file path) stdlib-roots))

;; Exit status for a report: 0 when every example passed (or there were none),

;; 1 otherwise. Callers turn this directly into a process exit code.

(define (doc-test-run-report-status [report : DocTestRunReport]) : i64
  (if (doc-test-run-report-ok? report)
    0
    1))

;; Render every failure as `path:line: ...`, one per line, in extraction order.

(define (doc-test-run-failures-render [failures : DocTestRunFailureList]) : String
  (match failures
    [(DocTestRunFailureNil) ""]
    [(DocTestRunFailureCons failure rest)
      (string-append
        (string-append (doc-test-run-failure-render failure) "\n")
        (doc-test-run-failures-render rest))]))

;; Human-readable report text. Success mirrors the Rust CLI's

;; `Doc tests passed: N example(s)` line; failure mirrors its

;; `doc tests failed: M failure(s) across N example(s)` summary followed by each

;; rendered failure.

(define (doc-test-run-report-render [report : DocTestRunReport]) : String
  (match report
    [(DocTestRunReport count failures)
      (match failures
        [(DocTestRunFailureNil)
          (string-append
            "Doc tests passed: "
            (string-append (int->string count) " example(s)"))]
        [(DocTestRunFailureCons _ _)
          (string-append
            (doc-test-cat3
              "doc tests failed: "
              (int->string (doc-test-run-failure-list-count failures))
              (doc-test-cat3
                " failure(s) across "
                (int->string count)
                " example(s)\n"))
            (doc-test-run-failures-render failures))])]))

(define (doc-test-smoke-source) : String
  ";;;; Module docs
;;;; ```typelisp
;;;; (define (main) : i64 0)
;;;; ```

;;; Item docs
;;; ```tl expect-error
;;; (define (bad) : i64 true)
;;; ```
(define good : i64 1)

;;; Unattached docs are ignored
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
  ";;;; ```typelisp maybe
;;;; (define (main) : i64 0)
;;;; ```

;;;; ```tl
;;;; ```

;;;; ```typelisp
;;;; (define (open) : i64 0)
")

(define (doc-test-example-ok?
  [example : DocTestExample]
  [index : i64]
  [source-line : i64]
  [expect-error : bool]
  [code-fragment : String]) : bool
  (if (= (doc-test-example-index example) index)
    (if (= (doc-test-example-source-line example) source-line)
      (if (=
        (doc-test-expectation-error? (doc-test-example-expectation example))
        expect-error)
        (doc-test-string-contains?
          (doc-test-example-code example)
          code-fragment)
        false)
      false)
    false))

(define (doc-test-smoke-examples-ok? [examples : DocTestExampleList]) : bool
  (match examples
    [(DocTestExampleCons first (DocTestExampleCons second DocTestExampleNil))
      (if (doc-test-example-ok? first 1 2 false "(define (main)")
        (doc-test-example-ok? second 2 7 true "(define (bad)")
        false)]
    [_ false]))

(define (doc-test-malformed-errors-ok? [errors : DocTestErrorList]) : bool
  (match errors
    [(DocTestErrorCons
        first
        (DocTestErrorCons second (DocTestErrorCons third DocTestErrorNil)))
      (if (= (doc-test-error-line first) 1)
        (if (doc-test-string-contains?
          (doc-test-error-message first)
          "unsupported TypeLisp doctest option")
          (if (= (doc-test-error-line second) 5)
            (if (doc-test-string-contains?
              (doc-test-error-message second)
              "empty TypeLisp doctest fence")
              (if (= (doc-test-error-line third) 8)
                (doc-test-string-contains?
                  (doc-test-error-message third)
                  "unterminated TypeLisp doctest fence")
                false)
              false)
            false)
          false)
        false)]
    [_ false]))

(define (doc-test-smoke) : i64
  (match (doc-test-extract-source (doc-test-smoke-source))
    [(DocTestExtraction examples errors)
      (if (= (doc-test-error-list-count errors) 0)
        (if (= (doc-test-example-list-count examples) 2)
          (if (doc-test-smoke-examples-ok? examples)
            (match (doc-test-extract-source (doc-test-ordinary-comment-source))
              [(DocTestExtraction ordinary-examples ordinary-errors)
                (if (= (doc-test-example-list-count ordinary-examples) 0)
                  (if (= (doc-test-error-list-count ordinary-errors) 0)
                    (match (doc-test-extract-source (doc-test-malformed-source))
                      [(DocTestExtraction malformed-examples malformed-errors)
                        (if (=
                          (doc-test-example-list-count malformed-examples)
                          0)
                          (if (= (doc-test-error-list-count malformed-errors) 3)
                            (if (doc-test-malformed-errors-ok? malformed-errors)
                              42
                              (begin
                                (panic "doc-test: malformed metadata mismatch")
                                0))
                            (begin
                              (panic "doc-test: malformed error count mismatch")
                              0))
                          (begin
                            (panic "doc-test: malformed example count mismatch")
                            0))])
                    (begin
                      (panic "doc-test: ordinary comment error mismatch")
                      0))
                  (begin
                    (panic "doc-test: ordinary comment example mismatch")
                    0))])
            (begin
              (panic "doc-test: example metadata mismatch")
              0))
          (begin
            (panic "doc-test: example count mismatch")
            0))
        (begin
          (panic "doc-test: unexpected extraction error")
          0))]))

;; --- runner self-test (#724) ------------------------------------------------

;; A normal example whose body fails to typecheck (i64 return, bool body).

(define (doc-test-run-unexpected-error-source) : String
  ";;;; ```typelisp
;;;; (define (main) : i64 true)
;;;; ```
")

;; An `expect-error` example that actually checks successfully.

(define (doc-test-run-unexpected-pass-source) : String
  ";;;; ```typelisp expect-error
;;;; (define (main) : i64 0)
;;;; ```
")

;; A file with no doctest fences at all.

(define (doc-test-run-empty-source) : String
  ";; just an ordinary comment, no doctest fence
(define answer : i64 1)
")

;; The shared smoke source has one passing and one correctly-erroring

;; (`expect-error`) example, so it must run clean: two examples, no failures.

(define (doc-test-run-smoke-pass-ok?) : bool
  (let ([report
      :
      DocTestRunReport
      (doc-test-run-source "docs/ok.tl" (doc-test-smoke-source))])
    (if (= (doc-test-run-report-count report) 2)
      (doc-test-run-report-ok? report)
      false)))

;; A normal example that fails to check yields exactly one failure carrying the

;; fence line (1), example index (1), and the rendered diagnostic message.

(define (doc-test-run-smoke-unexpected-error-ok?) : bool
  (let ([report
      :
      DocTestRunReport
      (doc-test-run-source "docs/bad.tl" (doc-test-run-unexpected-error-source))])
    (match (doc-test-run-report-failures report)
      [(DocTestRunFailureCons failure (DocTestRunFailureNil))
        (if (= (doc-test-run-failure-index failure) 1)
          (if (= (doc-test-run-failure-line failure) 1)
            (if (string-eq (doc-test-run-failure-path failure) "docs/bad.tl")
              (doc-test-string-contains?
                (doc-test-run-failure-message failure)
                "return type mismatch")
              false)
            false)
          false)]
      [_ false])))

;; An `expect-error` example that checks successfully is a failure.

(define (doc-test-run-smoke-unexpected-pass-ok?) : bool
  (let ([report
      :
      DocTestRunReport
      (doc-test-run-source "docs/bad.tl" (doc-test-run-unexpected-pass-source))])
    (match (doc-test-run-report-failures report)
      [(DocTestRunFailureCons failure (DocTestRunFailureNil))
        (doc-test-string-contains?
          (doc-test-run-failure-message failure)
          "was expected to fail")]
      [_ false])))

;; Malformed fences (the shared malformed source's three extraction errors)

;; become three runner failures with no examples.

(define (doc-test-run-smoke-malformed-ok?) : bool
  (let ([report
      :
      DocTestRunReport
      (doc-test-run-source "docs/malformed.tl" (doc-test-malformed-source))])
    (if (= (doc-test-run-report-count report) 0)
      (=
        (doc-test-run-failure-list-count (doc-test-run-report-failures report))
        3)
      false)))

;; A source with no examples reports success with a zero count.

(define (doc-test-run-smoke-empty-ok?) : bool
  (let ([report
      :
      DocTestRunReport
      (doc-test-run-source "docs/empty.tl" (doc-test-run-empty-source))])
    (if (= (doc-test-run-report-count report) 0)
      (doc-test-run-report-ok? report)
      false)))

;; The rendered failure carries the path, line, and message.

(define (doc-test-run-smoke-render-ok?) : bool
  (let ([rendered
      :
      String
      (doc-test-run-failure-render
        (DocTestRunFailure
          "docs/bad.tl"
          4
          2
          "doctest example 2 was expected to pass
typecheck: return type mismatch"))])
    (if (doc-test-string-contains? rendered "docs/bad.tl:4:")
      (if (doc-test-string-contains? rendered "doctest example 2")
        (doc-test-string-contains? rendered "return type mismatch")
        false)
      false)))

;; The report-level text mirrors the Rust CLI: a clean run renders the

;; `Doc tests passed: N example(s)` line with status 0, and a failing run renders

;; the `doc tests failed: M failure(s) across N example(s)` summary with status 1.

(define (doc-test-run-smoke-report-render-ok?) : bool
  (let ([pass-report
      :
      DocTestRunReport
      (doc-test-run-source "docs/ok.tl" (doc-test-smoke-source))]
    [fail-report
      :
      DocTestRunReport
      (doc-test-run-source "docs/bad.tl" (doc-test-run-unexpected-error-source))])
    (if (= (doc-test-run-report-status pass-report) 0)
      (if (string-eq
        (doc-test-run-report-render pass-report)
        "Doc tests passed: 2 example(s)")
        (if (= (doc-test-run-report-status fail-report) 1)
          (if (doc-test-string-contains?
            (doc-test-run-report-render fail-report)
            "doc tests failed: 1 failure(s) across 1 example(s)")
            (doc-test-string-contains?
              (doc-test-run-report-render fail-report)
              "return type mismatch")
            false)
          false)
        false)
      false)))

(define (doc-test-run-smoke) : i64
  (if (doc-test-run-smoke-pass-ok?)
    (if (doc-test-run-smoke-unexpected-error-ok?)
      (if (doc-test-run-smoke-unexpected-pass-ok?)
        (if (doc-test-run-smoke-malformed-ok?)
          (if (doc-test-run-smoke-empty-ok?)
            (if (doc-test-run-smoke-render-ok?)
              (if (doc-test-run-smoke-report-render-ok?)
                42
                (begin
                  (panic "doc-test-run: report render mismatch")
                  0))
              (begin
                (panic "doc-test-run: render mismatch")
                0))
            (begin
              (panic "doc-test-run: empty-source mismatch")
              0))
          (begin
            (panic "doc-test-run: malformed mismatch")
            0))
        (begin
          (panic "doc-test-run: unexpected-pass mismatch")
          0))
      (begin
        (panic "doc-test-run: unexpected-error mismatch")
        0))
    (begin
      (panic "doc-test-run: pass-case mismatch")
      0)))

;; Combined smoke: extraction (#722) then runner (#724). Returns 42 iff both

;; self-test batteries pass.

(define (doc-test-smoke-all) : i64
  (if (= (doc-test-smoke) 42)
    (doc-test-run-smoke)
    (begin
      (panic "doc-test: extraction smoke regressed")
      0)))