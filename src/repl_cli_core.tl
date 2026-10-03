;; repl_cli_core.tl - Selfhost REPL session command logic.
;;
;; Shared by the unified `main.tl` dispatcher and `cli_core_tests.tl`.
;;
;; Owns the REPL line loop and the dot-commands. It reads lines with
;; `read-stdin-line` until `.exit` or end of input, printing a flushed `tl> `
;; prompt (or a `... ` continuation marker while a multiline form is pending)
;; before each read so the prompt is visible in an interactive session, and
;; dispatches the dot commands:
;;
;;   - `.exit`            ends the session.
;;   - `.help`            prints the command help to stdout.
;;   - `.type <expr>`     prints the inferred type without running code.
;;   - `.load <file>`     loads declarations into the current session.
;;   - blank line         is skipped at the top level, and cancels a pending
;;                        multiline form (discarding the buffered input).
;;   - any other `.cmd`   reports an unknown command (to stderr).
;;   - declarations       are checked and persisted for later inputs.
;;   - expressions         are checked, compiled as scratch source, and run.
;;
;; Multiline input is accumulated until its delimiters are complete; while a form
;; is pending the prompt shows a `... ` continuation marker and a blank line
;; abandons it. Parse and type errors report diagnostics, discard only the
;; failing input, and return to the prompt with previously accepted declarations
;; intact.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.fs)
(import stdlib.process)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import compiler_typecheck_api)
(import compiler_ast_types as ast)
(import compiler_diagnostic as cdiag)
(import compiler_intern as ci)
(import compiler_load)
(import compiler_optimize as opt)
(import compiler_parse_core as parser)
(import compiler_typecheck_core as tc)
(import build_run_core)
(import stdlib.string)
(import source_text_core as source_text)
(import sym_i64_env)

(defenum ReplTypeCommand
  (No)
  (Expr String))

(defenum ReplLoadCommand
  (No)
  (Path String))

(defenum ReplLineResult
  (Line String String))

(defenum ResultReplString
  (Ok String)
  (Err String))

(defenum ResultReplDeclList
  (Ok ast.AstDeclList)
  (Err (Box cdiag.CompilerDiagnostic)))

(define (repl-banner) : String
  "TypeLisp REPL. Type .help for commands.\n")

(define (repl-help-text) : String
  "TypeLisp REPL commands:\n  .help         Show this help\n  .type <expr>  Print the inferred type without running code\n  .load <file>  Load declarations from a source file\n  .exit         Exit the REPL\n")

(define (repl-stdout-write [text : String]) : unit
  (io.stdout-write (byte_buf.str-as-bytes (& text))))

(define (repl-stdout-write-line [text : String]) : unit
  (io.stdout-write-line (byte_buf.str-as-bytes (& text))))

(define (repl-stderr-write [text : String]) : unit
  (io.stderr-write (byte_buf.str-as-bytes (& text))))

(define (repl-stderr-write-line [text : String]) : unit
  (io.stderr-write-line (byte_buf.str-as-bytes (& text))))

(define (repl-path-join [left : (& left str)] [right : String]) : String
  (fs.path-join left (& right)))

(define (repl-try-remove-file-if-exists [path : String]) : io.ResultIoUnit
  (fs.try-remove-file-if-exists (& path)))

(define (repl-try-remove-dir-if-exists [path : String]) : io.ResultIoUnit
  (fs.try-remove-dir-if-exists (& path)))

;; Print the prompt and flush stdout so it is visible before the blocking read.
;; A pending multiline form shows a `... ` continuation marker (aligned to the
;; 4-column `tl> ` prompt) so it is clear the previous input was not yet complete.
(define (repl-prompt [continuation? : bool]) : unit
  (repl-stdout-write
    (if continuation?
      "... "
      "tl> "))
  (io.stdout-flush))

;; `line` begins with `.` (a dot command). Empty lines are handled safely.
(define (repl-dot-command? [line : (& line str)]) : bool
  (if (> (string.string-length line) 0)
    (= (string.string-ref line 0) '.')
    false))

