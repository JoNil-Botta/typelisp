;; read.tl - The s-expression READER for TypeLisp's own syntax, factored out
;; as a `main`-less, importable module.
;;
;; --------------------------------------------------------------------------
;; Why this module exists (the module signal for reusable reader code).
;; --------------------------------------------------------------------------
;; `reader.tl` is the *demo* program for the s-expression reader: it carries a
;; `main` that reads a sample and folds the resulting tree with `sum-ints`.
;; Reusable frontend modules need the reader's
;; `read : (-> (__tl_dyn-array token.Token) Sexpr)` and the `Sexpr` AST it
;; builds without inheriting that demo `main`.
;;
;; The legacy stage0 module loader is whole-program: it concatenates every
;; imported module's declarations into a single program, then runs the unchanged
;; `typecheck -> lower -> codegen` pipeline. So two modules that both declare a
;; `main` and are loaded together produce a duplicate `main` symbol. The
;; selfhost namespace model specified in SPEC.md replaces
;; this flat import behavior with qualified module identities. Importing
;; `reader.tl` (which HAS a `main`) into another command driver that also needs
;; a `main` would clash.
;;
;; The fix is this `main`-less module: it holds the reader's cursor helpers, the
;; mutually recursive `read-form` / `read-list`, the public `read` entry, AND the
;; `Sexpr` AST definition. Callers that need to turn source text into tokens
;; import `lex.tl` alongside this reader module. This module imports the `token`
;; module for token types and declares NO `main`.
;; Command drivers and compiler modules can import it and still produce a
;; concatenated program with exactly one `main`. `reader.tl` stays as the
;; reader's standalone demo. This mirrors how `lex.tl` was factored from the
;; `main`-bearing `lexer.tl`: a `main`-less module is the unit of reuse, a
;; `main`-bearing file is a runnable demo.
(import stdlib.str_cat_runtime as str_cat)

(module read)

(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)
(import compiler_intern as ci)
(import lex as lexer)
(import token)

;; --------------------------------------------------------------------------
;; Dense s-expression node and child storage.
;; --------------------------------------------------------------------------
;; TypeLisp has only proper parenthesized and bracketed forms. A list therefore
;; stores one contiguous range of child-node ids instead of a boxed head/tail
;; spine. The storage variants are intentionally not a public traversal
;; contract: consumers use `SexprView` / `SpannedSexprView`, whose `Cons` step
;; carries a value-level tail view and never allocates or stores a recursive
;; pair. `Sexpr.Str` carries the parser-assigned ID of a string literal's
;; unescaped inner text. The reader preserves the lexer's `token.Token.Str` ID, so a
;; quoted string reads as a distinct atom rather than being conflated with a
;; `Sexpr.Sym` of the same characters. `Sexpr.Char` carries a character-literal
;; datum (`'x'`), likewise keeping chars distinct from symbols, ints, and
;; strings.
(defenum Sexpr
  (Int i64 String)
  (Sym ci.InternSyntaxId)
  (List i64 i64)
  (Str ci.InternId)
  (Char char)
  (Float String))

(defenum SexprView
  (Int i64 String)
  ;; Symbols retain their mixed renderable/structural syntax identity while
  ;; crossing the traversal surface. Consumers must explicitly preserve the
  ;; identity or reduce it to a renderable source name.
  (Sym ci.InternSyntaxId)
  (Nil)
  (Cons Sexpr Sexpr)
  (Str ci.InternId)
  (Char char)
  (Float String))

(defenum ResultSexpr
  (Ok Sexpr)
  (Err String))

(defenum SpannedSexpr
  (Int i64 String token.SourceSpan)
  (Sym ci.InternSyntaxId token.SourceSpan)
  (List i64 i64 token.SourceSpan)
  (Str ci.InternId token.SourceSpan)
  (Char char token.SourceSpan)
  (Float String token.SourceSpan)
  (BracketList i64 i64 token.SourceSpan))

(defenum SpannedSexprView
  (Int i64 String token.SourceSpan)
  (Sym ci.InternSyntaxId token.SourceSpan)
  (Nil token.SourceSpan)
  (Cons SpannedSexpr SpannedSexpr token.SourceSpan)
  (Str ci.InternId token.SourceSpan)
  (Char char token.SourceSpan)
  (Float String token.SourceSpan)
  (BracketList SpannedSexpr token.SourceSpan))

(defenum ResultSpannedSexpr
  (Ok SpannedSexpr)
  (Err token.SourceError))

;; --- flat Sexpr / SpannedSexpr child-node pools ---
;; List children are contiguous ids into their corresponding pool. Two plain
;; globals (array + count), NOT a struct, avoid the
;; opt2 hot-path-inline miscompile seen on the AstExpr pool. The spanned tree
;; is transient (consumed into AstExpr, spans copied out by value, then dead),
;; so the pool is reset per program parse (see compiler_parse_core.tl). Start
;; empty and retain geometrically grown storage: small compile commands should
;; not construct 262,144 enum slots before argv dispatch. Growth uses one
;; dedicated arena per pool, created on first growth and never reset, keeping
;; the long-lived global valid across transient driver arenas. The unspanned
;; pool's arena can additionally be retired outright once a load has finished
;; (`sexpr-node-pool-release!`); the spanned pool's cannot, because its origin
;; records outlive parsing.
(define sp-node-pool-slots : (__tl_dyn-array SpannedSexpr)
  (__tl_make-array SpannedSexpr 0))

;; Current head of the dedicated backing arena, or zero before first use.
(define sp-node-pool-base-arena : i64
  0)
(define sp-node-pool-count : i64
  0)
(define sp-builder-slots : (__tl_dyn-array SpannedSexpr)
  (__tl_make-array SpannedSexpr 0))
(define sp-builder-count : i64
  0)
(define sexpr-node-pool-slots : (__tl_dyn-array Sexpr)
  (__tl_make-array Sexpr 0))
(define sexpr-node-pool-base-arena : i64
  0)
(define sexpr-node-pool-count : i64
  0)
(define sexpr-builder-slots : (__tl_dyn-array Sexpr)
  (__tl_make-array Sexpr 0))
(define sexpr-builder-count : i64
  0)

;; Permanent zero-length replacements installed by `sexpr-node-pool-release!`.
;; Both are materialized once during global initialization, in the process
;; entry arena, so the pool globals still name live storage after the shared
;; growth arena is unmapped and the next push grows from zero into a fresh
;; arena. The spanned pool has no counterpart on purpose: its records outlive
;; parsing (see `sexpr-node-pool-release!`).
(define sexpr-node-pool-released-slots : (__tl_dyn-array Sexpr)
  (__tl_make-array Sexpr 0))
(define sexpr-builder-released-slots : (__tl_dyn-array Sexpr)
  (__tl_make-array Sexpr 0))

(define (sp-node-pool-base-arena-handle-value) : i64
  sp-node-pool-base-arena)

(define (sexpr-node-pool-base-arena-handle-value) : i64
  sexpr-node-pool-base-arena)

;; Source symbols remain ids from lexer through reader and parser. Consumers
;; request display text explicitly only when diagnostics or data formats need it.
;: Preserve the lexer-assigned id across the reader/parser boundary.
(define (symbol-id [name-id : ci.InternSyntaxId]) : i64
  (ci.intern-syntax-id-value name-id))

;: Parser metadata may deliberately promote a string literal to a symbol.
;: Assign that spelling its sole source id while the frontend is still writable.
(define (string-symbol-id [text : String]) : i64
  (ci.intern-source-slice text 0 (ci.intern-private-string-length text)))

;: Intern a process-stable parser literal once and memoize its String object.
(define (stable-symbol-id [text : String]) : i64
  (ci.intern-source-slice text 0 (ci.intern-private-string-length text)))

