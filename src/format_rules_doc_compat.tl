;; format_rules_doc_compat.tl - Doc-algebra parity checks for formatter rules.
(import "format_rules.tl")
(import "format_doc.tl")

(define (format-rules-gap) : Doc
  (doc-append (doc-hard-line) (doc-hard-line)))

(define (format-rules-forms-separator [previous : FormatCst] [node : FormatCst]) : Doc
  (if (format-rules-node-comment? previous)
    (doc-hard-line)
    (if (format-rules-adjacent-top-forms? previous node)
      (doc-hard-line)
      (format-rules-gap))))

(define (format-rules-space [doc : Doc]) : Doc
  (doc-append (doc-text " ") doc))

(define (format-rules-colon-pair-doc [colon : FormatCst] [next : FormatCst]) : Doc
  (doc-append
    (format-rules-cst-doc colon)
    (format-rules-space (format-rules-cst-doc next))))

(define (format-rules-return-type-tail-doc
  [colon : FormatCst]
  [typ : FormatCst]) : Doc
  (format-rules-space (format-rules-colon-pair-doc colon typ)))

(define (format-rules-return-type-breakable-tail-doc
  [colon : FormatCst]
  [typ : FormatCst]) : Doc
  (doc-group
    (doc-append (doc-soft-line) (format-rules-colon-pair-doc colon typ))))

(define (format-rules-inline-tail-doc [items : FormatCstList]) : Doc
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) (doc-empty)]
    [(FormatCstListStep.Item node rest)
      (doc-append
        (format-rules-space (format-rules-cst-doc node))
        (format-rules-inline-tail-doc rest))]))

(define (format-rules-hard-tail-doc [items : FormatCstList]) : Doc
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) (doc-empty)]
    [(FormatCstListStep.Item node tail)
      (if (format-rules-node-colon? node)
        (match (fmt-cst-list-step tail)
          [(FormatCstListStep.Item next after-next)
            (if (format-rules-node-comment? next)
              (doc-append
                (doc-hard-line)
                (doc-append
                  (format-rules-cst-doc node)
                  (format-rules-hard-tail-doc tail)))
              (doc-append
                (doc-hard-line)
                (doc-append
                  (format-rules-colon-pair-doc node next)
                  (if (fmt-cst-list-empty? after-next)
                    (doc-empty)
                    (format-rules-hard-tail-doc after-next)))))]
          [_ (doc-append (doc-hard-line) (format-rules-cst-doc node))])
        (doc-append
          (doc-hard-line)
          (doc-append
            (format-rules-cst-doc node)
            (if (fmt-cst-list-empty? tail)
              (if (format-rules-node-comment? node)
                (doc-hard-line)
                (doc-empty))
              (format-rules-hard-tail-doc tail)))))]))

(define (format-rules-tail-separator
  [previous-comment : bool]
  [node : FormatCst]) : Doc
  (if (or previous-comment (format-rules-node-comment? node))
    (doc-hard-line)
    (doc-soft-line)))

(define (format-rules-list-tail-doc
  [previous-comment : bool]
  [items : FormatCstList]) : Doc
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) (doc-empty)]
    [(FormatCstListStep.Item node tail)
      (if (format-rules-node-colon? node)
        (match (fmt-cst-list-step tail)
          [(FormatCstListStep.Item next after-next)
            (if (format-rules-node-comment? next)
              (doc-append
                (format-rules-tail-separator previous-comment node)
                (doc-append
                  (format-rules-cst-doc node)
                  (format-rules-list-tail-doc false tail)))
              (doc-append
                (format-rules-tail-separator previous-comment node)
                (doc-append
                  (format-rules-colon-pair-doc node next)
                  (if (fmt-cst-list-empty? after-next)
                    (doc-empty)
                    (format-rules-list-tail-doc
                      (format-rules-node-comment? next)
                      after-next)))))]
          [_
            (doc-append
              (format-rules-tail-separator previous-comment node)
              (format-rules-cst-doc node))])
        (doc-append
          (format-rules-tail-separator previous-comment node)
          (doc-append
            (format-rules-cst-doc node)
            (if (fmt-cst-list-empty? tail)
              (if (format-rules-node-comment? node)
                (doc-hard-line)
                (doc-empty))
              (format-rules-list-tail-doc
                (format-rules-node-comment? node)
                tail)))))]))