(define (repl-trim-left-from [text : (& text str)] [start : i64]) : String
  (let
    [i : i64 start]
    [len : i64 (string.string-length text)]
    (while (and
      (< i len)
      (source_text.source-text-space? (string.string-ref text i)))
      (set! i (+ i 1)))
    (if (< i len)
      (string.substring text i (- len i))
      "")))

(define (repl-line-ending? [c : char]) : bool
  (or (= c '\r') (= c '\n')))

(define (repl-leading-utf8-bom? [text : (& text str)]) : bool
  (if (< (string.string-length text) 3)
    false
    (and
      (= (cast (string.string-ref text 0) : i64) 239)
      (= (cast (string.string-ref text 1) : i64) 187)
      (= (cast (string.string-ref text 2) : i64) 191))))

(define (repl-trim-leading-utf8-bom [text : String]) : String
  (if (repl-leading-utf8-bom? text)
    (string.substring text 3 (- (string.string-length text) 3))
    text))

(define (repl-trim-right-line-ending [text : String]) : String
  (let
    [len : i64 (string.string-length text)]
    [end : i64 (string.string-length text)]
    [done : bool false]
    (while (> len 0)
      (if done
        (set! len 0)
        (if (repl-line-ending? (string.string-ref text (- len 1)))
          (begin
            (set! end (- len 1))
            (set! len (- len 1)))
          (set! done true))))
    (string.substring text 0 end)))

(define (repl-normalize-input-line [text : String]) : String
  (repl-trim-right-line-ending (repl-trim-leading-utf8-bom text)))

(define (repl-type-command [line : (& line str)]) : ReplTypeCommand
  (if (source_text.starts-with? line ".type")
    (if (= (string.string-length line) 5)
      (Expr "")
      (if (source_text.source-text-space? (string.string-ref line 5))
        (Expr (repl-trim-left-from line 5))
        (No)))
    (No)))

(define (repl-load-command [line : (& line str)]) : ReplLoadCommand
  (if (source_text.starts-with? line ".load")
    (if (= (string.string-length line) 5)
      (Path "")
      (if (source_text.source-text-space? (string.string-ref line 5))
        (Path (repl-trim-left-from line 5))
        (No)))
    (No)))

(define (repl-type-list-render-spaced-at
  [types : (& types ast.AstTypeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-type-list-len types))
    ""
    (str_cat.str-cat
      " "
      (repl-type-render
        (ast.ty-node-get
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback))))
      (repl-type-list-render-spaced-at types (+ index 1)))))

(define (repl-type-list-render-spaced [types : ast.AstTypeList]) : String
  (repl-type-list-render-spaced-at (& types) 0))

(define (repl-lifetime-list-render-spaced-at
  [lifetimes : (& lifetimes ast.AstLifetimeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-lifetime-list-len lifetimes))
    ""
    (str_cat.str-cat
      " "
      (tc.tc-hygiene-name-text-id
        (ast.ast-lifetime-list-get lifetimes index (ast.ast-lifetime-fallback)))
      (repl-lifetime-list-render-spaced-at lifetimes (+ index 1)))))

(define (repl-lifetime-list-render-spaced [lifetimes : ast.AstLifetimeList]) : String
  (repl-lifetime-list-render-spaced-at (& lifetimes) 0))

