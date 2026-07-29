;; format_rules_doc_compat.tl - Doc-algebra parity checks for formatter rules.
(import format_tokens as tokens)
(import format_cst as cst)
(import format_rules as rules)
(import format_doc as fmt_doc)
(import stdlib.string)

(define (format-rules-gap) : fmt_doc.Doc
  (fmt_doc.doc-append (fmt_doc.doc-hard-line) (fmt_doc.doc-hard-line)))

(define (format-rules-forms-separator
  [previous : cst.FormatCst]
  [node : cst.FormatCst]) : fmt_doc.Doc
  (if (rules.format-rules-node-comment? previous)
    (fmt_doc.doc-hard-line)
    (if (rules.format-rules-adjacent-top-forms? previous node)
      (fmt_doc.doc-hard-line)
      (format-rules-gap))))

(define (format-rules-space [doc : fmt_doc.Doc]) : fmt_doc.Doc
  (fmt_doc.doc-append (fmt_doc.doc-text " ") doc))

(define (format-rules-colon-pair-doc
  [colon : cst.FormatCst]
  [next : cst.FormatCst]) : fmt_doc.Doc
  (fmt_doc.doc-append
    (format-rules-cst-doc colon)
    (format-rules-space (format-rules-cst-doc next))))

(define (format-rules-return-type-tail-doc
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]) : fmt_doc.Doc
  (format-rules-space (format-rules-colon-pair-doc colon typ)))

(define (format-rules-return-type-breakable-tail-doc
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]) : fmt_doc.Doc
  (fmt_doc.doc-group
    (fmt_doc.doc-append
      (fmt_doc.doc-soft-line)
      (format-rules-colon-pair-doc colon typ))))

(define (format-rules-inline-tail-doc [items : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) (fmt_doc.doc-empty)]
    [(cst.FormatCstListStep.Item node rest)
      (fmt_doc.doc-append
        (format-rules-space (format-rules-cst-doc node))
        (format-rules-inline-tail-doc rest))]))

(define (format-rules-hard-tail-doc [items : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) (fmt_doc.doc-empty)]
    [(cst.FormatCstListStep.Item node tail)
      (if (rules.format-rules-node-colon? node)
        (match (cst.fmt-cst-list-step tail)
          [(cst.FormatCstListStep.Item next after-next)
            (if (rules.format-rules-node-comment? next)
              (fmt_doc.doc-append
                (fmt_doc.doc-hard-line)
                (fmt_doc.doc-append
                  (format-rules-cst-doc node)
                  (format-rules-hard-tail-doc tail)))
              (fmt_doc.doc-append
                (fmt_doc.doc-hard-line)
                (fmt_doc.doc-append
                  (format-rules-colon-pair-doc node next)
                  (if (cst.fmt-cst-list-empty? after-next)
                    (fmt_doc.doc-empty)
                    (format-rules-hard-tail-doc after-next)))))]
          [_
            (fmt_doc.doc-append
              (fmt_doc.doc-hard-line)
              (format-rules-cst-doc node))])
        (fmt_doc.doc-append
          (fmt_doc.doc-hard-line)
          (fmt_doc.doc-append
            (format-rules-cst-doc node)
            (if (cst.fmt-cst-list-empty? tail)
              (if (rules.format-rules-node-comment? node)
                (fmt_doc.doc-hard-line)
                (fmt_doc.doc-empty))
              (format-rules-hard-tail-doc tail)))))]))

(define (format-rules-tail-separator
  [previous-comment : bool]
  [node : cst.FormatCst]) : fmt_doc.Doc
  (if (or previous-comment (rules.format-rules-node-comment? node))
    (fmt_doc.doc-hard-line)
    (fmt_doc.doc-soft-line)))

(define (format-rules-list-tail-doc
  [previous-comment : bool]
  [items : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) (fmt_doc.doc-empty)]
    [(cst.FormatCstListStep.Item node tail)
      (if (rules.format-rules-node-colon? node)
        (match (cst.fmt-cst-list-step tail)
          [(cst.FormatCstListStep.Item next after-next)
            (if (rules.format-rules-node-comment? next)
              (fmt_doc.doc-append
                (format-rules-tail-separator previous-comment node)
                (fmt_doc.doc-append
                  (format-rules-cst-doc node)
                  (format-rules-list-tail-doc false tail)))
              (fmt_doc.doc-append
                (format-rules-tail-separator previous-comment node)
                (fmt_doc.doc-append
                  (format-rules-colon-pair-doc node next)
                  (if (cst.fmt-cst-list-empty? after-next)
                    (fmt_doc.doc-empty)
                    (format-rules-list-tail-doc
                      (rules.format-rules-node-comment? next)
                      after-next)))))]
          [_
            (fmt_doc.doc-append
              (format-rules-tail-separator previous-comment node)
              (format-rules-cst-doc node))])
        (fmt_doc.doc-append
          (format-rules-tail-separator previous-comment node)
          (fmt_doc.doc-append
            (format-rules-cst-doc node)
            (if (cst.fmt-cst-list-empty? tail)
              (if (rules.format-rules-node-comment? node)
                (fmt_doc.doc-hard-line)
                (fmt_doc.doc-empty))
              (format-rules-list-tail-doc
                (rules.format-rules-node-comment? node)
                tail)))))]))

