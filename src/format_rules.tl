;; format_rules.tl - TypeLisp-aware formatter rules (#367).
;;
;; `format_core.tl` stays syntax-neutral. This module adds deterministic
;; gofmt-like rules for common TypeLisp special forms. The normal source
;; formatting path renders those rules directly from the CST; doc-algebra
;; compatibility coverage lives in format_rules_doc_compat.tl so production CLI
;; builds do not import the full document algebra.
(import "../stdlib/io.tl")
(import "format_tokens.tl")
(import "format_cst.tl")
(import "format_render_buf.tl")
(import "../stdlib/string.tl")

(defenum ResultFormatString
  (OkFormatString String)
  (ErrFormatString FormatSourceError))

(define (format-rules-node-symbol? [node : FormatCst] [wanted : String]) : bool
  (match node
    [(FmtCstAtom tok)
      (match tok
        [(FmtSymbol name) (string-eq name wanted)]
        [_ false])]
    [_ false]))

(define (format-rules-node-colon? [node : FormatCst]) : bool
  (match node
    [(FmtCstAtom tok) (= (format-token-tag tok) (fmt-tag-colon))]
    [_ false]))

(define (format-rules-node-symbol-name [node : FormatCst]) : String
  (match node
    [(FmtCstAtom tok)
      (match tok
        [(FmtSymbol name) name]
        [_ ""])]
    [_ ""]))

(define (format-rules-node-comment? [node : FormatCst]) : bool
  (match node
    [(FmtCstComment _) true]
    [_ false]))

(define (format-rules-node-colon-list? [node : FormatCst]) : bool
  (match node
    [(FmtCstList items)
      (match (fmt-cst-list-step (box-get items))
        [(FmtCstListStepItem head _) (format-rules-node-colon? head)]
        [_ false])]
    [_ false]))

(define (format-rules-define-value-rest? [rest : FormatCstList]) : bool
  (match (fmt-cst-list-step rest)
    [(FmtCstListStepItem target _)
      (match target
        [(FmtCstList _) false]
        [_ true])]
    [_ false]))

(define (format-rules-cfg-top-form-family [rest : FormatCstList]) : String
  (match (fmt-cst-list-step rest)
    [(FmtCstListStepItem _ after-predicate)
      (match (fmt-cst-list-step after-predicate)
        [(FmtCstListStepItem inner _) (format-rules-top-form-family inner)]
        [_ ""])]
    [_ ""]))

(define (format-rules-top-form-family-list [items : FormatCstList]) : String
  (match (fmt-cst-list-step items)
    [(FmtCstListStepItem head rest)
      (let
        [head-name : String (format-rules-node-symbol-name head)]
        (cond
          [(string-eq head-name "import") "import"]
          [(string-eq head-name "extern") "extern"]
          [(string-eq head-name "include-str") "include-str"]
          [(string-eq head-name "define")
            (if (format-rules-define-value-rest? rest)
              "define"
              "")]
          [(string-eq head-name "cfg") (format-rules-cfg-top-form-family rest)]
          [else ""]))]
    [_ ""]))

(define (format-rules-top-form-family [node : FormatCst]) : String
  (match node
    [(FmtCstList items) (format-rules-top-form-family-list (box-get items))]
    [_ ""]))

(define (format-rules-adjacent-top-forms?
  [previous : FormatCst]
  [node : FormatCst]) : bool
  (let
    [previous-family : String (format-rules-top-form-family previous)]
    [node-family : String (format-rules-top-form-family node)]
    (and
      (> (string-length previous-family) 0)
      (string-eq previous-family node-family))))

(define (format-rules-list-append
  [left : FormatCstList]
  [right : FormatCstList]) : FormatCstList
  (match (fmt-cst-list-step left)
    [(FmtCstListStepEmpty) right]
    [(FmtCstListStepItem node rest)
      (FmtCstCons node (box (format-rules-list-append rest right)))]))

(define (format-rules-bracket-binding-items?
  [items : FormatCstList]
  [seen : bool]) : bool
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty) seen]
    [(FmtCstListStepItem node rest)
      (match node
        [(FmtCstComment _) (format-rules-bracket-binding-items? rest seen)]
        [(FmtCstBracketList _) (format-rules-bracket-binding-items? rest true)]
        [_ false])]))

