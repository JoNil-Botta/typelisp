;; format_rules.tl - TypeLisp-aware formatter rules (#367).
;;
;; `format_core.tl` stays syntax-neutral. This module adds a deterministic
;; gofmt-like first pass for common TypeLisp special forms while still building
;; `Doc` values for width-aware rendering.
(import "../stdlib/io.tl")
(import "format_tokens.tl")
(import "format_cst.tl")
(import "format_doc.tl")
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
      (match (box-get items)
        [(FmtCstCons head _) (format-rules-node-colon? head)]
        [_ false])]
    [_ false]))

(define (format-rules-define-value-rest? [rest : FormatCstList]) : bool
  (match rest
    [(FmtCstCons target _)
      (match target
        [(FmtCstList _) false]
        [_ true])]
    [_ false]))

(define (format-rules-cfg-top-form-family [rest : FormatCstList]) : String
  (match rest
    [(FmtCstCons _ after-predicate-box)
      (match (box-get after-predicate-box)
        [(FmtCstCons inner _) (format-rules-top-form-family inner)]
        [_ ""])]
    [_ ""]))

(define (format-rules-top-form-family-list [items : FormatCstList]) : String
  (match items
    [(FmtCstCons head rest-box)
      (let
        [head-name : String (format-rules-node-symbol-name head)]
        [rest : FormatCstList (box-get rest-box)]
        (if (string-eq head-name "import")
          "import"
          (if (string-eq head-name "extern")
            "extern"
            (if (string-eq head-name "include-str")
              "include-str"
              (if (string-eq head-name "define")
                (if (format-rules-define-value-rest? rest)
                  "define"
                  "")
                (if (string-eq head-name "cfg")
                  (format-rules-cfg-top-form-family rest)
                  ""))))))]
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
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (format-rules-space (format-rules-cst-doc node))
        (format-rules-inline-tail-doc (box-get rest)))]))

(define (format-rules-hard-tail-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (let
        [tail : FormatCstList (box-get rest)]
        (if (format-rules-node-colon? node)
          (match tail
            [(FmtCstCons next after-next-box)
              (if (format-rules-node-comment? next)
                (doc-append
                  (doc-hard-line)
                  (doc-append
                    (format-rules-cst-doc node)
                    (format-rules-hard-tail-doc tail)))
                (let
                  [after-next : FormatCstList (box-get after-next-box)]
                  (doc-append
                    (doc-hard-line)
                    (doc-append
                      (format-rules-colon-pair-doc node next)
                      (match after-next
                        [(FmtCstNil) (doc-empty)]
                        [_ (format-rules-hard-tail-doc after-next)])))))]
            [_ (doc-append (doc-hard-line) (format-rules-cst-doc node))])
          (doc-append
            (doc-hard-line)
            (doc-append
              (format-rules-cst-doc node)
              (match tail
                [(FmtCstNil)
                  (if (format-rules-node-comment? node)
                    (doc-hard-line)
                    (doc-empty))]
                [_ (format-rules-hard-tail-doc tail)])))))]))

(define (format-rules-tail-separator
  [previous-comment : bool]
  [node : FormatCst]) : Doc
  (if (or previous-comment (format-rules-node-comment? node))
    (doc-hard-line)
    (doc-soft-line)))

(define (format-rules-list-tail-doc
  [previous-comment : bool]
  [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (let
        [tail : FormatCstList (box-get rest)]
        (if (format-rules-node-colon? node)
          (match tail
            [(FmtCstCons next after-next-box)
              (if (format-rules-node-comment? next)
                (doc-append
                  (format-rules-tail-separator previous-comment node)
                  (doc-append
                    (format-rules-cst-doc node)
                    (format-rules-list-tail-doc false tail)))
                (let
                  [after-next : FormatCstList (box-get after-next-box)]
                  (doc-append
                    (format-rules-tail-separator previous-comment node)
                    (doc-append
                      (format-rules-colon-pair-doc node next)
                      (match after-next
                        [(FmtCstNil) (doc-empty)]
                        [_
                          (format-rules-list-tail-doc
                            (format-rules-node-comment? next)
                            after-next)])))))]
            [_
              (doc-append
                (format-rules-tail-separator previous-comment node)
                (format-rules-cst-doc node))])
          (doc-append
            (format-rules-tail-separator previous-comment node)
            (doc-append
              (format-rules-cst-doc node)
              (match tail
                [(FmtCstNil)
                  (if (format-rules-node-comment? node)
                    (doc-hard-line)
                    (doc-empty))]
                [_
                  (format-rules-list-tail-doc
                    (format-rules-node-comment? node)
                    tail)])))))]))

