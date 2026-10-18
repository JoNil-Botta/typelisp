;; format_rules.tl - TypeLisp-aware formatter rules.
;;
;; The CST (`format_cst.tl`) stays syntax-neutral. This module adds deterministic
;; gofmt-like rules for common TypeLisp special forms and renders them directly
;; from the CST. `tests/format_golden/` and `format-rules-self-test` pin the
;; output.
(import stdlib.iterator)
(import stdlib.str_cat_runtime as str_cat)
(import format_tokens as tokens)
(import format_cst as cst)
(import format_render_buf as fmt_buf)
(import stdlib.string)
(import compiler_owned_view as owned_view)

(defenum ResultFormatString
  (Ok String)
  (Err tokens.FormatSourceError))

(define (format-rules-node-colon? [node : cst.FormatCst]) : bool
  (match node
    [(Atom tok) (= (tokens.format-token-tag tok) (tokens.fmt-tag-colon))]
    [_ false]))

(define (format-rules-node-symbol-name [node : cst.FormatCst]) : String
  (match node
    [(Atom tok)
      (match tok
        [(Symbol name) name]
        [_ ""])]
    [_ ""]))

(define (format-rules-node-comment? [node : cst.FormatCst]) : bool
  (match node
    [(Comment _) true]
    [_ false]))

(define (format-rules-node-colon-list? [node : cst.FormatCst]) : bool
  (match node
    [(List items)
      (match (cst.fmt-cst-list-step (deref items))
        [(Item head _) (format-rules-node-colon? head)]
        [_ false])]
    [_ false]))