(define (repl-type-render [ty : ast.AstType]) : String
  (match ty
    [(I64) "i64"]
    [(I32) "i32"]
    [(I16) "i16"]
    [(I8) "i8"]
    [(U64) "u64"]
    [(U32) "u32"]
    [(U16) "u16"]
    [(U8) "u8"]
    [(F64) "f64"]
    [(F32) "f32"]
    [(Bool) "bool"]
    [(Char) "char"]
    [(String) "String"]
    [(Str) "str"]
    [(Bytes) "bytes"]
    [(Unit) "unit"]
    [(Never) "never"]
    [(Expr) "Expr"]
    [(ExprList) "ExprList"]
    [(Func args ret)
      (str_cat.str-cat
        "(->"
        (repl-type-list-render-spaced (deref args))
        " "
        (repl-type-render (ast.ty-node-get ret))
        ")")]
    [(CFunc signature mode)
      (str_cat.str-cat
        "(CFunc "
        (ast.ast-c-function-mode-name mode)
        " "
        (repl-type-render (ast.ty-node-get signature))
        ")")]
    [(Tuple elems)
      (str_cat.str-cat
        "(Tuple"
        (repl-type-list-render-spaced (deref elems))
        ")")]
    [(Array elem count)
      (str_cat.str-cat
        "(Array "
        (repl-type-render (ast.ty-node-get elem))
        " "
        (string.int->string count)
        ")")]
    [(DynArray elem)
      (str_cat.str-cat
        "(__tl_dyn-array "
        (repl-type-render (ast.ty-node-get elem))
        ")")]
    [(Slice elem)
      (str_cat.str-cat "(Slice " (repl-type-render (ast.ty-node-get elem)) ")")]
    [(Box elem)
      (str_cat.str-cat "(Box " (repl-type-render (ast.ty-node-get elem)) ")")]
    [(Ptr elem)
      (str_cat.str-cat "(Ptr " (repl-type-render (ast.ty-node-get elem)) ")")]
    [(MutPtr elem)
      (str_cat.str-cat "(MutPtr " (repl-type-render (ast.ty-node-get elem)) ")")]
    [(Ref region inner)
      (str_cat.str-cat
        "(& "
        (tc.tc-hygiene-name-text-id region)
        " "
        (repl-type-render (ast.ty-node-get inner))
        ")")]
    [(MutRef region inner)
      (str_cat.str-cat
        "(&mut "
        (tc.tc-hygiene-name-text-id region)
        " "
        (repl-type-render (ast.ty-node-get inner))
        ")")]
    [(Region region inner)
      (str_cat.str-cat
        "(in "
        (tc.tc-hygiene-name-text-id region)
        " "
        (repl-type-render (ast.ty-node-get inner))
        ")")]
    [(Invalidate lifetime inner)
      (str_cat.str-cat
        "(:invalidate "
        (tc.tc-hygiene-name-text-id lifetime)
        " "
        (repl-type-render (ast.ty-node-get inner))
        ")")]
    [(Enum name) (ast.ast-nominal-name-id-display name)]
    [(EnumArgs name lifetimes)
      (str_cat.str-cat
        "("
        (ast.ast-nominal-name-id-display name)
        (repl-lifetime-list-render-spaced (deref lifetimes))
        ")")]
    [(Struct name) (ast.ast-nominal-name-id-display name)]
    [(StructArgs name lifetimes)
      (str_cat.str-cat
        "("
        (ast.ast-nominal-name-id-display name)
        (repl-lifetime-list-render-spaced (deref lifetimes))
        ")")]
    [(Var name) (str_cat.str-cat "'" (ci.intern-str name) "'")]
    [(VarArgs name lifetimes)
      (str_cat.str-cat
        "("
        (ci.intern-str name)
        (repl-lifetime-list-render-spaced (deref lifetimes))
        ")")]))

(define (repl-print-error-line [message : String]) : unit
  (repl-stderr-write-line message))

(define (repl-input-path) : String
  "<repl>")

;; A parse or type error in the input just read is located in that input: the
;; report names it `<repl>` and quotes the offending line.
(define (repl-report-input-diagnostic
  [diag : cdiag.CompilerDiagnostic]
  [input : String]) : unit
  (repl-stderr-write
    (cdiag.compiler-diagnostic-render-source
      (cdiag.compiler-diagnostic-with-path diag (repl-input-path))
      input)))