(define (format-rules-list-items-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (let
        [tail : FormatCstList (box-get rest)]
        (doc-append
          (format-rules-cst-doc node)
          (match tail
            [(FmtCstNil)
              (if (format-rules-node-comment? node)
                (doc-hard-line)
                (doc-empty))]
            [_
              (format-rules-list-tail-doc
                (format-rules-node-comment? node)
                tail)])))]))

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
  (match rest
    [(FmtCstNil) (format-rules-inline-form-doc head FmtCstNil)]
    [(FmtCstCons first tail)
      (format-rules-first-line-form-doc head first (box-get tail))]))

(define (format-rules-list-append
  [left : FormatCstList]
  [right : FormatCstList]) : FormatCstList
  (match left
    [(FmtCstNil) right]
    [(FmtCstCons node rest)
      (FmtCstCons node (box (format-rules-list-append (box-get rest) right)))]))

(define (format-rules-bracket-binding-items?
  [items : FormatCstList]
  [seen : bool]) : bool
  (match items
    [(FmtCstNil) seen]
    [(FmtCstCons node rest)
      (match node
        [(FmtCstComment _)
          (format-rules-bracket-binding-items? (box-get rest) seen)]
        [(FmtCstBracketList _)
          (format-rules-bracket-binding-items? (box-get rest) true)]
        [_ false])]))

(define (format-rules-bracket-binding-list? [items : FormatCstList]) : bool
  (format-rules-bracket-binding-items? items false))

(define (format-rules-let-rest [rest : FormatCstList]) : FormatCstList
  (match rest
    [(FmtCstCons first tail)
      (match first
        [(FmtCstList bindings)
          (if (format-rules-bracket-binding-list? (box-get bindings))
            (format-rules-list-append (box-get bindings) (box-get tail))
            rest)]
        [_ rest])]
    [_ rest]))

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
  (match items
    [(FmtCstCons name after-name-box)
      (let
        [after-name : FormatCstList (box-get after-name-box)]
        (match after-name
          [(FmtCstCons second after-second-box)
            (let
              [after-second : FormatCstList (box-get after-second-box)]
              (match after-second
                [(FmtCstNil)
                  (format-rules-let-binding-unannotated-doc name second)]
                [(FmtCstCons typ after-typ-box)
                  (let
                    [after-typ : FormatCstList (box-get after-typ-box)]
                    (match after-typ
                      [(FmtCstCons init after-init-box)
                        (match (box-get after-init-box)
                          [(FmtCstNil)
                            (if (format-rules-node-colon? second)
                              (format-rules-let-binding-annotated-doc
                                name
                                second
                                typ
                                init)
                              (format-rules-delimited-doc "[" items "]"))]
                          [_ (format-rules-delimited-doc "[" items "]")])]
                      [_ (format-rules-delimited-doc "[" items "]")]))]
                [_ (format-rules-delimited-doc "[" items "]")]))]
          [_ (format-rules-delimited-doc "[" items "]")]))]
    [_ (format-rules-delimited-doc "[" items "]")]))

(define (format-rules-let-item-doc [node : FormatCst]) : Doc
  (match node
    [(FmtCstBracketList items) (format-rules-let-item-list-doc (box-get items))]
    [_ (format-rules-cst-doc node)]))

