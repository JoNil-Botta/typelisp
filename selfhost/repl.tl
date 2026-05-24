;; repl.tl - First selfhost REPL command driver (#591).

;;

;; A `main`-bearing TypeLisp program that owns the REPL line loop and the

;; dot-command behavior of the Rust REPL skeleton's first slice (#458). It reads

;; lines with `read-stdin-line` until `.exit` or end of input, printing a flushed

;; `tl> ` prompt before each read so the prompt is visible in an interactive

;; session, and dispatches the dot commands:

;;

;;   - `.exit`            ends the session.

;;   - `.help`            prints the command help to stdout.

;;   - `.type <expr>`     prints the inferred type without running code.

;;   - blank line         is skipped.

;;   - any other `.cmd`   reports an unknown command (to stderr).

;;   - any other input    reports that evaluation is not implemented (to stderr).

;;

;; Single-line declaration persistence is implemented so `.type` can see earlier

;; accepted declarations. Expression evaluation and multiline input

;; are intentionally out of scope for this slice; they remain in the Rust REPL

;; (#461/#462) until ported separately. The Rust `typelisp repl` stays

;; authoritative until an explicit CLI handoff chooses to run this driver.

;;

;; `read-stdin-line` returns a line with its trailing newline stripped, and

;; `stdin-eof?` reports a sticky end-of-input flag set once a read passes the

;; end of stdin. The loop checks `stdin-eof?` before each read; a trailing

;; newline yields one final empty read, which is handled as a (skipped) blank

;; line.

(import "compiler_typecheck.tl")

(defenum ReplTypeCommand
  (ReplNoTypeCommand)
  (ReplTypeCommandExpr String))

(define (repl-banner) : String
  "TypeLisp REPL. Type .help for commands.\n")

(define (repl-help-text) : String
  "TypeLisp REPL commands:\n  .help         Show this help\n  .type <expr>  Print the inferred type without running code\n  .exit         Exit the REPL\n")

;; Print the prompt and flush stdout so it is visible before the blocking read.

(define (repl-prompt) : unit
  (begin
    (print-string "tl> ")
    (flush-stdout)))

;; `line` begins with `.` (a dot command). Only called on a non-empty line, so

;; the `string-ref` is in bounds even though `and` is not short-circuiting here.

(define (repl-dot-command? [line : String]) : bool
  (and (> (string-length line) 0) (= (string-ref line 0) #.')))

(define (repl-space? [c : char]) : bool
  (or (= c #\space') (or (= c #\tab') (or (= c #\newline') (= c #\return')))))

(define (repl-string-prefix? [text : String] [prefix : String]) : bool
  (let ([text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)])
    (if (> prefix-len text-len)
      false
      (string-eq (substring text 0 prefix-len) prefix))))

(define (repl-trim-left-from [text : String] [start : i64]) : String
  (let ([i : i64 start] [len : i64 (string-length text)])
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
    [(AstTyEnum name) name]
    [(AstTyStruct name) name]
    [(AstTyVar name) (string-append "'" (string-append name "'"))]))

(define (repl-print-error-line [message : String]) : unit
  (print-error (string-append message "\n")))

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

(define (repl-session-append [session-source : String] [line : String]) : String
  (string-append session-source (string-append line "\n")))

(define (repl-handle-input [session-source : String] [line : String]) : String
  (match (parse-ast-repl-source line)
    [(OkAstReplItem item)
      (match item
        [(AstReplDecl _)
          (let ([candidate : String (repl-session-append session-source line)])
            (match (typecheck-compiler-source candidate)
              [(OkCompilerTypecheck _) candidate]
              [(ErrCompilerTypecheck diag)
                (begin
                  (print-error (compiler-diagnostic-render diag))
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

;; Handle one non-`.exit` input line, matching the Rust skeleton: blank lines are

;; skipped, `.help` prints help to stdout, any other dot command is unknown, and

;; any other input reports that evaluation is unimplemented (both to stderr).

(define (repl-handle-line [session-source : String] [line : String]) : String
  (if (string-eq line "")
    session-source
    (match (repl-type-command line)
      [(ReplTypeCommandExpr expr-source)
        (begin
          (repl-handle-type-command session-source expr-source)
          session-source)]
      [(ReplNoTypeCommand)
        (if (string-eq line ".help")
          (begin
            (print-string (repl-help-text))
            session-source)
          (if (repl-dot-command? line)
            (begin
              (print-error (string-append "Unknown REPL command: " line))
              (print-error "\nType .help for commands.\n")
              session-source)
            (repl-handle-input session-source line)))])))

;; The REPL loop: prompt, then read and dispatch until `.exit` or end of input.

(define (repl-loop [session-source : String]) : unit
  (begin
    (repl-prompt)
    (if (stdin-eof?)
      unit
      (let ([line : String (read-stdin-line)])
        (if (string-eq line ".exit")
          unit
          (begin
            (repl-loop (repl-handle-line session-source line))))))))

(define (main) : i64
  (begin
    (print-string (repl-banner))
    (repl-loop "")
    0))