(define (format-rules-bracket-binding-list? [items : FormatCstList]) : bool
  (format-rules-bracket-binding-items? items false))

(define (format-rules-let-rest [rest : FormatCstList]) : FormatCstList
  (match (fmt-cst-list-step rest)
    [(FmtCstListStepItem first tail)
      (match first
        [(FmtCstList bindings)
          (if (format-rules-bracket-binding-list? (box-get bindings))
            (format-rules-list-append (box-get bindings) tail)
            rest)]
        [_ rest])]
    [_ rest]))

;; Direct CST layout interpreter for the normal `fmt`/LSP path. `emit=false`
;; computes the same capped flat width as `flat-width-capped`; `emit=true`
;; writes the same bytes as `render-doc-into`. Keeping both modes in one set of
;; rule walkers prevents the hot path from allocating per-form Doc trees while
;; preserving the existing grouping decisions.
(define (format-rules-layout-text
  [text : String]
  [emit : bool]
  [_width : i64]
  [_indent : i64]
  [col : i64]
  [_flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (if emit
    (let
      [text-width : i64 (string-length text)]
      (begin
        (fmt-render-buf-append buf text)
        (+ col text-width)))
    (if (> col limit)
      col
      (+ col (string-length text)))))

(define (format-rules-layout-soft-line
  [emit : bool]
  [_width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (if emit
    (if flat
      (begin
        (fmt-render-buf-append buf " ")
        (+ col 1))
      (begin
        (render-newline-into! buf indent)
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
  [buf : FmtRenderBuf]) : i64
  (if emit
    (begin
      (render-newline-into! buf indent)
      indent)
    (if (> col limit)
      col
      (+ col 1000000))))

(define (format-rules-layout-cst
  [node : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match node
    [(FmtCstAtom tok)
      (format-rules-layout-text
        (format-token-text tok)
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [(FmtCstComment text)
      (format-rules-layout-text text emit width indent col flat limit buf)]
    [(FmtCstPrefix tok child)
      (format-rules-layout-cst
        (box-get child)
        emit
        width
        indent
        (format-rules-layout-text
          (format-token-text tok)
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
    [(FmtCstList items)
      (format-rules-layout-list
        (box-get items)
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [(FmtCstBracketList items)
      (format-rules-layout-delimited
        "["
        (box-get items)
        "]"
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [(FmtCstForms items)
      (format-rules-layout-forms
        (box-get items)
        emit
        width
        indent
        col
        flat
        limit
        buf)]))

(define (format-rules-layout-space-cst
  [node : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [colon : FormatCst]
  [next : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [colon : FormatCst]
  [typ : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [colon : FormatCst]
  [typ : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [colon : FormatCst]
  [typ : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (if emit
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-return-type-breakable-tail-inner
          colon
          typ
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

(define (format-rules-layout-inline-tail
  [items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty) col]
    [(FmtCstListStepItem node rest)
      (format-rules-layout-inline-tail
        rest
        emit
        width
        indent
        (format-rules-layout-space-cst
          node
          emit
          width
          indent
          col
          flat
          limit
          buf)
        flat
        limit
        buf)]))

(define (format-rules-layout-hard-tail
  [items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty) col]
    [(FmtCstListStepItem node tail)
      (if (format-rules-node-colon? node)
        (match (fmt-cst-list-step tail)
          [(FmtCstListStepItem next after-next)
            (if (format-rules-node-comment? next)
              (let
                [after-line : i64
                  (format-rules-layout-hard-line
                    emit
                    width
                    indent
                    col
                    flat
                    limit
                    buf)]
                [after-node : i64
                  (format-rules-layout-cst
                    node
                    emit
                    width
                    indent
                    after-line
                    flat
                    limit
                    buf)]
                (format-rules-layout-hard-tail
                  tail
                  emit
                  width
                  indent
                  after-node
                  flat
                  limit
                  buf))
              (let
                [after-line : i64
                  (format-rules-layout-hard-line
                    emit
                    width
                    indent
                    col
                    flat
                    limit
                    buf)]
                [after-pair : i64
                  (format-rules-layout-colon-pair
                    node
                    next
                    emit
                    width
                    indent
                    after-line
                    flat
                    limit
                    buf)]
                (if (fmt-cst-list-empty? after-next)
                  after-pair
                  (format-rules-layout-hard-tail
                    after-next
                    emit
                    width
                    indent
                    after-pair
                    flat
                    limit
                    buf))))]
          [_
            (format-rules-layout-cst
              node
              emit
              width
              indent
              (format-rules-layout-hard-line
                emit
                width
                indent
                col
                flat
                limit
                buf)
              flat
              limit
              buf)])
        (let
          [after-node : i64
            (format-rules-layout-cst
              node
              emit
              width
              indent
              (format-rules-layout-hard-line
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
          (if (fmt-cst-list-empty? tail)
            (if (format-rules-node-comment? node)
              (format-rules-layout-hard-line
                emit
                width
                indent
                after-node
                flat
                limit
                buf)
              after-node)
            (format-rules-layout-hard-tail
              tail
              emit
              width
              indent
              after-node
              flat
              limit
              buf))))]))

(define (format-rules-layout-tail-separator
  [previous-comment : bool]
  [node : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (if (or previous-comment (format-rules-node-comment? node))
    (format-rules-layout-hard-line emit width indent col flat limit buf)
    (format-rules-layout-soft-line emit width indent col flat limit buf)))

(define (format-rules-layout-list-tail
  [previous-comment : bool]
  [items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty) col]
    [(FmtCstListStepItem node tail)
      (let
        [after-separator : i64
          (format-rules-layout-tail-separator
            previous-comment
            node
            emit
            width
            indent
            col
            flat
            limit
            buf)]
        (if (format-rules-node-colon? node)
          (match (fmt-cst-list-step tail)
            [(FmtCstListStepItem next after-next)
              (if (format-rules-node-comment? next)
                (format-rules-layout-list-tail
                  false
                  tail
                  emit
                  width
                  indent
                  (format-rules-layout-cst
                    node
                    emit
                    width
                    indent
                    after-separator
                    flat
                    limit
                    buf)
                  flat
                  limit
                  buf)
                (let
                  [after-pair : i64
                    (format-rules-layout-colon-pair
                      node
                      next
                      emit
                      width
                      indent
                      after-separator
                      flat
                      limit
                      buf)]
                  (if (fmt-cst-list-empty? after-next)
                    after-pair
                    (format-rules-layout-list-tail
                      (format-rules-node-comment? next)
                      after-next
                      emit
                      width
                      indent
                      after-pair
                      flat
                      limit
                      buf))))]
            [_
              (format-rules-layout-cst
                node
                emit
                width
                indent
                after-separator
                flat
                limit
                buf)])
          (let
            [after-node : i64
              (format-rules-layout-cst
                node
                emit
                width
                indent
                after-separator
                flat
                limit
                buf)]
            (if (fmt-cst-list-empty? tail)
              (if (format-rules-node-comment? node)
                (format-rules-layout-hard-line
                  emit
                  width
                  indent
                  after-node
                  flat
                  limit
                  buf)
                after-node)
              (format-rules-layout-list-tail
                (format-rules-node-comment? node)
                tail
                emit
                width
                indent
                after-node
                flat
                limit
                buf)))))]))

(define (format-rules-layout-list-items
  [items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty) col]
    [(FmtCstListStepItem node tail)
      (let
        [after-node : i64
          (format-rules-layout-cst node emit width indent col flat limit buf)]
        (if (fmt-cst-list-empty? tail)
          (if (format-rules-node-comment? node)
            (format-rules-layout-hard-line
              emit
              width
              indent
              after-node
              flat
              limit
              buf)
            after-node)
          (format-rules-layout-list-tail
            (format-rules-node-comment? node)
            tail
            emit
            width
            indent
            after-node
            flat
            limit
            buf)))]))

(define (format-rules-layout-delimited-inner
  [open : String]
  [items : FormatCstList]
  [close : String]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [items : FormatCstList]
  [close : String]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (if emit
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-delimited-inner
          open
          items
          close
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
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (if emit
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-inline-form-inner
          head
          rest
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
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [first : FormatCst]
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step rest)
    [(FmtCstListStepEmpty)
      (format-rules-layout-inline-form
        head
        FmtCstNil
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [(FmtCstListStepItem first tail)
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
  [name : FormatCst]
  [colon : FormatCst]
  [typ : FormatCst]
  [init : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [name : FormatCst]
  [colon : FormatCst]
  [typ : FormatCst]
  [init : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (if emit
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-let-binding-annotated-inner
          name
          colon
          typ
          init
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
  [name : FormatCst]
  [init : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [name : FormatCst]
  [init : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (if emit
    (let
      [remaining : i64 (- width col)]
      [flat-width : i64
        (format-rules-layout-let-binding-unannotated-inner
          name
          init
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
  [items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepItem name after-name)
      (match (fmt-cst-list-step after-name)
        [(FmtCstListStepItem second after-second)
          (match (fmt-cst-list-step after-second)
            [(FmtCstListStepEmpty)
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
            [(FmtCstListStepItem typ after-typ)
              (match (fmt-cst-list-step after-typ)
                [(FmtCstListStepItem init after-init)
                  (if (fmt-cst-list-empty? after-init)
                    (if (format-rules-node-colon? second)
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
  [node : FormatCst]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match node
    [(FmtCstBracketList items)
      (format-rules-layout-let-item-list
        (box-get items)
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [_ (format-rules-layout-cst node emit width indent col flat limit buf)]))

(define (format-rules-layout-let-tail
  [items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty) col]
    [(FmtCstListStepItem node tail)
      (let
        [after-node : i64
          (format-rules-layout-let-item
            node
            emit
            width
            indent
            (format-rules-layout-hard-line emit width indent col flat limit buf)
            flat
            limit
            buf)]
        (if (fmt-cst-list-empty? tail)
          (if (format-rules-node-comment? node)
            (format-rules-layout-hard-line
              emit
              width
              indent
              after-node
              flat
              limit
              buf)
            after-node)
          (format-rules-layout-let-tail
            tail
            emit
            width
            indent
            after-node
            flat
            limit
            buf)))]))

(define (format-rules-layout-let
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [target : FormatCst]
  [colon : FormatCst]
  [typ : FormatCst]
  [body-items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [target : FormatCst]
  [metadata : FormatCst]
  [colon : FormatCst]
  [typ : FormatCst]
  [body-items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
      (format-rules-layout-return-type-breakable-tail
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
  [target : FormatCst]
  [body-items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
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
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step rest)
    [(FmtCstListStepItem target after-target)
      (match (fmt-cst-list-step after-target)
        [(FmtCstListStepItem second after-second)
          (if (format-rules-node-colon? second)
            (match (fmt-cst-list-step after-second)
              [(FmtCstListStepItem typ body)
                (if (fmt-cst-list-empty? body)
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
            (if (format-rules-node-colon-list? second)
              (match (fmt-cst-list-step after-second)
                [(FmtCstListStepItem colon after-colon)
                  (if (format-rules-node-colon? colon)
                    (match (fmt-cst-list-step after-colon)
                      [(FmtCstListStepItem typ body)
                        (if (fmt-cst-list-empty? body)
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
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step rest)
    [(FmtCstListStepItem target after-target)
      (match (fmt-cst-list-step after-target)
        [(FmtCstListStepItem colon after-colon)
          (if (format-rules-node-colon? colon)
            (match (fmt-cst-list-step after-colon)
              [(FmtCstListStepItem typ body)
                (if (fmt-cst-list-empty? body)
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
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step rest)
    [(FmtCstListStepItem target after-target)
      (match (fmt-cst-list-step after-target)
        [(FmtCstListStepItem colon after-colon)
          (if (format-rules-node-colon? colon)
            (match (fmt-cst-list-step after-colon)
              [(FmtCstListStepItem typ body)
                (if (fmt-cst-list-empty? body)
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

(define (format-rules-layout-special-list
  [head : FormatCst]
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (let
    [head-name : String (format-rules-node-symbol-name head)]
    (cond
      [(string-eq head-name "import")
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
      [(string-eq head-name "include-str")
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
      [(string-eq head-name "extern")
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
      [(string-eq head-name "define")
        (format-rules-layout-define rest emit width indent col flat limit buf)]
      [(string-eq head-name "defmacro")
        (format-rules-layout-defmacro rest emit width indent col flat limit buf)]
      [(string-eq head-name "defenum")
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
      [(string-eq head-name "defstruct")
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
      [(string-eq head-name "lambda")
        (format-rules-layout-lambda rest emit width indent col flat limit buf)]
      [(string-eq head-name "let")
        (format-rules-layout-let rest emit width indent col flat limit buf)]
      [(string-eq head-name "if")
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
      [(string-eq head-name "while")
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
      [(string-eq head-name "begin")
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
      [(string-eq head-name "unsafe")
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
      [(string-eq head-name "match")
        (format-rules-layout-first-or-line-form
          "match"
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
          (FmtCstCons head (box rest))
          ")"
          emit
          width
          indent
          col
          flat
          limit
          buf)])))

(define (format-rules-layout-colon-list
  [rest : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step rest)
    [(FmtCstListStepItem key tail)
      (let
        [name : String (format-rules-node-symbol-name key)]
        (if (> (string-length name) 0)
          (format-rules-layout-inline-form
            (string-append ":" name)
            tail
            emit
            width
            indent
            col
            flat
            limit
            buf)
          (format-rules-layout-delimited
            "("
            (FmtCstCons (FmtCstAtom (FmtColon)) (box rest))
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
        (FmtCstCons (FmtCstAtom (FmtColon)) (box rest))
        ")"
        emit
        width
        indent
        col
        flat
        limit
        buf)]))

(define (format-rules-layout-list
  [items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty)
      (format-rules-layout-delimited
        "("
        FmtCstNil
        ")"
        emit
        width
        indent
        col
        flat
        limit
        buf)]
    [(FmtCstListStepItem head rest)
      (if (format-rules-node-colon? head)
        (format-rules-layout-colon-list
          rest
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
          emit
          width
          indent
          col
          flat
          limit
          buf))]))

(define (format-rules-layout-forms-tail
  [previous : FormatCst]
  [items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty) col]
    [(FmtCstListStepItem node rest)
      (format-rules-layout-forms-tail
        node
        rest
        emit
        width
        indent
        (format-rules-layout-cst
          node
          emit
          width
          indent
          (if (format-rules-node-comment? previous)
            (format-rules-layout-hard-line emit width indent col flat limit buf)
            (if (format-rules-adjacent-top-forms? previous node)
              (format-rules-layout-hard-line
                emit
                width
                indent
                col
                flat
                limit
                buf)
              (format-rules-layout-hard-line
                emit
                width
                indent
                (format-rules-layout-hard-line
                  emit
                  width
                  indent
                  col
                  flat
                  limit
                  buf)
                flat
                limit
                buf)))
          flat
          limit
          buf)
        flat
        limit
        buf)]))

(define (format-rules-layout-forms
  [items : FormatCstList]
  [emit : bool]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [limit : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty) col]
    [(FmtCstListStepItem node rest)
      (format-rules-layout-forms-tail
        node
        rest
        emit
        width
        indent
        (format-rules-layout-cst node emit width indent col flat limit buf)
        flat
        limit
        buf)]))

(define (format-rules-render-hard-line-into [indent : i64] [buf : FmtRenderBuf]) : i64
  (begin
    (render-newline-into! buf indent)
    indent))

(define (format-rules-render-gap-into [indent : i64] [buf : FmtRenderBuf]) : i64
  (format-rules-render-hard-line-into
    (format-rules-render-hard-line-into indent buf)
    buf))

(define (format-rules-render-forms-separator-into
  [previous : FormatCst]
  [node : FormatCst]
  [indent : i64]
  [buf : FmtRenderBuf]) : i64
  (if (format-rules-node-comment? previous)
    (format-rules-render-hard-line-into indent buf)
    (if (format-rules-adjacent-top-forms? previous node)
      (format-rules-render-hard-line-into indent buf)
      (format-rules-render-gap-into indent buf))))

(define (format-rules-render-node-fragment-into
  [node : FormatCst]
  [width : i64]
  [indent : i64]
  [col : i64]
  [buf : FmtRenderBuf]) : i64
  (format-rules-layout-cst node true width indent col false 0 buf))

(define (format-rules-render-forms-tail-into
  [previous : FormatCst]
  [items : FormatCstList]
  [width : i64]
  [indent : i64]
  [col : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty) col]
    [(FmtCstListStepItem node rest)
      (let
        [after-separator : i64
          (format-rules-render-forms-separator-into previous node indent buf)]
        [after-node : i64
          (format-rules-render-node-fragment-into
            node
            width
            indent
            after-separator
            buf)]
        (format-rules-render-forms-tail-into
          node
          rest
          width
          indent
          after-node
          buf))]))

(define (format-rules-render-forms-into
  [items : FormatCstList]
  [width : i64]
  [indent : i64]
  [col : i64]
  [buf : FmtRenderBuf]) : i64
  (match (fmt-cst-list-step items)
    [(FmtCstListStepEmpty) col]
    [(FmtCstListStepItem node rest)
      (format-rules-render-forms-tail-into
        node
        rest
        width
        indent
        (format-rules-render-node-fragment-into node width indent col buf)
        buf)]))

(define (format-rules-render-cst-width [node : FormatCst] [width : i64]) : String
  (let
    [buf : FmtRenderBuf (fmt-render-buf-new)]
    (begin
      (match node
        [(FmtCstForms items)
          (format-rules-render-forms-into (box-get items) width 0 0 buf)]
        [_ (format-rules-render-node-fragment-into node width 0 0 buf)])
      (fmt-render-buf-string buf))))

(define (format-rules-render-source-width-result [src : String] [width : i64]) : ResultFormatString
  (match (parse-format-source-result src)
    [(OkFormatCst tree)
      (OkFormatString (format-rules-render-cst-width tree width))]
    [(ErrFormatCst err) (ErrFormatString err)]))

(define (format-rules-render [node : FormatCst]) : String
  (format-rules-render-cst-width node (format-width)))

(define (format-rules-render-width [node : FormatCst] [width : i64]) : String
  (format-rules-render-cst-width node width))

(define (format-rules-render-source [src : String]) : String
  (format-rules-render-source-width src (format-width)))

(define (format-rules-render-source-width [src : String] [width : i64]) : String
  (match (format-rules-render-source-width-result src width)
    [(OkFormatString formatted) formatted]
    [(ErrFormatString err) (panic (format-source-error-message err))]))

(define (format-rules-decls-source) : String
  "(import \"std.tl\") (import \"ffi.tl\") (extern (print-string [arg0 : String]) : unit (:abi c) (:symbol \"tl_print_string\")) (extern (print-int [arg0 : i64]) : unit) (defenum Maybe (Some i64) (None)) (defstruct Point (x i64) (y i64)) (define KEY_A : i64 1) (define KEY_B : i64 2)")

(define (format-rules-decls-expected) : String
  "(import \"std.tl\")\n(import \"ffi.tl\")\n\n(extern (print-string [arg0 : String]) : unit (:abi c) (:symbol \"tl_print_string\"))\n(extern (print-int [arg0 : i64]) : unit)\n\n(defenum Maybe\n  (Some i64)\n  (None))\n\n(defstruct Point\n  (x i64)\n  (y i64))\n\n(define KEY_A : i64\n  1)\n(define KEY_B : i64\n  2)")

(define (format-rules-flow-source) : String
  "(define (main [x : i64]) : i64 (begin (let ([y : i64 1]) (if (< x y) (while (< x 10) (set! x (+ x 1))) x)) (match (Some x) [(Some v) v] [None 0])))")

(define (format-rules-flow-expected) : String
  "(define (main [x : i64]) : i64\n  (begin\n    (let\n      [y : i64 1]\n      (if (< x y)\n        (while (< x 10)\n          (set! x (+ x 1)))\n        x))\n    (match (Some x)\n      [(Some v) v]\n      [None 0])))")

(define (format-rules-comments-source) : String
  ";; module header
;; keeps adjacent lines
(import \"std.tl\")
;; item docs
;; stay attached
(define answer : i64 42)
(begin ; keep
 (print-string \"x\"))")

(define (format-rules-comments-expected) : String
  ";; module header
;; keeps adjacent lines
(import \"std.tl\")

;; item docs
;; stay attached
(define answer : i64
  42)

(begin
  ; keep
  (print-string \"x\"))")

(define (format-rules-quote-source) : String
  "(define (mk [e : Expr]) : Expr `(if ,e true false)) (define (body [xs : ExprList]) : Expr `(begin ,@xs))")

(define (format-rules-quote-expected) : String
  "(define (mk [e : Expr]) : Expr
  `(if ,e
    true
    false))

(define (body [xs : ExprList]) : Expr
  `(begin
    ,@xs))")

(define (format-rules-unsafe-source) : String
  "(define (main [p : (Ptr i64)]) : i64 (unsafe (ptr-read p))) (unsafe (define (danger [x : i64]) : i64 x))")

(define (format-rules-unsafe-expected) : String
  "(define (main [p : (Ptr i64)]) : i64
  (unsafe
    (ptr-read p)))

(unsafe
  (define (danger [x : i64]) : i64
    x))")

(define (format-rules-define-metadata-source) : String
  "(define (probe-fn [x : i64]) (:export-symbol \"probe_sym\") : unit unit)")

(define (format-rules-define-metadata-expected) : String
  "(define (probe-fn [x : i64])
  (:export-symbol \"probe_sym\") : unit
  unit)")

(define (format-rules-define-metadata-long-source) : String
  "(define (probe-long [x : i64]) (:export-symbol \"probe_long\") : (Tuple i64 i64 i64 i64 i64 i64 i64 i64) unit)")

(define (format-rules-define-metadata-long-expected) : String
  "(define (probe-long [x : i64])
  (:export-symbol \"probe_long\")
  : (Tuple i64 i64 i64 i64 i64 i64 i64 i64)
  unit)")

(define (format-rules-variadic-macro-source) : String
  "(defmacro (all [first : bool] [rest : bool ...]) : bool first)")

(define (format-rules-variadic-macro-expected) : String
  "(defmacro (all [first : bool] [rest : bool ...]) : bool
  first)")

(define (format-rules-self-test) : i64
  (let
    [decls : String
      (format-rules-render-source-width (format-rules-decls-source) 80)]
    [flow : String
      (format-rules-render-source-width (format-rules-flow-source) 80)]
    [comments : String
      (format-rules-render-source-width (format-rules-comments-source) 80)]
    [quote : String
      (format-rules-render-source-width (format-rules-quote-source) 80)]
    [unsafe : String
      (format-rules-render-source-width (format-rules-unsafe-source) 80)]
    [metadata : String
      (format-rules-render-source-width
        (format-rules-define-metadata-source)
        80)]
    [metadata-long : String
      (format-rules-render-source-width
        (format-rules-define-metadata-long-source)
        48)]
    [variadic : String
      (format-rules-render-source-width (format-rules-variadic-macro-source) 80)]
    (begin
      (unless (string-eq decls (format-rules-decls-expected)) (return 1))
      (unless (string-eq flow (format-rules-flow-expected)) (return 2))
      (unless (string-eq comments (format-rules-comments-expected)) (return 3))
      (unless (string-eq quote (format-rules-quote-expected)) (return 4))
      (unless (string-eq unsafe (format-rules-unsafe-expected)) (return 5))
      (unless
        (string-eq metadata (format-rules-define-metadata-expected))
        (return 6))
      (unless
        (string-eq metadata-long (format-rules-define-metadata-long-expected))
        (return 7))
      (unless
        (string-eq variadic (format-rules-variadic-macro-expected))
        (return 8))
      42)))