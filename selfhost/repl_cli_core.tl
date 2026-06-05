;; repl_cli_core.tl - Selfhost REPL session command logic (#591/#798/#1641).
;;
;; Shared by the standalone `repl.tl` wrapper and the unified `cli.tl`
;; dispatcher.
;;
;; Owns the REPL line loop and the dot-command behavior of the Rust REPL
;; skeleton's in-process slices. It reads
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
;;   - expressions         are checked, compiled as scratch source, and run.
;;
;; Multiline input is accumulated until its delimiters are complete. Parse and
;; type errors report diagnostics, discard only the failing input, and return to
;; the prompt with previously accepted declarations intact.
(import "stdlib/io.tl")

(import "compiler_typecheck.tl")

(import "compiler_load.tl")

(import "build_run_core.tl")

(defenum ReplTypeCommand
  (ReplNoTypeCommand)
  (ReplTypeCommandExpr String))

(defenum ReplLineResult
  (ReplLineResult String String))

(defenum ResultReplString
  (OkReplString String)
  (ErrReplString String))

(defenum ResultReplDeclList
  (OkReplDeclList AstDeclList)
  (ErrReplDeclList String))

(define (repl-banner) : String
  "TypeLisp REPL. Type .help for commands.\n")

(define (repl-help-text) : String
  "TypeLisp REPL commands:\n  .help         Show this help\n  .type <expr>  Print the inferred type without running code\n  .exit         Exit the REPL\n")

(define (repl-stdout-write [text : String]) : unit
  (stdout-write (& text)))

(define (repl-stdout-write-line [text : String]) : unit
  (stdout-write-line (& text)))

(define (repl-stderr-write [text : String]) : unit
  (stderr-write (& text)))

(define (repl-stderr-write-line [text : String]) : unit
  (stderr-write-line (& text)))

(define (repl-path-join [left : String] [right : String]) : String
  (fs-path-join (& left) (& right)))

(define (repl-try-remove-file-if-exists [path : String]) : ResultIoUnit
  (try-remove-file-if-exists (& path)))

(define (repl-try-remove-dir-if-exists [path : String]) : ResultIoUnit
  (try-remove-dir-if-exists (& path)))

;; Print the prompt and flush stdout so it is visible before the blocking read.
(define (repl-prompt) : unit
  (begin
    (repl-stdout-write "tl> ")
    (stdout-flush)))

;; `line` begins with `.` (a dot command). Empty lines are handled safely.
(define (repl-dot-command? [line : String]) : bool
  (if (> (string-length line) 0)
    (= (string-ref line 0) #.')
    false))

(define (repl-space? [c : char]) : bool
  (or (= c #\space') (or (= c #\tab') (or (= c #\newline') (= c #\return')))))

(define (repl-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (> prefix-len text-len)
      false
      (string-eq (substring text 0 prefix-len) prefix))))

(define (repl-trim-left-from [text : String] [start : i64]) : String
  (let
    [i : i64 start]
    [len : i64 (string-length text)]
    (begin
      (while (and (< i len) (repl-space? (string-ref text i)))
        (set! i (+ i 1)))
      (if (< i len)
        (substring text i (- len i))
        ""))))

(define (repl-line-ending? [c : char]) : bool
  (or (= c #\return') (= c #\newline')))

(define (repl-leading-utf8-bom? [text : String]) : bool
  (if (< (string-length text) 3)
    false
    (and
      (= (cast (string-ref text 0) : i64) 239)
      (and
        (= (cast (string-ref text 1) : i64) 187)
        (= (cast (string-ref text 2) : i64) 191)))))

(define (repl-trim-leading-utf8-bom [text : String]) : String
  (if (repl-leading-utf8-bom? text)
    (substring text 3 (- (string-length text) 3))
    text))

(define (repl-trim-right-line-ending [text : String]) : String
  (let
    [len : i64 (string-length text)]
    [end : i64 (string-length text)]
    [done : bool false]
    (begin
      (while (> len 0)
        (if done
          (set! len 0)
          (if (repl-line-ending? (string-ref text (- len 1)))
            (begin
              (set! end (- len 1))
              (set! len (- len 1)))
            (set! done true))))
      (substring text 0 end))))

(define (repl-normalize-input-line [text : String]) : String
  (repl-trim-right-line-ending (repl-trim-leading-utf8-bom text)))

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
      (let
        [rest : AstTypeList (box-get rest)]
        (string-append
          " "
          (string-append
            (repl-type-render head)
            (repl-type-list-render-spaced rest))))]))

(define (repl-lifetime-list-render-spaced [lifetimes : AstLifetimeList]) : String
  (match lifetimes
    [(AstLifetimeNil) ""]
    [(AstLifetimeCons head rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (string-append
          " "
          (string-append head (repl-lifetime-list-render-spaced rest))))]))

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
    [(AstTyStr) "str"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyFunc args ret)
      (string-append
        "(->"
        (string-append
          (repl-type-list-render-spaced args)
          (string-append
            " "
            (string-append (repl-type-render (box-get ret)) ")"))))]
    [(AstTyTuple elems)
      (string-append
        "(Tuple"
        (string-append (repl-type-list-render-spaced elems) ")"))]
    [(AstTyArray elem count)
      (string-append
        "(Array "
        (string-append
          (repl-type-render (box-get elem))
          (string-append " " (string-append (int->string count) ")"))))]
    [(AstTyDynArray elem)
      (string-append
        "(Array "
        (string-append (repl-type-render (box-get elem)) ")"))]
    [(AstTyBox elem)
      (string-append
        "(Box "
        (string-append (repl-type-render (box-get elem)) ")"))]
    [(AstTyPtr elem)
      (string-append
        "(Ptr "
        (string-append (repl-type-render (box-get elem)) ")"))]
    [(AstTyMutPtr elem)
      (string-append
        "(MutPtr "
        (string-append (repl-type-render (box-get elem)) ")"))]
    [(AstTyRef region inner)
      (string-append
        "(& "
        (string-append
          region
          (string-append
            " "
            (string-append (repl-type-render (box-get inner)) ")"))))]
    [(AstTyMutRef region inner)
      (string-append
        "(&mut "
        (string-append
          region
          (string-append
            " "
            (string-append (repl-type-render (box-get inner)) ")"))))]
    [(AstTyRegion region inner)
      (string-append
        "(in "
        (string-append
          region
          (string-append
            " "
            (string-append (repl-type-render (box-get inner)) ")"))))]
    [(AstTyEnum name) name]
    [(AstTyEnumArgs name lifetimes)
      (string-append
        "("
        (string-append
          name
          (string-append (repl-lifetime-list-render-spaced lifetimes) ")")))]
    [(AstTyStruct name) name]
    [(AstTyStructArgs name lifetimes)
      (string-append
        "("
        (string-append
          name
          (string-append (repl-lifetime-list-render-spaced lifetimes) ")")))]
    [(AstTyVar name) (string-append "'" (string-append name "'"))]
    [(AstTyVarArgs name lifetimes)
      (string-append
        "("
        (string-append
          name
          (string-append (repl-lifetime-list-render-spaced lifetimes) ")")))]))

(define (repl-print-error-line [message : String]) : unit
  (repl-stderr-write-line message))

(define (repl-report-diagnostic [diag : CompilerDiagnostic]) : unit
  (repl-stderr-write-line (compiler-diagnostic-render diag)))

(define (repl-char-display-helpers-source) : String
  "(define __tl_repl_ascii_printable_table : String
  \" !\\\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\")

(define (__tl_repl_char_string [c : char]) : String
  (let
    [code : i64 (cast c : i64)]
    (cond
      [(= code 9) \"\t\"]
      [(= code 10) \"
\"]
      [(= code 13) \"\r\"]
      [(and (>= code 32) (<= code 126))
        (substring __tl_repl_ascii_printable_table (- code 32) 1)]
      [else \"?\"])))

(define (__tl_repl_print_char [c : char]) : unit
  (begin
    (print-string (__tl_repl_char_string c))
    (print-newline)))

")

(define (repl-f64-display-helpers-source) : String
  "(define (__tl_repl_trim_fraction_value [value : i64]) : i64
  (if (and (> value 0) (= (% value 10) 0))
    (__tl_repl_trim_fraction_value (/ value 10))
    value))

(define (__tl_repl_trim_fraction_divisor [value : i64] [divisor : i64]) : i64
  (if (and (> value 0) (= (% value 10) 0))
    (__tl_repl_trim_fraction_divisor (/ value 10) (/ divisor 10))
    divisor))

(define (__tl_repl_print_fraction_digits [value : i64] [divisor : i64]) : unit
  (if (= divisor 0)
    unit
    (begin
      (print-string (int->string (/ value divisor)))
      (__tl_repl_print_fraction_digits (% value divisor) (/ divisor 10)))))

(define (__tl_repl_print_f64_positive [x : f64]) : unit
  (let
    [whole : i64 (cast x : i64)]
    [fraction : f64 (- x (cast whole : f64))]
    [raw-scaled : i64 (cast (+ (* fraction 1000000.0) 0.5) : i64)]
    [carry : bool (= raw-scaled 1000000)]
    [shown-whole : i64 (if carry (+ whole 1) whole)]
    [scaled : i64 (if carry 0 raw-scaled)]
    (begin
      (print-string (int->string shown-whole))
      (if (= scaled 0)
        unit
        (let
          [trimmed : i64 (__tl_repl_trim_fraction_value scaled)]
          [divisor : i64 (__tl_repl_trim_fraction_divisor scaled 100000)]
          (begin
            (print-string \".\")
            (__tl_repl_print_fraction_digits trimmed divisor))))
      (print-newline))))

(define (__tl_repl_print_f64 [x : f64]) : unit
  (if (< x 0.0)
    (begin
      (print-string \"-\")
      (__tl_repl_print_f64_positive (- 0.0 x)))
    (__tl_repl_print_f64_positive x)))

")

(define (repl-display-helpers-source [ty : AstType]) : String
  (match ty
    [(AstTyF64) (repl-f64-display-helpers-source)]
    [(AstTyChar) (repl-char-display-helpers-source)]
    [_ ""]))

(define (repl-display-body [ty : AstType] [expr-source : String]) : ResultReplString
  (match ty
    [(AstTyI64)
      (OkReplString
        (string-append "(print\n" (string-append expr-source "\n)")))]
    [(AstTyBool)
      (OkReplString
        (string-append "(print-bool\n" (string-append expr-source "\n)")))]
    [(AstTyF64)
      (OkReplString
        (string-append
          "(__tl_repl_print_f64\n"
          (string-append expr-source "\n)")))]
    [(AstTyChar)
      (OkReplString
        (string-append
          "(__tl_repl_print_char\n"
          (string-append expr-source "\n)")))]
    [(AstTyString)
      (OkReplString
        (string-append
          "(begin\n  (print-string\n"
          (string-append expr-source "\n  )\n  (print-newline))")))]
    [(AstTyUnit) (OkReplString expr-source)]
    [_
      (ErrReplString
        (string-append
          "Error: cannot display a value of type "
          (repl-type-render ty)))]))

(define (repl-scratch-main-source [body : String]) : String
  (string-append
    "(define (main) : i64\n  (begin\n    "
    (string-append body "\n    0))\n")))

(define (repl-scratch-source
  [session-source : String]
  [expr-source : String]
  [ty : AstType]) : ResultReplString
  (match (repl-display-body ty expr-source)
    [(OkReplString body)
      (OkReplString
        (string-append
          "(import \"stdlib/io.tl\")\n"
          (string-append
            session-source
            (string-append
              "\n"
              (string-append
                (repl-display-helpers-source ty)
                (repl-scratch-main-source body))))))]
    [(ErrReplString message) (ErrReplString message)]))

(define (repl-clean-scratch-source [temp-dir : String] [source-path : String]) : unit
  (begin
    (repl-try-remove-file-if-exists source-path)
    (repl-try-remove-dir-if-exists temp-dir)
    unit))

(define (repl-session-source-path) : String
  "repl-session.tl")

(define (repl-load-session-decls [session-source : String]) : ResultReplDeclList
  (match (compiler-load-source
    (repl-session-source-path)
    session-source
    (sym-i64-empty))
    [(OkCompilerLoad decls _) (OkReplDeclList decls)]
    [(ErrCompilerLoad diag)
      (ErrReplDeclList (compiler-diagnostic-message diag))]))

(define (repl-typecheck-session-source [session-source : String]) : ResultCompilerTypecheck
  (match (repl-load-session-decls session-source)
    [(OkReplDeclList decls) (typecheck-compiler-program (ast-program decls))]
    [(ErrReplDeclList message)
      (ErrCompilerTypecheck (tc-diag-at-start message))]))

(define (repl-report-run-status [status : i64]) : unit
  (if (= status 0)
    unit
    (begin
      (repl-stderr-write "\n")
      (repl-print-error-line
        (string-append
          "REPL evaluation exited with status "
          (int->string status))))))

(define (repl-run-scratch-source [source : String]) : unit
  (match (source-tool-create-temp-dir "typelisp-repl")
    [(OkSourceToolString temp-dir)
      (let
        [source-path : String (repl-path-join temp-dir "repl_expr.tl")]
        (match (source-tool-write-file
          source-path
          source
          "repl: failed to write scratch source")
          [(SourceToolCommandErr message)
            (begin
              (repl-print-error-line message)
              (repl-clean-scratch-source temp-dir source-path))]
          [(SourceToolCommandOk)
            (let
              [status : i64
                (source-tool-run-source-in-temp
                  source-path
                  (source-tool-default-target)
                  CompilerLoadRootNil
                  (process-args-empty)
                  (compiler-optimize-default-level)
                  (BackendModeScalar)
                  (source-tool-link-inputs-empty)
                  temp-dir)]
              (begin
                (repl-clean-scratch-source temp-dir source-path)
                (repl-report-run-status status)))]))]
    [(ErrSourceToolString message)
      (repl-print-error-line
        (string-append "repl: failed to create scratch temp dir: " message))]))

(define (repl-evaluate-expr
  [session-source : String]
  [expr-source : String]
  [expr : AstExpr]) : unit
  (match (repl-load-session-decls session-source)
    [(OkReplDeclList decls)
      (match (typecheck-compiler-repl-expr decls expr)
        [(OkTcType ty)
          (match (repl-scratch-source session-source expr-source ty)
            [(OkReplString scratch-source)
              (repl-run-scratch-source scratch-source)]
            [(ErrReplString message) (repl-print-error-line message)])]
        [(ErrTcType message)
          (repl-print-error-line (string-append "Error: " message))])]
    [(ErrReplDeclList message)
      (repl-print-error-line (string-append "Error: " message))]))

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
            (match (repl-load-session-decls session-source)
              [(OkReplDeclList decls)
                (match (typecheck-compiler-repl-expr decls expr)
                  [(OkTcType ty) (repl-stdout-write-line (repl-type-render ty))]
                  [(ErrTcType message)
                    (repl-print-error-line (string-append "Error: " message))])]
              [(ErrReplDeclList message)
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
          (let
            [candidate : String (repl-session-candidate session-source input)]
            (match (repl-typecheck-session-source candidate)
              [(OkCompilerTypecheck _) candidate]
              [(ErrCompilerTypecheck diag)
                (begin
                  (repl-report-diagnostic diag)
                  session-source)]))]
        [(AstReplExpr expr)
          (begin
            (repl-evaluate-expr session-source input expr)
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
    (let
      [c : char (string-ref text idx)]
      (cond
        [in-string
          (cond
            [escaped
              (repl-input-complete-loop
                text
                (+ idx 1)
                len
                parens
                brackets
                true
                false)]
            [(= c #\\')
              (repl-input-complete-loop
                text
                (+ idx 1)
                len
                parens
                brackets
                true
                true)]
            [(= c #"')
              (repl-input-complete-loop
                text
                (+ idx 1)
                len
                parens
                brackets
                false
                false)]
            [else
              (repl-input-complete-loop
                text
                (+ idx 1)
                len
                parens
                brackets
                true
                false)])]
        [(= c #;')
          (repl-input-complete-loop
            text
            (repl-skip-comment text (+ idx 1) len)
            len
            parens
            brackets
            false
            false)]
        [(= c #"')
          (repl-input-complete-loop
            text
            (+ idx 1)
            len
            parens
            brackets
            true
            false)]
        [(= c ##')
          (repl-input-complete-loop
            text
            (repl-skip-char-literal text (+ idx 1) len)
            len
            parens
            brackets
            false
            false)]
        [(= c #(')
          (repl-input-complete-loop
            text
            (+ idx 1)
            len
            (+ parens 1)
            brackets
            false
            false)]
        [(= c #[')
          (repl-input-complete-loop
            text
            (+ idx 1)
            len
            parens
            (+ brackets 1)
            false
            false)]
        [(= c #)')
          (if (= parens 0)
            true
            (repl-input-complete-loop
              text
              (+ idx 1)
              len
              (- parens 1)
              brackets
              false
              false))]
        [(= c #]')
          (if (= brackets 0)
            true
            (repl-input-complete-loop
              text
              (+ idx 1)
              len
              parens
              (- brackets 1)
              false
              false))]
        [else
          (repl-input-complete-loop
            text
            (+ idx 1)
            len
            parens
            brackets
            false
            false)]))))

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
  (let
    [next-pending : String (repl-append-pending pending line)]
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
              (repl-stdout-write (repl-help-text))
              (ReplLineResult session-source ""))
            (if (repl-dot-command? line)
              (begin
                (repl-stderr-write
                  (string-append "Unknown REPL command: " line))
                (repl-stderr-write "\nType .help for commands.\n")
                (ReplLineResult session-source ""))
              (repl-handle-source-line session-source pending line)))]))
    (repl-handle-source-line session-source pending line)))

;; The REPL loop: prompt, then read and dispatch until `.exit` or end of input.
(define (repl-loop [session-source : String] [pending : String]) : unit
  (begin
    (repl-prompt)
    (if (stdin-at-eof?)
      (if (string-eq pending "")
        unit
        (repl-stderr-write "Error: incomplete REPL input at EOF\n"))
      (let
        [line-read : StdinRead (stdin-read-line)]
        [line : String (repl-normalize-input-line (stdin-read-text line-read))]
        (if (and (string-eq pending "") (string-eq line ".exit"))
          unit
          (match (repl-handle-line session-source pending line)
            [(ReplLineResult next-session next-pending)
              (repl-loop next-session next-pending)]))))))

(define (repl-run) : i64
  (begin
    (repl-stdout-write (repl-banner))
    (repl-loop "" "")
    0))

(define (repl-run-from [start : i64] [count : i64]) : i64
  (if (< start count)
    (begin
      (print-error "Error: repl does not accept arguments\n")
      1)
    (repl-run)))