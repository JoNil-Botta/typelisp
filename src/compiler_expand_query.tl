;; compiler_expand_query.tl - The macro-expansion inspection query shared by
;; `typelisp expand` and LSP `tl/expandMacro` (#7067).
;;
;; One query checks a source exactly as `typelisp check` does, then reads the
;; checked program: every expression macro invocation leaves a
;; `Spanned(MacroExpansion produced provenance name)` node at its call site,
;; whose provenance records the invoking and defining source paths. The query
;; selects the innermost invocation in the checked source that covers a
;; position, reports the ordered frames from the outermost invocation to it,
;; and renders its checked expansion as source text. It reuses the production
;; expansion pipeline and never evaluates a transformer of its own.
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import sym_i64_env)
(import token)
(import read as reader)
(import compiler_owned_view as owned_view)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_diagnostic as cdiag)
(import compiler_load as cload)
(import compiler_parse_core as parse_core)
(import compiler_check_core as check_core)
(import compiler_typecheck_core as tc)
(import compiler_typecheck_api as tc_api)
(import format_rules)
(import doc_expand)

;: One macro invocation on the path to the selected one: the macro's name, the
;: source path that defines it, and the invocation's span (1-based, exclusive
;: end) in the inspected source.
(defstruct CompilerExpandFrame
  (macro-name String)
  (module-path String)
  (start-line i64)
  (start-col i64)
  (end-line i64)
  (end-col i64))

;: Frames from the outermost invocation to the selected, innermost one, six
;: words each: macro name id, provenance id and the span's four coordinates.
(defstruct CompilerExpandFrames
  (slots (__tl_dyn-array i64))
  (len i64))

(define compiler-expand-frame-words : i64
  6)

;: `Expanded` carries the frames, the rendered expansion, and whether the
;: rendering stopped at the byte limit. Diagnostics of a source that does not
;: fully check travel with the answer: an expansion that fails to typecheck is
;: exactly the one worth inspecting.
(defenum CompilerExpandQueryResult
  (Expanded CompilerExpandFrames String bool cdiag.CompilerDiagnosticList)
  (NotFound cdiag.CompilerDiagnosticList)
  (Failed cdiag.CompilerDiagnosticList))

;; The default bound on rendered expansion text.
(define compiler-expand-default-max-bytes : i64
  65536)

(define (compiler-expand-frames-new) : CompilerExpandFrames
  (CompilerExpandFrames
    (__tl_make-array i64 (* 4 compiler-expand-frame-words))
    0))

(define (compiler-expand-frames-push!
  [frames : (&mut frames CompilerExpandFrames)]
  [name-id : i64]
  [provenance : i64]
  [span : ast.AstSourceSpan]) : unit
  (let
    [base : i64 (* frames.len compiler-expand-frame-words)]
    (when
      (> (+ base compiler-expand-frame-words) (array-length frames.slots))
      (let
        [grown : (__tl_dyn-array i64)
          (__tl_make-array i64 (* 2 (array-length frames.slots)))]
        [index : i64 0]
        (while (< index base)
          (set! (array-ref grown index) (array-ref frames.slots index))
          (set! index (+ index 1)))
        (set! frames.slots grown)))
    (set! (array-ref frames.slots base) name-id)
    (set! (array-ref frames.slots (+ base 1)) provenance)
    (set! (array-ref frames.slots (+ base 2)) (cast span.start-line : i64))
    (set! (array-ref frames.slots (+ base 3)) (cast span.start-col : i64))
    (set! (array-ref frames.slots (+ base 4)) (cast span.end-line : i64))
    (set! (array-ref frames.slots (+ base 5)) (cast span.end-col : i64))
    (set! frames.len (+ frames.len 1))))

(define (compiler-expand-frames-copy [frames : (& frames CompilerExpandFrames)]) : CompilerExpandFrames
  (let
    [words : i64 (* frames.len compiler-expand-frame-words)]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 (+ words 1))]
    [index : i64 0]
    (while (< index words)
      (set! (array-ref slots index) (array-ref frames.slots index))
      (set! index (+ index 1)))
    (CompilerExpandFrames slots frames.len)))

;: Frame `index`, 0 being the outermost.
(define (compiler-expand-frame-ref
  [frames : (& frames CompilerExpandFrames)]
  [index : i64]) : CompilerExpandFrame
  (let
    [base : i64 (* index compiler-expand-frame-words)]
    [origin-path-id : i64
      (tc.macro-expansion-origin-path-id (array-ref frames.slots (+ base 1)))]
    (CompilerExpandFrame
      (ci.intern-str (array-ref frames.slots base))
      (if (< origin-path-id 0)
        ""
        (ci.intern-str origin-path-id))
      (array-ref frames.slots (+ base 2))
      (array-ref frames.slots (+ base 3))
      (array-ref frames.slots (+ base 4))
      (array-ref frames.slots (+ base 5)))))

