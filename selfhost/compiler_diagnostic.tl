;; compiler_diagnostic.tl - Shared selfhost compiler diagnostic payload.

(import "token.tl")

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

(define (compiler-diagnostic-at
  [path : String]
  [line : i64]
  [col : i64]
  [message : String]) : CompilerDiagnostic
  (CompilerDiagnostic path line col message))

(define (compiler-diagnostic-at-span
  [path : String]
  [span : SourceSpan]
  [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-at path (span-start-line span) (span-start-col span) message))

(define (compiler-diagnostic-at-start
  [path : String]
  [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-at path 1 1 message))

(define (compiler-diagnostic-from-source-error
  [path : String]
  [err : SourceError]) : CompilerDiagnostic
  (compiler-diagnostic-at-span path (source-error-span err) (source-error-message err)))

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

(define (compiler-diagnostic-smoke) : i64
  (let ([diag
      :
      CompilerDiagnostic
      (compiler-diagnostic-at "example.tl" 2 7 "parse: bad")])
    (if (string-eq
      (compiler-diagnostic-render diag)
      "example.tl:2:7: parse: bad")
      42
      (begin
        (panic "diagnostic: render mismatch")
        0))))
