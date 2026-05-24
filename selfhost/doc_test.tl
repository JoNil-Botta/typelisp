;; doc_test.tl - Self-hosted TypeLisp doctest extraction layer (#722).

;;

;; This module only extracts TypeLisp fenced examples from public doc comments.

;; It mirrors the Rust doctest runner's source scanning policy: module docs

;; (`;;;;`) are scanned as standalone doc blocks, item docs (`;;;`) attach only

;; to the next supported top-level declaration, ordinary comments are ignored,

;; and unattached item docs are dropped.

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