;; Whether 1-based `line`:`col` lies in `span`, whose end is exclusive.
(define (compiler-expand-span-covers?
  [span : ast.AstSourceSpan]
  [line : i64]
  [col : i64]) : bool
  (let
    [start-line : i64 (cast span.start-line : i64)]
    [start-col : i64 (cast span.start-col : i64)]
    [end-line : i64 (cast span.end-line : i64)]
    [end-col : i64 (cast span.end-col : i64)]
    (and
      (or (> line start-line) (and (= line start-line) (>= col start-col)))
      (or (< line end-line) (and (= line end-line) (< col end-col))))))

;; --- finding the invocation ------------------------------------------------
(defstruct CompilerExpandWalk
  (expr-bases i64)
  (path-id i64)
  (line i64)
  (col i64)
  (frames CompilerExpandFrames)
  (best CompilerExpandFrames)
  (best-produced i64))

;; Walk expression `id`. A call-site `Spanned(MacroExpansion ...)` node of the
;; inspected source that covers the position pushes a frame for its subtree;
;; the deepest one seen is the selection. Argument syntax a macro splices back
;; keeps its own invocations, so a covering nested invocation is found inside
;; the produced expression.
(define (compiler-expand-walk!
  [walk : (&mut walk CompilerExpandWalk)]
  [id : i64]) : unit
  (let
    [expr : ast.AstExpr (ast.ast-expr-segment-bases-get walk.expr-bases id)]
    [pushed? : bool false]
    (match (& expr)
      [(Spanned inner span)
        (match (ast.ast-expr-segment-bases-get walk.expr-bases inner)
          [(MacroExpansion produced provenance name-id)
            (when
              (and
                (>= name-id 0)
                (=
                  (tc.macro-expansion-invocation-path-id provenance)
                  walk.path-id)
                (compiler-expand-span-covers? span walk.line walk.col))
              (compiler-expand-frames-push!
                (&mut walk.frames)
                name-id
                provenance
                span)
              (set! pushed? true)
              (when
                (> walk.frames.len walk.best.len)
                (set! walk.best (compiler-expand-frames-copy (& walk.frames)))
                (set! walk.best-produced produced)))]
          [_ unit])]
      [_ unit])
    (let
      [children : ast.AstExprList (ast.ast-expr-child-ids expr)]
      [index : i64 0]
      (while (< index (ast.ast-expr-list-len (& children)))
        (compiler-expand-walk!
          walk
          (ast.ast-expr-list-get (& children) index -1))
        (set! index (+ index 1))))
    (when pushed? (set! walk.frames.len (- walk.frames.len 1)))))

(define (compiler-expand-walk-decl!
  [walk : (&mut walk CompilerExpandWalk)]
  [decl : ast.AstDecl]) : unit
  (match decl
    [(Def _ _ _ body) (compiler-expand-walk! walk body)]
    [(DefFn _ _ _ _ body _) (compiler-expand-walk! walk body)]
    [(Test _ body _ _) (compiler-expand-walk! walk body)]
    [(Unsafe inner) (compiler-expand-walk-decl! walk (deref inner))]
    [(ModuleBody _ inner)
      (compiler-expand-walk-decls!
        walk
        (ast.ast-decl-list-box-shared-view inner))]
    [_ unit]))

(define (compiler-expand-walk-decls!
  [walk : (&mut walk CompilerExpandWalk)]
  [decls : ast.AstDeclList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast.ast-decl-list-len (& decls)))
      (compiler-expand-walk-decl!
        walk
        (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback)))
      (set! index (+ index 1)))))

;; --- rendering -------------------------------------------------------------
(defstruct CompilerExpandText
  (buf text_buf.TextBuf)
  (remaining i64)
  (truncated bool))

(define (compiler-expand-text-append!
  [out : (&mut out CompilerExpandText)]
  [chunk : String]) : unit
  (unless
    out.truncated
    (if (> (string.string-length (& chunk)) out.remaining)
      (set! out.truncated true)
      (begin
        (set! out.remaining (- out.remaining (string.string-length (& chunk))))
        (set!
          out.buf
          (text_buf.append (replace! out.buf (text_buf.empty)) chunk))))))

