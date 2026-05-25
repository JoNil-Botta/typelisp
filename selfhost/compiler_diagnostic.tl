;; compiler_diagnostic.tl - Shared selfhost compiler diagnostic payloads.
(import "token.tl")

(import "compiler_ast_types.tl")

(defstruct CompilerDiagnostic
  (path String)
  (line i64)
  (col i64)
  (message String))

(defenum CompilerDiagnosticLevel
  (CompilerDiagnosticError)
  (CompilerDiagnosticWarning)
  (CompilerDiagnosticNote))

(defenum CompilerDiagnosticMaybeString
  (CompilerDiagnosticNoString)
  (CompilerDiagnosticSomeString String))

(define (compiler-diagnostic-cat3
  [left : String]
  [middle : String]
  [right : String]) : String
  (string-append left (string-append middle right)))

(define (compiler-diagnostic-path [diag : CompilerDiagnostic]) : String
  (struct-get diag path))

(define (compiler-diagnostic-line [diag : CompilerDiagnostic]) : i64
  (struct-get diag line))

(define (compiler-diagnostic-col [diag : CompilerDiagnostic]) : i64
  (struct-get diag col))

(define (compiler-diagnostic-message [diag : CompilerDiagnostic]) : String
  (struct-get diag message))

(define (compiler-diagnostic-from-span
  [path : String]
  [span : SourceSpan]
  [message : String]) : CompilerDiagnostic
  (CompilerDiagnostic path (span-start-line span) (span-start-col span) message))

(define (compiler-diagnostic-from-ast-span
  [path : String]
  [span : AstSourceSpan]
  [message : String]) : CompilerDiagnostic
  (CompilerDiagnostic
    path
    (struct-get span start-line)
    (struct-get span start-col)
    message))

(define (compiler-diagnostic-from-source-error
  [path : String]
  [err : SourceError]) : CompilerDiagnostic
  (compiler-diagnostic-from-span
    path
    (source-error-span err)
    (source-error-message err)))

(define (compiler-diagnostic-at-start [path : String] [message : String]) : CompilerDiagnostic
  (CompilerDiagnostic path 1 1 message))

(define (compiler-diagnostic-with-path
  [diag : CompilerDiagnostic]
  [path : String]) : CompilerDiagnostic
  (CompilerDiagnostic
    path
    (compiler-diagnostic-line diag)
    (compiler-diagnostic-col diag)
    (compiler-diagnostic-message diag)))

;; Reuse a diagnostic's location (path/line/col) with a new message. Used by the
;;
;; backend to stamp an error message onto a function's source span (#605).
(define (compiler-diagnostic-with-message
  [diag : CompilerDiagnostic]
  [message : String]) : CompilerDiagnostic
  (CompilerDiagnostic
    (compiler-diagnostic-path diag)
    (compiler-diagnostic-line diag)
    (compiler-diagnostic-col diag)
    message))

(define (compiler-diagnostic-render [diag : CompilerDiagnostic]) : String
  (string-append
    (compiler-diagnostic-path diag)
    (string-append
      ":"
      (string-append
        (int->string (compiler-diagnostic-line diag))
        (string-append
          ":"
          (string-append
            (int->string (compiler-diagnostic-col diag))
            (string-append ": " (compiler-diagnostic-message diag))))))))

(define (compiler-diagnostic-level-render [level : CompilerDiagnosticLevel]) : String
  (match level
    [(CompilerDiagnosticError) "error"]
    [(CompilerDiagnosticWarning) "warning"]
    [(CompilerDiagnosticNote) "note"]))

(define (compiler-diagnostic-repeat [chunk : String] [count : i64]) : String
  (let
    [idx : i64 0]
    [out : String ""]
    (begin
      (while (< idx count)
        (begin
          (set! out (string-append out chunk))
          (set! idx (+ idx 1))))
      out)))