(define (format-rules-list-items-doc [items : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) (fmt_doc.doc-empty)]
    [(cst.FormatCstListStep.Item node tail)
      (fmt_doc.doc-append
        (format-rules-cst-doc node)
        (if (cst.fmt-cst-list-empty? tail)
          (if (rules.format-rules-node-comment? node)
            (fmt_doc.doc-hard-line)
            (fmt_doc.doc-empty))
          (format-rules-list-tail-doc
            (rules.format-rules-node-comment? node)
            tail)))]))

(define (format-rules-delimited-doc
  [open : String]
  [items : cst.FormatCstList]
  [close : String]) : fmt_doc.Doc
  (fmt_doc.doc-group
    (fmt_doc.doc-append
      (fmt_doc.doc-text open)
      (fmt_doc.doc-append
        (fmt_doc.doc-nest 2 (format-rules-list-items-doc items))
        (fmt_doc.doc-text close)))))

(define (format-rules-inline-form-doc
  [head : String]
  [rest : cst.FormatCstList]) : fmt_doc.Doc
  (fmt_doc.doc-group
    (fmt_doc.doc-append
      (fmt_doc.doc-text "(")
      (fmt_doc.doc-append
        (fmt_doc.doc-text head)
        (fmt_doc.doc-append
          (format-rules-inline-tail-doc rest)
          (fmt_doc.doc-text ")"))))))

(define (format-rules-line-form-doc [head : String] [rest : cst.FormatCstList]) : fmt_doc.Doc
  (fmt_doc.doc-append
    (fmt_doc.doc-text "(")
    (fmt_doc.doc-append
      (fmt_doc.doc-text head)
      (fmt_doc.doc-append
        (fmt_doc.doc-nest 2 (format-rules-hard-tail-doc rest))
        (fmt_doc.doc-text ")")))))

(define (format-rules-first-line-form-doc
  [head : String]
  [first : cst.FormatCst]
  [rest : cst.FormatCstList]) : fmt_doc.Doc
  (fmt_doc.doc-append
    (fmt_doc.doc-text "(")
    (fmt_doc.doc-append
      (fmt_doc.doc-text head)
      (fmt_doc.doc-append
        (format-rules-space (format-rules-cst-doc first))
        (fmt_doc.doc-append
          (fmt_doc.doc-nest 2 (format-rules-hard-tail-doc rest))
          (fmt_doc.doc-text ")"))))))

(define (format-rules-first-or-line-form-doc
  [head : String]
  [rest : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step rest)
    [(cst.FormatCstListStep.Empty) (format-rules-inline-form-doc head rest)]
    [(cst.FormatCstListStep.Item first tail)
      (format-rules-first-line-form-doc head first tail)]))

(define (format-rules-let-binding-annotated-doc
  [name : cst.FormatCst]
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [init : cst.FormatCst]) : fmt_doc.Doc
  (fmt_doc.doc-group
    (fmt_doc.doc-append
      (fmt_doc.doc-text "[")
      (fmt_doc.doc-append
        (format-rules-cst-doc name)
        (fmt_doc.doc-append
          (format-rules-space (format-rules-cst-doc colon))
          (fmt_doc.doc-append
            (format-rules-space (format-rules-cst-doc typ))
            (fmt_doc.doc-append
              (fmt_doc.doc-nest
                2
                (fmt_doc.doc-append
                  (fmt_doc.doc-soft-line)
                  (format-rules-cst-doc init)))
              (fmt_doc.doc-text "]"))))))))

(define (format-rules-let-binding-unannotated-doc
  [name : cst.FormatCst]
  [init : cst.FormatCst]) : fmt_doc.Doc
  (fmt_doc.doc-group
    (fmt_doc.doc-append
      (fmt_doc.doc-text "[")
      (fmt_doc.doc-append
        (format-rules-cst-doc name)
        (fmt_doc.doc-append
          (fmt_doc.doc-nest
            2
            (fmt_doc.doc-append
              (fmt_doc.doc-soft-line)
              (format-rules-cst-doc init)))
          (fmt_doc.doc-text "]"))))))