(define (format-rules-list-items-doc [items : FormatCstList]) : Doc
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) (doc-empty)]
    [(FormatCstListStep.Item node tail)
      (doc-append
        (format-rules-cst-doc node)
        (if (fmt-cst-list-empty? tail)
          (if (format-rules-node-comment? node)
            (doc-hard-line)
            (doc-empty))
          (format-rules-list-tail-doc (format-rules-node-comment? node) tail)))]))

(define (format-rules-delimited-doc
  [open : String]
  [items : FormatCstList]
  [close : String]) : Doc
  (doc-group
    (doc-append
      (doc-text open)
      (doc-append
        (doc-nest 2 (format-rules-list-items-doc items))
        (doc-text close)))))

(define (format-rules-inline-form-doc [head : String] [rest : FormatCstList]) : Doc
  (doc-group
    (doc-append
      (doc-text "(")
      (doc-append
        (doc-text head)
        (doc-append (format-rules-inline-tail-doc rest) (doc-text ")"))))))

(define (format-rules-line-form-doc [head : String] [rest : FormatCstList]) : Doc
  (doc-append
    (doc-text "(")
    (doc-append
      (doc-text head)
      (doc-append (doc-nest 2 (format-rules-hard-tail-doc rest)) (doc-text ")")))))

(define (format-rules-first-line-form-doc
  [head : String]
  [first : FormatCst]
  [rest : FormatCstList]) : Doc
  (doc-append
    (doc-text "(")
    (doc-append
      (doc-text head)
      (doc-append
        (format-rules-space (format-rules-cst-doc first))
        (doc-append
          (doc-nest 2 (format-rules-hard-tail-doc rest))
          (doc-text ")"))))))

(define (format-rules-first-or-line-form-doc
  [head : String]
  [rest : FormatCstList]) : Doc
  (match (fmt-cst-list-step rest)
    [(FormatCstListStep.Empty)
      (format-rules-inline-form-doc head FormatCstList.Nil)]
    [(FormatCstListStep.Item first tail)
      (format-rules-first-line-form-doc head first tail)]))

(define (format-rules-let-binding-annotated-doc
  [name : FormatCst]
  [colon : FormatCst]
  [typ : FormatCst]
  [init : FormatCst]) : Doc
  (doc-group
    (doc-append
      (doc-text "[")
      (doc-append
        (format-rules-cst-doc name)
        (doc-append
          (format-rules-space (format-rules-cst-doc colon))
          (doc-append
            (format-rules-space (format-rules-cst-doc typ))
            (doc-append
              (doc-nest
                2
                (doc-append (doc-soft-line) (format-rules-cst-doc init)))
              (doc-text "]"))))))))

(define (format-rules-let-binding-unannotated-doc
  [name : FormatCst]
  [init : FormatCst]) : Doc
  (doc-group
    (doc-append
      (doc-text "[")
      (doc-append
        (format-rules-cst-doc name)
        (doc-append
          (doc-nest 2 (doc-append (doc-soft-line) (format-rules-cst-doc init)))
          (doc-text "]"))))))

