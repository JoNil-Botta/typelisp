;; format_core.tl - Generic formatter CST to Doc traversal (#366).

;;

;; This module is intentionally syntax-neutral. Special forms get their own

;; layout rules later; this pass preserves token spelling, delimiter shape, and

;; comment text while building reusable `Doc` values.

(import "format_tokens.tl")

(import "format_cst.tl")

(import "format_doc.tl")

(define (format-core-node-comment? [node : FormatCst]) : bool
  (match node
    [(FmtCstComment _) true]
    [_ false]))

(define (format-core-gap) : Doc
  (doc-append (doc-hard-line) (doc-hard-line)))

(define (format-core-tail-separator
  [previous-comment : bool]
  [node : FormatCst]) : Doc
  (if (or previous-comment (format-core-node-comment? node))
    (doc-hard-line)
    (doc-soft-line)))

(define (format-core-list-tail-doc
  [previous-comment : bool]
  [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (format-core-tail-separator previous-comment node)
        (doc-append
          (format-core-cst-doc node)
          (format-core-list-tail-doc (format-core-node-comment? node) rest)))]))

(define (format-core-list-items-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (format-core-cst-doc node)
        (format-core-list-tail-doc (format-core-node-comment? node) rest))]))

(define (format-core-delimited-doc
  [open : String]
  [items : FormatCstList]
  [close : String]) : Doc
  (doc-group
    (doc-append
      (doc-text open)
      (doc-append
        (doc-nest 2 (format-core-list-items-doc items))
        (doc-text close)))))

(define (format-core-forms-tail-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (format-core-gap)
        (doc-append
          (format-core-cst-doc node)
          (format-core-forms-tail-doc rest)))]))

(define (format-core-forms-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append (format-core-cst-doc node) (format-core-forms-tail-doc rest))]))

(define (format-core-cst-doc [node : FormatCst]) : Doc
  (match node
    [(FmtCstAtom tok) (doc-text (format-token-text tok))]
    [(FmtCstComment text) (doc-text text)]
    [(FmtCstList items) (format-core-delimited-doc "(" items ")")]
    [(FmtCstBracketList items) (format-core-delimited-doc "[" items "]")]
    [(FmtCstForms items) (format-core-forms-doc items)]))

(define (format-core-source-doc [src : String]) : Doc
  (format-core-cst-doc (parse-format-source src)))

(define (format-core-render [node : FormatCst]) : String
  (render-doc (format-core-cst-doc node)))

(define (format-core-render-width [node : FormatCst] [width : i64]) : String
  (render-doc-width (format-core-cst-doc node) width))

(define (format-core-render-source [src : String]) : String
  (render-doc (format-core-source-doc src)))

(define (format-core-render-source-width [src : String] [width : i64]) : String
  (render-doc-width (format-core-source-doc src) width))

(define (format-core-self-test) : i64
  (let (
    [flat : String
      (format-core-render-source-width "(foo [bar 1] baz)\n; leading\n(qux)" 80)]
    [narrow : String (format-core-render-source-width "(alpha beta gamma)" 10)]
    [commented : String (format-core-render-source-width "(a ; note\n b)" 80)]
    [atom : String (format-core-render (FmtCstAtom (FmtSymbol "name")))])
    (if (string-eq flat "(foo [bar 1] baz)\n\n; leading\n\n(qux)")
      (if (string-eq narrow "(alpha\n  beta\n  gamma)")
        (if (string-eq commented "(a\n  ; note\n  b)")
          (if (string-eq atom "name")
            42
            4)
          3)
        2)
      1)))