(define (format-rules-let-item-list-doc [items : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Item name after-name)
      (match (cst.fmt-cst-list-step after-name)
        [(cst.FormatCstListStep.Item second after-second)
          (match (cst.fmt-cst-list-step after-second)
            [(cst.FormatCstListStep.Empty)
              (format-rules-let-binding-unannotated-doc name second)]
            [(cst.FormatCstListStep.Item typ after-typ)
              (match (cst.fmt-cst-list-step after-typ)
                [(cst.FormatCstListStep.Item init after-init)
                  (if (cst.fmt-cst-list-empty? after-init)
                    (if (rules.format-rules-node-colon? second)
                      (format-rules-let-binding-annotated-doc
                        name
                        second
                        typ
                        init)
                      (format-rules-delimited-doc "[" items "]"))
                    (format-rules-delimited-doc "[" items "]"))]
                [_ (format-rules-delimited-doc "[" items "]")])]
            [_ (format-rules-delimited-doc "[" items "]")])]
        [_ (format-rules-delimited-doc "[" items "]")])]
    [_ (format-rules-delimited-doc "[" items "]")]))

(define (format-rules-let-item-doc [node : cst.FormatCst]) : fmt_doc.Doc
  (match node
    [(cst.FormatCst.BracketList items)
      (format-rules-let-item-list-doc (box-get items))]
    [_ (format-rules-cst-doc node)]))

(define (format-rules-let-tail-doc [items : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) (fmt_doc.doc-empty)]
    [(cst.FormatCstListStep.Item node tail)
      (fmt_doc.doc-append
        (fmt_doc.doc-hard-line)
        (fmt_doc.doc-append
          (format-rules-let-item-doc node)
          (if (cst.fmt-cst-list-empty? tail)
            (if (rules.format-rules-node-comment? node)
              (fmt_doc.doc-hard-line)
              (fmt_doc.doc-empty))
            (format-rules-let-tail-doc tail))))]))

(define (format-rules-let-doc [rest : cst.FormatCstList]) : fmt_doc.Doc
  (fmt_doc.doc-append
    (fmt_doc.doc-text "(")
    (fmt_doc.doc-append
      (fmt_doc.doc-text "let")
      (fmt_doc.doc-append
        (fmt_doc.doc-nest
          2
          (format-rules-let-tail-doc (rules.format-rules-let-rest rest)))
        (fmt_doc.doc-text ")")))))

(define (format-rules-signature-annotated-doc
  [head : String]
  [target : cst.FormatCst]
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [body-items : cst.FormatCstList]) : fmt_doc.Doc
  (fmt_doc.doc-append
    (fmt_doc.doc-text "(")
    (fmt_doc.doc-append
      (fmt_doc.doc-text head)
      (fmt_doc.doc-append
        (format-rules-space (format-rules-cst-doc target))
        (fmt_doc.doc-append
          (fmt_doc.doc-nest 2 (format-rules-return-type-tail-doc colon typ))
          (fmt_doc.doc-append
            (fmt_doc.doc-nest 2 (format-rules-hard-tail-doc body-items))
            (fmt_doc.doc-text ")")))))))

(define (format-rules-define-metadata-annotated-doc
  [target : cst.FormatCst]
  [metadata : cst.FormatCst]
  [colon : cst.FormatCst]
  [typ : cst.FormatCst]
  [body-items : cst.FormatCstList]) : fmt_doc.Doc
  (fmt_doc.doc-append
    (fmt_doc.doc-text "(")
    (fmt_doc.doc-append
      (fmt_doc.doc-text "define")
      (fmt_doc.doc-append
        (format-rules-space (format-rules-cst-doc target))
        (fmt_doc.doc-append
          (fmt_doc.doc-nest
            2
            (fmt_doc.doc-append
              (fmt_doc.doc-hard-line)
              (fmt_doc.doc-append
                (format-rules-cst-doc metadata)
                (format-rules-return-type-breakable-tail-doc colon typ))))
          (fmt_doc.doc-append
            (fmt_doc.doc-nest 2 (format-rules-hard-tail-doc body-items))
            (fmt_doc.doc-text ")")))))))

(define (format-rules-define-body-doc
  [target : cst.FormatCst]
  [body-items : cst.FormatCstList]) : fmt_doc.Doc
  (fmt_doc.doc-append
    (fmt_doc.doc-text "(")
    (fmt_doc.doc-append
      (fmt_doc.doc-text "define")
      (fmt_doc.doc-append
        (format-rules-space (format-rules-cst-doc target))
        (fmt_doc.doc-append
          (fmt_doc.doc-nest 2 (format-rules-hard-tail-doc body-items))
          (fmt_doc.doc-text ")"))))))

