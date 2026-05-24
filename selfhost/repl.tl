;; repl.tl - Selfhost REPL session driver (#591/#798).
;;
;; A `main`-bearing TypeLisp program that owns the REPL line loop and the
;; dot-command behavior of the Rust REPL skeleton's in-process slices. It reads
;; lines with `read-stdin-line` until `.exit` or end of input, printing a flushed
;; `tl> ` prompt before each read so the prompt is visible in an interactive
;; session, and dispatches the dot commands:
;;
;;   - `.exit`            ends the session.
;;   - `.help`            prints the command help to stdout.
;;   - `.type <expr>`     prints the inferred type without running code.
;;   - blank line         is skipped.
;;   - any other `.cmd`   reports an unknown command (to stderr).
;;   - declarations       are checked and persisted for later inputs.
;;   - any other input    reports that evaluation is not implemented (to stderr).
;;
;; Multiline input is accumulated until its delimiters are complete. Parse and
;; type errors report diagnostics, discard only the failing input, and return to
;; the prompt with previously accepted declarations intact.
(import "compiler_typecheck.tl")

(defenum ReplTypeCommand
  (ReplNoTypeCommand)
  (ReplTypeCommandExpr String))

(defenum ReplLineResult
  (ReplLineResult String String))

(define (repl-banner) : String
  "TypeLisp REPL. Type .help for commands.\n")

(define (repl-help-text) : String
  "TypeLisp REPL commands:\n  .help         Show this help\n  .type <expr>  Print the inferred type without running code\n  .exit         Exit the REPL\n")

;; Print the prompt and flush stdout so it is visible before the blocking read.
(define (repl-prompt) : unit
  (begin
    (print-string "tl> ")
    (flush-stdout)))

;; `line` begins with `.` (a dot command). Empty lines are handled safely.
(define (repl-dot-command? [line : String]) : bool
  (if (> (string-length line) 0)
    (= (string-ref line 0) #.')
    false))

(define (repl-space? [c : char]) : bool
  (or (= c #\space') (or (= c #\tab') (or (= c #\newline') (= c #\return')))))

(define (repl-string-prefix? [text : String] [prefix : String]) : bool
  (let (
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)])
    (if (> prefix-len text-len)
      false
      (string-eq (substring text 0 prefix-len) prefix))))

(define (repl-trim-left-from [text : String] [start : i64]) : String
  (let (
    [i : i64 start]
    [len : i64 (string-length text)])
    (begin
      (while (and (< i len) (repl-space? (string-ref text i)))
        (set! i (+ i 1)))
      (if (< i len)
        (substring text i (- len i))
        ""))))

(define (repl-type-command [line : String]) : ReplTypeCommand
  (if (repl-string-prefix? line ".type")
    (if (= (string-length line) 5)
      (ReplTypeCommandExpr "")
      (if (repl-space? (string-ref line 5))
        (ReplTypeCommandExpr (repl-trim-left-from line 5))
        (ReplNoTypeCommand)))
    (ReplNoTypeCommand)))

(define (repl-type-list-render-spaced [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) ""]
    [(AstTypeCons head rest)
      (string-append
        " "
        (string-append
          (repl-type-render head)
          (repl-type-list-render-spaced rest)))]))

(define (repl-type-render [ty : AstType]) : String
  (match ty
    [(AstTyI64) "i64"]
    [(AstTyI32) "i32"]
    [(AstTyI16) "i16"]
    [(AstTyI8) "i8"]
    [(AstTyU64) "u64"]
    [(AstTyU32) "u32"]
    [(AstTyU16) "u16"]
    [(AstTyU8) "u8"]
    [(AstTyF64) "f64"]
    [(AstTyF32) "f32"]
    [(AstTyBool) "bool"]
    [(AstTyChar) "char"]
    [(AstTyString) "String"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyFunc args ret)
      (string-append
        "(->"
        (string-append
          (repl-type-list-render-spaced args)
          (string-append " " (string-append (repl-type-render ret) ")"))))]
    [(AstTyTuple elems)
      (string-append
        "(Tuple"
        (string-append (repl-type-list-render-spaced elems) ")"))]
    [(AstTyArray elem count)
      (string-append
        "(Array "
        (string-append
          (repl-type-render elem)
          (string-append " " (string-append (int->string count) ")"))))]
    [(AstTyDynArray elem)
      (string-append "(Array " (string-append (repl-type-render elem) ")"))]
    [(AstTyRegion region inner)
      (string-append
        "(in "
        (string-append
          region
          (string-append " " (string-append (repl-type-render inner) ")"))))]
    [(AstTyEnum name) name]
    [(AstTyStruct name) name]
    [(AstTyVar name) (string-append "'" (string-append name "'"))]))

(define (repl-print-error-line [message : String]) : unit
  (print-error (string-append message "\n")))

(define (repl-report-diagnostic [diag : CompilerDiagnostic]) : unit
  (begin
    (print-error (compiler-diagnostic-render diag))
    (print-error "\n")))

(define (repl-handle-type-command
  [session-source : String]
  [expr-source : String]) : unit
  (if (string-eq expr-source "")
    (repl-print-error-line "Error: .type expects an expression")
    (match (parse-ast-repl-source expr-source)
      [(OkAstReplItem item)
        (match item
          [(AstReplDecl _)
            (repl-print-error-line
              "Error: .type expects an expression, got a declaration")]
          [(AstReplExpr expr)
            (match (parse-ast-source session-source)
              [(OkAstProgram (AstProgram decls))
                (match (typecheck-compiler-repl-expr decls expr)
                  [(OkTcType ty)
                    (print-string (string-append (repl-type-render ty) "\n"))]
                  [(ErrTcType message)
                    (repl-print-error-line (string-append "Error: " message))])]
              [(ErrAstProgram message)
                (repl-print-error-line (string-append "Error: " message))])])]
      [(ErrAstReplItem message)
        (repl-print-error-line (string-append "Error: " message))])))

(define (repl-session-candidate [session-source : String] [input : String]) : String
  (string-append session-source (string-append input "\n")))

(define (repl-handle-input [session-source : String] [input : String]) : String
  (match (parse-ast-repl-source input)
    [(OkAstReplItem item)
      (match item
        [(AstReplDecl _)
          (let ([candidate : String
            (repl-session-candidate session-source input)])
            (match (typecheck-compiler-source candidate)
              [(OkCompilerTypecheck _) candidate]
              [(ErrCompilerTypecheck diag)
                (begin
                  (repl-report-diagnostic diag)
                  session-source)]))]
        [(AstReplExpr _)
          (begin
            (print-error
              "REPL evaluation is not implemented yet. Type .help for commands.\n")
            session-source)])]
    [(ErrAstReplItem message)
      (begin
        (repl-print-error-line (string-append "REPL parse error: " message))
        session-source)]))

;; Completeness tracking mirrors the Rust REPL's delimiter check closely enough
;; for the selfhost slice: strings, comments, and char literals do not count
;; delimiters; unmatched closing delimiters are considered complete so parsing can
;; report the real error and the session can recover.
(define (repl-skip-comment [text : String] [idx : i64] [len : i64]) : i64
  (if (>= idx len)
    idx
    (if (= (string-ref text idx) #\newline')
      (+ idx 1)
      (repl-skip-comment text (+ idx 1) len))))

(define (repl-skip-char-literal [text : String] [idx : i64] [len : i64]) : i64
  (if (>= idx len)
    idx
    (if (= (string-ref text idx) #'')
      (+ idx 1)
      (repl-skip-char-literal text (+ idx 1) len))))

(define (repl-input-complete-loop
  [text : String]
  [idx : i64]
  [len : i64]
  [parens : i64]
  [brackets : i64]
  [in-string : bool]
  [escaped : bool]) : bool
  (if (>= idx len)
    (and (not in-string) (and (= parens 0) (= brackets 0)))
    (let ([c : char (string-ref text idx)])
      (if in-string
        (if escaped
          (repl-input-complete-loop
            text
            (+ idx 1)
            len
            parens
            brackets
            true
            false)
          (if (= c #\\')
            (repl-input-complete-loop
              text
              (+ idx 1)
              len
              parens
              brackets
              true
              true)
            (if (= c #"')
              (repl-input-complete-loop
                text
                (+ idx 1)
                len
                parens
                brackets
                false
                false)
              (repl-input-complete-loop
                text
                (+ idx 1)
                len
                parens
                brackets
                true
                false))))
        (if (= c #;')
          (repl-input-complete-loop
            text
            (repl-skip-comment text (+ idx 1) len)
            len
            parens
            brackets
            false
            false)
          (if (= c #"')
            (repl-input-complete-loop
              text
              (+ idx 1)
              len
              parens
              brackets
              true
              false)
            (if (= c ##')
              (repl-input-complete-loop
                text
                (repl-skip-char-literal text (+ idx 1) len)
                len
                parens
                brackets
                false
                false)
              (if (= c #(')
                (repl-input-complete-loop
                  text
                  (+ idx 1)
                  len
                  (+ parens 1)
                  brackets
                  false
                  false)
                (if (= c #[')
                  (repl-input-complete-loop
                    text
                    (+ idx 1)
                    len
                    parens
                    (+ brackets 1)
                    false
                    false)
                  (if (= c #)')
                    (if (= parens 0)
                      true
                      (repl-input-complete-loop
                        text
                        (+ idx 1)
                        len
                        (- parens 1)
                        brackets
                        false
                        false))
                    (if (= c #]')
                      (if (= brackets 0)
                        true
                        (repl-input-complete-loop
                          text
                          (+ idx 1)
                          len
                          parens
                          (- brackets 1)
                          false
                          false))
                      (repl-input-complete-loop
                        text
                        (+ idx 1)
                        len
                        parens
                        brackets
                        false
                        false))))))))))))

(define (repl-input-complete? [input : String]) : bool
  (repl-input-complete-loop input 0 (string-length input) 0 0 false false))

(define (repl-append-pending [pending : String] [line : String]) : String
  (if (string-eq pending "")
    line
    (string-append pending (string-append "\n" line))))

(define (repl-handle-source-line
  [session-source : String]
  [pending : String]
  [line : String]) : ReplLineResult
  (let ([next-pending : String (repl-append-pending pending line)])
    (if (repl-input-complete? next-pending)
      (ReplLineResult (repl-handle-input session-source next-pending) "")
      (ReplLineResult session-source next-pending))))

;; Handle one non-`.exit` command line. When a multiline input is pending, all
;; following lines are treated as source until the form is complete.
(define (repl-handle-line
  [session-source : String]
  [pending : String]
  [line : String]) : ReplLineResult
  (if (string-eq pending "")
    (if (string-eq line "")
      (ReplLineResult session-source "")
      (match (repl-type-command line)
        [(ReplTypeCommandExpr expr-source)
          (begin
            (repl-handle-type-command session-source expr-source)
            (ReplLineResult session-source ""))]
        [(ReplNoTypeCommand)
          (if (string-eq line ".help")
            (begin
              (print-string (repl-help-text))
              (ReplLineResult session-source ""))
            (if (repl-dot-command? line)
              (begin
                (print-error (string-append "Unknown REPL command: " line))
                (print-error "\nType .help for commands.\n")
                (ReplLineResult session-source ""))
              (repl-handle-source-line session-source pending line)))]))
    (repl-handle-source-line session-source pending line)))

;; The REPL loop: prompt, then read and dispatch until `.exit` or end of input.
(define (repl-loop [session-source : String] [pending : String]) : unit
  (begin
    (repl-prompt)
    (if (stdin-eof?)
      (if (string-eq pending "")
        unit
        (print-error "Error: incomplete REPL input at EOF\n"))
      (let ([line : String (read-stdin-line)])
        (if (and (string-eq pending "") (string-eq line ".exit"))
          unit
          (match (repl-handle-line session-source pending line)
            [(ReplLineResult next-session next-pending)
              (repl-loop next-session next-pending)]))))))

(define (main) : i64
  (begin
    (print-string (repl-banner))
    (repl-loop "" "")
    0))