(define (format-rules-let-tail-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (let
        [tail : FormatCstList (box-get rest)]
        (doc-append
          (doc-hard-line)
          (doc-append
            (format-rules-let-item-doc node)
            (match tail
              [(FmtCstNil)
                (if (format-rules-node-comment? node)
                  (doc-hard-line)
                  (doc-empty))]
              [_ (format-rules-let-tail-doc tail)]))))]))

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
  (match rest
    [(FmtCstCons target after-target-box)
      (let
        [after-target : FormatCstList (box-get after-target-box)]
        (match after-target
          [(FmtCstCons second after-second-box)
            (let
              [after-second : FormatCstList (box-get after-second-box)]
              (if (format-rules-node-colon? second)
                (match after-second
                  [(FmtCstCons typ body-box)
                    (match (box-get body-box)
                      [(FmtCstNil)
                        (format-rules-first-or-line-form-doc "define" rest)]
                      [_
                        (format-rules-signature-annotated-doc
                          "define"
                          target
                          second
                          typ
                          (box-get body-box))])]
                  [_ (format-rules-first-or-line-form-doc "define" rest)])
                (if (format-rules-node-colon-list? second)
                  (match after-second
                    [(FmtCstCons colon after-colon-box)
                      (if (format-rules-node-colon? colon)
                        (match (box-get after-colon-box)
                          [(FmtCstCons typ body-box)
                            (match (box-get body-box)
                              [(FmtCstNil)
                                (format-rules-first-or-line-form-doc
                                  "define"
                                  rest)]
                              [_
                                (format-rules-define-metadata-annotated-doc
                                  target
                                  second
                                  colon
                                  typ
                                  (box-get body-box))])]
                          [_
                            (format-rules-first-or-line-form-doc "define" rest)])
                        (format-rules-first-or-line-form-doc "define" rest))]
                    [_ (format-rules-first-or-line-form-doc "define" rest)])
                  (format-rules-define-body-doc target after-target))))]
          [_ (format-rules-first-or-line-form-doc "define" rest)]))]
    [_ (format-rules-first-or-line-form-doc "define" rest)]))

(define (format-rules-defmacro-doc [rest : FormatCstList]) : Doc
  (match rest
    [(FmtCstCons target after-target-box)
      (match (box-get after-target-box)
        [(FmtCstCons colon after-colon-box)
          (if (format-rules-node-colon? colon)
            (match (box-get after-colon-box)
              [(FmtCstCons typ body-box)
                (match (box-get body-box)
                  [(FmtCstNil)
                    (format-rules-first-or-line-form-doc "defmacro" rest)]
                  [_
                    (format-rules-signature-annotated-doc
                      "defmacro"
                      target
                      colon
                      typ
                      (box-get body-box))])]
              [_ (format-rules-first-or-line-form-doc "defmacro" rest)])
            (format-rules-first-or-line-form-doc "defmacro" rest))]
        [_ (format-rules-first-or-line-form-doc "defmacro" rest)])]
    [_ (format-rules-first-or-line-form-doc "defmacro" rest)]))

(define (format-rules-lambda-doc [rest : FormatCstList]) : Doc
  (match rest
    [(FmtCstCons target after-target-box)
      (match (box-get after-target-box)
        [(FmtCstCons colon after-colon-box)
          (if (format-rules-node-colon? colon)
            (match (box-get after-colon-box)
              [(FmtCstCons typ body-box)
                (match (box-get body-box)
                  [(FmtCstNil)
                    (format-rules-first-or-line-form-doc "lambda" rest)]
                  [_
                    (format-rules-signature-annotated-doc
                      "lambda"
                      target
                      colon
                      typ
                      (box-get body-box))])]
              [_ (format-rules-first-or-line-form-doc "lambda" rest)])
            (format-rules-first-or-line-form-doc "lambda" rest))]
        [_ (format-rules-first-or-line-form-doc "lambda" rest)])]
    [_ (format-rules-first-or-line-form-doc "lambda" rest)]))