(define (format-rules-define-doc [rest : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step rest)
    [(cst.FormatCstListStep.Item target after-target)
      (match (cst.fmt-cst-list-step after-target)
        [(cst.FormatCstListStep.Item second after-second)
          (if (rules.format-rules-node-colon? second)
            (match (cst.fmt-cst-list-step after-second)
              [(cst.FormatCstListStep.Item typ body)
                (if (cst.fmt-cst-list-empty? body)
                  (format-rules-first-or-line-form-doc "define" rest)
                  (format-rules-signature-annotated-doc
                    "define"
                    target
                    second
                    typ
                    body))]
              [_ (format-rules-first-or-line-form-doc "define" rest)])
            (if (rules.format-rules-node-colon-list? second)
              (match (cst.fmt-cst-list-step after-second)
                [(cst.FormatCstListStep.Item colon after-colon)
                  (if (rules.format-rules-node-colon? colon)
                    (match (cst.fmt-cst-list-step after-colon)
                      [(cst.FormatCstListStep.Item typ body)
                        (if (cst.fmt-cst-list-empty? body)
                          (format-rules-first-or-line-form-doc "define" rest)
                          (format-rules-define-metadata-annotated-doc
                            target
                            second
                            colon
                            typ
                            body))]
                      [_ (format-rules-first-or-line-form-doc "define" rest)])
                    (format-rules-first-or-line-form-doc "define" rest))]
                [_ (format-rules-first-or-line-form-doc "define" rest)])
              (format-rules-define-body-doc target after-target)))]
        [_ (format-rules-first-or-line-form-doc "define" rest)])]
    [_ (format-rules-first-or-line-form-doc "define" rest)]))

(define (format-rules-defmacro-doc [rest : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step rest)
    [(cst.FormatCstListStep.Item target after-target)
      (match (cst.fmt-cst-list-step after-target)
        [(cst.FormatCstListStep.Item colon after-colon)
          (if (rules.format-rules-node-colon? colon)
            (match (cst.fmt-cst-list-step after-colon)
              [(cst.FormatCstListStep.Item typ body)
                (if (cst.fmt-cst-list-empty? body)
                  (format-rules-first-or-line-form-doc "defmacro" rest)
                  (format-rules-signature-annotated-doc
                    "defmacro"
                    target
                    colon
                    typ
                    body))]
              [_ (format-rules-first-or-line-form-doc "defmacro" rest)])
            (format-rules-first-or-line-form-doc "defmacro" rest))]
        [_ (format-rules-first-or-line-form-doc "defmacro" rest)])]
    [_ (format-rules-first-or-line-form-doc "defmacro" rest)]))

(define (format-rules-lambda-doc [rest : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step rest)
    [(cst.FormatCstListStep.Item target after-target)
      (match (cst.fmt-cst-list-step after-target)
        [(cst.FormatCstListStep.Item colon after-colon)
          (if (rules.format-rules-node-colon? colon)
            (match (cst.fmt-cst-list-step after-colon)
              [(cst.FormatCstListStep.Item typ body)
                (if (cst.fmt-cst-list-empty? body)
                  (format-rules-first-or-line-form-doc "lambda" rest)
                  (format-rules-signature-annotated-doc
                    "lambda"
                    target
                    colon
                    typ
                    body))]
              [_ (format-rules-first-or-line-form-doc "lambda" rest)])
            (format-rules-first-or-line-form-doc "lambda" rest))]
        [_ (format-rules-first-or-line-form-doc "lambda" rest)])]
    [_ (format-rules-first-or-line-form-doc "lambda" rest)]))

(define (format-rules-special-list-doc
  [head : cst.FormatCst]
  [rest : cst.FormatCstList]
  [items : cst.FormatCstList]) : fmt_doc.Doc
  (let
    [head-name : String (rules.format-rules-node-symbol-name head)]
    (cond
      [(string.eq head-name "import")
        (format-rules-inline-form-doc "import" rest)]
      [(string.eq head-name "include-str")
        (format-rules-inline-form-doc "include-str" rest)]
      [(string.eq head-name "extern")
        (format-rules-inline-form-doc "extern" rest)]
      [(string.eq head-name "define") (format-rules-define-doc rest)]
      [(string.eq head-name "defmacro") (format-rules-defmacro-doc rest)]
      [(string.eq head-name "defenum")
        (format-rules-first-or-line-form-doc "defenum" rest)]
      [(string.eq head-name "defstruct")
        (format-rules-first-or-line-form-doc "defstruct" rest)]
      [(string.eq head-name "lambda") (format-rules-lambda-doc rest)]
      [(string.eq head-name "let") (format-rules-let-doc rest)]
      [(string.eq head-name "if")
        (format-rules-first-or-line-form-doc "if" rest)]
      [(string.eq head-name "while")
        (format-rules-first-or-line-form-doc "while" rest)]
      [(string.eq head-name "begin") (format-rules-line-form-doc "begin" rest)]
      [(string.eq head-name "unsafe")
        (format-rules-line-form-doc "unsafe" rest)]
      [(string.eq head-name "match")
        (format-rules-first-or-line-form-doc "match" rest)]
      [else (format-rules-delimited-doc "(" items ")")])))

