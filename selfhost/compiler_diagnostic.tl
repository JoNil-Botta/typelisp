;; compiler_diagnostic.tl - Shared selfhost compiler diagnostic payloads.

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

(define (compiler-diagnostic-from-span
  [path : String]
  [span : SourceSpan]
  [message : String]) : CompilerDiagnostic
  (CompilerDiagnostic path (span-start-line span) (span-start-col span) message))

(define (compiler-diagnostic-from-source-error
  [path : String]
  [err : SourceError]) : CompilerDiagnostic
  (compiler-diagnostic-from-span
    path
    (source-error-span err)
    (source-error-message err)))

(define (compiler-diagnostic-at-start [path : String] [message : String]) : CompilerDiagnostic
  (CompilerDiagnostic path 1 1 message))

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

;; Re-stamp a diagnostic with a known source path, preserving its line/col and

;; message. Phases that do not know the file path (e.g. the typechecker, which

;; receives an already-loaded program) build diagnostics with an empty path; the

;; CLI driver fills the real path before rendering.

(define (compiler-diagnostic-with-path
  [diag : CompilerDiagnostic]
  [path : String]) : CompilerDiagnostic
  (CompilerDiagnostic
    path
    (compiler-diagnostic-line diag)
    (compiler-diagnostic-col diag)
    (compiler-diagnostic-message diag)))