(define (format-rules-special-list-doc
  [head : FormatCst]
  [rest : FormatCstList]) : Doc
  (if (format-rules-node-symbol? head "import")
    (format-rules-inline-form-doc "import" rest)
    (if (format-rules-node-symbol? head "include-str")
      (format-rules-inline-form-doc "include-str" rest)
      (if (format-rules-node-symbol? head "extern")
        (format-rules-inline-form-doc "extern" rest)
        (if (format-rules-node-symbol? head "define")
          (format-rules-define-doc rest)
          (if (format-rules-node-symbol? head "defmacro")
            (format-rules-defmacro-doc rest)
            (if (format-rules-node-symbol? head "defenum")
              (format-rules-first-or-line-form-doc "defenum" rest)
              (if (format-rules-node-symbol? head "defstruct")
                (format-rules-first-or-line-form-doc "defstruct" rest)
                (if (format-rules-node-symbol? head "lambda")
                  (format-rules-lambda-doc rest)
                  (if (format-rules-node-symbol? head "let")
                    (format-rules-let-doc rest)
                    (if (format-rules-node-symbol? head "if")
                      (format-rules-first-or-line-form-doc "if" rest)
                      (if (format-rules-node-symbol? head "while")
                        (format-rules-first-or-line-form-doc "while" rest)
                        (if (format-rules-node-symbol? head "begin")
                          (format-rules-line-form-doc "begin" rest)
                          (if (format-rules-node-symbol? head "unsafe")
                            (format-rules-line-form-doc "unsafe" rest)
                            (if (format-rules-node-symbol? head "match")
                              (format-rules-first-or-line-form-doc "match" rest)
                              (format-rules-delimited-doc
                                "("
                                (FmtCstCons head (box rest))
                                ")"))))))))))))))))

(define (format-rules-colon-list-doc [rest : FormatCstList]) : Doc
  (match rest
    [(FmtCstCons key tail)
      (let
        [name : String (format-rules-node-symbol-name key)]
        (if (> (string-length name) 0)
          (format-rules-inline-form-doc (string-append ":" name) (box-get tail))
          (format-rules-delimited-doc
            "("
            (FmtCstCons (FmtCstAtom (FmtColon)) (box rest))
            ")")))]
    [_
      (format-rules-delimited-doc
        "("
        (FmtCstCons (FmtCstAtom (FmtColon)) (box rest))
        ")")]))

(define (format-rules-list-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (format-rules-delimited-doc "(" FmtCstNil ")")]
    [(FmtCstCons head rest)
      (if (format-rules-node-colon? head)
        (format-rules-colon-list-doc (box-get rest))
        (format-rules-special-list-doc head (box-get rest)))]))

(define (format-rules-forms-tail-doc
  [previous : FormatCst]
  [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (format-rules-forms-separator previous node)
        (doc-append
          (format-rules-cst-doc node)
          (format-rules-forms-tail-doc node (box-get rest))))]))

(define (format-rules-forms-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (format-rules-cst-doc node)
        (format-rules-forms-tail-doc node (box-get rest)))]))

(define (format-rules-cst-doc [node : FormatCst]) : Doc
  (match node
    [(FmtCstAtom tok) (doc-text (format-token-text tok))]
    [(FmtCstComment text) (doc-text text)]
    [(FmtCstPrefix tok child)
      (doc-append
        (doc-text (format-token-text tok))
        (format-rules-cst-doc (box-get child)))]
    [(FmtCstList items) (format-rules-list-doc (box-get items))]
    [(FmtCstBracketList items)
      (format-rules-delimited-doc "[" (box-get items) "]")]
    [(FmtCstForms items) (format-rules-forms-doc (box-get items))]))

(define (format-rules-source-doc [src : String]) : Doc
  (format-rules-cst-doc (parse-format-source src)))

(define (format-rules-render-source-width-result [src : String] [width : i64]) : ResultFormatString
  (match (parse-format-source-result src)
    [(OkFormatCst tree)
      (OkFormatString (render-doc-width (format-rules-cst-doc tree) width))]
    [(ErrFormatCst err) (ErrFormatString err)]))

(define (format-rules-render [node : FormatCst]) : String
  (render-doc (format-rules-cst-doc node)))

(define (format-rules-render-width [node : FormatCst] [width : i64]) : String
  (render-doc-width (format-rules-cst-doc node) width))

(define (format-rules-render-source [src : String]) : String
  (render-doc (format-rules-source-doc src)))

(define (format-rules-render-source-width [src : String] [width : i64]) : String
  (match (format-rules-render-source-width-result src width)
    [(OkFormatString formatted) formatted]
    [(ErrFormatString err)
      (begin
        (panic (format-source-error-message err))
        ;; lint-allow: unreachable-code
        "")]))

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