(define (format-rules-let-item-list-doc [items : FormatCstList]) : Doc
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Item name after-name)
      (match (fmt-cst-list-step after-name)
        [(FormatCstListStep.Item second after-second)
          (match (fmt-cst-list-step after-second)
            [(FormatCstListStep.Empty)
              (format-rules-let-binding-unannotated-doc name second)]
            [(FormatCstListStep.Item typ after-typ)
              (match (fmt-cst-list-step after-typ)
                [(FormatCstListStep.Item init after-init)
                  (if (fmt-cst-list-empty? after-init)
                    (if (format-rules-node-colon? second)
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

(define (format-rules-let-item-doc [node : FormatCst]) : Doc
  (match node
    [(FormatCst.BracketList items)
      (format-rules-let-item-list-doc (box-get items))]
    [_ (format-rules-cst-doc node)]))

(define (format-rules-let-tail-doc [items : FormatCstList]) : Doc
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) (doc-empty)]
    [(FormatCstListStep.Item node tail)
      (doc-append
        (doc-hard-line)
        (doc-append
          (format-rules-let-item-doc node)
          (if (fmt-cst-list-empty? tail)
            (if (format-rules-node-comment? node)
              (doc-hard-line)
              (doc-empty))
            (format-rules-let-tail-doc tail))))]))

(define (format-rules-let-doc [rest : FormatCstList]) : Doc
  (doc-append
    (doc-text "(")
    (doc-append
      (doc-text "let")
      (doc-append
        (doc-nest 2 (format-rules-let-tail-doc (format-rules-let-rest rest)))
        (doc-text ")")))))

(define (format-rules-signature-annotated-doc
  [head : String]
  [target : FormatCst]
  [colon : FormatCst]
  [typ : FormatCst]
  [body-items : FormatCstList]) : Doc
  (doc-append
    (doc-text "(")
    (doc-append
      (doc-text head)
      (doc-append
        (format-rules-space (format-rules-cst-doc target))
        (doc-append
          (doc-nest 2 (format-rules-return-type-tail-doc colon typ))
          (doc-append
            (doc-nest 2 (format-rules-hard-tail-doc body-items))
            (doc-text ")")))))))

(define (format-rules-define-metadata-annotated-doc
  [target : FormatCst]
  [metadata : FormatCst]
  [colon : FormatCst]
  [typ : FormatCst]
  [body-items : FormatCstList]) : Doc
  (doc-append
    (doc-text "(")
    (doc-append
      (doc-text "define")
      (doc-append
        (format-rules-space (format-rules-cst-doc target))
        (doc-append
          (doc-nest
            2
            (doc-append
              (doc-hard-line)
              (doc-append
                (format-rules-cst-doc metadata)
                (format-rules-return-type-breakable-tail-doc colon typ))))
          (doc-append
            (doc-nest 2 (format-rules-hard-tail-doc body-items))
            (doc-text ")")))))))

(define (format-rules-define-body-doc
  [target : FormatCst]
  [body-items : FormatCstList]) : Doc
  (doc-append
    (doc-text "(")
    (doc-append
      (doc-text "define")
      (doc-append
        (format-rules-space (format-rules-cst-doc target))
        (doc-append
          (doc-nest 2 (format-rules-hard-tail-doc body-items))
          (doc-text ")"))))))

(define (format-rules-define-doc [rest : FormatCstList]) : Doc
  (match (fmt-cst-list-step rest)
    [(FormatCstListStep.Item target after-target)
      (match (fmt-cst-list-step after-target)
        [(FormatCstListStep.Item second after-second)
          (if (format-rules-node-colon? second)
            (match (fmt-cst-list-step after-second)
              [(FormatCstListStep.Item typ body)
                (if (fmt-cst-list-empty? body)
                  (format-rules-first-or-line-form-doc "define" rest)
                  (format-rules-signature-annotated-doc
                    "define"
                    target
                    second
                    typ
                    body))]
              [_ (format-rules-first-or-line-form-doc "define" rest)])
            (if (format-rules-node-colon-list? second)
              (match (fmt-cst-list-step after-second)
                [(FormatCstListStep.Item colon after-colon)
                  (if (format-rules-node-colon? colon)
                    (match (fmt-cst-list-step after-colon)
                      [(FormatCstListStep.Item typ body)
                        (if (fmt-cst-list-empty? body)
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

(define (format-rules-defmacro-doc [rest : FormatCstList]) : Doc
  (match (fmt-cst-list-step rest)
    [(FormatCstListStep.Item target after-target)
      (match (fmt-cst-list-step after-target)
        [(FormatCstListStep.Item colon after-colon)
          (if (format-rules-node-colon? colon)
            (match (fmt-cst-list-step after-colon)
              [(FormatCstListStep.Item typ body)
                (if (fmt-cst-list-empty? body)
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

(define (format-rules-lambda-doc [rest : FormatCstList]) : Doc
  (match (fmt-cst-list-step rest)
    [(FormatCstListStep.Item target after-target)
      (match (fmt-cst-list-step after-target)
        [(FormatCstListStep.Item colon after-colon)
          (if (format-rules-node-colon? colon)
            (match (fmt-cst-list-step after-colon)
              [(FormatCstListStep.Item typ body)
                (if (fmt-cst-list-empty? body)
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
  [head : FormatCst]
  [rest : FormatCstList]) : Doc
  (let
    [head-name : String (format-rules-node-symbol-name head)]
    (cond
      [(string-eq head-name "import")
        (format-rules-inline-form-doc "import" rest)]
      [(string-eq head-name "include-str")
        (format-rules-inline-form-doc "include-str" rest)]
      [(string-eq head-name "extern")
        (format-rules-inline-form-doc "extern" rest)]
      [(string-eq head-name "define") (format-rules-define-doc rest)]
      [(string-eq head-name "defmacro") (format-rules-defmacro-doc rest)]
      [(string-eq head-name "defenum")
        (format-rules-first-or-line-form-doc "defenum" rest)]
      [(string-eq head-name "defstruct")
        (format-rules-first-or-line-form-doc "defstruct" rest)]
      [(string-eq head-name "lambda") (format-rules-lambda-doc rest)]
      [(string-eq head-name "let") (format-rules-let-doc rest)]
      [(string-eq head-name "if")
        (format-rules-first-or-line-form-doc "if" rest)]
      [(string-eq head-name "while")
        (format-rules-first-or-line-form-doc "while" rest)]
      [(string-eq head-name "begin") (format-rules-line-form-doc "begin" rest)]
      [(string-eq head-name "unsafe")
        (format-rules-line-form-doc "unsafe" rest)]
      [(string-eq head-name "match")
        (format-rules-first-or-line-form-doc "match" rest)]
      [else
        (format-rules-delimited-doc
          "("
          (FormatCstList.Cons head (box rest))
          ")")])))

(define (format-rules-colon-list-doc [rest : FormatCstList]) : Doc
  (match (fmt-cst-list-step rest)
    [(FormatCstListStep.Item key tail)
      (let
        [name : String (format-rules-node-symbol-name key)]
        (if (> (string-length name) 0)
          (format-rules-inline-form-doc (string-append ":" name) tail)
          (format-rules-delimited-doc
            "("
            (FormatCstList.Cons (FormatCst.Atom (FormatToken.Colon)) (box rest))
            ")")))]
    [_
      (format-rules-delimited-doc
        "("
        (FormatCstList.Cons (FormatCst.Atom (FormatToken.Colon)) (box rest))
        ")")]))

(define (format-rules-list-doc [items : FormatCstList]) : Doc
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty)
      (format-rules-delimited-doc "(" FormatCstList.Nil ")")]
    [(FormatCstListStep.Item head rest)
      (if (format-rules-node-colon? head)
        (format-rules-colon-list-doc rest)
        (format-rules-special-list-doc head rest))]))

(define (format-rules-forms-tail-doc
  [previous : FormatCst]
  [items : FormatCstList]) : Doc
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) (doc-empty)]
    [(FormatCstListStep.Item node rest)
      (doc-append
        (format-rules-forms-separator previous node)
        (doc-append
          (format-rules-cst-doc node)
          (format-rules-forms-tail-doc node rest)))]))

(define (format-rules-forms-doc [items : FormatCstList]) : Doc
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) (doc-empty)]
    [(FormatCstListStep.Item node rest)
      (doc-append
        (format-rules-cst-doc node)
        (format-rules-forms-tail-doc node rest))]))

(define (format-rules-cst-doc [node : FormatCst]) : Doc
  (match node
    [(FormatCst.Atom tok) (doc-text (format-token-text tok))]
    [(FormatCst.Comment text) (doc-text text)]
    [(FormatCst.Prefix tok child)
      (doc-append
        (doc-text (format-token-text tok))
        (format-rules-cst-doc (box-get child)))]
    [(FormatCst.List items) (format-rules-list-doc (box-get items))]
    [(FormatCst.BracketList items)
      (format-rules-delimited-doc "[" (box-get items) "]")]
    [(FormatCst.Forms items) (format-rules-forms-doc (box-get items))]))

(define (format-rules-source-doc [src : String]) : Doc
  (format-rules-cst-doc (parse-format-source src)))

(define (format-rules-streaming-matches-doc? [src : String] [width : i64]) : bool
  (let
    [tree : FormatCst (parse-format-source src)]
    (string-eq
      (format-rules-render-cst-width tree width)
      (render-doc-width (format-rules-cst-doc tree) width))))

(define (format-rules-streaming-doc-fixtures-ok?) : bool
  (and
    (format-rules-streaming-matches-doc? (format-rules-decls-source) 80)
    (format-rules-streaming-matches-doc? (format-rules-flow-source) 80)
    (format-rules-streaming-matches-doc? (format-rules-comments-source) 80)
    (format-rules-streaming-matches-doc? (format-rules-quote-source) 80)
    (format-rules-streaming-matches-doc? (format-rules-unsafe-source) 80)
    (format-rules-streaming-matches-doc?
      (format-rules-define-metadata-source)
      80)
    (format-rules-streaming-matches-doc?
      (format-rules-define-metadata-long-source)
      48)
    (format-rules-streaming-matches-doc?
      (format-rules-variadic-macro-source)
      80)
    (format-rules-streaming-matches-doc? "(: 1 2) (foo a b c d e f g h)" 12)))

(define (format-rules-doc-compat-self-test) : i64
  (if (format-rules-streaming-doc-fixtures-ok?)
    42
    9))