(define (format-rules-colon-list-doc
  [rest : cst.FormatCstList]
  [items : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step rest)
    [(cst.FormatCstListStep.Item key tail)
      (let
        [name : String (rules.format-rules-node-symbol-name key)]
        (if (> (string-length name) 0)
          (format-rules-inline-form-doc (string.append ":" name) tail)
          (format-rules-delimited-doc "(" items ")")))]
    [_ (format-rules-delimited-doc "(" items ")")]))

(define (format-rules-list-doc [items : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) (format-rules-delimited-doc "(" items ")")]
    [(cst.FormatCstListStep.Item head rest)
      (if (rules.format-rules-node-colon? head)
        (format-rules-colon-list-doc rest items)
        (format-rules-special-list-doc head rest items))]))

(define (format-rules-forms-tail-doc
  [previous : cst.FormatCst]
  [items : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) (fmt_doc.doc-empty)]
    [(cst.FormatCstListStep.Item node rest)
      (fmt_doc.doc-append
        (format-rules-forms-separator previous node)
        (fmt_doc.doc-append
          (format-rules-cst-doc node)
          (format-rules-forms-tail-doc node rest)))]))

(define (format-rules-forms-doc [items : cst.FormatCstList]) : fmt_doc.Doc
  (match (cst.fmt-cst-list-step items)
    [(cst.FormatCstListStep.Empty) (fmt_doc.doc-empty)]
    [(cst.FormatCstListStep.Item node rest)
      (fmt_doc.doc-append
        (format-rules-cst-doc node)
        (format-rules-forms-tail-doc node rest))]))

(define (format-rules-cst-doc [node : cst.FormatCst]) : fmt_doc.Doc
  (match node
    [(cst.FormatCst.Atom tok) (fmt_doc.doc-text (tokens.format-token-text tok))]
    [(cst.FormatCst.Comment text) (fmt_doc.doc-text text)]
    [(cst.FormatCst.Prefix tok child)
      (fmt_doc.doc-append
        (fmt_doc.doc-text (tokens.format-token-text tok))
        (format-rules-cst-doc (box-get child)))]
    [(cst.FormatCst.List items) (format-rules-list-doc (box-get items))]
    [(cst.FormatCst.BracketList items)
      (format-rules-delimited-doc "[" (box-get items) "]")]
    [(cst.FormatCst.Forms items) (format-rules-forms-doc (box-get items))]))

(define (format-rules-streaming-matches-doc? [src : String] [width : i64]) : bool
  (let
    [tree : cst.FormatCst (cst.parse-format-source src)]
    (string.eq
      (rules.format-rules-render-cst-width tree width)
      (fmt_doc.render-doc-width (format-rules-cst-doc tree) width))))

(define (format-rules-streaming-doc-fixtures-ok?) : bool
  (and
    (format-rules-streaming-matches-doc? (rules.format-rules-decls-source) 80)
    (format-rules-streaming-matches-doc? (rules.format-rules-flow-source) 80)
    (format-rules-streaming-matches-doc?
      (rules.format-rules-empty-let-source)
      80)
    (format-rules-streaming-matches-doc?
      (rules.format-rules-comments-source)
      80)
    (format-rules-streaming-matches-doc? (rules.format-rules-quote-source) 80)
    (format-rules-streaming-matches-doc? (rules.format-rules-unsafe-source) 80)
    (format-rules-streaming-matches-doc?
      (rules.format-rules-define-metadata-source)
      80)
    (format-rules-streaming-matches-doc?
      (rules.format-rules-define-metadata-long-source)
      48)
    (format-rules-streaming-matches-doc?
      (rules.format-rules-variadic-macro-source)
      80)
    (format-rules-streaming-matches-doc? "(: 1 2) (foo a b c d e f g h)" 12)))

(define (format-rules-doc-compat-self-test) : i64
  (if (format-rules-streaming-doc-fixtures-ok?)
    42
    9))