;; A candidate is the accepted session followed by new source: typed input,
;; named `<repl>`, or a loaded file, named by its path. The session already
;; typechecked on its own, so a candidate error normally lies in the new source
;; and is reported there, counted from its first line with that line quoted. A
;; location inside the session stays there, as `<repl-session>`, quoting the
;; session's own line.
(define (repl-report-candidate-diagnostics
  [diagnostics : cdiag.CompilerDiagnosticList]
  [session-source : String]
  [source-path : String]
  [source : String]) : unit
  (let
    [session-end : source_text.SourceTextLineCol
      (source_text.source-text-line-col-at-offset
        (& session-source)
        (string.string-length session-source)
        false)]
    [session-lines : i64 (- session-end.line 1)]
    [count : i64 (cdiag.compiler-diagnostic-list-count diagnostics)]
    [index : i64 0]
    (while (< index count)
      (let
        [diag : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-split-at-line
            (cdiag.compiler-diagnostic-list-get diagnostics index)
            (repl-session-source-path)
            session-lines
            "<repl-session>"
            (owned_view.compiler-owned-shared-view source-path))]
        [in-source : bool
          (string.eq (cdiag.compiler-diagnostic-path diag) source-path)]
        (repl-stderr-write
          (cdiag.compiler-diagnostic-render-source
            diag
            (if in-source
              (owned_view.compiler-owned-shared-view source)
              (owned_view.compiler-owned-shared-view session-source))))
        (set! index (+ index 1))))))