(define (format-rules-node-spmd-callable? [node : cst.FormatCst]) : bool
  (match node
    [(List items)
      (match (cst.fmt-cst-list-step (deref items))
        [(Item colon rest)
          (and
            (format-rules-node-colon? colon)
            (match (cst.fmt-cst-list-step rest)
              [(Item key _)
                (string.eq (format-rules-node-symbol-name key) "spmd-callable")]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (format-rules-define-value-rest? [rest : cst.FormatCstList]) : bool
  (match (cst.fmt-cst-list-step rest)
    [(Item target _)
      (match target
        [(List _) false]
        [_ true])]
    [_ false]))

(define (format-rules-cfg-top-form-family [rest : cst.FormatCstList]) : String
  (match (cst.fmt-cst-list-step rest)
    [(Item _ after-predicate)
      (match (cst.fmt-cst-list-step after-predicate)
        [(Item inner _) (format-rules-top-form-family inner)]
        [_ ""])]
    [_ ""]))

(define (format-rules-top-form-family-list [items : cst.FormatCstList]) : String
  (match (cst.fmt-cst-list-step items)
    [(Item head rest)
      (let
        [head-name : String (format-rules-node-symbol-name head)]
        (cond
          [(string.eq head-name "import") "import"]
          [(string.eq head-name "extern") "extern"]
          [(string.eq head-name "include-str") "include-str"]
          [(string.eq head-name "define")
            (if (format-rules-define-value-rest? rest)
              "define"
              "")]
          [(string.eq head-name "cfg") (format-rules-cfg-top-form-family rest)]
          [else ""]))]
    [_ ""]))

(define (format-rules-top-form-family [node : cst.FormatCst]) : String
  (match node
    [(List items) (format-rules-top-form-family-list (deref items))]
    [_ ""]))

(define (format-rules-list-append
  [left : cst.FormatCstList]
  [right : cst.FormatCstList]) : cst.FormatCstList
  (let
    [out : cst.FormatCstVec (cst.format-cst-vec-new)]
    (cst.fmt-cst-vec-push-list! (&mut out) left)
    (cst.fmt-cst-vec-push-list! (&mut out) right)
    (cst.fmt-cst-list-from-vec out)))

(define (format-rules-bracket-binding-items?
  [items : cst.FormatCstList]
  [seen : bool]) : bool
  (match (cst.fmt-cst-list-step items)
    [(Empty) seen]
    [(Item node rest)
      (match node
        [(Comment _) (format-rules-bracket-binding-items? rest seen)]
        [(BracketList _) (format-rules-bracket-binding-items? rest true)]
        [_ false])]))

(define (format-rules-bracket-binding-list? [items : cst.FormatCstList]) : bool
  (format-rules-bracket-binding-items? items false))

(define (format-rules-let-rest [rest : cst.FormatCstList]) : cst.FormatCstList
  (match (cst.fmt-cst-list-step rest)
    [(Item first tail)
      (match first
        [(List bindings)
          (match (cst.fmt-cst-list-step (deref bindings))
            [(Empty)
              (cst.fmt-cst-list-cons
                (BracketList (box (cst.fmt-cst-list-nil)))
                tail)]
            [_
              (if (format-rules-bracket-binding-list?
                (owned_view.compiler-owned-box-shared-view bindings))
                (format-rules-list-append (deref bindings) tail)
                rest)])]
        [_ rest])]
    [_ rest]))

;; Direct CST layout interpreter for the normal `fmt`/LSP path. `emit=false`
;; computes the flat width of a fragment, capped at `limit`; `emit=true` writes
;; its bytes. Keeping both modes in one set of rule walkers keeps the grouping
;; decisions in one place without allocating per-form document trees.
(define (format-rules-layout-text
  [text : String]
  [emit : bool]
  [_width : i64]
  [_indent : i64]
  [col : i64]
  [_flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if emit
    (let
      [text-width : i64 (string.string-length text)]
      (fmt_buf.fmt-render-buf-append buf text)
      (+ col text-width))
    (if (> col limit)
      col
      (+ col (string.string-length text)))))

(define (format-rules-layout-soft-line
  [emit : bool]
  [_width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if emit
    (if flat
      (begin
        (fmt_buf.fmt-render-buf-append buf " ")
        (+ col 1))
      (begin
        (fmt_buf.render-newline-into! buf indent)
        indent))
    (if (> col limit)
      col
      (+ col 1))))

(define (format-rules-layout-hard-line
  [emit : bool]
  [_width : i64]
  [indent : i64]
  [col : i64]
  [_flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if emit
    (begin
      (fmt_buf.render-newline-into! buf indent)
      indent)
    (if (> col limit)
      col
      (+ col 1000000))))

(define (format-rules-layout-cst
  [node : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (match node
    [(Atom tok)
      (format-rules-layout-text
        (tokens.format-token-text tok)
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [(Comment text)
      (format-rules-layout-text text emit width indent col flat limit buf)]
    [(Prefix tok child)
      (format-rules-layout-cst
        (deref child)
        emit
        width
        indent
        (format-rules-layout-text
          (tokens.format-token-text tok)
          emit
          width
          indent
          col
          flat
          limit
          buf)
        flat
        limit
        buf)]
    [(Projection child field)
      (format-rules-layout-text
        field
        emit
        width
        indent
        (format-rules-layout-text
          "."
          emit
          width
          indent
          (format-rules-layout-cst
            (deref child)
            emit
            width
            indent
            col
            flat
            limit
            buf)
          flat
          limit
          buf)
        flat
        limit
        buf)]
    [(List items)
      (format-rules-layout-list
        (deref items)
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [(BracketList items)
      (format-rules-layout-delimited
        "["
        (deref items)
        "]"
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [(Forms items)
      (format-rules-layout-forms
        (deref items)
        emit
        width
        indent
        col
        flat
        limit
        buf)]))

(define (format-rules-layout-space-cst
  [node : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-cst
    node
    emit
    width
    indent
    (format-rules-layout-text " " emit width indent col flat limit buf)
    flat
    limit
    buf))

(define (format-rules-layout-colon-pair
  [colon : cst.FormatCst]
  [next : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-space-cst
    next
    emit
    width
    indent
    (format-rules-layout-cst colon emit width indent col flat limit buf)
    flat
    limit
    buf))

(define (format-rules-layout-return-type-tail
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-colon-pair
    colon
    typ
    emit
    width
    indent
    (format-rules-layout-text " " emit width indent col flat limit buf)
    flat
    limit
    buf))

(define (format-rules-layout-return-type-breakable-tail-inner
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-colon-pair
    colon
    typ
    emit
    width
    indent
    (format-rules-layout-soft-line emit width indent col flat limit buf)
    flat
    limit
    buf))

(define (format-rules-layout-return-type-breakable-tail
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if emit
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-return-type-breakable-tail-inner
          (owned_view.compiler-owned-shared-view colon)
          (owned_view.compiler-owned-shared-view typ)
          false
          width
          indent
          0
          false
          remaining
          buf)]
      (format-rules-layout-return-type-breakable-tail-inner
        colon
        typ
        true
        width
        indent
        col
        (<= flat-width remaining)
        limit
        buf))
    (format-rules-layout-return-type-breakable-tail-inner
      colon
      typ
      false
      width
      indent
      col
      flat
      limit
      buf)))

(define (format-rules-layout-metadata-return-type-tail
  [metadata : cst.FormatCst]
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if (format-rules-node-spmd-callable? metadata)
    (format-rules-layout-colon-pair
      colon
      typ
      emit
      width
      indent
      (format-rules-layout-hard-line emit width indent col flat limit buf)
      flat
      limit
      buf)
    (format-rules-layout-return-type-breakable-tail
      colon
      typ
      emit
      width
      indent
      col
      flat
      limit
      buf)))

(define (format-rules-layout-inline-tail-dense
  [slots : (__tl_dyn-array cst.FormatCst)]
  [start : i64]
  [count : i64]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (let
    [end : i64 (+ start count)]
    [out : i64 col]
    (for [index (iterator.range start end)]
      (set!
        out
        (format-rules-layout-space-cst
          (owned_view.compiler-owned-array-element-shared-view slots index)
          emit
          width
          indent
          out
          flat
          limit
          buf)))
    out))

(define (format-rules-layout-inline-tail
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-inline-tail-dense
    items.slots
    items.start
    items.len
    emit
    width
    indent
    col
    flat
    limit
    buf))

(define (format-rules-layout-hard-tail-dense
  [slots : (__tl_dyn-array cst.FormatCst)]
  [start : i64]
  [count : i64]
  [arms : bool]
  [or-arms : bool]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (let
    [index : i64 start]
    [end : i64 (+ start count)]
    [out : i64 col]
    [last-comment : bool false]
    (while (< index end)
      (let
        [node : cst.FormatCst
          (owned_view.compiler-owned-array-element-shared-view slots index)]
        [after-line : i64
          (format-rules-layout-hard-line emit width indent out flat limit buf)]
        (if (if (format-rules-node-colon?
          (owned_view.compiler-owned-shared-view node))
          (< (+ index 1) end)
          false)
          (let
            [next : cst.FormatCst
              (owned_view.compiler-owned-array-element-shared-view
                slots
                (+ index 1))]
            (if (format-rules-node-comment?
              (owned_view.compiler-owned-shared-view next))
              (begin
                (set!
                  out
                  (format-rules-layout-cst
                    node
                    emit
                    width
                    indent
                    after-line
                    flat
                    limit
                    buf))
                (set! last-comment false)
                (+= index 1))
              (begin
                (set!
                  out
                  (format-rules-layout-colon-pair
                    node
                    (owned_view.compiler-owned-shared-view next)
                    emit
                    width
                    indent
                    after-line
                    flat
                    limit
                    buf))
                (set! last-comment (format-rules-node-comment? next))
                (+= index 2))))
          (begin
            (set!
              out
              (if arms
                (format-rules-layout-arm-cst
                  (owned_view.compiler-owned-shared-view node)
                  or-arms
                  emit
                  width
                  indent
                  after-line
                  flat
                  limit
                  buf)
                (format-rules-layout-cst
                  (owned_view.compiler-owned-shared-view node)
                  emit
                  width
                  indent
                  after-line
                  flat
                  limit
                  buf)))
            (set! last-comment (format-rules-node-comment? node))
            (+= index 1)))))
    (if last-comment
      (format-rules-layout-hard-line emit width indent out flat limit buf)
      out)))

(define (format-rules-layout-hard-tail
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-hard-tail-dense
    items.slots
    items.start
    items.len
    false
    false
    emit
    width
    indent
    col
    flat
    limit
    buf))

;; Match and cond arms: a bracket arm with two or more body forms is laid out
;; like a `begin` body, its head on the bracket's line and one form per line.
(define (format-rules-arm-form-count [items : (& items cst.FormatCstList)]) : i64
  (let
    [count : i64 0]
    (for [index (iterator.range 0 items.len)]
      (unless
        (format-rules-node-comment?
          (owned_view.compiler-owned-array-element-shared-view
            items.slots
            (+ items.start index)))
        (+= count 1)))
    count))

;; A `:` after the head marks a parameter or binding clause such as
;; `[arms : ExprClause ...]` in a `(cond ...)` macro signature, never an arm.
(define (format-rules-arm-sequence? [node : cst.FormatCst]) : bool
  (match node
    [(BracketList items)
      (match (cst.fmt-cst-list-step (deref items))
        [(Item head rest)
          (and
            (not (format-rules-node-comment? head))
            (match (cst.fmt-cst-list-step rest)
              [(Item second _) (not (format-rules-node-colon? second))]
              [(Empty) false])
            (> (format-rules-arm-form-count (& (deref items))) 2))]
        [(Empty) false])]
    [_ false]))

(define (format-rules-arms-have-sequence? [items : (& items cst.FormatCstList)]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index items.len))
      (set!
        found
        (format-rules-arm-sequence?
          (owned_view.compiler-owned-array-element-shared-view
            items.slots
            (+ items.start index))))
      (+= index 1))
    found))

(define (format-rules-layout-arm-cst
  [node : cst.FormatCst]
  [or-arms : bool]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (cond
    [(and
        or-arms
        (format-rules-arm-or-pattern?
          (owned_view.compiler-owned-shared-view node)))
      (format-rules-layout-or-arm node emit width indent col flat limit buf)]
    [(format-rules-arm-sequence? (owned_view.compiler-owned-shared-view node))
      (match node
        [(BracketList items)
          (match (cst.fmt-cst-list-step (deref items))
            [(Item head body)
              (format-rules-layout-text
                "]"
                emit
                width
                indent
                (format-rules-layout-arm-hard-tail
                  false
                  false
                  body
                  emit
                  width
                  (+ indent 2)
                  (format-rules-layout-cst
                    head
                    emit
                    width
                    indent
                    (format-rules-layout-text
                      "["
                      emit
                      width
                      indent
                      col
                      flat
                      limit
                      buf)
                    flat
                    limit
                    buf)
                  flat
                  limit
                  buf)
                flat
                limit
                buf)]
            [(Empty) col])]
        [_ col])]
    [else (format-rules-layout-cst node emit width indent col flat limit buf)]))

(define (format-rules-layout-arm-hard-tail
  [arms : bool]
  [or-arms : bool]
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-hard-tail-dense
    items.slots
    items.start
    items.len
    arms
    or-arms
    emit
    width
    indent
    col
    flat
    limit
    buf))

;; `(head first arm...)` for match, or `(head arm...)` for a cond that has a
;; multi-form arm, with every arm on its own line. A match arm whose pattern
;; is `(or ...)` fills its alternatives (`format-rules-layout-or-arm`).
(define (format-rules-layout-arms-form
  [head : String]
  [rest : cst.FormatCstList]
  [skip-first : bool]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (let
    [after-head : i64
      (format-rules-layout-text
        head
        emit
        width
        indent
        (format-rules-layout-text "(" emit width indent col flat limit buf)
        flat
        limit
        buf)]
    (format-rules-layout-text
      ")"
      emit
      width
      indent
      (match (cst.fmt-cst-list-step rest)
        [(Item first arms)
          (if skip-first
            (format-rules-layout-arm-hard-tail
              true
              true
              arms
              emit
              width
              (+ indent 2)
              (format-rules-layout-space-cst
                first
                emit
                width
                indent
                after-head
                flat
                limit
                buf)
              flat
              limit
              buf)
            (format-rules-layout-arm-hard-tail
              true
              false
              rest
              emit
              width
              (+ indent 2)
              after-head
              flat
              limit
              buf))]
        [(Empty) after-head])
      flat
      limit
      buf)))

(define (format-rules-layout-tail-separator
  [previous-comment : bool]
  [node : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if (or previous-comment (format-rules-node-comment? node))
    (format-rules-layout-hard-line emit width indent col flat limit buf)
    (format-rules-layout-soft-line emit width indent col flat limit buf)))

(define (format-rules-layout-list-tail-dense
  [previous-comment : bool]
  [slots : (__tl_dyn-array cst.FormatCst)]
  [start : i64]
  [count : i64]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (let
    [index : i64 start]
    [end : i64 (+ start count)]
    [out : i64 col]
    [prev-comment : bool previous-comment]
    [last-comment : bool false]
    (while (< index end)
      (let
        [node : cst.FormatCst
          (owned_view.compiler-owned-array-element-shared-view slots index)]
        [after-separator : i64
          (format-rules-layout-tail-separator
            prev-comment
            (owned_view.compiler-owned-shared-view node)
            emit
            width
            indent
            out
            flat
            limit
            buf)]
        (if (if (format-rules-node-colon?
          (owned_view.compiler-owned-shared-view node))
          (< (+ index 1) end)
          false)
          (let
            [next : cst.FormatCst
              (owned_view.compiler-owned-array-element-shared-view
                slots
                (+ index 1))]
            (if (format-rules-node-comment?
              (owned_view.compiler-owned-shared-view next))
              (begin
                (set!
                  out
                  (format-rules-layout-cst
                    node
                    emit
                    width
                    indent
                    after-separator
                    flat
                    limit
                    buf))
                (set! prev-comment false)
                (set! last-comment false)
                (+= index 1))
              (begin
                (set!
                  out
                  (format-rules-layout-colon-pair
                    node
                    (owned_view.compiler-owned-shared-view next)
                    emit
                    width
                    indent
                    after-separator
                    flat
                    limit
                    buf))
                (set!
                  prev-comment
                  (format-rules-node-comment?
                    (owned_view.compiler-owned-shared-view next)))
                (set! last-comment (format-rules-node-comment? next))
                (+= index 2))))
          (begin
            (set!
              out
              (format-rules-layout-cst
                (owned_view.compiler-owned-shared-view node)
                emit
                width
                indent
                after-separator
                flat
                limit
                buf))
            (set! prev-comment (format-rules-node-comment? node))
            (set! last-comment prev-comment)
            (+= index 1)))))
    (if last-comment
      (format-rules-layout-hard-line emit width indent out flat limit buf)
      out)))

(define (format-rules-layout-list-items-dense
  [slots : (__tl_dyn-array cst.FormatCst)]
  [start : i64]
  [count : i64]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if (<= count 0)
    col
    (let
      [first : cst.FormatCst
        (owned_view.compiler-owned-array-element-shared-view slots start)]
      [after-first : i64
        (format-rules-layout-cst
          (owned_view.compiler-owned-shared-view first)
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      (if (<= count 1)
        (if (format-rules-node-comment? first)
          (format-rules-layout-hard-line
            emit
            width
            indent
            after-first
            flat
            limit
            buf)
          after-first)
        (format-rules-layout-list-tail-dense
          (format-rules-node-comment? first)
          slots
          (+ start 1)
          (- count 1)
          emit
          width
          indent
          after-first
          flat
          limit
          buf)))))

(define (format-rules-layout-list-items
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-list-items-dense
    items.slots
    items.start
    items.len
    emit
    width
    indent
    col
    flat
    limit
    buf))

(define (format-rules-layout-delimited-inner
  [open : String]
  [items : cst.FormatCstList]
  [close : String]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-text
    close
    emit
    width
    indent
    (format-rules-layout-list-items
      items
      emit
      width
      (+ indent 2)
      (format-rules-layout-text open emit width indent col flat limit buf)
      flat
      limit
      buf)
    flat
    limit
    buf))

(define (format-rules-layout-delimited
  [open : String]
  [items : cst.FormatCstList]
  [close : String]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if emit
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-delimited-inner
          (owned_view.compiler-owned-shared-view open)
          (owned_view.compiler-owned-shared-view items)
          (owned_view.compiler-owned-shared-view close)
          false
          width
          indent
          0
          false
          remaining
          buf)]
      (format-rules-layout-delimited-inner
        open
        items
        close
        true
        width
        indent
        col
        (<= flat-width remaining)
        limit
        buf))
    (format-rules-layout-delimited-inner
      open
      items
      close
      false
      width
      indent
      col
      flat
      limit
      buf)))

(define (format-rules-layout-inline-form-inner
  [head : String]
  [rest : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-text
    ")"
    emit
    width
    indent
    (format-rules-layout-inline-tail
      rest
      emit
      width
      indent
      (format-rules-layout-text
        head
        emit
        width
        indent
        (format-rules-layout-text "(" emit width indent col flat limit buf)
        flat
        limit
        buf)
      flat
      limit
      buf)
    flat
    limit
    buf))

(define (format-rules-layout-inline-form
  [head : String]
  [rest : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if emit
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-inline-form-inner
          (owned_view.compiler-owned-shared-view head)
          (owned_view.compiler-owned-shared-view rest)
          false
          width
          indent
          0
          false
          remaining
          buf)]
      (format-rules-layout-inline-form-inner
        head
        rest
        true
        width
        indent
        col
        (<= flat-width remaining)
        limit
        buf))
    (format-rules-layout-inline-form-inner
      head
      rest
      false
      width
      indent
      col
      flat
      limit
      buf)))

(define (format-rules-layout-line-form
  [head : String]
  [rest : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-text
    ")"
    emit
    width
    indent
    (format-rules-layout-hard-tail
      rest
      emit
      width
      (+ indent 2)
      (format-rules-layout-text
        head
        emit
        width
        indent
        (format-rules-layout-text "(" emit width indent col flat limit buf)
        flat
        limit
        buf)
      flat
      limit
      buf)
    flat
    limit
    buf))

(define (format-rules-layout-first-line-form
  [head : String]
  [first : cst.FormatCst]
  [rest : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-text
    ")"
    emit
    width
    indent
    (format-rules-layout-hard-tail
      rest
      emit
      width
      (+ indent 2)
      (format-rules-layout-space-cst
        first
        emit
        width
        indent
        (format-rules-layout-text
          head
          emit
          width
          indent
          (format-rules-layout-text "(" emit width indent col flat limit buf)
          flat
          limit
          buf)
        flat
        limit
        buf)
      flat
      limit
      buf)
    flat
    limit
    buf))

(define (format-rules-layout-first-or-line-form
  [head : String]
  [rest : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (match (cst.fmt-cst-list-step rest)
    [(Empty)
      (format-rules-layout-inline-form
        head
        rest
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [(Item first tail)
      (format-rules-layout-first-line-form
        head
        first
        tail
        emit
        width
        indent
        col
        flat
        limit
        buf)]))

(define (format-rules-layout-let-binding-annotated-inner
  [name : cst.FormatCst]
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [init : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-text
    "]"
    emit
    width
    indent
    (format-rules-layout-cst
      init
      emit
      width
      (+ indent 2)
      (format-rules-layout-soft-line
        emit
        width
        (+ indent 2)
        (format-rules-layout-space-cst
          typ
          emit
          width
          indent
          (format-rules-layout-space-cst
            colon
            emit
            width
            indent
            (format-rules-layout-cst
              name
              emit
              width
              indent
              (format-rules-layout-text
                "["
                emit
                width
                indent
                col
                flat
                limit
                buf)
              flat
              limit
              buf)
            flat
            limit
            buf)
          flat
          limit
          buf)
        flat
        limit
        buf)
      flat
      limit
      buf)
    flat
    limit
    buf))

(define (format-rules-layout-let-binding-annotated
  [name : cst.FormatCst]
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [init : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if emit
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-let-binding-annotated-inner
          (owned_view.compiler-owned-shared-view name)
          (owned_view.compiler-owned-shared-view colon)
          (owned_view.compiler-owned-shared-view typ)
          (owned_view.compiler-owned-shared-view init)
          false
          width
          indent
          0
          false
          remaining
          buf)]
      (format-rules-layout-let-binding-annotated-inner
        name
        colon
        typ
        init
        true
        width
        indent
        col
        (<= flat-width remaining)
        limit
        buf))
    (format-rules-layout-let-binding-annotated-inner
      name
      colon
      typ
      init
      false
      width
      indent
      col
      flat
      limit
      buf)))

(define (format-rules-layout-let-binding-unannotated-inner
  [name : cst.FormatCst]
  [init : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-text
    "]"
    emit
    width
    indent
    (format-rules-layout-cst
      init
      emit
      width
      (+ indent 2)
      (format-rules-layout-soft-line
        emit
        width
        (+ indent 2)
        (format-rules-layout-cst
          name
          emit
          width
          indent
          (format-rules-layout-text "[" emit width indent col flat limit buf)
          flat
          limit
          buf)
        flat
        limit
        buf)
      flat
      limit
      buf)
    flat
    limit
    buf))

(define (format-rules-layout-let-binding-unannotated
  [name : cst.FormatCst]
  [init : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if emit
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-let-binding-unannotated-inner
          (owned_view.compiler-owned-shared-view name)
          (owned_view.compiler-owned-shared-view init)
          false
          width
          indent
          0
          false
          remaining
          buf)]
      (format-rules-layout-let-binding-unannotated-inner
        name
        init
        true
        width
        indent
        col
        (<= flat-width remaining)
        limit
        buf))
    (format-rules-layout-let-binding-unannotated-inner
      name
      init
      false
      width
      indent
      col
      flat
      limit
      buf)))

(define (format-rules-layout-let-item-list
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (match (cst.fmt-cst-list-step items)
    [(Item name after-name)
      (match (cst.fmt-cst-list-step after-name)
        [(Item second after-second)
          (match (cst.fmt-cst-list-step after-second)
            [(Empty)
              (format-rules-layout-let-binding-unannotated
                name
                second
                emit
                width
                indent
                col
                flat
                limit
                buf)]
            [(Item typ after-typ)
              (match (cst.fmt-cst-list-step after-typ)
                [(Item init after-init)
                  (if (cst.fmt-cst-list-empty? after-init)
                    (if (format-rules-node-colon?
                      (owned_view.compiler-owned-shared-view second))
                      (format-rules-layout-let-binding-annotated
                        name
                        second
                        typ
                        init
                        emit
                        width
                        indent
                        col
                        flat
                        limit
                        buf)
                      (format-rules-layout-delimited
                        "["
                        items
                        "]"
                        emit
                        width
                        indent
                        col
                        flat
                        limit
                        buf))
                    (format-rules-layout-delimited
                      "["
                      items
                      "]"
                      emit
                      width
                      indent
                      col
                      flat
                      limit
                      buf))]
                [_
                  (format-rules-layout-delimited
                    "["
                    items
                    "]"
                    emit
                    width
                    indent
                    col
                    flat
                    limit
                    buf)])]
            [_
              (format-rules-layout-delimited
                "["
                items
                "]"
                emit
                width
                indent
                col
                flat
                limit
                buf)])]
        [_
          (format-rules-layout-delimited
            "["
            items
            "]"
            emit
            width
            indent
            col
            flat
            limit
            buf)])]
    [_
      (format-rules-layout-delimited
        "["
        items
        "]"
        emit
        width
        indent
        col
        flat
        limit
        buf)]))

(define (format-rules-layout-let-item
  [node : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (match (owned_view.compiler-owned-shared-view node)
    [(BracketList items)
      (format-rules-layout-let-item-list
        (deref items)
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [_ (format-rules-layout-cst node emit width indent col flat limit buf)]))

(define (format-rules-layout-let-tail-dense
  [slots : (__tl_dyn-array cst.FormatCst)]
  [start : i64]
  [count : i64]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (let
    [end : i64 (+ start count)]
    [out : i64 col]
    [last-comment : bool false]
    (for [index (iterator.range start end)]
      (let
        [node : cst.FormatCst
          (owned_view.compiler-owned-array-element-shared-view slots index)]
        (set!
          out
          (format-rules-layout-let-item
            (owned_view.compiler-owned-shared-view node)
            emit
            width
            indent
            (format-rules-layout-hard-line emit width indent out flat limit buf)
            flat
            limit
            buf))
        (set! last-comment (format-rules-node-comment? node))))
    (if last-comment
      (format-rules-layout-hard-line emit width indent out flat limit buf)
      out)))

(define (format-rules-layout-let-tail
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-let-tail-dense
    items.slots
    items.start
    items.len
    emit
    width
    indent
    col
    flat
    limit
    buf))

(define (format-rules-layout-let
  [rest : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-text
    ")"
    emit
    width
    indent
    (format-rules-layout-let-tail
      (format-rules-let-rest rest)
      emit
      width
      (+ indent 2)
      (format-rules-layout-text
        "let"
        emit
        width
        indent
        (format-rules-layout-text "(" emit width indent col flat limit buf)
        flat
        limit
        buf)
      flat
      limit
      buf)
    flat
    limit
    buf))

(define (format-rules-layout-signature-annotated
  [head : String]
  [target : cst.FormatCst]
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [body-items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-text
    ")"
    emit
    width
    indent
    (format-rules-layout-hard-tail
      body-items
      emit
      width
      (+ indent 2)
      (format-rules-layout-return-type-tail
        colon
        typ
        emit
        width
        (+ indent 2)
        (format-rules-layout-space-cst
          target
          emit
          width
          indent
          (format-rules-layout-text
            head
            emit
            width
            indent
            (format-rules-layout-text "(" emit width indent col flat limit buf)
            flat
            limit
            buf)
          flat
          limit
          buf)
        flat
        limit
        buf)
      flat
      limit
      buf)
    flat
    limit
    buf))

(define (format-rules-layout-define-metadata-annotated
  [target : cst.FormatCst]
  [metadata : cst.FormatCst]
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [body-items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-text
    ")"
    emit
    width
    indent
    (format-rules-layout-hard-tail
      body-items
      emit
      width
      (+ indent 2)
      (format-rules-layout-metadata-return-type-tail
        (owned_view.compiler-owned-shared-view metadata)
        colon
        typ
        emit
        width
        (+ indent 2)
        (format-rules-layout-cst
          metadata
          emit
          width
          (+ indent 2)
          (format-rules-layout-hard-line
            emit
            width
            (+ indent 2)
            (format-rules-layout-space-cst
              target
              emit
              width
              indent
              (format-rules-layout-text
                "define"
                emit
                width
                indent
                (format-rules-layout-text
                  "("
                  emit
                  width
                  indent
                  col
                  flat
                  limit
                  buf)
                flat
                limit
                buf)
              flat
              limit
              buf)
            flat
            limit
            buf)
          flat
          limit
          buf)
        flat
        limit
        buf)
      flat
      limit
      buf)
    flat
    limit
    buf))

(define (format-rules-layout-define-body
  [target : cst.FormatCst]
  [body-items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-text
    ")"
    emit
    width
    indent
    (format-rules-layout-hard-tail
      body-items
      emit
      width
      (+ indent 2)
      (format-rules-layout-space-cst
        target
        emit
        width
        indent
        (format-rules-layout-text
          "define"
          emit
          width
          indent
          (format-rules-layout-text "(" emit width indent col flat limit buf)
          flat
          limit
          buf)
        flat
        limit
        buf)
      flat
      limit
      buf)
    flat
    limit
    buf))

(define (format-rules-layout-define
  [rest : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (match (cst.fmt-cst-list-step rest)
    [(Item target after-target)
      (match (cst.fmt-cst-list-step after-target)
        [(Item second after-second)
          (if (format-rules-node-colon?
            (owned_view.compiler-owned-shared-view second))
            (match (cst.fmt-cst-list-step after-second)
              [(Item typ body)
                (if (cst.fmt-cst-list-empty? body)
                  (format-rules-layout-first-or-line-form
                    "define"
                    rest
                    emit
                    width
                    indent
                    col
                    flat
                    limit
                    buf)
                  (format-rules-layout-signature-annotated
                    "define"
                    target
                    second
                    typ
                    body
                    emit
                    width
                    indent
                    col
                    flat
                    limit
                    buf))]
              [_
                (format-rules-layout-first-or-line-form
                  "define"
                  rest
                  emit
                  width
                  indent
                  col
                  flat
                  limit
                  buf)])
            (if (format-rules-node-colon-list?
              (owned_view.compiler-owned-shared-view second))
              (match (cst.fmt-cst-list-step after-second)
                [(Item colon after-colon)
                  (if (format-rules-node-colon?
                    (owned_view.compiler-owned-shared-view colon))
                    (match (cst.fmt-cst-list-step after-colon)
                      [(Item typ body)
                        (if (cst.fmt-cst-list-empty? body)
                          (format-rules-layout-first-or-line-form
                            "define"
                            rest
                            emit
                            width
                            indent
                            col
                            flat
                            limit
                            buf)
                          (format-rules-layout-define-metadata-annotated
                            target
                            second
                            colon
                            typ
                            body
                            emit
                            width
                            indent
                            col
                            flat
                            limit
                            buf))]
                      [_
                        (format-rules-layout-first-or-line-form
                          "define"
                          rest
                          emit
                          width
                          indent
                          col
                          flat
                          limit
                          buf)])
                    (format-rules-layout-first-or-line-form
                      "define"
                      rest
                      emit
                      width
                      indent
                      col
                      flat
                      limit
                      buf))]
                [_
                  (format-rules-layout-first-or-line-form
                    "define"
                    rest
                    emit
                    width
                    indent
                    col
                    flat
                    limit
                    buf)])
              (format-rules-layout-define-body
                target
                after-target
                emit
                width
                indent
                col
                flat
                limit
                buf)))]
        [_
          (format-rules-layout-first-or-line-form
            "define"
            rest
            emit
            width
            indent
            col
            flat
            limit
            buf)])]
    [_
      (format-rules-layout-first-or-line-form
        "define"
        rest
        emit
        width
        indent
        col
        flat
        limit
        buf)]))

(define (format-rules-layout-defmacro
  [rest : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (match (cst.fmt-cst-list-step rest)
    [(Item target after-target)
      (match (cst.fmt-cst-list-step after-target)
        [(Item colon after-colon)
          (if (format-rules-node-colon?
            (owned_view.compiler-owned-shared-view colon))
            (match (cst.fmt-cst-list-step after-colon)
              [(Item typ body)
                (if (cst.fmt-cst-list-empty? body)
                  (format-rules-layout-first-or-line-form
                    "defmacro"
                    rest
                    emit
                    width
                    indent
                    col
                    flat
                    limit
                    buf)
                  (format-rules-layout-signature-annotated
                    "defmacro"
                    target
                    colon
                    typ
                    body
                    emit
                    width
                    indent
                    col
                    flat
                    limit
                    buf))]
              [_
                (format-rules-layout-first-or-line-form
                  "defmacro"
                  rest
                  emit
                  width
                  indent
                  col
                  flat
                  limit
                  buf)])
            (format-rules-layout-first-or-line-form
              "defmacro"
              rest
              emit
              width
              indent
              col
              flat
              limit
              buf))]
        [_
          (format-rules-layout-first-or-line-form
            "defmacro"
            rest
            emit
            width
            indent
            col
            flat
            limit
            buf)])]
    [_
      (format-rules-layout-first-or-line-form
        "defmacro"
        rest
        emit
        width
        indent
        col
        flat
        limit
        buf)]))

(define (format-rules-layout-lambda
  [rest : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (match (cst.fmt-cst-list-step rest)
    [(Item target after-target)
      (match (cst.fmt-cst-list-step after-target)
        [(Item colon after-colon)
          (if (format-rules-node-colon?
            (owned_view.compiler-owned-shared-view colon))
            (match (cst.fmt-cst-list-step after-colon)
              [(Item typ body)
                (if (cst.fmt-cst-list-empty? body)
                  (format-rules-layout-first-or-line-form
                    "lambda"
                    rest
                    emit
                    width
                    indent
                    col
                    flat
                    limit
                    buf)
                  (format-rules-layout-signature-annotated
                    "lambda"
                    target
                    colon
                    typ
                    body
                    emit
                    width
                    indent
                    col
                    flat
                    limit
                    buf))]
              [_
                (format-rules-layout-first-or-line-form
                  "lambda"
                  rest
                  emit
                  width
                  indent
                  col
                  flat
                  limit
                  buf)])
            (format-rules-layout-first-or-line-form
              "lambda"
              rest
              emit
              width
              indent
              col
              flat
              limit
              buf))]
        [_
          (format-rules-layout-first-or-line-form
            "lambda"
            rest
            emit
            width
            indent
            col
            flat
            limit
            buf)])]
    [_
      (format-rules-layout-first-or-line-form
        "lambda"
        rest
        emit
        width
        indent
        col
        flat
        limit
        buf)]))

;; A loop ends with a body expression after its bracketed binding clauses. A
;; signature that only declares bracketed parameters, such as the prelude's own
;; `(defmacro (for [bindings : ExprBindingClause ...] [body : Expr ...]) ...)`,
;; keeps the ordinary call layout. Trailing comments do not decide.
(define (format-rules-loop-form-from?
  [items : (& items cst.FormatCstList)]
  [ends-in-body : bool]) : bool
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) ends-in-body]
    [(cst.FormatCstListStep.Item node tail)
      (format-rules-loop-form-from?
        tail
        (match node
          [(cst.FormatCst.BracketList _) false]
          [(cst.FormatCst.Comment _) ends-in-body]
          [_ true]))]))

(define (format-rules-node-or-list? [node : cst.FormatCst]) : bool
  (match node
    [(List items)
      (match (cst.fmt-cst-list-step (deref items))
        [(Item head _) (string.eq (format-rules-node-symbol-name head) "or")]
        [_ false])]
    [_ false]))

;; Whether `node` is a `[pattern body...]` arm whose pattern is `(or ...)`.
(define (format-rules-arm-or-pattern? [node : cst.FormatCst]) : bool
  (match node
    [(BracketList items)
      (match (cst.fmt-cst-list-step (deref items))
        [(Item pattern _) (format-rules-node-or-list? pattern)]
        [_ false])]
    [_ false]))

;; A match arm with an `(or ...)` pattern is delimited like any arm, but the
;; pattern fills its alternatives. The emitting pass first measures whether
;; the whole arm fits flat on its line.
(define (format-rules-layout-or-arm
  [node : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (match (owned_view.compiler-owned-shared-view node)
    [(BracketList items)
      (if emit
        (let
          [remaining : i64 (- width col)]
          [flat-width : i64
            (format-rules-layout-or-arm-inner
              (owned_view.compiler-owned-box-shared-view items)
              false
              width
              indent
              0
              false
              remaining
              buf)]
          (format-rules-layout-or-arm-inner
            (owned_view.compiler-owned-box-shared-view items)
            true
            width
            indent
            col
            (<= flat-width remaining)
            limit
            buf))
        (format-rules-layout-or-arm-inner
          (owned_view.compiler-owned-box-shared-view items)
          false
          width
          indent
          col
          flat
          limit
          buf))]
    [_ (format-rules-layout-cst node emit width indent col flat limit buf)]))

(define (format-rules-layout-or-arm-inner
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (let
    [pattern : cst.FormatCst
      (owned_view.compiler-owned-array-element-shared-view
        items.slots
        items.start)]
    [after-pattern : i64
      (format-rules-layout-or-fill
        (owned_view.compiler-owned-shared-view pattern)
        emit
        width
        (+ indent 2)
        (format-rules-layout-text "[" emit width indent col flat limit buf)
        flat
        limit
        buf)]
    (format-rules-layout-text
      "]"
      emit
      width
      indent
      (cond
        [(<= items.len 1) after-pattern]
        [(> (format-rules-arm-form-count (& items)) 2)
          (format-rules-layout-hard-tail-dense
            items.slots
            (+ items.start 1)
            (- items.len 1)
            false
            false
            emit
            width
            (+ indent 2)
            after-pattern
            flat
            limit
            buf)]
        [else
          (format-rules-layout-list-tail-dense
            (format-rules-node-comment? pattern)
            items.slots
            (+ items.start 1)
            (- items.len 1)
            emit
            width
            (+ indent 2)
            after-pattern
            flat
            limit
            buf)])
      flat
      limit
      buf)))

;; An `(or ...)` pattern that does not fit on its line packs as many
;; alternatives per line as fit, each continuation line aligned under the first
;; alternative. A comment between alternatives stays on its own line.
(define (format-rules-layout-or-fill
  [node : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if (not emit)
    (format-rules-layout-cst node false width indent col flat limit buf)
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-cst
          (owned_view.compiler-owned-shared-view node)
          false
          width
          indent
          0
          false
          remaining
          buf)]
      (if (<= flat-width remaining)
        (format-rules-layout-cst node true width indent col true limit buf)
        (match (owned_view.compiler-owned-shared-view node)
          [(cst.FormatCst.List boxed)
            (let
              [items : cst.FormatCstList (deref boxed)]
              [align : i64 (+ col 4)]
              [end : i64 (+ items.start items.len)]
              [out : i64
                (format-rules-layout-text
                  "(or"
                  true
                  width
                  indent
                  col
                  flat
                  limit
                  buf)]
              [first : bool true]
              [break-next : bool false]
              (for [index (iterator.range (+ items.start 1) end)]
                (let
                  [alternative : cst.FormatCst
                    (owned_view.compiler-owned-array-element-shared-view
                      items.slots
                      index)]
                  (if (format-rules-node-comment?
                    (owned_view.compiler-owned-shared-view alternative))
                    (begin
                      (set!
                        out
                        (format-rules-layout-cst
                          (owned_view.compiler-owned-shared-view alternative)
                          true
                          width
                          align
                          (if first
                            (format-rules-layout-text
                              " "
                              true
                              width
                              align
                              out
                              flat
                              limit
                              buf)
                            (format-rules-layout-hard-line
                              true
                              width
                              align
                              out
                              flat
                              limit
                              buf))
                          flat
                          limit
                          buf))
                      (set! break-next true))
                    (let
                      [alternative-width : i64
                        (format-rules-layout-cst
                          (owned_view.compiler-owned-shared-view alternative)
                          false
                          width
                          align
                          0
                          false
                          (- width align)
                          buf)]
                      ;; The last alternative also needs room for `)`.
                      [needed : i64
                        (+
                          out
                          1
                          alternative-width
                          (if (= index (- end 1))
                            1
                            0))]
                      (set!
                        out
                        (format-rules-layout-cst
                          (owned_view.compiler-owned-shared-view alternative)
                          true
                          width
                          align
                          (if (or break-next (and (not first) (> needed width)))
                            (format-rules-layout-hard-line
                              true
                              width
                              align
                              out
                              flat
                              limit
                              buf)
                            (format-rules-layout-text
                              " "
                              true
                              width
                              align
                              out
                              flat
                              limit
                              buf))
                          flat
                          limit
                          buf))
                      (set! break-next false)))
                  (set! first false)))
              (format-rules-layout-text
                ")"
                true
                width
                indent
                (if break-next
                  (format-rules-layout-hard-line
                    true
                    width
                    align
                    out
                    flat
                    limit
                    buf)
                  out)
                flat
                limit
                buf))]
          [_
            (format-rules-layout-cst node true width indent col flat limit buf)])))))

(define (format-rules-layout-special-list
  [head : cst.FormatCst]
  [rest : cst.FormatCstList]
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (let
    [head-name : String (format-rules-node-symbol-name head)]
    (cond
      [(string.eq head-name "import")
        (format-rules-layout-inline-form
          "import"
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [(string.eq head-name "include-str")
        (format-rules-layout-inline-form
          "include-str"
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [(string.eq head-name "extern")
        (format-rules-layout-inline-form
          "extern"
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [(string.eq head-name "define")
        (format-rules-layout-define rest emit width indent col flat limit buf)]
      [(string.eq head-name "defmacro")
        (format-rules-layout-defmacro rest emit width indent col flat limit buf)]
      [(string.eq head-name "defenum")
        (format-rules-layout-first-or-line-form
          "defenum"
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [(string.eq head-name "defstruct")
        (format-rules-layout-first-or-line-form
          "defstruct"
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [(string.eq head-name "lambda")
        (format-rules-layout-lambda rest emit width indent col flat limit buf)]
      [(string.eq head-name "let")
        (format-rules-layout-let rest emit width indent col flat limit buf)]
      [(string.eq head-name "if")
        (format-rules-layout-first-or-line-form
          "if"
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [(string.eq head-name "while")
        (format-rules-layout-first-or-line-form
          "while"
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      ;; The prelude loops keep their first binding clause beside the head and
      ;; their body below it, like `while`.
      [(and
          (or
            (string.eq head-name "for")
            (string.eq head-name "any?")
            (string.eq head-name "all?"))
          (format-rules-loop-form-from? rest false))
        (format-rules-layout-first-or-line-form
          head-name
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [(string.eq head-name "begin")
        (format-rules-layout-line-form
          "begin"
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [(string.eq head-name "unsafe")
        (format-rules-layout-line-form
          "unsafe"
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [(string.eq head-name "match")
        (match (cst.fmt-cst-list-step rest)
          [(Empty)
            (format-rules-layout-inline-form
              "match"
              rest
              emit
              width
              indent
              col
              flat
              limit
              buf)]
          [(Item _ _)
            (format-rules-layout-arms-form
              "match"
              rest
              true
              emit
              width
              indent
              col
              flat
              limit
              buf)])]
      [(and
          (string.eq head-name "cond")
          (format-rules-arms-have-sequence? (& rest)))
        (format-rules-layout-arms-form
          "cond"
          rest
          false
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [(string.eq head-name "specialization")
        (format-rules-layout-line-form
          "specialization"
          rest
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [else
        (format-rules-layout-delimited
          "("
          items
          ")"
          emit
          width
          indent
          col
          flat
          limit
          buf)])))

(define (format-rules-layout-colon-list
  [rest : cst.FormatCstList]
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (match (cst.fmt-cst-list-step rest)
    [(Item key tail)
      (let
        [name : String (format-rules-node-symbol-name key)]
        (if (> (string.string-length name) 0)
          (if (string.eq name "spmd-callable")
            (format-rules-layout-line-form
              ":spmd-callable"
              tail
              emit
              width
              indent
              col
              flat
              limit
              buf)
            (format-rules-layout-inline-form
              (str_cat.str-cat ":" name)
              tail
              emit
              width
              indent
              col
              flat
              limit
              buf))
          (format-rules-layout-delimited
            "("
            items
            ")"
            emit
            width
            indent
            col
            flat
            limit
            buf)))]
    [_
      (format-rules-layout-delimited
        "("
        items
        ")"
        emit
        width
        indent
        col
        flat
        limit
        buf)]))

(define (format-rules-layout-list
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (match (cst.fmt-cst-list-step items)
    [(Empty)
      (format-rules-layout-delimited
        "("
        items
        ")"
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [(Item head rest)
      (if (format-rules-node-colon?
        (owned_view.compiler-owned-shared-view head))
        (format-rules-layout-colon-list
          rest
          items
          emit
          width
          indent
          col
          flat
          limit
          buf)
        (format-rules-layout-special-list
          head
          rest
          items
          emit
          width
          indent
          col
          flat
          limit
          buf))]))

(define (format-rules-layout-forms-separator-state
  [previous-comment : bool]
  [previous-family : (& previous-family str)]
  [node : cst.FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if previous-comment
    (format-rules-layout-hard-line emit width indent col flat limit buf)
    (let
      [node-family : String (format-rules-top-form-family node)]
      (if (and
        (> (string.string-length previous-family) 0)
        (string.eq previous-family node-family))
        (format-rules-layout-hard-line emit width indent col flat limit buf)
        (format-rules-layout-hard-line
          emit
          width
          indent
          (format-rules-layout-hard-line emit width indent col flat limit buf)
          flat
          limit
          buf)))))

(define (format-rules-layout-forms-dense
  [slots : (__tl_dyn-array cst.FormatCst)]
  [start : i64]
  [count : i64]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if (<= count 0)
    col
    (let
      [first : cst.FormatCst
        (owned_view.compiler-owned-array-element-shared-view slots start)]
      [end : i64 (+ start count)]
      [out : i64
        (format-rules-layout-cst
          (owned_view.compiler-owned-shared-view first)
          emit
          width
          indent
          col
          flat
          limit
          buf)]
      [previous-comment : bool
        (format-rules-node-comment?
          (owned_view.compiler-owned-shared-view first))]
      [previous-family : String (format-rules-top-form-family first)]
      (for [index (iterator.range (+ start 1) end)]
        (let
          [node : cst.FormatCst
            (owned_view.compiler-owned-array-element-shared-view slots index)]
          (set!
            out
            (format-rules-layout-cst
              (owned_view.compiler-owned-shared-view node)
              emit
              width
              indent
              (format-rules-layout-forms-separator-state
                previous-comment
                previous-family
                (owned_view.compiler-owned-shared-view node)
                emit
                width
                indent
                out
                flat
                limit
                buf)
              flat
              limit
              buf))
          (set!
            previous-comment
            (format-rules-node-comment?
              (owned_view.compiler-owned-shared-view node)))
          (set! previous-family (format-rules-top-form-family node))))
      out)))

(define (format-rules-layout-forms
  [items : cst.FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-forms-dense
    items.slots
    items.start
    items.len
    emit
    width
    indent
    col
    flat
    limit
    buf))

(define (format-rules-render-hard-line-into
  [indent : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (fmt_buf.render-newline-into! buf indent)
  indent)

(define (format-rules-render-gap-into
  [indent : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-render-hard-line-into
    (format-rules-render-hard-line-into indent buf)
    buf))

(define (format-rules-render-forms-separator-state-into
  [previous-comment : bool]
  [previous-family : (& previous-family str)]
  [node : cst.FormatCst]
  [indent : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if previous-comment
    (format-rules-render-hard-line-into indent buf)
    (let
      [node-family : String (format-rules-top-form-family node)]
      (if (and
        (> (string.string-length previous-family) 0)
        (string.eq previous-family node-family))
        (format-rules-render-hard-line-into indent buf)
        (format-rules-render-gap-into indent buf)))))

(define (format-rules-render-node-fragment-into
  [node : cst.FormatCst]
  [width : i64]
  [indent : i64]
  [col : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-layout-cst node true width indent col false 0 buf))

(define (format-rules-render-forms-into-dense
  [slots : (__tl_dyn-array cst.FormatCst)]
  [start : i64]
  [count : i64]
  [width : i64]
  [indent : i64]
  [col : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (if (<= count 0)
    col
    (let
      [first : cst.FormatCst
        (owned_view.compiler-owned-array-element-shared-view slots start)]
      [end : i64 (+ start count)]
      [out : i64
        (format-rules-render-node-fragment-into
          (owned_view.compiler-owned-shared-view first)
          width
          indent
          col
          buf)]
      [previous-comment : bool
        (format-rules-node-comment?
          (owned_view.compiler-owned-shared-view first))]
      [previous-family : String (format-rules-top-form-family first)]
      (for [index (iterator.range (+ start 1) end)]
        (let
          [node : cst.FormatCst
            (owned_view.compiler-owned-array-element-shared-view slots index)]
          [after-separator : i64
            (format-rules-render-forms-separator-state-into
              previous-comment
              previous-family
              (owned_view.compiler-owned-shared-view node)
              indent
              buf)]
          (set!
            out
            (format-rules-render-node-fragment-into
              (owned_view.compiler-owned-shared-view node)
              width
              indent
              after-separator
              buf))
          (set!
            previous-comment
            (format-rules-node-comment?
              (owned_view.compiler-owned-shared-view node)))
          (set! previous-family (format-rules-top-form-family node))))
      out)))

(define (format-rules-render-forms-into
  [items : cst.FormatCstList]
  [width : i64]
  [indent : i64]
  [col : i64]
  [buf : (&mut buf fmt_buf.FmtRenderBuf)]) : i64
  (format-rules-render-forms-into-dense
    items.slots
    items.start
    items.len
    width
    indent
    col
    buf))

(define (format-rules-render-cst-width [node : cst.FormatCst] [width : i64]) : String
  (let
    [buf : fmt_buf.FmtRenderBuf (fmt_buf.fmt-render-buf-new)]
    (match (owned_view.compiler-owned-shared-view node)
      [(Forms items)
        (format-rules-render-forms-into (deref items) width 0 0 (&mut buf))]
      [_ (format-rules-render-node-fragment-into node width 0 0 (&mut buf))])
    (fmt_buf.fmt-render-buf-string buf)))

(define (format-rules-render-source-width-result [src : String] [width : i64]) : ResultFormatString
  (let
    [tree (try (cst.parse-format-source-result src))]
    (Ok (format-rules-render-cst-width tree width))))