(define (compiler-expand-string-literal [text : String]) : String
  (let
    [buf : text_buf.TextBuf (text_buf.append (text_buf.empty) "\"")]
    [index : i64 0]
    [count : i64 (string.string-length (& text))]
    (while (< index count)
      (let
        [c : char (string.char-at (& text) index)]
        (set!
          buf
          (cond
            [(= c '"') (text_buf.append buf "\\\"")]
            [(= c '\\') (text_buf.append buf "\\\\")]
            [(= c '\n') (text_buf.append buf "\\n")]
            [(= c '\t') (text_buf.append buf "\\t")]
            [(= c '\r') (text_buf.append buf "\\r")]
            [else (text_buf.append-char buf c)])))
      (set! index (+ index 1)))
    (text_buf.render (text_buf.append buf "\""))))

(define (compiler-expand-char-literal [c : char]) : String
  (cond
    [(= c '\n') "'\\n'"]
    [(= c '\t') "'\\t'"]
    [(= c '\r') "'\\r'"]
    [(= c '\0') "'\\0'"]
    [(= c '\\') "'\\\\'"]
    [(= c '\'') "'\\''"]
    [else
      (text_buf.render
        (text_buf.append
          (text_buf.append-char (text_buf.append (text_buf.empty) "'") c)
          "'"))]))

(define (compiler-expand-sexpr-items!
  [out : (&mut out CompilerExpandText)]
  [names : doc_expand.DocExpandContext]
  [items : (& program (Slice reader.SpannedSexpr))]
  [open : String]
  [close : String]) : unit
  (compiler-expand-text-append! out open)
  (compiler-expand-sexpr-each! out names items false)
  (compiler-expand-text-append! out close))

(define (compiler-expand-sexpr-each!
  [out : (&mut out CompilerExpandText)]
  [names : doc_expand.DocExpandContext]
  [items : (& program (Slice reader.SpannedSexpr))]
  [separate? : bool]) : unit
  (match items
    [(slice) unit]
    [(slice item & rest)
      (unless
        out.truncated
        (when separate? (compiler-expand-text-append! out " "))
        (compiler-expand-sexpr! out names item)
        (compiler-expand-sexpr-each! out names rest true))]))

;; Write `s` in reader syntax: the text reads back as the same form. Names
;; resolve through the checked session, so hygiene-renamed and structural names
;; render as `typelisp doc` renders them.
(define (compiler-expand-sexpr!
  [out : (&mut out CompilerExpandText)]
  [names : doc_expand.DocExpandContext]
  [s : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-slice-view s)
    [(Int n text _)
      (compiler-expand-text-append!
        out
        (if (> (string.string-length (& text)) 0)
          text
          (string.int->string n)))]
    [(Sym name _)
      (compiler-expand-text-append!
        out
        (doc_expand.doc-expand-name-text names (ci.intern-syntax-id-value name)))]
    [(List items _) (compiler-expand-sexpr-items! out names items "(" ")")]
    [(BracketList items _)
      (compiler-expand-sexpr-items! out names items "[" "]")]
    [(Str text-id _)
      (compiler-expand-text-append!
        out
        (compiler-expand-string-literal (ci.intern-id-str text-id)))]
    [(Char c _)
      (compiler-expand-text-append! out (compiler-expand-char-literal c))]
    [(Float text _) (compiler-expand-text-append! out text)]))

;; The expansion `produced` as source text no longer than `max-bytes`. The
;; formatter's layout is used only when it fits too: its line breaks and
;; indentation make it longer than the one-line rendering, which is kept
;; otherwise.
(define (compiler-expand-render
  [ctx : tc.TcContext]
  [produced : i64]
  [frame : CompilerExpandFrame]
  [max-bytes : i64]) : CompilerExpandText
  (let
    [owner : tc.MacroSexprOwner
      (tc.macro-sexpr-owner
        (tc.tc-context-expr-bases ctx)
        (tc.tc-context-structural-session ctx))]
    [names : doc_expand.DocExpandContext
      (doc_expand.DocExpandContext
        (tc.tc-context-expr-bases ctx)
        (ast.ast-node-pool-context-type-segment-bases
          (tc.tc-context-pools-ref (& ctx)))
        (tc.tc-context-source-names ctx))]
    [out : CompilerExpandText
      (CompilerExpandText (text_buf.empty) max-bytes false)]
    (match (tc.macro-child-to-spanned-sexpr
      (& owner)
      produced
      (token.SourceSpan
        frame.start-line
        frame.start-col
        frame.end-line
        frame.end-col)
      (ast.ast-expr-segment-bases-get (tc.tc-context-expr-bases ctx) produced))
      [(Ok sexpr)
        (compiler-expand-sexpr! (&mut out) names sexpr)
        (if out.truncated
          out
          (match (format_rules.format-rules-render-source-width-result
            (text_buf.render out.buf)
            80)
            [(Ok formatted)
              (let
                [length : i64 (string.string-length (& formatted))]
                (if (> length max-bytes)
                  out
                  (CompilerExpandText
                    (text_buf.append (text_buf.empty) formatted)
                    (- max-bytes length)
                    false)))]
            [(Err _) out]))]
      [(Err diag)
        (CompilerExpandText
          (text_buf.append
            (text_buf.empty)
            (str_cat.str-cat
              "; expansion cannot be rendered: "
              (cdiag.compiler-diagnostic-message (deref diag))))
          max-bytes
          false)])))