(define (repl-char-display-helpers-source) : String
  "(define __tl_repl_ascii_printable_table : String
  \" !\\\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\")

(define (__tl_repl_char_string [c : char]) : String
  (let
    [code : i64 (cast c : i64)]
    (if (= code 9)
      \"\t\"
      (if (= code 10)
        \"
\"
        (if (= code 13)
          \"\r\"
          (if (and (>= code 32) (<= code 126))
            (string.substring __tl_repl_ascii_printable_table (- code 32) 1)
            \"?\"))))))

(define (__tl_repl_print_char [c : char]) : unit
  (begin
    (io.print-format \"{}\" (__tl_repl_char_string c))
    (io.println \"\")))

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
      (io.print-format \"{}\" (string.int->string (/ value divisor)))
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
      (io.print-format \"{}\" (string.int->string shown-whole))
      (if (= scaled 0)
        unit
        (let
          [trimmed : i64 (__tl_repl_trim_fraction_value scaled)]
          [divisor : i64 (__tl_repl_trim_fraction_divisor scaled 100000)]
          (begin
            (io.print-format \"{}\" \".\")
            (__tl_repl_print_fraction_digits trimmed divisor))))
      (io.println \"\"))))

(define (__tl_repl_print_f64 [x : f64]) : unit
  (if (< x 0.0)
    (begin
      (io.print-format \"{}\" \"-\")
      (__tl_repl_print_f64_positive (- 0.0 x)))
    (__tl_repl_print_f64_positive x)))

")

(define (repl-display-helpers-source [ty : ast.AstType]) : String
  (match ty
    [(F64) (repl-f64-display-helpers-source)]
    [(F32) (repl-f64-display-helpers-source)]
    [(Char) (repl-char-display-helpers-source)]
    [_ ""]))

(define (repl-aggregate-display-body [ty : ast.AstType] [expr-source : String]) : String
  (str_cat.str-cat
    "(begin\n  "
    expr-source
    "\n  (io.print-format \"{}\" \"<value: "
    (repl-type-render ty)
    ">\")\n  (io.println \"\"))"))

(define (repl-display-body [ty : ast.AstType] [expr-source : String]) : ResultReplString
  (match (owned_view.compiler-owned-shared-view ty)
    [(I64) (Ok (str_cat.str-cat "(io.println \"{}\"\n" expr-source "\n)"))]
    [(I32)
      (Ok
        (str_cat.str-cat
          "(io.println \"{}\"\n(cast\n"
          expr-source
          "\n: i64)\n)"))]
    [(Bool) (Ok (str_cat.str-cat "(io.println \"{}\"\n" expr-source "\n)"))]
    [(F64) (Ok (str_cat.str-cat "(__tl_repl_print_f64\n" expr-source "\n)"))]
    [(F32)
      (Ok
        (str_cat.str-cat
          "(__tl_repl_print_f64\n(cast\n"
          expr-source
          "\n: f64)\n)"))]
    [(Char) (Ok (str_cat.str-cat "(__tl_repl_print_char\n" expr-source "\n)"))]
    [(String)
      (Ok
        (str_cat.str-cat
          "(begin\n  (io.print-format \"{}\"\n"
          expr-source
          "\n  )\n  (io.println \"\"))"))]
    [(Unit) (Ok expr-source)]
    [(Tuple _) (Ok (repl-aggregate-display-body ty expr-source))]
    [(Array _ _) (Ok (repl-aggregate-display-body ty expr-source))]
    [(Enum _) (Ok (repl-aggregate-display-body ty expr-source))]
    [(EnumArgs _ _) (Ok (repl-aggregate-display-body ty expr-source))]
    [(Struct _) (Ok (repl-aggregate-display-body ty expr-source))]
    [(StructArgs _ _) (Ok (repl-aggregate-display-body ty expr-source))]
    [_
      (Err
        (str_cat.str-cat
          "Error: cannot display a value of type "
          (repl-type-render ty)))]))

(define (repl-scratch-main-source [body : String]) : String
  (str_cat.str-cat "(define (main) : i64\n  (begin\n    " body "\n    0))\n"))

(define (repl-scratch-source
  [session-source : String]
  [expr-source : String]
  [ty : ast.AstType]) : ResultReplString
  (match (repl-display-body
    (owned_view.compiler-owned-shared-view ty)
    expr-source)
    [(Ok body)
      (Ok
        (str_cat.str-cat
          "(import stdlib.io)\n(import stdlib.string)\n"
          session-source
          "\n"
          (repl-display-helpers-source ty)
          (repl-scratch-main-source body)))]
    [(Err message) (Err message)]))

(define (repl-scratch-cleanup-error-class [error : io.IoError]) : String
  (match error
    [(IoNotFound _) "not-found"]
    [(IoPermissionDenied _) "permission-denied"]
    [(IoInvalidPath _) "invalid-path"]
    [(IoUnsupported _) "unsupported"]
    [(IoInterrupted _) "interrupted"]
    [(IoSystemCode _ _) "system-error"]
    [(IoUnknown _) "unknown"]))

;; Error payloads can contain the randomized scratch path. Only fixed class
;; names and caller-owned component labels may reach the REPL diagnostic.
(define (repl-scratch-cleanup-message
  [component : String]
  [result : io.ResultIoUnit]) : String
  (match result
    [(OkIoUnit) ""]
    [(ErrIoUnit error)
      (str_cat.str-cat
        "repl: scratch "
        component
        " cleanup failed ("
        (repl-scratch-cleanup-error-class error)
        ")")]))

(define (repl-scratch-cleanup-report-text
  [file-result : io.ResultIoUnit]
  [dir-result : io.ResultIoUnit]) : String
  (let
    [file-message : String (repl-scratch-cleanup-message "file" file-result)]
    [dir-message : String (repl-scratch-cleanup-message "directory" dir-result)]
    (str_cat.str-cat
      (if (string.eq file-message "")
        ""
        (str_cat.str-cat file-message "\n"))
      (if (string.eq dir-message "")
        ""
        (str_cat.str-cat dir-message "\n")))))

(define (repl-report-scratch-cleanup-results
  [file-result : io.ResultIoUnit]
  [dir-result : io.ResultIoUnit]) : unit
  (let
    [report : String (repl-scratch-cleanup-report-text file-result dir-result)]
    (if (string.eq report "")
      unit
      (repl-stderr-write report))))

(define (repl-session-source-path) : String
  "repl-session.tl")

(define (repl-load-session-decls [session-source : String]) : ResultReplDeclList
  (match (compiler_load.compiler-load-source
    (repl-session-source-path)
    session-source
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _) (Ok decls)]
    [(Err diag) (Err diag)]))

(define (repl-typecheck-session-source [session-source : String]) : tc.ResultCompilerTypecheck
  (match (repl-load-session-decls session-source)
    [(Ok decls)
      (compiler_typecheck_api.typecheck-compiler-program
        (ast.ast-program decls))]
    [(Err diag) (Err (cdiag.compiler-diagnostic-list-box-single diag))]))

(define (repl-run-status-report-text [status : i64]) : String
  (if (= status 0)
    ""
    (str_cat.str-cat
      "\nREPL evaluation exited with status "
      (string.int->string status)
      "\n")))

(define (repl-run-and-scratch-cleanup-report-text
  [status : i64]
  [file-result : io.ResultIoUnit]
  [dir-result : io.ResultIoUnit]) : String
  (str_cat.str-cat
    (repl-run-status-report-text status)
    (repl-scratch-cleanup-report-text file-result dir-result)))

(define (repl-report-run-and-scratch-cleanup-results
  [status : i64]
  [file-result : io.ResultIoUnit]
  [dir-result : io.ResultIoUnit]) : unit
  (let
    [report : String
      (repl-run-and-scratch-cleanup-report-text status file-result dir-result)]
    (if (string.eq report "")
      unit
      (repl-stderr-write report))))

(define (repl-run-scratch-source [source : String]) : unit
  (match (build_run_core.source-tool-create-temp-dir "typelisp-repl")
    [(Ok temp-dir)
      (let
        [source-path : String (repl-path-join temp-dir "repl_expr.tl")]
        (match (build_run_core.source-tool-write-file
          source-path
          source
          "repl: failed to write scratch source")
          [(Err message)
            (repl-print-error-line message)
            (let
              [file-result : io.ResultIoUnit
                (repl-try-remove-file-if-exists source-path)]
              [dir-result : io.ResultIoUnit
                (repl-try-remove-dir-if-exists temp-dir)]
              (repl-report-scratch-cleanup-results file-result dir-result))]
          [(Ok)
            (let
              [status : i64
                (build_run_core.source-tool-run-source-in-temp
                  (owned_view.compiler-owned-shared-view source-path)
                  (build_run_core.source-tool-default-target)
                  (cli_svec.new)
                  (cli_svec.new)
                  (process.args-empty)
                  (opt.compiler-optimize-default-level)
                  (Scalar)
                  (build_run_core.source-tool-link-inputs-empty)
                  false
                  (owned_view.compiler-owned-shared-view temp-dir))]
              [file-result : io.ResultIoUnit
                (repl-try-remove-file-if-exists source-path)]
              [dir-result : io.ResultIoUnit
                (repl-try-remove-dir-if-exists temp-dir)]
              (repl-report-run-and-scratch-cleanup-results
                status
                file-result
                dir-result))]))]
    [(Err message)
      (repl-print-error-line
        (str_cat.str-cat "repl: failed to create scratch temp dir: " message))]))

(define (repl-evaluate-expr
  [session-source : String]
  [expr-source : String]
  [expr : ast.AstExpr]) : unit
  (match (repl-load-session-decls
    (owned_view.compiler-owned-shared-view session-source))
    [(Ok decls)
      (match (compiler_typecheck_api.typecheck-compiler-repl-expr decls expr)
        [(Ok ty)
          (match (repl-scratch-source session-source expr-source ty)
            [(Ok scratch-source) (repl-run-scratch-source scratch-source)]
            [(Err message) (repl-print-error-line message)])]
        [(Err message)
          (repl-report-input-diagnostic
            (tc.tc-diag-at-start message)
            expr-source)])]
    [(Err diag)
      (repl-print-error-line
        (str_cat.str-cat
          "Error: "
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))))]))

(define (repl-handle-type-command
  [session-source : String]
  [expr-source : String]) : unit
  (if (string.eq expr-source "")
    (repl-print-error-line "Error: .type expects an expression")
    (match (parser.parse-ast-repl-source
      (owned_view.compiler-owned-shared-view expr-source))
      [(Ok item)
        (match item
          [(AstReplDecl _)
            (repl-print-error-line
              "Error: .type expects an expression, got a declaration")]
          [(AstReplExpr expr)
            (match (repl-load-session-decls session-source)
              [(Ok decls)
                (match (compiler_typecheck_api.typecheck-compiler-repl-expr
                  decls
                  (ast.ast-node-get expr))
                  [(Ok ty) (repl-stdout-write-line (repl-type-render ty))]
                  [(Err message)
                    (repl-report-input-diagnostic
                      (tc.tc-diag-at-start message)
                      expr-source)])]
              [(Err diag)
                (repl-print-error-line
                  (str_cat.str-cat
                    "Error: "
                    (cdiag.compiler-diagnostic-message (__tl-box-place diag))))])])]
      [(Err diag) (repl-report-input-diagnostic (deref diag) expr-source)])))

(define (repl-session-candidate [session-source : String] [input : String]) : String
  (str_cat.str-cat session-source input "\n"))

(define (repl-handle-load-command [session-source : String] [path : String]) : String
  (if (string.eq path "")
    (begin
      (repl-print-error-line "Error: .load expects a file path")
      session-source)
    (match (io.try-read-file (& path))
      [(OkIoBytes contents)
        (let
          [source : String (byte_buf.to-string contents)]
          [candidate : String
            (repl-session-candidate
              (owned_view.compiler-owned-shared-view session-source)
              (owned_view.compiler-owned-shared-view source))]
          (match (repl-typecheck-session-source
            (owned_view.compiler-owned-shared-view candidate))
            [(Ok _)
              (repl-stdout-write-line (str_cat.str-cat "Loaded " path))
              candidate]
            [(Err diag)
              (repl-report-candidate-diagnostics
                (deref diag)
                (owned_view.compiler-owned-shared-view session-source)
                path
                source)
              session-source]))]
      [(ErrIoBytes error)
        (repl-print-error-line
          (str_cat.str-cat "Error: .load failed: " (io.error-message error)))
        session-source])))

(define (repl-handle-input [session-source : String] [input : String]) : String
  (match (parser.parse-ast-repl-source
    (owned_view.compiler-owned-shared-view input))
    [(Ok item)
      (match item
        [(AstReplDecl _)
          (let
            [candidate : String
              (repl-session-candidate
                (owned_view.compiler-owned-shared-view session-source)
                (owned_view.compiler-owned-shared-view input))]
            (match (repl-typecheck-session-source
              (owned_view.compiler-owned-shared-view candidate))
              [(Ok _) candidate]
              [(Err diag)
                (repl-report-candidate-diagnostics
                  (deref diag)
                  (owned_view.compiler-owned-shared-view session-source)
                  (repl-input-path)
                  input)
                session-source]))]
        [(AstReplExpr expr)
          (repl-evaluate-expr
            (owned_view.compiler-owned-shared-view session-source)
            input
            (ast.ast-node-get expr))
          session-source])]
    [(Err diag)
      (repl-report-input-diagnostic (deref diag) input)
      session-source]))

;; Completeness tracking is a delimiter check: strings, comments, and char
;; literals do not count delimiters; unmatched closing delimiters are considered
;; complete so parsing can report the real error and the session can recover.
(define (repl-skip-comment [text : (& text str)] [idx : i64] [len : i64]) : i64
  (if (>= idx len)
    idx
    (if (= (string.string-ref text idx) '\n')
      (+ idx 1)
      (repl-skip-comment text (+ idx 1) len))))

(define (repl-skip-char-literal [text : (& text str)] [idx : i64] [len : i64]) : i64
  (if (>= idx len)
    idx
    (if (= (string.string-ref text idx) '\'')
      (+ idx 1)
      (repl-skip-char-literal text (+ idx 1) len))))

(define (repl-input-complete-loop
  [text : (& text str)]
  [idx : i64]
  [len : i64]
  [parens : i64]
  [brackets : i64]
  [in-string : bool]
  [escaped : bool]) : bool
  (if (>= idx len)
    (and (not in-string) (= parens 0) (= brackets 0))
    (let
      [c : char (string.string-ref text idx)]
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
            [(= c '\\')
              (repl-input-complete-loop
                text
                (+ idx 1)
                len
                parens
                brackets
                true
                true)]
            [(= c '"')
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
        [(= c ';')
          (repl-input-complete-loop
            text
            (repl-skip-comment text (+ idx 1) len)
            len
            parens
            brackets
            false
            false)]
        [(= c '"')
          (repl-input-complete-loop
            text
            (+ idx 1)
            len
            parens
            brackets
            true
            false)]
        [(= c '\'')
          (repl-input-complete-loop
            text
            (source_text.source-text-skip-char-literal text idx len)
            len
            parens
            brackets
            false
            false)]
        [(= c '#')
          (repl-input-complete-loop
            text
            (repl-skip-char-literal text (+ idx 1) len)
            len
            parens
            brackets
            false
            false)]
        [(= c '(')
          (repl-input-complete-loop
            text
            (+ idx 1)
            len
            (+ parens 1)
            brackets
            false
            false)]
        [(= c '[')
          (repl-input-complete-loop
            text
            (+ idx 1)
            len
            parens
            (+ brackets 1)
            false
            false)]
        [(= c ')')
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
        [(= c ']')
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

(define (repl-input-complete? [input : (& input str)]) : bool
  (repl-input-complete-loop
    input
    0
    (string.string-length input)
    0
    0
    false
    false))

(define (repl-append-pending [pending : String] [line : String]) : String
  (if (string.eq pending "")
    line
    (str_cat.str-cat pending "\n" line)))

(define (repl-handle-source-line
  [session-source : String]
  [pending : String]
  [line : String]) : ReplLineResult
  (let
    [next-pending : String (repl-append-pending pending line)]
    (if (repl-input-complete? next-pending)
      (Line (repl-handle-input session-source next-pending) "")
      (Line session-source next-pending))))

;; Handle one non-`.exit` command line. When a multiline input is pending, all
;; following lines are treated as source until the form is complete.
(define (repl-handle-line
  [session-source : String]
  [pending : String]
  [line : String]) : ReplLineResult
  (if (string.eq pending "")
    (if (string.eq line "")
      (Line session-source "")
      (match (repl-type-command line)
        [(Expr expr-source)
          (repl-handle-type-command
            (owned_view.compiler-owned-shared-view session-source)
            expr-source)
          (Line session-source "")]
        [(No)
          (match (repl-load-command line)
            [(Path path)
              (Line (repl-handle-load-command session-source path) "")]
            [(No)
              (if (string.eq line ".help")
                (begin
                  (repl-stdout-write (repl-help-text))
                  (Line session-source ""))
                (if (repl-dot-command? line)
                  (begin
                    (repl-stderr-write
                      (str_cat.str-cat "Unknown REPL command: " line))
                    (repl-stderr-write "\nType .help for commands.\n")
                    (Line session-source ""))
                  (repl-handle-source-line session-source pending line)))])]))
    (repl-handle-source-line session-source pending line)))

;; The REPL loop: prompt, then read and dispatch until `.exit` or end of input.
;; While a multiline form is pending the prompt becomes a `... ` continuation
;; marker, and a blank line (Enter on an empty line, as distinct from EOF)
;; discards the pending buffer and returns to the top-level prompt.
(define (repl-loop [session-source : String] [pending : String]) : unit
  (let
    [pending? : bool (not (string.eq pending ""))]
    (repl-prompt pending?)
    (if (io.stdin-at-eof?)
      (if pending?
        (repl-stderr-write "Error: incomplete REPL input at EOF\n")
        unit)
      (let
        [line-read : io.StdinRead (io.stdin-read-line)]
        [line : String
          (repl-normalize-input-line
            (byte_buf.to-string
              (io.stdin-read-buffer
                (owned_view.compiler-owned-shared-view line-read))))]
        (if (and (not pending?) (string.eq line ".exit"))
          unit
          ;; A blank line while a form is pending cancels it. Guard on the
          ;; read's EOF flag so an EOF-induced empty read is not mistaken for a
          ;; user-entered blank line (that path still reports incomplete-at-EOF).
          (if (and
            pending?
            (string.eq line "")
            (not (io.stdin-read-eof? line-read)))
            (repl-loop session-source "")
            (match (repl-handle-line session-source pending line)
              [(Line next-session next-pending)
                (repl-loop next-session next-pending)])))))))

(define (repl-run) : i64
  (repl-stdout-write (repl-banner))
  (repl-loop "" "")
  0)

(define (repl-run-from [start : i64] [count : i64]) : i64
  (if (< start count)
    (begin
      (io.print-error "Error: repl does not accept arguments\n")
      1)
    (repl-run)))