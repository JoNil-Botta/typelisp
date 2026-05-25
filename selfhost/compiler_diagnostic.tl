;; compiler_diagnostic.tl - Shared selfhost compiler diagnostic payloads.
(import "token.tl")

(import "compiler_ast_types.tl")

(defstruct CompilerDiagnostic
  (path String)
  (line i64)
  (col i64)
  (message String))

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

(define (compiler-diagnostic-self-test) : i64
  (if (compiler-diagnostic-render-ok?)
    (if (compiler-diagnostic-source-error-ok?)
      (if (compiler-diagnostic-rewrite-ok?)
        42
        3)
      2)
    1))