(define (stable-syntax-id [text : String]) : ci.InternSyntaxId
  (ci.intern-syntax-id-from-renderable
    (ci.intern-source-slice-id text 0 (ci.intern-private-string-length text))))

(define (symbol-text-for-syntax-id [id : ci.InternSyntaxId]) : String
  (ci.intern-syntax-id-text id))

(define (sp-node-pool-len) : i64
  sp-node-pool-count)

(define (sexpr-node-pool-len) : i64
  sexpr-node-pool-count)

;; Grow is a safety net. The spanned pool is reset per program parse and
;; truncated per top-level form (compiler_parse_core.tl), so ordinary inputs
;; stay under the initial capacity. Large generated/selfhost closures can still
;; reach it. Growing reassigns the global mid-push, so allocate in the
;; persistent base arena just like the AST/type node pools do; otherwise a grow
;; from a transient file/test arena leaves the global dangling at teardown.
(define (sp-node-pool-grow!) : unit
  (let
    [old-cap : i64 (array-length sp-node-pool-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [base-arena : i64 sp-node-pool-base-arena]
    [storage-root : i64
      (if (= base-arena 0)
        (arena.tl_arena_make)
        base-arena)]
    (in-arena
      (arena.Arena storage-root)
      (let
        [new-slots : (__tl_dyn-array SpannedSexpr)
          (__tl_make-array SpannedSexpr new-cap)]
        [len : i64 sp-node-pool-count]
        [i : i64 0]
        (begin
          (while (< i len)
            (begin
              (set! (array-ref new-slots i) (array-ref sp-node-pool-slots i))
              (set! i (+ i 1))))
          (set! sp-node-pool-base-arena storage-root)
          (set! sp-node-pool-slots new-slots))))))

(define (sexpr-node-pool-grow!) : unit
  (let
    [old-cap : i64 (array-length sexpr-node-pool-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [base-arena : i64 sexpr-node-pool-base-arena]
    [storage-root : i64
      (if (= base-arena 0)
        (arena.tl_arena_make)
        base-arena)]
    (in-arena
      (arena.Arena storage-root)
      (let
        [new-slots : (__tl_dyn-array Sexpr) (__tl_make-array Sexpr new-cap)]
        [len : i64 sexpr-node-pool-count]
        [i : i64 0]
        (begin
          (while (< i len)
            (begin
              (set! (array-ref new-slots i) (array-ref sexpr-node-pool-slots i))
              (set! i (+ i 1))))
          (set! sexpr-node-pool-base-arena storage-root)
          (set! sexpr-node-pool-slots new-slots))))))

(define (sp-builder-grow!) : unit
  (let
    [old-cap : i64 (array-length sp-builder-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [base-arena : i64 sp-node-pool-base-arena]
    [storage-root : i64
      (if (= base-arena 0)
        (arena.tl_arena_make)
        base-arena)]
    (in-arena
      (arena.Arena storage-root)
      (let
        [new-slots : (__tl_dyn-array SpannedSexpr)
          (__tl_make-array SpannedSexpr new-cap)]
        [i : i64 0]
        (begin
          (while (< i sp-builder-count)
            (begin
              (set! (array-ref new-slots i) (array-ref sp-builder-slots i))
              (set! i (+ i 1))))
          (set! sp-node-pool-base-arena storage-root)
          (set! sp-builder-slots new-slots))))))

(define (sexpr-builder-grow!) : unit
  (let
    [old-cap : i64 (array-length sexpr-builder-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [base-arena : i64 sexpr-node-pool-base-arena]
    [storage-root : i64
      (if (= base-arena 0)
        (arena.tl_arena_make)
        base-arena)]
    (in-arena
      (arena.Arena storage-root)
      (let
        [new-slots : (__tl_dyn-array Sexpr) (__tl_make-array Sexpr new-cap)]
        [i : i64 0]
        (begin
          (while (< i sexpr-builder-count)
            (begin
              (set! (array-ref new-slots i) (array-ref sexpr-builder-slots i))
              (set! i (+ i 1))))
          (set! sexpr-node-pool-base-arena storage-root)
          (set! sexpr-builder-slots new-slots))))))

(define (sp-node-push [node : SpannedSexpr]) : i64
  (begin
    (if (>= sp-node-pool-count (array-length sp-node-pool-slots))
      (sp-node-pool-grow!)
      unit)
    (let
      [id : i64 sp-node-pool-count]
      (begin
        (set! (array-ref sp-node-pool-slots id) node)
        (set! sp-node-pool-count (+ id 1))
        id))))

(define (sexpr-node-push [node : Sexpr]) : i64
  (begin
    (if (>= sexpr-node-pool-count (array-length sexpr-node-pool-slots))
      (sexpr-node-pool-grow!)
      unit)
    (let
      [id : i64 sexpr-node-pool-count]
      (begin
        (set! (array-ref sexpr-node-pool-slots id) node)
        (set! sexpr-node-pool-count (+ id 1))
        id))))

;; Reader nodes and builder rows live in the reader's arena-backed pools. These
;; compatibility accessors expose immutable/shared views without transferring
;; ownership out of their global storage.
(define (sp-node-pool-shared-view [id : i64]) : SpannedSexpr
  (unsafe
    (ptr-read
      (ptr-offset
        (ptr-cast (array-data sp-node-pool-slots) : (Ptr SpannedSexpr))
        id))))

(define (sexpr-node-pool-shared-view [id : i64]) : Sexpr
  (unsafe
    (ptr-read
      (ptr-offset
        (ptr-cast (array-data sexpr-node-pool-slots) : (Ptr Sexpr))
        id))))

(define (sexpr-builder-shared-view [id : i64]) : Sexpr
  (unsafe
    (ptr-read
      (ptr-offset (ptr-cast (array-data sexpr-builder-slots) : (Ptr Sexpr)) id))))

(define (sp-builder-shared-view [id : i64]) : SpannedSexpr
  (unsafe
    (ptr-read
      (ptr-offset
        (ptr-cast (array-data sp-builder-slots) : (Ptr SpannedSexpr))
        id))))

(define (sp-node-get [id : i64]) : SpannedSexpr
  (sp-node-pool-shared-view id))

(define (sexpr-node-get [id : i64]) : Sexpr
  (sexpr-node-pool-shared-view id))

(define (sp-node-pool-truncate! [mark : i64]) : unit
  (set! sp-node-pool-count mark))

(define (sp-node-pool-reset!) : unit
  (begin
    (sp-node-pool-truncate! 0)
    (set! sp-builder-count 0)))

(define (sexpr-node-pool-truncate! [mark : i64]) : unit
  (set! sexpr-node-pool-count mark))

(define (sexpr-node-pool-reset!) : unit
  (begin
    (sexpr-node-pool-truncate! 0)
    (set! sexpr-builder-count 0)))

;; Unmap the unspanned pool's shared growth arena and reinstall zero-length
;; slot arrays. Both `sexpr-node-pool-slots` and `sexpr-builder-slots` grow
;; into `sexpr-node-pool-base-arena`, so both are reinstalled here.
;;
;; No-dangling argument:
;;
;;   - An `Sexpr` is a value enum. Only `Sexpr.List` names pool storage, and it
;;     names it as an (id, count) range - valid only while the array is live
;;     and the range is below `sexpr-node-pool-count`. This release zeroes that
;;     count, so it is exactly a stronger `sexpr-node-pool-reset!`.
;;   - No `defstruct` in the tree has an `Sexpr` field, and no global, session
;;     cache, or driver state stores one. Every unspanned consumer converts to
;;     owned data before returning: `tlci_core` walks a form into `String`/i64
;;     `TlciMetadata` fields, `package_lock_core.package-lock-parse` and the
;;     `typelisp.pkg` manifest walkers in `compiler_load.tl` return `String`s.
;;   - Every unspanned producer is already bracketed by the pool discipline
;;     this release strengthens: `compiler_parse_core.tl` resets the pool per
;;     program parse, the loader resets it per session, and typecheck's macro
;;     expansion marks `sexpr-node-pool-len` and truncates back to that mark.
;;   - TLCI text is read during module load (dependency `.tlci` interfaces) and
;;     during artifact emission, never lazily from typecheck or lower.
;;
;; Callers must only prove that no read/parse is in flight. Later pushes are
;; fine: the pool regrows geometrically from zero.
(define (sexpr-node-pool-release!) : unit
  (if (= sexpr-node-pool-base-arena 0)
    unit
    (let
      [retire-arena : i64 sexpr-node-pool-base-arena]
      [retained-arena : i64 (arena.tl_arena_current)]
      (begin
        ;; The sentinels remain owned by their permanent globals. Reinstall
        ;; shared representation views; direct RHS reads would move non-Copy
        ;; dynamic arrays out of those globals.
        (set!
          sexpr-node-pool-slots
          (unsafe
            (ptr-read (ptr-addr-of sexpr-node-pool-released-slots))))
        (set!
          sexpr-builder-slots
          (unsafe
            (ptr-read (ptr-addr-of sexpr-builder-released-slots))))
        (set! sexpr-node-pool-count 0)
        (set! sexpr-builder-count 0)
        (set! sexpr-node-pool-base-arena 0)
        (unsafe
          (begin
            (arena.tl_arena_destroy retire-arena)
            (arena.tl_arena_set retained-arena)))))))

(define (sexpr-node-pool-release-regrow-ok?) : bool
  (begin
    (sexpr-node-pool-release!)
    (if (and
      (= (array-length sexpr-node-pool-slots) 0)
      (= (array-length sexpr-builder-slots) 0)
      (= sexpr-node-pool-count 0)
      (= sexpr-builder-count 0)
      (= sexpr-node-pool-base-arena 0))
      (let
        [builder : SexprBuilder (sexpr-builder-new)]
        [_pushed : SexprBuilder
          (sexpr-builder-push
            builder
            (Sexpr.Sym (ci.intern-syntax-id-from-raw 13)))]
        [list : Sexpr (sexpr-list-from-builder builder)]
        [regrown-ok : bool
          (match list
            [(Sexpr.List start length)
              (and
                (= length 1)
                (!= sexpr-node-pool-base-arena 0)
                (> (array-length sexpr-node-pool-slots) 0)
                (> (array-length sexpr-builder-slots) 0)
                (match (sexpr-node-get start)
                  [(Sexpr.Sym value) (= (ci.intern-syntax-id-value value) 13)]
                  [_ false]))]
            [_ false])]
        (begin
          (sexpr-node-pool-release!)
          (let
            [released-again-ok : bool
              (and
                (= (array-length sexpr-node-pool-slots) 0)
                (= (array-length sexpr-builder-slots) 0)
                (= sexpr-node-pool-count 0)
                (= sexpr-builder-count 0)
                (= sexpr-node-pool-base-arena 0))]
            (begin
              ;; A release without a backing arena is idempotent.
              (sexpr-node-pool-release!)
              (and
                regrown-ok
                released-again-ok
                (= (array-length sexpr-node-pool-slots) 0)
                (= (array-length sexpr-builder-slots) 0)
                (= sexpr-node-pool-count 0)
                (= sexpr-builder-count 0)
                (= sexpr-node-pool-base-arena 0))))))
      false)))

(define (sp-node-pool-arena-ownership-self-test) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    (begin
      (in-arena
        scratch
        (begin
          (sp-node-pool-grow!)
          (sexpr-node-pool-grow!)
          (sp-builder-grow!)
          (sexpr-builder-grow!)))
      (arena.destroy-safe! scratch)
      (sp-node-pool-reset!)
      (sexpr-node-pool-reset!)
      (let
        [span : token.SourceSpan (token.SourceSpan 1 1 1 1)]
        [sp-list : SpannedSexpr
          (spanned-sexpr-list1
            (SpannedSexpr.Sym (ci.intern-syntax-id-from-raw 7) span)
            span)]
        [sexpr-list : Sexpr
          (sexpr-list-from-builder
            (sexpr-builder-push
              (sexpr-builder-new)
              (Sexpr.Sym (ci.intern-syntax-id-from-raw 9))))]
        (match sp-list
          [(SpannedSexpr.List sp-start sp-length sp-span)
            (match sexpr-list
              [(Sexpr.List sexpr-start sexpr-length)
                (if (and
                  (= sp-start 0)
                  (= sp-length 1)
                  (= sp-span.start-line 1)
                  (= sexpr-start 0)
                  (= sexpr-length 1))
                  (match (sp-node-get sp-start)
                    [(SpannedSexpr.Sym sp-value _)
                      (match (sexpr-node-get sexpr-start)
                        [(Sexpr.Sym sexpr-value)
                          (if (and
                            (= (ci.intern-syntax-id-value sp-value) 7)
                            (= (ci.intern-syntax-id-value sexpr-value) 9))
                            (if (sexpr-node-pool-release-regrow-ok?)
                              42
                              3)
                            1)]
                        [_ 1])]
                    [_ 1])
                  1)]
              [_ 1])]
          [_ 2])))))

(defstruct SexprBuilder
  (start i64))

(defstruct SpannedSexprBuilder
  (start i64))

(define (sexpr-builder-new) : SexprBuilder
  (SexprBuilder sexpr-builder-count))

(define (spanned-sexpr-builder-new) : SpannedSexprBuilder
  (SpannedSexprBuilder sp-builder-count))

(define (sexpr-builder-push [builder : SexprBuilder] [item : Sexpr]) : SexprBuilder
  (begin
    (if (>= sexpr-builder-count (array-length sexpr-builder-slots))
      (sexpr-builder-grow!)
      unit)
    (set! (array-ref sexpr-builder-slots sexpr-builder-count) item)
    (set! sexpr-builder-count (+ sexpr-builder-count 1))
    builder))

(define (spanned-sexpr-builder-push
  [builder : SpannedSexprBuilder]
  [item : SpannedSexpr]) : SpannedSexprBuilder
  (begin
    (if (>= sp-builder-count (array-length sp-builder-slots))
      (sp-builder-grow!)
      unit)
    (set! (array-ref sp-builder-slots sp-builder-count) item)
    (set! sp-builder-count (+ sp-builder-count 1))
    builder))

(define (sexpr-list-from-builder [builder : SexprBuilder]) : Sexpr
  (let
    [start : i64 (sexpr-node-pool-len)]
    [builder-start : i64 builder.start]
    [len : i64 (- sexpr-builder-count builder-start)]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (sexpr-node-push (sexpr-builder-shared-view (+ builder-start i)))
          (set! i (+ i 1))))
      (set! sexpr-builder-count builder-start)
      (Sexpr.List start len))))

(define (spanned-sexpr-list-from-builder
  [builder : SpannedSexprBuilder]
  [span : token.SourceSpan]) : SpannedSexpr
  (let
    [start : i64 (sp-node-pool-len)]
    [builder-start : i64 builder.start]
    [len : i64 (- sp-builder-count builder-start)]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (sp-node-push (sp-builder-shared-view (+ builder-start i)))
          (set! i (+ i 1))))
      (set! sp-builder-count builder-start)
      (SpannedSexpr.List start len span))))

(define (sexpr-builder-discard! [builder : SexprBuilder]) : unit
  (set! sexpr-builder-count builder.start))

(define (spanned-sexpr-builder-discard! [builder : SpannedSexprBuilder]) : unit
  (set! sp-builder-count builder.start))

(define (spanned-sexpr-builder-extend
  [builder : SpannedSexprBuilder]
  [items : SpannedSexpr]) : SpannedSexprBuilder
  (match items
    [(SpannedSexpr.List start length _)
      (let
        [out : SpannedSexprBuilder builder]
        [i : i64 0]
        (begin
          (while (< i length)
            (begin
              (set!
                out
                (spanned-sexpr-builder-push out (sp-node-get (+ start i))))
              (set! i (+ i 1))))
          out))]
    [_ (io.panic "reader: list builder extend requires a proper list")]))

(define (spanned-sexpr-list1 [a : SpannedSexpr] [span : token.SourceSpan]) : SpannedSexpr
  (spanned-sexpr-list-from-builder
    (spanned-sexpr-builder-push (spanned-sexpr-builder-new) a)
    span))

(define (spanned-sexpr-list2
  [a : SpannedSexpr]
  [b : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (spanned-sexpr-list-from-builder
    (spanned-sexpr-builder-push
      (spanned-sexpr-builder-push (spanned-sexpr-builder-new) a)
      b)
    span))

(define (spanned-sexpr-list3
  [a : SpannedSexpr]
  [b : SpannedSexpr]
  [c : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (spanned-sexpr-list-from-builder
    (spanned-sexpr-builder-push
      (spanned-sexpr-builder-push
        (spanned-sexpr-builder-push (spanned-sexpr-builder-new) a)
        b)
      c)
    span))

(define (spanned-sexpr-list4
  [a : SpannedSexpr]
  [b : SpannedSexpr]
  [c : SpannedSexpr]
  [d : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (spanned-sexpr-list-from-builder
    (spanned-sexpr-builder-push
      (spanned-sexpr-builder-push
        (spanned-sexpr-builder-push
          (spanned-sexpr-builder-push (spanned-sexpr-builder-new) a)
          b)
        c)
      d)
    span))

(define (spanned-sexpr-empty [span : token.SourceSpan]) : SpannedSexpr
  (SpannedSexpr.List (sp-node-pool-len) 0 span))

(define (spanned-sexpr-list-prepend
  [head : SpannedSexpr]
  [tail : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (match tail
    [(SpannedSexpr.List start length _)
      (let
        [builder : SpannedSexprBuilder
          (spanned-sexpr-builder-push (spanned-sexpr-builder-new) head)]
        [i : i64 0]
        (begin
          (while (< i length)
            (begin
              (set!
                builder
                (spanned-sexpr-builder-push builder (sp-node-get (+ start i))))
              (set! i (+ i 1))))
          (spanned-sexpr-list-from-builder builder span)))]
    [_ (io.panic "reader: list prepend requires a proper list")]))

(define (spanned-sexpr-bracket-list
  [items : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (match items
    [(SpannedSexpr.List start length _)
      (SpannedSexpr.BracketList start length span)]
    [_ (io.panic "reader: bracket form requires a proper list")]))

(define (sexpr-view [s : Sexpr]) : SexprView
  (match s
    [(Sexpr.Int n text) (SexprView.Int n text)]
    [(Sexpr.Sym name) (SexprView.Sym name)]
    [(Sexpr.List start length)
      (if (<= length 0)
        SexprView.Nil
        (SexprView.Cons
          (sexpr-node-get start)
          (Sexpr.List (+ start 1) (- length 1))))]
    [(Sexpr.Str text) (SexprView.Str text)]
    [(Sexpr.Char c) (SexprView.Char c)]
    [(Sexpr.Float text) (SexprView.Float text)]))

(define (spanned-sexpr-view [s : SpannedSexpr]) : SpannedSexprView
  (match s
    [(SpannedSexpr.Int n text span) (SpannedSexprView.Int n text span)]
    [(SpannedSexpr.Sym name span) (SpannedSexprView.Sym name span)]
    [(SpannedSexpr.List start length span)
      (if (<= length 0)
        (SpannedSexprView.Nil span)
        (SpannedSexprView.Cons
          (sp-node-get start)
          (SpannedSexpr.List (+ start 1) (- length 1) span)
          span))]
    [(SpannedSexpr.Str text span) (SpannedSexprView.Str text span)]
    [(SpannedSexpr.Char c span) (SpannedSexprView.Char c span)]
    [(SpannedSexpr.Float text span) (SpannedSexprView.Float text span)]
    [(SpannedSexpr.BracketList start length span)
      (SpannedSexprView.BracketList (SpannedSexpr.List start length span) span)]))

(define (spanned-sexpr-span [s : SpannedSexpr]) : token.SourceSpan
  (match s
    [(SpannedSexpr.Int _ _ span) span]
    [(SpannedSexpr.Sym _ span) span]
    [(SpannedSexpr.List _ _ span) span]
    [(SpannedSexpr.Str _ span) span]
    [(SpannedSexpr.Char _ span) span]
    [(SpannedSexpr.Float _ span) span]
    [(SpannedSexpr.BracketList _ _ span) span]))

(define (spanned-sexpr-range-form [start : i64] [length : i64]) : Sexpr
  (let
    [builder : SexprBuilder (sexpr-builder-new)]
    [i : i64 0]
    (begin
      (while (< i length)
        (begin
          (set!
            builder
            (sexpr-builder-push
              builder
              (spanned-sexpr-form (sp-node-get (+ start i)))))
          (set! i (+ i 1))))
      (sexpr-list-from-builder builder))))

(define (spanned-sexpr-form [s : SpannedSexpr]) : Sexpr
  (match s
    [(SpannedSexpr.Int n text _) (Sexpr.Int n text)]
    [(SpannedSexpr.Sym sym _) (Sexpr.Sym sym)]
    [(SpannedSexpr.List start length _) (spanned-sexpr-range-form start length)]
    [(SpannedSexpr.Str text _) (Sexpr.Str text)]
    [(SpannedSexpr.Char c _) (Sexpr.Char c)]
    [(SpannedSexpr.Float text _) (Sexpr.Float text)]
    [(SpannedSexpr.BracketList start length _)
      (spanned-sexpr-range-form start length)]))

;; --------------------------------------------------------------------------
;; The reader cursor: a single mutable index into the
;; `(__tl_dyn-array token.Token)`.
;; --------------------------------------------------------------------------
;; A TypeLisp function returns a single value, but the reader must both *return
;; an `Sexpr`* and *advance past the tokens it consumed*. So the position is an
;; out-param: a single-cell `(__tl_dyn-array i64)` (`cur`) holding the index of
;; the token under the cursor. Because arrays are heap references, a mutation
;; through `cur` is visible to the caller across the recursive `read-form` /
;; `read-list` calls.
;; Current cursor position (index of the token under the cursor).
(define (cur-pos [cur : (__tl_dyn-array i64)]) : i64
  (array-ref cur 0))

;; Kind tag of the token under the cursor, via the imported `token.tag`. This is
;; the load-bearing cross-import call: the reader classifies a `token.Token` produced
;; by the imported `lex` using the accessor defined in the imported token model.
(define (peek-tag
  [toks : (__tl_dyn-array token.Token)]
  [cur : (__tl_dyn-array i64)]) : i64
  (token.tag (array-ref toks (cur-pos cur))))

;; The `token.Token` value under the cursor (for projecting its int/symbol payload).
(define (peek-tok
  [toks : (__tl_dyn-array token.Token)]
  [cur : (__tl_dyn-array i64)]) : token.Token
  (array-ref toks (cur-pos cur)))

(define (peek-spanned-token
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]) : token.SpannedToken
  (array-ref toks (cur-pos cur)))

(define (peek-spanned-tag
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]) : i64
  (token.tag (token.spanned-token-token (peek-spanned-token toks cur))))

;; Consume the current token: advance the cursor by one.
(define (advance [cur : (__tl_dyn-array i64)]) : unit
  (set! (array-ref cur 0) (+ (cur-pos cur) 1)))

(define (prefix-tag? [t : i64]) : bool
  (or
    (= t (token.tag-quote))
    (= t (token.tag-backtick))
    (= t (token.tag-comma))
    (= t (token.tag-comma-at))))

(define (prefix-symbol [t : i64]) : ci.InternSyntaxId
  (cond
    [(= t (token.tag-quote)) (stable-syntax-id "quote")]
    [(= t (token.tag-backtick)) (stable-syntax-id "quasiquote")]
    [(= t (token.tag-comma)) (stable-syntax-id "unquote")]
    [(= t (token.tag-comma-at)) (stable-syntax-id "unquote-splicing")]
    [else (stable-syntax-id "quote")]))

(define (prefix-form [name : ci.InternSyntaxId] [form : Sexpr]) : Sexpr
  (sexpr-list-from-builder
    (sexpr-builder-push
      (sexpr-builder-push (sexpr-builder-new) (Sexpr.Sym name))
      form)))

(define (prefix-spanned-form
  [name : ci.InternSyntaxId]
  [prefix-span : token.SourceSpan]
  [form : SpannedSexpr]) : SpannedSexpr
  (let
    [span : token.SourceSpan
      (token.merge-spans prefix-span (spanned-sexpr-span form))]
    (spanned-sexpr-list-from-builder
      (spanned-sexpr-builder-push
        (spanned-sexpr-builder-push
          (spanned-sexpr-builder-new)
          (SpannedSexpr.Sym name prefix-span))
        form)
      span)))

(define (close-delimiter-text [tag : i64]) : String
  (if (= tag (token.tag-rparen))
    ")"
    (if (= tag (token.tag-rbracket))
      "]"
      "?")))

(define (quoted-close-delimiter [tag : i64]) : String
  (str_cat.str-cat "'" (close-delimiter-text tag) "'"))

(define (opposite-close-delimiter? [tag : i64] [expected : i64]) : bool
  (if (= expected (token.tag-rparen))
    (= tag (token.tag-rbracket))
    (if (= expected (token.tag-rbracket))
      (= tag (token.tag-rparen))
      false)))

(define (span-location [span : token.SourceSpan]) : String
  (str_cat.str-cat
    (string.int->string (token.span-start-line span))
    ":"
    (string.int->string (token.span-start-col span))))

(define (unterminated-list-message [expected : i64]) : String
  (str_cat.str-cat
    "reader: unterminated list: reached end of input before "
    (quoted-close-delimiter expected)))

(define (mismatched-close-message
  [expected : i64]
  [actual : i64]
  [actual-span : token.SourceSpan]) : String
  (str_cat.str-cat
    "reader: mismatched delimiter: expected "
    (quoted-close-delimiter expected)
    " but found "
    (quoted-close-delimiter actual)
    " at "
    (span-location actual-span)))

;; --------------------------------------------------------------------------
;; The reader proper: `read-form` and `read-list`, mutually recursive.
;; --------------------------------------------------------------------------
;; read-form: read exactly one s-expression starting at the cursor and return
;; it, advancing the cursor past the tokens it consumed.
;;   token.Token.Int n text -> Sexpr.Int n text  an integer atom with source spelling
;;   token.Token.Float s -> Sexpr.Float s        a float atom carrying source text
;;   token.Token.Sym s -> Sexpr.Sym s            a symbol atom
;;   token.Token.Str s -> Sexpr.Str s            a string-literal atom (`"..."`)
;;   token.Token.Char c -> Sexpr.Char c          a character-literal atom (`'x'`)
;;   token.Token.LParen -> list-result      consume '(' then read a list to its ')'
;;   token.Token.RParen -> error                 a stray ')' with no opening '(' is malformed
;;   token.Token.End -> error                    end of stream where a form was expected
;; A grammar violation returns a recoverable `ErrSexpr String`; the public
;; `read` wrapper below still panics for callers that have not moved to
;; `result`.
(define (form-spanned-result
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]) : ResultSpannedSexpr
  (let
    [st : token.SpannedToken (peek-spanned-token toks cur)]
    [tok : token.Token (token.spanned-token-token st)]
    [span : token.SourceSpan (token.spanned-token-span st)]
    [t : i64 (token.tag tok)]
    (cond
      [(= t (token.tag-int))
        (let
          [v : i64 (token.int tok)]
          [text : String (token.int-text tok)]
          (begin
            (advance cur)
            (ResultSpannedSexpr.Ok (SpannedSexpr.Int v text span))))]
      [(= t (token.tag-float))
        (let
          [s : String (token.float tok)]
          (begin
            (advance cur)
            (ResultSpannedSexpr.Ok (SpannedSexpr.Float s span))))]
      [(= t (token.tag-sym))
        (let
          [name-id : ci.InternId (token.sym-id tok)]
          (begin
            (advance cur)
            (ResultSpannedSexpr.Ok
              (SpannedSexpr.Sym
                (ci.intern-syntax-id-from-renderable name-id)
                span))))]
      [(= t (token.tag-str))
        (let
          [string-id : ci.InternId (token.str-id tok)]
          (begin
            (advance cur)
            (ResultSpannedSexpr.Ok (SpannedSexpr.Str string-id span))))]
      [(= t (token.tag-char))
        (let
          [c : char (token.char tok)]
          (begin
            (advance cur)
            (ResultSpannedSexpr.Ok (SpannedSexpr.Char c span))))]
      [(= t (token.tag-lparen))
        (begin
          (advance cur)
          (form-spanned-compound-result
            toks
            cur
            (list-spanned-result toks cur span)))]
      [(= t (token.tag-lbracket))
        (begin
          (advance cur)
          (form-spanned-compound-result
            toks
            cur
            (bracket-list-spanned-result toks cur span)))]
      [(prefix-tag? t)
        (let
          [name : ci.InternSyntaxId (prefix-symbol t)]
          (begin
            (advance cur)
            (match (form-spanned-result toks cur)
              [(ResultSpannedSexpr.Ok form)
                (form-spanned-suffix-result
                  toks
                  cur
                  (prefix-spanned-form name span form))]
              [(ResultSpannedSexpr.Err err) (ResultSpannedSexpr.Err err)])))]
      [(= t (token.tag-rparen))
        (ResultSpannedSexpr.Err
          (token.SourceError "reader: unexpected ')'" span))]
      [(= t (token.tag-rbracket))
        (ResultSpannedSexpr.Err
          (token.SourceError "reader: unexpected ']'" span))]
      [else
        (ResultSpannedSexpr.Err
          (token.SourceError "reader: unexpected end of input" span))])))

(define (spanned-sexpr-adjacent?
  [left : SpannedSexpr]
  [right-span : token.SourceSpan]) : bool
  (let
    [left-span : token.SourceSpan (spanned-sexpr-span left)]
    (and
      (= (token.span-end-line left-span) (token.span-start-line right-span))
      (= (+ (token.span-end-col left-span) 1) (token.span-start-col right-span)))))

(define (projection-suffix-symbol? [text : String]) : bool
  (and (> (string.string-length text) 0) (= (string.string-ref text 0) '.')))

(define (projection-suffix-next-dot
  [text : String]
  [index : i64]
  [length : i64]) : i64
  (let
    [end : i64 index]
    (begin
      (while (and (< end length) (!= (string.string-ref text end) '.'))
        (set! end (+ end 1)))
      end)))

(define (projection-suffix-error [message : String] [span : token.SourceSpan]) : ResultSpannedSexpr
  (ResultSpannedSexpr.Err (token.SourceError message span)))

(define (spanned-projection-suffix-at
  [base : SpannedSexpr]
  [text : String]
  [suffix-span : token.SourceSpan]
  [start : i64]) : ResultSpannedSexpr
  (let
    [length : i64 (string.string-length text)]
    [end : i64 (projection-suffix-next-dot text start length)]
    (cond
      [(>= start end)
        (projection-suffix-error
          "reader: malformed dotted field access; field name cannot be empty"
          suffix-span)]
      [(and
          (>= (string.string-ref text start) '0')
          (<= (string.string-ref text start) '9'))
        (projection-suffix-error
          "reader: dotted field access cannot use numeric field segments; use tuple-ref or array-ref"
          suffix-span)]
      [else
        (let
          [span : token.SourceSpan
            (token.merge-spans (spanned-sexpr-span base) suffix-span)]
          [field : ci.InternSyntaxId
            (ci.intern-syntax-id-from-renderable
              (ci.intern-source-slice-id text start (- end start)))]
          [projected : SpannedSexpr
            (spanned-sexpr-list3
              (SpannedSexpr.Sym
                (stable-syntax-id "__tl_struct-get")
                suffix-span)
              base
              (SpannedSexpr.Sym field suffix-span)
              span)]
          (if (< end length)
            (spanned-projection-suffix-at projected text suffix-span (+ end 1))
            (ResultSpannedSexpr.Ok projected)))])))

(define (form-spanned-suffix-result
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [base : SpannedSexpr]) : ResultSpannedSexpr
  (let
    [st : token.SpannedToken (peek-spanned-token toks cur)]
    [tok : token.Token (token.spanned-token-token st)]
    [span : token.SourceSpan (token.spanned-token-span st)]
    ;; Most forms are followed by whitespace or a delimiter. Reject those
    ;; before materializing the interned symbol text; only lexically adjacent
    ;; symbols can be projection suffixes.
    (if (and
      (= (token.tag tok) (token.tag-sym))
      (spanned-sexpr-adjacent? base span))
      (let
        [text : String (ci.intern-id-str (token.sym-id tok))]
        (if (projection-suffix-symbol? text)
          (begin
            (advance cur)
            (match (spanned-projection-suffix-at base text span 1)
              [(ResultSpannedSexpr.Ok projected)
                (form-spanned-suffix-result toks cur projected)]
              [(ResultSpannedSexpr.Err err) (ResultSpannedSexpr.Err err)]))
          (ResultSpannedSexpr.Ok base)))
      (ResultSpannedSexpr.Ok base))))

(define (form-spanned-compound-result
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [result : ResultSpannedSexpr]) : ResultSpannedSexpr
  (match result
    [(ResultSpannedSexpr.Ok form) (form-spanned-suffix-result toks cur form)]
    [(ResultSpannedSexpr.Err err) (ResultSpannedSexpr.Err err)]))

(define (list-spanned-items-result
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [open-span : token.SourceSpan]
  [close-tag : i64]
  [builder : SpannedSexprBuilder]) : ResultSpannedSexpr
  (let
    [st : token.SpannedToken (peek-spanned-token toks cur)]
    [span : token.SourceSpan (token.spanned-token-span st)]
    [t : i64 (token.tag (token.spanned-token-token st))]
    (cond
      [(= t close-tag)
        (begin
          (advance cur)
          (ResultSpannedSexpr.Ok
            (spanned-sexpr-list-from-builder
              builder
              (token.merge-spans open-span span))))]
      [(= t (token.tag-end))
        (ResultSpannedSexpr.Err
          (token.SourceError (unterminated-list-message close-tag) open-span))]
      [(opposite-close-delimiter? t close-tag)
        (ResultSpannedSexpr.Err
          (token.SourceError (mismatched-close-message close-tag t span) span))]
      [else
        (match (form-spanned-result toks cur)
          [(ResultSpannedSexpr.Ok head)
            (list-spanned-items-result
              toks
              cur
              open-span
              close-tag
              (spanned-sexpr-builder-push builder head))]
          [(ResultSpannedSexpr.Err err) (ResultSpannedSexpr.Err err)])])))

(define (list-spanned-result
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [open-span : token.SourceSpan]) : ResultSpannedSexpr
  (let
    [pool-mark : i64 (sp-node-pool-len)]
    [builder : SpannedSexprBuilder (spanned-sexpr-builder-new)]
    [result : ResultSpannedSexpr
      (list-spanned-items-result toks cur open-span (token.tag-rparen) builder)]
    (match result
      [(ResultSpannedSexpr.Ok form) (ResultSpannedSexpr.Ok form)]
      [(ResultSpannedSexpr.Err err)
        (begin
          (spanned-sexpr-builder-discard! builder)
          (sp-node-pool-truncate! pool-mark)
          (ResultSpannedSexpr.Err err))])))

(define (bracket-list-spanned-result
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [open-span : token.SourceSpan]) : ResultSpannedSexpr
  (let
    [pool-mark : i64 (sp-node-pool-len)]
    [builder : SpannedSexprBuilder (spanned-sexpr-builder-new)]
    [result : ResultSpannedSexpr
      (list-spanned-items-result
        toks
        cur
        open-span
        (token.tag-rbracket)
        builder)]
    (match result
      [(ResultSpannedSexpr.Ok items)
        (ResultSpannedSexpr.Ok
          (spanned-sexpr-bracket-list items (spanned-sexpr-span items)))]
      [(ResultSpannedSexpr.Err err)
        (begin
          (spanned-sexpr-builder-discard! builder)
          (sp-node-pool-truncate! pool-mark)
          (ResultSpannedSexpr.Err err))])))

(define (form-result
  [toks : (__tl_dyn-array token.Token)]
  [cur : (__tl_dyn-array i64)]) : ResultSexpr
  (let
    [t : i64 (peek-tag toks cur)]
    (cond
      [(= t (token.tag-int))
        (let
          [tok : token.Token (peek-tok toks cur)]
          [v : i64 (token.int tok)]
          [text : String (token.int-text tok)]
          (begin
            (advance cur)
            (ResultSexpr.Ok (Sexpr.Int v text))))]
      [(= t (token.tag-float))
        (let
          [s : String (token.float (peek-tok toks cur))]
          (begin
            (advance cur)
            (ResultSexpr.Ok (Sexpr.Float s))))]
      [(= t (token.tag-sym))
        (let
          [name-id : ci.InternId (token.sym-id (peek-tok toks cur))]
          (begin
            (advance cur)
            (ResultSexpr.Ok
              (Sexpr.Sym (ci.intern-syntax-id-from-renderable name-id)))))]
      [(= t (token.tag-str))
        (let
          [string-id : ci.InternId (token.str-id (peek-tok toks cur))]
          (begin
            (advance cur)
            (ResultSexpr.Ok (Sexpr.Str string-id))))]
      [(= t (token.tag-char))
        (let
          [c : char (token.char (peek-tok toks cur))]
          (begin
            (advance cur)
            (ResultSexpr.Ok (Sexpr.Char c))))]
      [(= t (token.tag-lparen))
        (begin
          (advance cur)
          (list-result toks cur))]
      [(= t (token.tag-lbracket))
        (begin
          (advance cur)
          (bracket-list-result toks cur))]
      [(prefix-tag? t)
        (let
          [name : ci.InternSyntaxId (prefix-symbol t)]
          (begin
            (advance cur)
            (match (form-result toks cur)
              [(ResultSexpr.Ok form) (ResultSexpr.Ok (prefix-form name form))]
              [(ResultSexpr.Err message) (ResultSexpr.Err message)])))]
      [(= t (token.tag-rparen)) (ResultSexpr.Err "reader: unexpected ')'")]
      [(= t (token.tag-rbracket)) (ResultSexpr.Err "reader: unexpected ']'")]
      [else (ResultSexpr.Err "reader: unexpected end of input")])))

;; read-list: the cursor is positioned just AFTER an opening '('. Read forms
;; until the matching ')' into a growable temporary builder. Completing the
;; form copies that builder once into a contiguous child range in source order.
;; The base case consumes the closing delimiter and records the range; hitting
;; `token.Token.End` first returns `ErrSexpr`. Nesting is handled for free: a
;; head form that starts with '(' re-enters `form-result` -> `list-result`,
;; completes its own child range, and then becomes one value in this builder.
(define (list-result-with-close
  [toks : (__tl_dyn-array token.Token)]
  [cur : (__tl_dyn-array i64)]
  [close-tag : i64]
  [unterminated-message : String]
  [builder : SexprBuilder]) : ResultSexpr
  (let
    [t : i64 (peek-tag toks cur)]
    (if (= t close-tag)
      ;; End of this list: consume the ')' and seal the dense child range.
      (begin
        (advance cur)
        (ResultSexpr.Ok (sexpr-list-from-builder builder)))
      (if (= t (token.tag-end))
        (ResultSexpr.Err unterminated-message)
        ;; A list element: read the next form (which advances the cursor past
        ;; it, however deeply nested), append it, and continue.
        (match (form-result toks cur)
          [(ResultSexpr.Ok head)
            (list-result-with-close
              toks
              cur
              close-tag
              unterminated-message
              (sexpr-builder-push builder head))]
          [(ResultSexpr.Err message) (ResultSexpr.Err message)])))))

(define (list-result
  [toks : (__tl_dyn-array token.Token)]
  [cur : (__tl_dyn-array i64)]) : ResultSexpr
  (let
    [pool-mark : i64 (sexpr-node-pool-len)]
    [builder : SexprBuilder (sexpr-builder-new)]
    [result : ResultSexpr
      (list-result-with-close
        toks
        cur
        (token.tag-rparen)
        "reader: unterminated list (missing ')')"
        builder)]
    (match result
      [(ResultSexpr.Ok form) (ResultSexpr.Ok form)]
      [(ResultSexpr.Err message)
        (begin
          (sexpr-builder-discard! builder)
          (sexpr-node-pool-truncate! pool-mark)
          (ResultSexpr.Err message))])))

(define (bracket-list-result
  [toks : (__tl_dyn-array token.Token)]
  [cur : (__tl_dyn-array i64)]) : ResultSexpr
  (let
    [pool-mark : i64 (sexpr-node-pool-len)]
    [builder : SexprBuilder (sexpr-builder-new)]
    [result : ResultSexpr
      (list-result-with-close
        toks
        cur
        (token.tag-rbracket)
        "reader: unterminated list (missing ']')"
        builder)]
    (match result
      [(ResultSexpr.Ok form) (ResultSexpr.Ok form)]
      [(ResultSexpr.Err message)
        (begin
          (sexpr-builder-discard! builder)
          (sexpr-node-pool-truncate! pool-mark)
          (ResultSexpr.Err message))])))

;; read: the public entry point. Read a single top-level form from the front of
;; `toks` (a cursor starting at index 0) and return its `Sexpr` tree. (Trailing
;; tokens after the first form are ignored here, as a top-level `read` returns
;; one datum at a time.)
(define (result [toks : (__tl_dyn-array token.Token)]) : ResultSexpr
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (sexpr-node-pool-reset!)
      (set! (array-ref cur 0) 0)
      (form-result toks cur))))

(define (spanned-result [toks : (__tl_dyn-array token.SpannedToken)]) : ResultSpannedSexpr
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (set! sp-builder-count 0)
      (set! (array-ref cur 0) 0)
      (form-spanned-result toks cur))))

(define (symbol-id-preservation-ok?) : bool
  (match (lexer.spanned-result "(alpha alpha)")
    [(lexer.ResultSpannedTokens.Ok toks)
      (let
        [first-id : ci.InternId
          (token.sym-id (token.spanned-token-token (array-ref toks 1)))]
        [second-id : ci.InternId
          (token.sym-id (token.spanned-token-token (array-ref toks 2)))]
        [pool-len-before : i64 (ci.intern-pool-len)]
        (begin
          (sp-node-pool-reset!)
          (match (spanned-result toks)
            [(ResultSpannedSexpr.Ok form)
              (and
                (= pool-len-before (ci.intern-pool-len))
                (ci.intern-id-eq? first-id second-id)
                (match (spanned-sexpr-view form)
                  [(SpannedSexprView.Cons first tail _)
                    (match first
                      [(SpannedSexpr.Sym first-text _)
                        (match (spanned-sexpr-view tail)
                          [(SpannedSexprView.Cons second _ _)
                            (match second
                              [(SpannedSexpr.Sym second-text _)
                                (and
                                  (=
                                    (symbol-id first-text)
                                    (ci.intern-id-value first-id))
                                  (=
                                    (symbol-id second-text)
                                    (ci.intern-id-value second-id)))]
                              [_ false])]
                          [_ false])]
                      [_ false])]
                  [_ false]))]
            [(ResultSpannedSexpr.Err _) false])))]
    [(lexer.ResultSpannedTokens.Err _) false]))

(define (read [toks : (__tl_dyn-array token.Token)]) : Sexpr
  (match (result toks)
    [(ResultSexpr.Ok form) form]
    [(ResultSexpr.Err message) (io.panic message)]))

(define (reader-test-symbol? [form : Sexpr] [expected : String]) : bool
  (match (sexpr-view form)
    [(SexprView.Sym name-id)
      (string.eq (symbol-text-for-syntax-id name-id) expected)]
    [_ false]))

(define (reader-test-projection-suffix-cursor?
  [source : String]
  [expected-cursor : i64]) : bool
  (match (lexer.spanned-result source)
    [(lexer.ResultSpannedTokens.Err _) false]
    [(lexer.ResultSpannedTokens.Ok toks)
      (let
        [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
        (begin
          (sp-node-pool-reset!)
          (set! (array-ref cur 0) 0)
          (match (form-spanned-result toks cur)
            [(ResultSpannedSexpr.Err _) false]
            [(ResultSpannedSexpr.Ok _) (= (array-ref cur 0) expected-cursor)])))]))

(define (reader-test-invalid-projection-suffix?) : bool
  (match (lexer.spanned-result "(deref boxed).0")
    [(lexer.ResultSpannedTokens.Err _) false]
    [(lexer.ResultSpannedTokens.Ok toks)
      (let
        [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
        (begin
          (sp-node-pool-reset!)
          (set! (array-ref cur 0) 0)
          (match (form-spanned-result toks cur)
            [(ResultSpannedSexpr.Ok _) false]
            [(ResultSpannedSexpr.Err err)
              (string.eq
                (token.source-error-message err)
                "reader: dotted field access cannot use numeric field segments; use tuple-ref or array-ref")])))]))

(define (reader-test-unspanned-dense-ranges?) : bool
  (match (result (lexer.lex "(alpha (beta gamma) [])"))
    [(ResultSexpr.Err _) false]
    [(ResultSexpr.Ok form)
      (and
        (= (sexpr-node-pool-len) 5)
        (match form
          [(Sexpr.List start length)
            (and
              (= start 2)
              (= length 3)
              (match (sexpr-view form)
                [(SexprView.Cons first tail1)
                  (and
                    (reader-test-symbol? first "alpha")
                    (match (sexpr-view tail1)
                      [(SexprView.Cons nested tail2)
                        (and
                          (match (sexpr-view nested)
                            [(SexprView.Cons beta nested-tail)
                              (and
                                (reader-test-symbol? beta "beta")
                                (match (sexpr-view nested-tail)
                                  [(SexprView.Cons gamma nested-end)
                                    (and
                                      (reader-test-symbol? gamma "gamma")
                                      (match (sexpr-view nested-end)
                                        [(SexprView.Nil) true]
                                        [_ false]))]
                                  [_ false]))]
                            [_ false])
                          (match (sexpr-view tail2)
                            [(SexprView.Cons empty tail3)
                              (and
                                (match (sexpr-view empty)
                                  [(SexprView.Nil) true]
                                  [_ false])
                                (match (sexpr-view tail3)
                                  [(SexprView.Nil) true]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]))

(define (reader-test-spanned-bracket-range?) : bool
  (begin
    (sp-node-pool-reset!)
    (match (lexer.spanned-result "[alpha (beta gamma)]")
      [(lexer.ResultSpannedTokens.Err _) false]
      [(lexer.ResultSpannedTokens.Ok toks)
        (match (spanned-result toks)
          [(ResultSpannedSexpr.Err _) false]
          [(ResultSpannedSexpr.Ok form)
            (and
              (= (sp-node-pool-len) 4)
              (match form
                [(SpannedSexpr.BracketList start length span)
                  (and
                    (= start 2)
                    (= length 2)
                    (= (token.span-start-line span) 1)
                    (= (token.span-start-col span) 1)
                    (match (spanned-sexpr-view form)
                      [(SpannedSexprView.BracketList items _)
                        (match (spanned-sexpr-view items)
                          [(SpannedSexprView.Cons alpha tail _)
                            (and
                              (match (spanned-sexpr-view alpha)
                                [(SpannedSexprView.Sym name-id _)
                                  (string.eq
                                    (symbol-text-for-syntax-id name-id)
                                    "alpha")]
                                [_ false])
                              (match (spanned-sexpr-view tail)
                                [(SpannedSexprView.Cons nested end _)
                                  (and
                                    (match (spanned-sexpr-view nested)
                                      [(SpannedSexprView.Cons _ _ _) true]
                                      [_ false])
                                    (match (spanned-sexpr-view end)
                                      [(SpannedSexprView.Nil _) true]
                                      [_ false]))]
                                [_ false]))]
                          [_ false])]
                      [_ false]))]
                [_ false]))])])))

(define (reader-test-prefix-range?) : bool
  (match (result (lexer.lex "'alpha"))
    [(ResultSexpr.Err _) false]
    [(ResultSexpr.Ok form)
      (and
        (= (sexpr-node-pool-len) 2)
        (match (sexpr-view form)
          [(SexprView.Cons quote tail)
            (and
              (reader-test-symbol? quote "quote")
              (match (sexpr-view tail)
                [(SexprView.Cons value end)
                  (and
                    (reader-test-symbol? value "alpha")
                    (match (sexpr-view end)
                      [(SexprView.Nil) true]
                      [_ false]))]
                [_ false]))]
          [_ false]))]))

(define (reader-test-mismatched-delimiter?) : bool
  (begin
    (sp-node-pool-reset!)
    (match (lexer.spanned-result "(alpha]")
      [(lexer.ResultSpannedTokens.Err _) false]
      [(lexer.ResultSpannedTokens.Ok toks)
        (match (spanned-result toks)
          [(ResultSpannedSexpr.Ok _) false]
          [(ResultSpannedSexpr.Err err)
            (and
              (string.eq
                (token.source-error-message err)
                "reader: mismatched delimiter: expected ')' but found ']' at 1:7")
              (= (token.span-start-line (token.source-error-span err)) 1)
              (= (token.span-start-col (token.source-error-span err)) 7))])])))

(define (reader-test-error-rolls-back-ranges?) : bool
  (let
    [plain-error-ok : bool
      (match (result (lexer.lex "((alpha)]"))
        [(ResultSexpr.Ok _) false]
        [(ResultSexpr.Err _)
          (and (= (sexpr-node-pool-len) 0) (= sexpr-builder-count 0))])]
    [_reset-spanned : unit (sp-node-pool-reset!)]
    [spanned-error-ok : bool
      (match (lexer.spanned-result "((alpha)]")
        [(lexer.ResultSpannedTokens.Err _) false]
        [(lexer.ResultSpannedTokens.Ok toks)
          (match (spanned-result toks)
            [(ResultSpannedSexpr.Ok _) false]
            [(ResultSpannedSexpr.Err _)
              (and (= (sp-node-pool-len) 0) (= sp-builder-count 0))])])]
    [repeated-read-ok : bool
      (match (lexer.spanned-result "(beta)")
        [(lexer.ResultSpannedTokens.Err _) false]
        [(lexer.ResultSpannedTokens.Ok toks)
          (match (spanned-result toks)
            [(ResultSpannedSexpr.Err _) false]
            [(ResultSpannedSexpr.Ok form)
              (and
                (= (sp-node-pool-len) 1)
                (match (spanned-sexpr-view form)
                  [(SpannedSexprView.Cons value tail _)
                    (and
                      (match (spanned-sexpr-view value)
                        [(SpannedSexprView.Sym name-id _)
                          (string.eq (symbol-text-for-syntax-id name-id) "beta")]
                        [_ false])
                      (match (spanned-sexpr-view tail)
                        [(SpannedSexprView.Nil _) true]
                        [_ false]))]
                  [_ false]))])])]
    [ok : bool (and plain-error-ok spanned-error-ok repeated-read-ok)]
    (begin
      (sp-node-pool-reset!)
      (sexpr-node-pool-reset!)
      ok)))

(define (reader-test-typed-traversal-ids?) : bool
  (let
    [source : ci.InternId (ci.intern-source-slice-id "reader-view-name" 0 16)]
    [text : ci.InternId (ci.intern-source-slice-id "reader-view-string" 0 18)]
    [structural : ci.InternSyntaxId
      (ci.intern-syntax-id-from-raw
        (ci.intern-structural-local-id 7 (ci.intern-id-value source)))]
    [span : token.SourceSpan (token.source-span-new 2 3 2 7)]
    (and
      (match (sexpr-view (Sexpr.Sym structural))
        [(SexprView.Sym found)
          (and
            (ci.intern-syntax-id-eq? found structural)
            (string.eq (symbol-text-for-syntax-id found) "reader-view-name"))]
        [_ false])
      (match (sexpr-view (Sexpr.Str text))
        [(SexprView.Str found) (ci.intern-id-eq? found text)]
        [_ false])
      (match (spanned-sexpr-view (SpannedSexpr.Sym structural span))
        [(SpannedSexprView.Sym found found-span)
          (and
            (ci.intern-syntax-id-eq? found structural)
            (= (token.span-start-line found-span) 2)
            (= (token.span-start-col found-span) 3))]
        [_ false])
      (match (spanned-sexpr-view (SpannedSexpr.Str text span))
        [(SpannedSexprView.Str found _) (ci.intern-id-eq? found text)]
        [_ false]))))

(test
  reader-traversal-ids-typed-and-preserved
  (if (reader-test-typed-traversal-ids?)
    unit
    (io.panic "reader: typed traversal identity self-test failed")))

(test
  reader-dense-child-ranges
  (if (and
    (reader-test-unspanned-dense-ranges?)
    (reader-test-spanned-bracket-range?)
    (reader-test-prefix-range?)
    (reader-test-mismatched-delimiter?)
    (reader-test-error-rolls-back-ranges?))
    unit
    (io.panic "reader: dense child range self-test failed")))

(test
  reader-projection-suffixes
  (if (and
    ;; The suffix token is consumed only when no whitespace separates it from
    ;; the closing delimiter. The final token in both streams is End.
    (reader-test-projection-suffix-cursor? "(array-ref items 0).inner.value" 6)
    (reader-test-projection-suffix-cursor? "(array-ref items 0) .value" 5)
    (reader-test-invalid-projection-suffix?))
    unit
    (io.panic "reader: projection suffix self-test failed")))