;; --- the query -------------------------------------------------------------
(define (compiler-expand-select
  [ctx : tc.TcContext]
  [path : String]
  [line : i64]
  [col : i64]
  [max-bytes : i64]
  [diagnostics : cdiag.CompilerDiagnosticList]) : CompilerExpandQueryResult
  (let
    [walk : CompilerExpandWalk
      (CompilerExpandWalk
        (tc.tc-context-expr-bases ctx)
        (ci.intern path)
        line
        col
        (compiler-expand-frames-new)
        (compiler-expand-frames-new)
        -1)]
    (compiler-expand-walk-decls!
      (&mut walk)
      (match (tc.tc-context-program ctx)
        [(Program decls-box) (deref decls-box)]))
    (if (= walk.best.len 0)
      (NotFound diagnostics)
      (let
        [rendered : CompilerExpandText
          (compiler-expand-render
            ctx
            walk.best-produced
            (compiler-expand-frame-ref (& walk.best) (- walk.best.len 1))
            max-bytes)]
        (Expanded
          walk.best
          (text_buf.render rendered.buf)
          rendered.truncated
          diagnostics)))))

(define (compiler-expand-loaded
  [path : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [loaded : cload.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [line : i64]
  [col : i64]
  [max-bytes : i64]) : CompilerExpandQueryResult
  (match loaded
    [(Ok entry-decls entry-paths entry-modules _)
      (match (tc_api.typecheck-compiler-program-with-paths-checked-cache
        (ast.ast-program
          (cload.compiler-load-decl-list-append prelude-decls entry-decls))
        (cload.compiler-load-decl-path-list-append
          prelude-paths
          (ast.ast-decl-path-list-with-modules entry-paths entry-modules))
        stdlib-roots
        cfgs
        "typecheck-prefix-expand")
        [(Ok _ ctx _ _)
          (compiler-expand-select
            ctx
            path
            line
            col
            max-bytes
            (cdiag.compiler-diagnostic-list-empty))]
        [(Partial diagnostics ctx _ _)
          (compiler-expand-select
            ctx
            path
            line
            col
            max-bytes
            (deref diagnostics))]
        [(Err diagnostics) (Failed (deref diagnostics))])]
    [(Err diag) (Failed (cdiag.compiler-diagnostic-list-single (deref diag)))]))

;: Check `source` (read from `path`) with the core macro prelude and select the
;: innermost macro invocation in it that covers 1-based `line`:`col`.
(define (compiler-expand-source-at
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [line : i64]
  [col : i64]
  [max-bytes : i64]) : CompilerExpandQueryResult
  (check_core.compiler-check-reset-pools!)
  (match (cload.compiler-load-core-macro-prelude-with-roots-cfg
    (sym_i64_env.sym-i64-empty)
    (owned_view.compiler-owned-shared-view stdlib-roots)
    cfgs)
    [(Ok prelude-decls prelude-paths prelude-modules prelude-seen)
      (match (parse_core.parse-ast-source-recovery-diagnostic-with-cfg
        (owned_view.compiler-owned-shared-view path)
        (owned_view.compiler-owned-shared-view source)
        cfgs)
        [(Fatal diagnostics) (Failed (deref diagnostics))]
        [(Parsed program diagnostics)
          (if (> (cdiag.compiler-diagnostic-list-count (deref diagnostics)) 0)
            (Failed (deref diagnostics))
            (compiler-expand-loaded
              (owned_view.compiler-owned-shared-view path)
              prelude-decls
              (ast.ast-decl-path-list-with-modules
                prelude-paths
                prelude-modules)
              (cload.compiler-load-program-with-paths-and-roots-expect-cfg
                (owned_view.compiler-owned-shared-view path)
                program
                prelude-seen
                (owned_view.compiler-owned-shared-view stdlib-roots)
                No
                cfgs
                (cload.compiler-load-parse-identity
                  (owned_view.compiler-owned-shared-view path)
                  (cload.compiler-load-canonical-module-id-from-path
                    (owned_view.compiler-owned-shared-view path))
                  No))
              stdlib-roots
              cfgs
              line
              col
              max-bytes))])]
    [(Err diag) (Failed (cdiag.compiler-diagnostic-list-single (deref diag)))]))