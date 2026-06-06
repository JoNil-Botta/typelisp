;; doc_test.tl - Self-hosted TypeLisp doctest extraction (#722) + runner (#724).
;;
;; Extraction pulls TypeLisp fenced examples from public doc comments, mirroring
;; the public doc scanning policy: module docs (`;#`) are scanned as standalone
;; doc blocks, item docs (`;:`) attach only to the next supported top-level
;; declaration, blank physical lines are tolerated between doc comment lines,
;; ordinary comments are ignored, and unattached item docs are dropped.
;;
;; The runner (#724/#1322) checks extracted examples through the in-memory
;; virtual-source loader/typechecker (`compiler-check-source`, #723), and runs
;; `typelisp run` / `tl run` examples through the self-hosted no-Rust build/run
;; path where the target supports process execution. Each failure records the
;; source path, the fence's source line, the example index, and the rendered
;; diagnostic when one is available.
(import "../stdlib/io.tl")

(import "compiler_check_core.tl")

(import "build_run_core.tl")

(defenum DocTestExpectation
  (DocTestExpectPass)
  (DocTestExpectError)
  (DocTestExpectRun i64 String String))

(defenum DocTestFenceMode
  (DocTestFenceCheck DocTestExpectation)
  (DocTestFenceRun))

(defenum DocTestLine
  (DocTestLine i64 String))

(defenum DocTestLineList
  (DocTestLineNil)
  (DocTestLineCons DocTestLine (Box DocTestLineList)))

(defenum DocTestExample
  (DocTestExample i64 i64 DocTestExpectation String))

(defenum DocTestExampleList
  (DocTestExampleNil)
  (DocTestExampleCons DocTestExample (Box DocTestExampleList)))

(defenum DocTestError
  (DocTestError i64 String))

(defenum DocTestErrorList
  (DocTestErrorNil)
  (DocTestErrorCons DocTestError (Box DocTestErrorList)))

(defenum DocTestExtraction
  (DocTestExtraction DocTestExampleList DocTestErrorList))

(define (doc-test-line-cons [line : DocTestLine] [rest : DocTestLineList]) : DocTestLineList
  (DocTestLineCons line (box rest)))

(define (doc-test-example-cons
  [example : DocTestExample]
  [rest : DocTestExampleList]) : DocTestExampleList
  (DocTestExampleCons example (box rest)))

(define (doc-test-error-cons [err : DocTestError] [rest : DocTestErrorList]) : DocTestErrorList
  (DocTestErrorCons err (box rest)))

(defenum DocTestMaybeString
  (DocTestNoString)
  (DocTestSomeString String))

(defenum DocTestFenceInfo
  (DocTestFenceIgnore)
  (DocTestFenceTypeLisp DocTestFenceMode)
  (DocTestFenceMalformed DocTestError))

(defenum DocTestCodeCollect
  (DocTestCodeCollect DocTestLineList String DocTestLineList bool))

(defenum DocTestMaybeI64
  (DocTestNoI64 String)
  (DocTestSomeI64 i64))

(defenum DocTestMaybeOutput
  (DocTestNoOutput String)
  (DocTestSomeOutput String))

(defenum DocTestRunMetadata
  (DocTestRunMetadata bool i64 bool String bool String DocTestErrorList))

(defenum DocTestRunMetadataParse
  (DocTestRunMetadataOk DocTestExpectation)
  (DocTestRunMetadataErr DocTestErrorList))

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
    [(DocTestExpectError) true]
    [(DocTestExpectRun _ _ _) false]))

(define (doc-test-expectation-run? [expectation : DocTestExpectation]) : bool
  (match expectation
    [(DocTestExpectRun _ _ _) true]
    [_ false]))

(define (doc-test-expectation-run-exit [expectation : DocTestExpectation]) : i64
  (match expectation
    [(DocTestExpectRun expected-exit _ _) expected-exit]
    [_ -1]))

(define (doc-test-expectation-run-stdout [expectation : DocTestExpectation]) : String
  (match expectation
    [(DocTestExpectRun _ expected-stdout _) expected-stdout]
    [_ ""]))

(define (doc-test-expectation-run-stderr [expectation : DocTestExpectation]) : String
  (match expectation
    [(DocTestExpectRun _ _ expected-stderr) expected-stderr]
    [_ ""]))

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
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
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
                (if (= (string-ref text (+ start i)) (string-ref prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (doc-test-string-prefix? [text : String] [prefix : String]) : bool
  (doc-test-string-prefix-at? text prefix 0))

(define (doc-test-string-contains? [text : String] [needle : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)]
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
    [n : i64 (string-length text)]
    [i : i64 0]
    [start : i64 0]
    [done : bool false]
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

(define (doc-test-trim-right [text : String]) : String
  (let
    [end : i64 (string-length text)]
    [keep : bool true]
    (begin
      (while keep
        (if (> end 0)
          (if (doc-test-inline-space? (string-ref text (- end 1)))
            (set! end (- end 1))
            (set! keep false))
          (set! keep false)))
      (substring text 0 end))))

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

(define (doc-test-parse-i64 [text : String]) : DocTestMaybeI64
  (let
    [trimmed : String (doc-test-trim text)]
    [n : i64 (string-length trimmed)]
    (if (= n 0)
      (DocTestNoI64 "expected integer")
      (let
        [i : i64 0]
        [sign : i64 1]
        [value : i64 0]
        [ok : bool true]
        (begin
          (if (= (string-ref trimmed 0) #-')
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
                (doc-test-decimal-digit-value (string-ref trimmed i))]
              (if (< digit 0)
                (set! ok false)
                (begin
                  (set! value (+ (* value 10) digit))
                  (set! i (+ i 1))))))
          (if ok
            (DocTestSomeI64 (* sign value))
            (DocTestNoI64 "expected integer")))))))

(define (doc-test-decode-output-literal [text : String]) : DocTestMaybeOutput
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [out : String ""]
    [message : String ""]
    (begin
      (while (and (= (string-length message) 0) (< i n))
        (let
          [c : char (string-ref text i)]
          (if (= c #\\')
            (if (>= (+ i 1) n)
              (set! message "trailing escape in doctest output metadata")
              (let
                [esc : char (string-ref text (+ i 1))]
                (cond
                  [(= esc #n')
                    (begin
                      (set! out (string-append out "\n"))
                      (set! i (+ i 2)))]
                  [(= esc #t')
                    (begin
                      (set! out (string-append out "\t"))
                      (set! i (+ i 2)))]
                  [(= esc #r')
                    (begin
                      (set! out (string-append out "\r"))
                      (set! i (+ i 2)))]
                  [(= esc #\\')
                    (begin
                      (set! out (string-append out "\\"))
                      (set! i (+ i 2)))]
                  [else
                    (set!
                      message
                      (doc-test-cat3
                        "unsupported doctest output escape `\\"
                        (substring text (+ i 1) 1)
                        "`"))])))
            (begin
              (set! out (string-append out (substring text i 1)))
              (set! i (+ i 1))))))
      (if (= (string-length message) 0)
        (DocTestSomeOutput out)
        (DocTestNoOutput message)))))

(define (doc-test-parse-output-spec [text : String]) : DocTestMaybeOutput
  (let
    [trimmed : String (doc-test-trim text)]
    (if (string-eq trimmed "-")
      (DocTestSomeOutput "")
      (if (doc-test-string-prefix? trimmed "literal:")
        (doc-test-decode-output-literal
          (substring trimmed 8 (- (string-length trimmed) 8)))
        (DocTestNoOutput
          "doctest output metadata must be '-' or 'literal:<escaped text>'")))))

(define (doc-test-string-blank? [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [blank : bool true]
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
  (let
    [n : i64 (string-length text)]
    [i : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (if (doc-test-space? (string-ref text i))
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
          (if (doc-test-newline? (string-ref src i))
            (set! keep false)
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (doc-test-next-line-start [src : String] [line-end : i64] [n : i64]) : i64
  (begin
    (unless (< line-end n) (return line-end))
    (let
      [c : char (string-ref src line-end)]
      (begin
        (unless (= c #\return') (return (+ line-end 1)))
        (unless (< (+ line-end 1) n) (return (+ line-end 1)))
        (if (= (string-ref src (+ line-end 1)) #\newline')
          (+ line-end 2)
          (+ line-end 1))))))

(define (doc-test-line-list-reverse-into
  [lines : DocTestLineList]
  [acc : DocTestLineList]) : DocTestLineList
  (match lines
    [(DocTestLineNil) acc]
    [(DocTestLineCons line rest)
      (doc-test-line-list-reverse-into
        (box-get rest)
        (doc-test-line-cons line acc))]))

(define (doc-test-line-list-reverse [lines : DocTestLineList]) : DocTestLineList
  (doc-test-line-list-reverse-into lines DocTestLineNil))

(define (doc-test-line-array-to-list-rev
  [lines : (Array DocTestLine)]
  [index : i64]
  [acc : DocTestLineList]) : DocTestLineList
  (if (< index 0)
    acc
    (doc-test-line-array-to-list-rev
      lines
      (- index 1)
      (DocTestLineCons (array-ref lines index) (box acc)))))

(define (doc-test-line-array-to-list [lines : (Array DocTestLine)]) : DocTestLineList
  (doc-test-line-array-to-list-rev
    lines
    (- (array-length lines) 1)
    DocTestLineNil))

(define (doc-test-example-list-append
  [examples : DocTestExampleList]
  [example : DocTestExample]) : DocTestExampleList
  (match examples
    [(DocTestExampleNil) (doc-test-example-cons example DocTestExampleNil)]
    [(DocTestExampleCons head rest)
      (doc-test-example-cons
        head
        (doc-test-example-list-append (box-get rest) example))]))

(define (doc-test-error-list-append
  [errors : DocTestErrorList]
  [err : DocTestError]) : DocTestErrorList
  (match errors
    [(DocTestErrorNil) (doc-test-error-cons err DocTestErrorNil)]
    [(DocTestErrorCons head rest)
      (doc-test-error-cons head (doc-test-error-list-append (box-get rest) err))]))

(define (doc-test-error-list-append-all
  [errors : DocTestErrorList]
  [more : DocTestErrorList]) : DocTestErrorList
  (match more
    [(DocTestErrorNil) errors]
    [(DocTestErrorCons err rest)
      (doc-test-error-list-append-all
        (doc-test-error-list-append errors err)
        (box-get rest))]))

(define (doc-test-example-list-count [examples : DocTestExampleList]) : i64
  (match examples
    [(DocTestExampleNil) 0]
    [(DocTestExampleCons _ rest)
      (+ 1 (doc-test-example-list-count (box-get rest)))]))

(define (doc-test-error-list-count [errors : DocTestErrorList]) : i64
  (match errors
    [(DocTestErrorNil) 0]
    [(DocTestErrorCons _ rest) (+ 1 (doc-test-error-list-count (box-get rest)))]))

(define (doc-test-doc-comment-body-with-prefix
  [line : String]
  [prefix : String]) : DocTestMaybeString
  (let
    [trimmed : String (doc-test-trim-left line)]
    (if (doc-test-string-prefix? trimmed prefix)
      (let
        [prefix-len : i64 (string-length prefix)]
        [trimmed-len : i64 (string-length trimmed)]
        [body : String
          (substring trimmed prefix-len (- trimmed-len prefix-len))]
        (if (> (string-length body) 0)
          (if (= (string-ref body 0) #\space')
            (DocTestSomeString (substring body 1 (- (string-length body) 1)))
            (DocTestSomeString body))
          (DocTestSomeString body)))
      (DocTestNoString))))

(define (doc-test-module-doc-comment-body [line : String]) : DocTestMaybeString
  (doc-test-doc-comment-body-with-prefix line ";#"))

(define (doc-test-item-doc-comment-body [line : String]) : DocTestMaybeString
  (doc-test-doc-comment-body-with-prefix line ";:"))

(define (doc-test-starts-with-form-head? [text : String] [head : String]) : bool
  (if (doc-test-string-prefix? text head)
    (let
      [head-len : i64 (string-length head)]
      [text-len : i64 (string-length text)]
      (if (= head-len text-len)
        true
        (let
          [c : char (string-ref text head-len)]
          (or (doc-test-space? c) (or (= c #(') (= c #)'))))))
    false))

(define (doc-test-supported-item-declaration? [line : String]) : bool
  (let
    [trimmed : String (doc-test-trim-left line)]
    (if (> (string-length trimmed) 0)
      (if (= (string-ref trimmed 0) #(')
        (let
          [rest : String
            (doc-test-trim-left
              (substring trimmed 1 (- (string-length trimmed) 1)))]
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
  [mode : DocTestFenceMode]) : DocTestFenceInfo
  (let
    [trimmed : String (doc-test-trim-left text)]
    (if (= (string-length trimmed) 0)
      (DocTestFenceTypeLisp mode)
      (let
        [end : i64 (doc-test-word-end trimmed 0)]
        [option : String (substring trimmed 0 end)]
        [rest : String (substring trimmed end (- (string-length trimmed) end))]
        (if (string-eq option "expect-error")
          (match mode
            [(DocTestFenceRun)
              (DocTestFenceMalformed
                (DocTestError
                  line-number
                  "TypeLisp doctest options `run` and `expect-error` cannot be combined"))]
            [(DocTestFenceCheck _)
              (doc-test-parse-fence-options
                rest
                line-number
                (DocTestFenceCheck (DocTestExpectError)))])
          (if (string-eq option "run")
            (match mode
              [(DocTestFenceRun)
                (doc-test-parse-fence-options rest line-number mode)]
              [(DocTestFenceCheck expectation)
                (if (doc-test-expectation-error? expectation)
                  (DocTestFenceMalformed
                    (DocTestError
                      line-number
                      "TypeLisp doctest options `run` and `expect-error` cannot be combined"))
                  (doc-test-parse-fence-options
                    rest
                    line-number
                    (DocTestFenceRun)))])
            (DocTestFenceMalformed
              (DocTestError
                line-number
                (doc-test-cat3
                  "unsupported TypeLisp doctest option `"
                  option
                  "`")))))))))

(define (doc-test-parse-fence-info [info : String] [line-number : i64]) : DocTestFenceInfo
  (let
    [trimmed : String (doc-test-trim-left info)]
    (if (= (string-length trimmed) 0)
      (DocTestFenceIgnore)
      (let
        [end : i64 (doc-test-word-end trimmed 0)]
        [language : String (substring trimmed 0 end)]
        [rest : String (substring trimmed end (- (string-length trimmed) end))]
        (if (or (string-eq language "typelisp") (string-eq language "tl"))
          (doc-test-parse-fence-options
            rest
            line-number
            (DocTestFenceCheck (DocTestExpectPass)))
          (DocTestFenceIgnore))))))

(define (doc-test-skip-ignored-fence [lines : DocTestLineList]) : DocTestLineList
  (match lines
    [(DocTestLineNil) DocTestLineNil]
    [(DocTestLineCons line rest)
      (if (doc-test-string-prefix?
        (doc-test-trim-left (doc-test-line-text line))
        "```")
        (box-get rest)
        (doc-test-skip-ignored-fence (box-get rest)))]))

(define (doc-test-collect-code-inner
  [lines : DocTestLineList]
  [code : String]
  [collected : DocTestLineList]) : DocTestCodeCollect
  (match lines
    [(DocTestLineNil)
      (DocTestCodeCollect
        DocTestLineNil
        code
        (doc-test-line-list-reverse collected)
        false)]
    [(DocTestLineCons line rest)
      (if (doc-test-string-prefix?
        (doc-test-trim-left (doc-test-line-text line))
        "```")
        (DocTestCodeCollect
          (box-get rest)
          code
          (doc-test-line-list-reverse collected)
          true)
        (doc-test-collect-code-inner
          (box-get rest)
          (string-append code (string-append (doc-test-line-text line) "\n"))
          (doc-test-line-cons line collected)))]))

(define (doc-test-collect-code [lines : DocTestLineList]) : DocTestCodeCollect
  (doc-test-collect-code-inner lines "" DocTestLineNil))

(define (doc-test-metadata-value [line : DocTestLine] [prefix : String]) : DocTestMaybeString
  (let
    [trimmed : String (doc-test-trim-left (doc-test-line-text line))]
    (if (doc-test-string-prefix? trimmed prefix)
      (DocTestSomeString
        (doc-test-trim
          (substring
            trimmed
            (string-length prefix)
            (- (string-length trimmed) (string-length prefix)))))
      (DocTestNoString))))

(define (doc-test-metadata-line? [line : DocTestLine]) : bool
  (doc-test-string-prefix?
    (doc-test-trim-left (doc-test-line-text line))
    ";; doctest-"))

(define (doc-test-run-metadata-append-error
  [metadata : DocTestRunMetadata]
  [err : DocTestError]) : DocTestRunMetadata
  (match metadata
    [(DocTestRunMetadata
        has-exit
        expected-exit
        has-stdout
        expected-stdout
        has-stderr
        expected-stderr
        errors)
      (DocTestRunMetadata
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
    [(DocTestRunMetadata
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
          (DocTestError
            (doc-test-line-number line)
            "duplicate doctest-exit metadata"))
        (match (doc-test-parse-i64 text)
          [(DocTestSomeI64 parsed)
            (DocTestRunMetadata
              true
              parsed
              has-stdout
              expected-stdout
              has-stderr
              expected-stderr
              errors)]
          [(DocTestNoI64 _)
            (doc-test-run-metadata-append-error
              (DocTestRunMetadata
                true
                expected-exit
                has-stdout
                expected-stdout
                has-stderr
                expected-stderr
                errors)
              (DocTestError
                (doc-test-line-number line)
                "doctest-exit metadata must be an integer"))]))]))

(define (doc-test-run-metadata-set-stdout
  [metadata : DocTestRunMetadata]
  [line : DocTestLine]
  [text : String]) : DocTestRunMetadata
  (match metadata
    [(DocTestRunMetadata
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
          (DocTestError
            (doc-test-line-number line)
            "duplicate doctest-stdout metadata"))
        (match (doc-test-parse-output-spec text)
          [(DocTestSomeOutput parsed)
            (DocTestRunMetadata
              has-exit
              expected-exit
              true
              parsed
              has-stderr
              expected-stderr
              errors)]
          [(DocTestNoOutput message)
            (doc-test-run-metadata-append-error
              metadata
              (DocTestError (doc-test-line-number line) message))]))]))

(define (doc-test-run-metadata-set-stderr
  [metadata : DocTestRunMetadata]
  [line : DocTestLine]
  [text : String]) : DocTestRunMetadata
  (match metadata
    [(DocTestRunMetadata
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
          (DocTestError
            (doc-test-line-number line)
            "duplicate doctest-stderr metadata"))
        (match (doc-test-parse-output-spec text)
          [(DocTestSomeOutput parsed)
            (DocTestRunMetadata
              has-exit
              expected-exit
              has-stdout
              expected-stdout
              true
              parsed
              errors)]
          [(DocTestNoOutput message)
            (doc-test-run-metadata-append-error
              metadata
              (DocTestError (doc-test-line-number line) message))]))]))

(define (doc-test-run-metadata-parse-line
  [metadata : DocTestRunMetadata]
  [line : DocTestLine]) : DocTestRunMetadata
  (match (doc-test-metadata-value line ";; doctest-exit:")
    [(DocTestSomeString value)
      (doc-test-run-metadata-set-exit metadata line value)]
    [(DocTestNoString)
      (match (doc-test-metadata-value line ";; doctest-stdout:")
        [(DocTestSomeString value)
          (doc-test-run-metadata-set-stdout metadata line value)]
        [(DocTestNoString)
          (match (doc-test-metadata-value line ";; doctest-stderr:")
            [(DocTestSomeString value)
              (doc-test-run-metadata-set-stderr metadata line value)]
            [(DocTestNoString)
              (if (doc-test-metadata-line? line)
                (doc-test-run-metadata-append-error
                  metadata
                  (DocTestError
                    (doc-test-line-number line)
                    "unsupported runnable doctest metadata"))
                metadata)])])]))

(define (doc-test-run-metadata-parse-lines
  [lines : DocTestLineList]
  [metadata : DocTestRunMetadata]) : DocTestRunMetadata
  (match lines
    [(DocTestLineNil) metadata]
    [(DocTestLineCons line rest)
      (doc-test-run-metadata-parse-lines
        (box-get rest)
        (doc-test-run-metadata-parse-line metadata line))]))

(define (doc-test-parse-run-metadata
  [source-line : i64]
  [lines : DocTestLineList]) : DocTestRunMetadataParse
  (match (doc-test-run-metadata-parse-lines
    lines
    (DocTestRunMetadata false 0 false "" false "" DocTestErrorNil))
    [(DocTestRunMetadata
        has-exit
        expected-exit
        _
        expected-stdout
        _
        expected-stderr
        errors)
      (let
        [all-errors : DocTestErrorList
          (if has-exit
            errors
            (doc-test-error-list-append
              errors
              (DocTestError
                source-line
                "runnable TypeLisp doctest requires doctest-exit metadata")))]
        (match all-errors
          [(DocTestErrorNil)
            (DocTestRunMetadataOk
              (DocTestExpectRun expected-exit expected-stdout expected-stderr))]
          [_ (DocTestRunMetadataErr all-errors)]))]))

(define (doc-test-scan-type-lisp-fence
  [rest : DocTestLineList]
  [state : DocTestScanState]
  [source-line : i64]
  [mode : DocTestFenceMode]) : DocTestScanState
  (match (doc-test-collect-code rest)
    [(DocTestCodeCollect remaining code code-lines closed)
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
                (match mode
                  [(DocTestFenceCheck expectation)
                    (DocTestScanState
                      (doc-test-example-list-append
                        examples
                        (DocTestExample next-index source-line expectation code))
                      errors
                      (+ next-index 1))]
                  [(DocTestFenceRun)
                    (match (doc-test-parse-run-metadata source-line code-lines)
                      [(DocTestRunMetadataOk expectation)
                        (DocTestScanState
                          (doc-test-example-list-append
                            examples
                            (DocTestExample
                              next-index
                              source-line
                              expectation
                              code))
                          errors
                          (+ next-index 1))]
                      [(DocTestRunMetadataErr metadata-errors)
                        (DocTestScanState
                          examples
                          (doc-test-error-list-append-all
                            errors
                            metadata-errors)
                          next-index)])])))
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
      (let
        [trimmed : String (doc-test-trim-left (doc-test-line-text line))]
        (if (doc-test-string-prefix? trimmed "```")
          (let
            [info : String (substring trimmed 3 (- (string-length trimmed) 3))]
            (match (doc-test-parse-fence-info info (doc-test-line-number line))
              [(DocTestFenceIgnore)
                (doc-test-scan-doc-block
                  (doc-test-skip-ignored-fence (box-get rest))
                  state)]
              [(DocTestFenceMalformed err)
                (match state
                  [(DocTestScanState examples errors next-index)
                    (doc-test-scan-doc-block
                      (doc-test-skip-ignored-fence (box-get rest))
                      (DocTestScanState
                        examples
                        (doc-test-error-list-append errors err)
                        next-index))])]
              [(DocTestFenceTypeLisp expectation)
                (doc-test-scan-type-lisp-fence
                  (box-get rest)
                  state
                  (doc-test-line-number line)
                  expectation)]))
          (doc-test-scan-doc-block (box-get rest) state)))]))

(define (doc-test-scan-reversed-block
  [lines : DocTestLineList]
  [state : DocTestScanState]) : DocTestScanState
  (doc-test-scan-doc-block (doc-test-line-list-reverse lines) state))

(define (doc-test-scan-line-array
  [lines : (Array DocTestLine)]
  [state : DocTestScanState]) : DocTestScanState
  (doc-test-scan-doc-block (doc-test-line-array-to-list lines) state))

(define (doc-test-extract-source [src : String]) : DocTestExtraction
  (let
    [n : i64 (string-length src)]
    [pos : i64 0]
    [line-number : i64 1]
    [module-lines : (Array DocTestLine) (make-array DocTestLine 0)]
    [pending-lines : (Array DocTestLine) (make-array DocTestLine 0)]
    [state : DocTestScanState
      (DocTestScanState DocTestExampleNil DocTestErrorNil 1)]
    (begin
      (while (< pos n)
        (let
          [line-end : i64 (doc-test-line-end src pos n)]
          [line : String (substring src pos (- line-end pos))]
          (begin
            (match (doc-test-module-doc-comment-body line)
              [(DocTestSomeString body)
                (begin
                  (set! pending-lines (make-array DocTestLine 0))
                  (array-push! module-lines (DocTestLine line-number body)))]
              [(DocTestNoString)
                (if (doc-test-string-blank? line)
                  unit
                  (begin
                    (set! state (doc-test-scan-line-array module-lines state))
                    (set! module-lines (make-array DocTestLine 0))
                    (match (doc-test-item-doc-comment-body line)
                      [(DocTestSomeString body)
                        (array-push!
                          pending-lines
                          (DocTestLine line-number body))]
                      [(DocTestNoString)
                        (if (doc-test-supported-item-declaration? line)
                          (begin
                            (set!
                              state
                              (doc-test-scan-line-array pending-lines state))
                            (set! pending-lines (make-array DocTestLine 0)))
                          (set! pending-lines (make-array DocTestLine 0)))])))])
            (set! pos (doc-test-next-line-start src line-end n))
            (set! line-number (+ line-number 1)))))
      (set! state (doc-test-scan-line-array module-lines state))
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
  (DocTestRunFailureCons DocTestRunFailure (Box DocTestRunFailureList)))

(define (doc-test-run-failure-cons
  [failure : DocTestRunFailure]
  [rest : DocTestRunFailureList]) : DocTestRunFailureList
  (DocTestRunFailureCons failure (box rest)))

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
      (+ 1 (doc-test-run-failure-list-count (box-get rest)))]))

(define (doc-test-run-report-ok? [report : DocTestRunReport]) : bool
  (match (doc-test-run-report-failures report)
    [(DocTestRunFailureNil) true]
    [(DocTestRunFailureCons _ _) false]))

(define (doc-test-run-failure-list-append
  [failures : DocTestRunFailureList]
  [failure : DocTestRunFailure]) : DocTestRunFailureList
  (match failures
    [(DocTestRunFailureNil)
      (doc-test-run-failure-cons failure DocTestRunFailureNil)]
    [(DocTestRunFailureCons head rest)
      (doc-test-run-failure-cons
        head
        (doc-test-run-failure-list-append (box-get rest) failure))]))

;; Render a failure as `path:line: message`. Fence-level extraction
;; errors use index `-1`; example failures include the example number in their
;; message so the public CLI text matches the stage0 Rust runner.
(define (doc-test-run-failure-render [failure : DocTestRunFailure]) : String
  (match failure
    [(DocTestRunFailure path line index message)
      (let
        [location : String
          (string-append
            path
            (string-append ":" (string-append (int->string line) ": ")))]
        (string-append location message))]))

(define (doc-test-unexpected-pass-message [index : i64]) : String
  (string-append
    "doctest example "
    (string-append (int->string index) " was expected to fail but passed")))

(define (doc-test-diagnostic-code [diag : CompilerDiagnostic]) : String
  (let
    [message : String (compiler-diagnostic-message diag)]
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

;; Runnable doctests spawn nested build/run commands from a generated test
;; binary. This is a required gate on both Linux and Windows because skipped
;; runnable doctests can hide target-specific compiler/runtime bugs.
(define (doc-test-runnable-target-supported? [target : CompilerBackendTarget]) : bool
  (match target
    [(BackendTargetLinux) true]
    [(BackendTargetWindows) true]))

(define (doc-test-runnable-supported?) : bool
  (doc-test-runnable-target-supported? (source-tool-default-target)))

(define (doc-test-runnable-unsupported-message
  [index : i64]
  [target : CompilerBackendTarget]) : String
  (string-append
    "doctest example "
    (string-append
      (int->string index)
      (string-append
        " is a runnable doctest, but runnable doctests are unsupported on target "
        (source-tool-target-name target)))))

(define (doc-test-runnable-compile-message [index : i64] [message : String]) : String
  (string-append
    "doctest example "
    (string-append
      (int->string index)
      (string-append " runnable compile failed\n" message))))

(define (doc-test-runnable-build-message [index : i64] [message : String]) : String
  (string-append
    "doctest example "
    (string-append
      (int->string index)
      (string-append " runnable build failed\n" message))))

(define (doc-test-runnable-exec-message [index : i64] [message : String]) : String
  (string-append
    "doctest example "
    (string-append
      (int->string index)
      (string-append " runnable execution failed: " message))))

(define (doc-test-output-comparison-message
  [name : String]
  [expected : String]
  [actual : String]) : String
  (string-append
    "expected "
    (string-append
      name
      (string-append
        ":\n"
        (string-append
          expected
          (string-append
            "\nactual "
            (string-append name (string-append ":\n" actual))))))))

(define (doc-test-normalize-windows-crlf [text : String]) : String
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (if (and
          (= (string-ref text i) #\return')
          (and (< (+ i 1) n) (= (string-ref text (+ i 1)) #\newline')))
          (begin
            (set! out (string-append out "\n"))
            (set! i (+ i 2)))
          (begin
            (set! out (string-append out (substring text i 1)))
            (set! i (+ i 1)))))
      out)))

(define (doc-test-normalize-output-for-target
  [target : CompilerBackendTarget]
  [text : String]) : String
  (match target
    [(BackendTargetLinux) text]
    [(BackendTargetWindows) (doc-test-normalize-windows-crlf text)]))

(define (doc-test-runnable-mismatch-message
  [index : i64]
  [expectation : DocTestExpectation]
  [target : CompilerBackendTarget]
  [output : ProcessOutput]) : String
  (let
    [expected-exit : i64 (doc-test-expectation-run-exit expectation)]
    [expected-stdout : String (doc-test-expectation-run-stdout expectation)]
    [expected-stderr : String (doc-test-expectation-run-stderr expectation)]
    [actual-exit : i64 (process-output-status output)]
    [actual-stdout : String
      (doc-test-normalize-output-for-target
        target
        (process-output-stdout output))]
    [actual-stderr : String
      (doc-test-normalize-output-for-target
        target
        (process-output-stderr output))]
    (string-append
      "doctest example "
      (string-append
        (int->string index)
        (string-append
          " runnable output mismatch\nexpected exit: "
          (string-append
            (int->string expected-exit)
            (string-append
              "\nactual exit: "
              (string-append
                (int->string actual-exit)
                (string-append
                  "\n"
                  (string-append
                    (doc-test-output-comparison-message
                      "stdout"
                      expected-stdout
                      actual-stdout)
                    (string-append
                      "\n"
                      (doc-test-output-comparison-message
                        "stderr"
                        expected-stderr
                        actual-stderr))))))))))))

(define (doc-test-runnable-output-matches?
  [expectation : DocTestExpectation]
  [target : CompilerBackendTarget]
  [output : ProcessOutput]) : bool
  (if (=
    (doc-test-expectation-run-exit expectation)
    (process-output-status output))
    (if (string-eq
      (doc-test-expectation-run-stdout expectation)
      (doc-test-normalize-output-for-target
        target
        (process-output-stdout output)))
      (string-eq
        (doc-test-expectation-run-stderr expectation)
        (doc-test-normalize-output-for-target
          target
          (process-output-stderr output)))
      false)
    false))

(define (doc-test-command-output-message
  [role : String]
  [target : CompilerBackendTarget]
  [command : ProcessCommand]
  [output : ProcessOutput]) : String
  (string-append
    "Error: "
    (string-append
      role
      (string-append
        " '"
        (string-append
          (process-command-executable command)
          (string-append
            "' failed for target "
            (string-append
              (source-tool-target-name target)
              (string-append
                " with status "
                (string-append
                  (int->string (process-output-status output))
                  (string-append
                    "\nstdout:\n"
                    (string-append
                      (process-output-stdout output)
                      (string-append
                        "\nstderr:\n"
                        (process-output-stderr output)))))))))))))

(define (doc-test-run-command-captured
  [role : String]
  [target : CompilerBackendTarget]
  [command : ProcessCommand]) : SourceToolCommandStatus
  (match (process-output command)
    [(OkProcessOutput output)
      (if (process-success? output)
        SourceToolCommandOk
        (SourceToolCommandErr
          (doc-test-command-output-message role target command output)))]
    [(ErrProcessOutput error)
      (SourceToolCommandErr
        (string-append
          "Error: failed to run "
          (string-append
            role
            (string-append
              " '"
              (string-append
                (process-command-executable command)
                (string-append
                  "' for target "
                  (string-append
                    (source-tool-target-name target)
                    (string-append ": " (process-error-message error)))))))))]))

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
  [stdlib-roots : StringVec]
  [target : CompilerBackendTarget]) : ResultSourceToolString
  (let
    [index : i64 (doc-test-example-index example)]
    [virtual-path : String (doc-test-example-virtual-path path index)]
    [code : String (doc-test-example-code example)]
    (match (compiler-load-source-with-paths-and-roots-cfg
      virtual-path
      code
      (sym-i64-empty)
      stdlib-roots
      (compiler-driver-target-cfgs target (compiler-cfg-empty)))
      [(OkCompilerLoadWithPaths decls paths _ _)
        (match (lower-compiler-program-with-decl-paths
          virtual-path
          (ast-program decls)
          paths)
          [(OkCompilerLower program spans)
            (match (compiler-driver-emit-lowered-with-level
              virtual-path
              program
              spans
              target
              true
              (compiler-optimize-default-level))
              [(OkCompilerDriver asm)
                (OkSourceToolString
                  (source-tool-augment-assembly-for-target asm target))]
              [(ErrCompilerDriver diag)
                (ErrSourceToolString (compiler-diagnostic-render diag))])]
          [(ErrCompilerLower diag)
            (ErrSourceToolString (compiler-diagnostic-render diag))])]
      [(ErrCompilerLoadWithPaths diag)
        (ErrSourceToolString (compiler-diagnostic-render diag))])))

(define (doc-test-runnable-failure
  [path : String]
  [source-line : i64]
  [index : i64]
  [message : String]) : DocTestMaybeFailure
  (DocTestSomeFailure (DocTestRunFailure path source-line index message)))

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
  (match (source-tool-run-executable bin-path target (process-args-empty))
    [(OkProcessOutput output)
      (begin
        (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
        (if (doc-test-runnable-output-matches? expectation target output)
          (DocTestNoFailure)
          (doc-test-runnable-failure
            path
            source-line
            index
            (doc-test-runnable-mismatch-message index expectation target output))))]
    [(ErrProcessOutput error)
      (begin
        (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
        (doc-test-runnable-failure
          path
          source-line
          index
          (doc-test-runnable-exec-message index (process-error-message error))))]))

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
    [(SourceToolCommandErr message)
      (begin
        (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
        (doc-test-runnable-failure
          path
          source-line
          index
          (doc-test-runnable-build-message index message)))]
    [(SourceToolCommandOk)
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
    [(SourceToolCommandErr message)
      (begin
        (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
        (doc-test-runnable-failure
          path
          source-line
          index
          (doc-test-runnable-build-message index message)))]
    [(SourceToolCommandOk)
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
  [stdlib-roots : StringVec]
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
      [(ErrSourceToolString message)
        (begin
          (source-tool-clean-temp temp-dir asm-path obj-path bin-path true)
          (doc-test-runnable-failure
            path
            source-line
            index
            (doc-test-runnable-compile-message index message)))]
      [(OkSourceToolString asm)
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
  [stdlib-roots : StringVec]) : DocTestMaybeFailure
  (let
    [index : i64 (doc-test-example-index example)]
    [source-line : i64 (doc-test-example-source-line example)]
    [target : CompilerBackendTarget (source-tool-default-target)]
    (if (doc-test-runnable-target-supported? target)
      (match (source-tool-create-temp-dir "typelisp-doctest")
        [(OkSourceToolString temp-dir)
          (doc-test-run-runnable-output
            path
            example
            stdlib-roots
            target
            temp-dir)]
        [(ErrSourceToolString message)
          (DocTestSomeFailure
            (DocTestRunFailure
              path
              source-line
              index
              (doc-test-runnable-build-message
                index
                (string-append "doctest: failed to create temp dir: " message))))])
      (DocTestSomeFailure
        (DocTestRunFailure
          path
          source-line
          index
          (doc-test-runnable-unsupported-message index target))))))

;; Check one extracted example through the virtual-source typechecker, comparing
;; the outcome against its expectation. Imports inside the example resolve
;; relative to a sibling of `path` (the doc'd source file), so examples may
;; import the doc'd file without colliding with the virtual source root.
(define (doc-test-example-virtual-path [path : String] [index : i64]) : String
  (string-append path (string-append ".doctest." (int->string index))))

(define (doc-test-check-example [path : String] [example : DocTestExample]) : DocTestMaybeFailure
  (doc-test-check-example-with-roots path example (string-vec-new)))

(define (doc-test-check-example-with-roots
  [path : String]
  [example : DocTestExample]
  [stdlib-roots : StringVec]) : DocTestMaybeFailure
  (let
    [index : i64 (doc-test-example-index example)]
    [source-line : i64 (doc-test-example-source-line example)]
    [expectation : DocTestExpectation (doc-test-example-expectation example)]
    [expect-error : bool (doc-test-expectation-error? expectation)]
    [code : String (doc-test-example-code example)]
    (if (doc-test-expectation-run? expectation)
      (doc-test-run-runnable-example-with-roots path example stdlib-roots)
      (match (compiler-check-source-with-roots
        (doc-test-example-virtual-path path index)
        code
        stdlib-roots)
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
                (doc-test-unexpected-error-message index diag))))]))))

(define (doc-test-run-examples
  [path : String]
  [examples : DocTestExampleList]
  [failures : DocTestRunFailureList]) : DocTestRunFailureList
  (doc-test-run-examples-with-roots path examples failures (string-vec-new)))

(define (doc-test-run-examples-with-roots
  [path : String]
  [examples : DocTestExampleList]
  [failures : DocTestRunFailureList]
  [stdlib-roots : StringVec]) : DocTestRunFailureList
  (match examples
    [(DocTestExampleNil) failures]
    [(DocTestExampleCons example rest)
      (match (doc-test-check-example-with-roots path example stdlib-roots)
        [(DocTestNoFailure)
          (doc-test-run-examples-with-roots
            path
            (box-get rest)
            failures
            stdlib-roots)]
        [(DocTestSomeFailure failure)
          (doc-test-run-examples-with-roots
            path
            (box-get rest)
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
        (box-get rest)
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
  (doc-test-run-source-with-roots path source (string-vec-new)))

(define (doc-test-run-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : StringVec]) : DocTestRunReport
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
  [stdlib-roots : StringVec]) : DocTestRunReport
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
        (doc-test-run-failures-render (box-get rest)))]))

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
  (string-append
    ";# Runnable docs\n"
    (string-append
      ";# ```typelisp run\n"
      (string-append
        ";# ;; doctest-exit: 0\n"
        (string-append
          ";# ;; doctest-stdout: literal:hello\\n\n"
          (string-append
            ";# ;; doctest-stderr: literal:error\\tline\\r\n"
            (string-append
              ";# (import \"stdlib/io.tl\")\n"
              (string-append
                ";# (define (main) : i64\n"
                (string-append
                  ";#   (begin\n"
                  (string-append
                    ";#     (let [text : String \"hello\\n\"] (stdout-write (& text)))\n"
                    (string-append
                      ";#     (let [text : String \"error\\tline\\r\"] (stderr-write (& text)))\n"
                      (string-append
                        ";#     0))\n"
                        (string-append
                          ";# ```\n"
                          (string-append
                            ";# ```tl run\n"
                            (string-append
                              ";# ;; doctest-exit: 42\n"
                              (string-append
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
      [(DocTestExpectRun actual-exit actual-stdout actual-stderr)
        (begin
          (unless (= actual-exit expected-exit) (return false))
          (unless (string-eq actual-stdout expected-stdout) (return false))
          (unless (string-eq actual-stderr expected-stderr) (return false))
          (doc-test-string-contains?
            (doc-test-example-code example)
            code-fragment))]
      [_ false])))

(define (doc-test-error-list-has?
  [errors : DocTestErrorList]
  [line : i64]
  [message-fragment : String]) : bool
  (match errors
    [(DocTestErrorNil) false]
    [(DocTestErrorCons err rest)
      (if (= (doc-test-error-line err) line)
        (if (doc-test-string-contains?
          (doc-test-error-message err)
          message-fragment)
          true
          (doc-test-error-list-has? (box-get rest) line message-fragment))
        (doc-test-error-list-has? (box-get rest) line message-fragment))]))

(define (doc-test-smoke-examples-ok? [examples : DocTestExampleList]) : bool
  (match examples
    [(DocTestExampleCons first rest-first)
      (match (box-get rest-first)
        [(DocTestExampleCons second rest-second)
          (match (box-get rest-second)
            [(DocTestExampleNil)
              (if (doc-test-example-ok? first 1 2 false "(define (main)")
                (doc-test-example-ok? second 2 9 true "(define (bad)")
                false)]
            [_ false])]
        [_ false])]
    [_ false]))

(define (doc-test-malformed-errors-ok? [errors : DocTestErrorList]) : bool
  (match errors
    [(DocTestErrorCons first rest-first)
      (match (box-get rest-first)
        [(DocTestErrorCons second rest-second)
          (match (box-get rest-second)
            [(DocTestErrorCons third rest-third)
              (match (box-get rest-third)
                [(DocTestErrorNil)
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
                      "unterminated TypeLisp doctest fence"))]
                [_ false])]
            [_ false])]
        [_ false])]
    [_ false]))

(define (doc-test-ordinary-comments-ok?) : bool
  (match (doc-test-extract-source (doc-test-ordinary-comment-source))
    [(DocTestExtraction ordinary-examples ordinary-errors)
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
    [(DocTestExtraction examples errors)
      (begin
        (unless (= (doc-test-error-list-count errors) 0) (return false))
        (unless (= (doc-test-example-list-count examples) 1) (return false))
        (match examples
          [(DocTestExampleCons example rest)
            (match (box-get rest)
              [(DocTestExampleNil)
                (doc-test-string-contains?
                  (doc-test-example-code example)
                  "(define legacy")]
              [_ false])]
          [_ false]))]))

(define (doc-test-malformed-smoke-ok?) : bool
  (match (doc-test-extract-source (doc-test-malformed-source))
    [(DocTestExtraction malformed-examples malformed-errors)
      (if (= (doc-test-example-list-count malformed-examples) 0)
        (if (= (doc-test-error-list-count malformed-errors) 3)
          (doc-test-malformed-errors-ok? malformed-errors)
          false)
        false)]))

(define (doc-test-runnable-smoke-ok?) : bool
  (match (doc-test-extract-source (doc-test-runnable-source))
    [(DocTestExtraction examples errors)
      (begin
        (unless (= (doc-test-error-list-count errors) 0) (return false))
        (unless (= (doc-test-example-list-count examples) 2) (return false))
        (match examples
          [(DocTestExampleCons first rest-first)
            (match (box-get rest-first)
              [(DocTestExampleCons second rest-second)
                (match (box-get rest-second)
                  [(DocTestExampleNil)
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
                        "(define (main)"))]
                  [_ false])]
              [_ false])]
          [_ false]))]))

(define (doc-test-runnable-malformed-smoke-ok?) : bool
  (match (doc-test-extract-source (doc-test-runnable-malformed-source))
    [(DocTestExtraction examples errors)
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
    [(DocTestExtraction examples errors)
      (begin
        (unless
          (= (doc-test-error-list-count errors) 0)
          (return
            (begin
              (panic "doc-test: unexpected extraction error")
              0)))
        (unless
          (= (doc-test-example-list-count examples) 2)
          (return
            (begin
              (panic "doc-test: example count mismatch")
              0)))
        (unless
          (doc-test-smoke-examples-ok? examples)
          (return
            (begin
              (panic "doc-test: example metadata mismatch")
              0)))
        (unless
          (doc-test-ordinary-comments-ok?)
          (return
            (begin
              (panic "doc-test: ordinary comment smoke mismatch")
              0)))
        (unless
          (doc-test-legacy-item-smoke-ok?)
          (return
            (begin
              (panic "doc-test: legacy item smoke mismatch")
              0)))
        (unless
          (doc-test-malformed-smoke-ok?)
          (return
            (begin
              (panic "doc-test: malformed smoke mismatch")
              0)))
        (unless
          (doc-test-runnable-smoke-ok?)
          (return
            (begin
              (panic "doc-test: runnable smoke mismatch")
              0)))
        (unless
          (doc-test-runnable-malformed-smoke-ok?)
          (return
            (begin
              (panic "doc-test: runnable malformed smoke mismatch")
              0)))
        42)]))

;; --- runner self-test (#724) ------------------------------------------------
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

(define (doc-test-run-smoke-stdlib-roots) : StringVec
  (string-vec-push (string-vec-new) "stdlib"))

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
;# (import \"stdlib/io.tl\")
;# (define (main) : i64
;#   (begin
;#     (let [text : String \"actual\\n\"] (stdout-write (& text)))
;#     0))
;# ```
")

(define (doc-test-run-runnable-stderr-mismatch-source) : String
  ";# ```typelisp run
;# ;; doctest-exit: 0
;# ;; doctest-stderr: literal:expected-error\\n
;# (import \"stdlib/io.tl\")
;# (define (main) : i64
;#   (begin
;#     (let [text : String \"actual-error\\n\"] (stderr-write (& text)))
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
    (match (doc-test-run-report-failures report)
      [(DocTestRunFailureCons failure rest)
        (match (box-get rest)
          [(DocTestRunFailureNil)
            (begin
              (unless (= (doc-test-run-failure-index failure) 1) (return false))
              (unless (= (doc-test-run-failure-line failure) 1) (return false))
              (unless
                (string-eq (doc-test-run-failure-path failure) "docs/bad.tl")
                (return false))
              (doc-test-string-contains?
                (doc-test-run-failure-message failure)
                "return type mismatch"))]
          [_ false])]
      [_ false])))

;; An `expect-error` example that checks successfully is a failure.
(define (doc-test-run-smoke-unexpected-pass-ok?) : bool
  (let
    [report : DocTestRunReport
      (doc-test-run-source "docs/bad.tl" (doc-test-run-unexpected-pass-source))]
    (match (doc-test-run-report-failures report)
      [(DocTestRunFailureCons failure rest)
        (match (box-get rest)
          [(DocTestRunFailureNil)
            (doc-test-string-contains?
              (doc-test-run-failure-message failure)
              "was expected to fail")]
          [_ false])]
      [_ false])))

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
    (if (= (doc-test-run-report-count report) 2)
      (match (doc-test-run-report-failures report)
        [(DocTestRunFailureCons first rest-first)
          (match (box-get rest-first)
            [(DocTestRunFailureCons second rest-second)
              (match (box-get rest-second)
                [(DocTestRunFailureNil)
                  (if (doc-test-string-contains?
                    (doc-test-run-failure-message first)
                    "unsupported")
                    (doc-test-string-contains?
                      (doc-test-run-failure-message second)
                      "unsupported")
                    false)]
                [_ false])]
            [_ false])]
        [_ false])
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
    (if (= (doc-test-run-report-count report) 1)
      (match (doc-test-run-report-failures report)
        [(DocTestRunFailureCons failure rest)
          (match (box-get rest)
            [(DocTestRunFailureNil)
              (doc-test-string-contains?
                (doc-test-run-failure-message failure)
                fragment)]
            [_ false])]
        [_ false])
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
        (DocTestRunFailure
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
        (string-eq
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

(define (doc-test-run-smoke) : i64
  (begin
    (unless
      (doc-test-run-smoke-pass-ok?)
      (return
        (begin
          (panic "doc-test-run: pass-case mismatch")
          0)))
    (unless
      (doc-test-run-smoke-unexpected-error-ok?)
      (return
        (begin
          (panic "doc-test-run: unexpected-error mismatch")
          0)))
    (unless
      (doc-test-run-smoke-unexpected-pass-ok?)
      (return
        (begin
          (panic "doc-test-run: unexpected-pass mismatch")
          0)))
    (unless
      (doc-test-run-smoke-malformed-ok?)
      (return
        (begin
          (panic "doc-test-run: malformed mismatch")
          0)))
    (unless
      (doc-test-run-smoke-empty-ok?)
      (return
        (begin
          (panic "doc-test-run: empty-source mismatch")
          0)))
    (unless
      (doc-test-run-smoke-runnable-ok?)
      (return
        (begin
          (panic "doc-test-run: runnable execution mismatch")
          0)))
    (unless
      (doc-test-run-smoke-render-ok?)
      (return
        (begin
          (panic "doc-test-run: render mismatch")
          0)))
    (unless
      (doc-test-run-smoke-report-render-ok?)
      (return
        (begin
          (panic "doc-test-run: report render mismatch")
          0)))
    42))

;; Combined smoke: extraction (#722) then runner (#724). Returns 42 iff both
;; self-test batteries pass.
(define (doc-test-smoke-all) : i64
  (if (= (doc-test-smoke) 42)
    (if (source-tool-link-inputs-dedupe-smoke-ok?)
      (doc-test-run-smoke)
      (begin
        (panic "source-tool: link input dedupe smoke regressed")
        0))
    (begin
      (panic "doc-test: extraction smoke regressed")
      0)))