(define (compiler-diagnostic-line-gutter [line : i64]) : String
  (let
    [line-text : String (int->string line)]
    (if (< line 10)
      (string-append " " line-text)
      line-text)))

(define (compiler-diagnostic-blank-gutter [line : i64]) : String
  (compiler-diagnostic-repeat
    " "
    (string-length (compiler-diagnostic-line-gutter line))))

(define (compiler-diagnostic-column-padding [col : i64]) : i64
  (if (> col 1)
    (- col 1)
    0))

(define (compiler-diagnostic-string-eq? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
    (if (= left-len right-len)
      (let
        [idx : i64 0]
        [ok : bool true]
        (begin
          (while (and ok (< idx left-len))
            (begin
              (if (= (string-ref left idx) (string-ref right idx))
                unit
                (set! ok false))
              (set! idx (+ idx 1))))
          ok))
      false)))

(define (compiler-diagnostic-source-line [source : String] [target-line : i64]) : CompilerDiagnosticMaybeString
  (if (< target-line 1)
    CompilerDiagnosticNoString
    (let
      [idx : i64 0]
      [n : i64 (string-length source)]
      [line : i64 1]
      [start : i64 0]
      [done : bool false]
      [out : String ""]
      (begin
        (while (and (< idx n) (not done))
          (begin
            (if (= line target-line)
              (if (= (string-ref source idx) #\newline')
                (begin
                  (set! out (substring source start (- idx start)))
                  (set! done true))
                unit)
              unit)
            (if (and (not done) (= (string-ref source idx) #\newline'))
              (begin
                (set! line (+ line 1))
                (set! start (+ idx 1)))
              unit)
            (set! idx (+ idx 1))))
        (if done
          (CompilerDiagnosticSomeString out)
          (if (= line target-line)
            (CompilerDiagnosticSomeString (substring source start (- n start)))
            CompilerDiagnosticNoString))))))

(define (compiler-diagnostic-render-header
  [diag : CompilerDiagnostic]
  [level : CompilerDiagnosticLevel]
  [code : CompilerDiagnosticMaybeString]) : String
  (let
    [level-text : String (compiler-diagnostic-level-render level)]
    (match code
      [(CompilerDiagnosticSomeString code-text)
        (compiler-diagnostic-cat3
          level-text
          "["
          (compiler-diagnostic-cat3
            code-text
            "]: "
            (string-append (compiler-diagnostic-message diag) "\n")))]
      [CompilerDiagnosticNoString
        (compiler-diagnostic-cat3
          level-text
          ": "
          (string-append (compiler-diagnostic-message diag) "\n"))])))

(define (compiler-diagnostic-render-location [diag : CompilerDiagnostic]) : String
  (compiler-diagnostic-cat3
    "  --> "
    (compiler-diagnostic-path diag)
    (compiler-diagnostic-cat3
      ":"
      (int->string (compiler-diagnostic-line diag))
      (compiler-diagnostic-cat3
        ":"
        (int->string (compiler-diagnostic-col diag))
        "\n"))))

(define (compiler-diagnostic-render-source-snippet
  [diag : CompilerDiagnostic]
  [source : String]) : String
  (match (compiler-diagnostic-source-line
    source
    (compiler-diagnostic-line diag))
    [(CompilerDiagnosticSomeString line-text)
      (let
        [line : i64 (compiler-diagnostic-line diag)]
        [gutter : String (compiler-diagnostic-line-gutter line)]
        [blank : String (compiler-diagnostic-blank-gutter line)]
        [padding : String
          (compiler-diagnostic-repeat
            " "
            (compiler-diagnostic-column-padding (compiler-diagnostic-col diag)))]
        (string-append
          (compiler-diagnostic-cat3 gutter " | " (string-append line-text "\n"))
          (compiler-diagnostic-cat3
            blank
            " | "
            (compiler-diagnostic-cat3 padding "^" "\n"))))]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-help [help : CompilerDiagnosticMaybeString]) : String
  (match help
    [(CompilerDiagnosticSomeString text)
      (compiler-diagnostic-cat3 "   = help: " text "\n")]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-source
  [diag : CompilerDiagnostic]
  [source : String]
  [level : CompilerDiagnosticLevel]
  [code : CompilerDiagnosticMaybeString]
  [help : CompilerDiagnosticMaybeString]) : String
  (string-append
    (compiler-diagnostic-render-header diag level code)
    (string-append
      (compiler-diagnostic-render-location diag)
      (string-append
        "   |\n"
        (string-append
          (compiler-diagnostic-render-source-snippet diag source)
          (compiler-diagnostic-render-help help))))))

(define (compiler-diagnostic-render-ok?) : bool
  (string-eq
    (compiler-diagnostic-render
      (CompilerDiagnostic "demo.tl" 3 7 "parse: malformed define"))
    "demo.tl:3:7: parse: malformed define"))

(define (compiler-diagnostic-source-error-ok?) : bool
  (let
    [err : SourceError
      (SourceError "lexer: unexpected character" (SourceSpan 4 5 4 6))]
    [diag : CompilerDiagnostic
      (compiler-diagnostic-from-source-error "input.tl" err)]
    (and
      (string-eq (compiler-diagnostic-path diag) "input.tl")
      (and
        (= (compiler-diagnostic-line diag) 4)
        (and
          (= (compiler-diagnostic-col diag) 5)
          (string-eq
            (compiler-diagnostic-message diag)
            "lexer: unexpected character"))))))

(define (compiler-diagnostic-rewrite-ok?) : bool
  (let
    [diag : CompilerDiagnostic (CompilerDiagnostic "old.tl" 1 2 "old")]
    [moved : CompilerDiagnostic (compiler-diagnostic-with-path diag "new.tl")]
    [rewritten : CompilerDiagnostic
      (compiler-diagnostic-with-message moved "new message")]
    (and
      (string-eq (compiler-diagnostic-path rewritten) "new.tl")
      (and
        (= (compiler-diagnostic-line rewritten) 1)
        (and
          (= (compiler-diagnostic-col rewritten) 2)
          (string-eq (compiler-diagnostic-message rewritten) "new message"))))))

(define (compiler-diagnostic-source-render-ok?) : bool
  (let
    [diag : CompilerDiagnostic
      (CompilerDiagnostic "test.tl" 3 6 "type mismatch")]
    [source : String "(define x true)\n(define y 42)\n(+ x y)\n"]
    [out : String
      (compiler-diagnostic-render-source
        diag
        source
        CompilerDiagnosticError
        (CompilerDiagnosticSomeString "E0001")
        (CompilerDiagnosticSomeString "expected i64, found bool"))]
    (compiler-diagnostic-string-eq?
      out
      "error[E0001]: type mismatch\n  --> test.tl:3:6\n   |\n 3 | (+ x y)\n   |      ^\n   = help: expected i64, found bool\n")))

(define (compiler-diagnostic-source-render-minimal-ok?) : bool
  (let
    [diag : CompilerDiagnostic (CompilerDiagnostic "lib.tl" 1 1 "heads up")]
    [out : String
      (compiler-diagnostic-render-source
        diag
        "x\n"
        CompilerDiagnosticWarning
        CompilerDiagnosticNoString
        CompilerDiagnosticNoString)]
    (compiler-diagnostic-string-eq?
      out
      "warning: heads up\n  --> lib.tl:1:1\n   |\n 1 | x\n   | ^\n")))

(define (compiler-diagnostic-self-test) : i64
  (if (compiler-diagnostic-render-ok?)
    (if (compiler-diagnostic-source-error-ok?)
      (if (compiler-diagnostic-rewrite-ok?)
        (if (and
          (compiler-diagnostic-source-render-ok?)
          (compiler-diagnostic-source-render-minimal-ok?))
          42
          4)
        3)
      2)
    1))