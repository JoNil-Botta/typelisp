;; format_rules.tl - TypeLisp-aware formatter rules (#367).
;;
;; `format_core.tl` stays syntax-neutral. This module adds a deterministic
;; gofmt-like first pass for common TypeLisp special forms while still building
;; `Doc` values for width-aware rendering.
(import "../stdlib/io.tl")

(import "format_tokens.tl")

(import "format_cst.tl")

(import "format_doc.tl")

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

(define (format-rules-node-comment? [node : FormatCst]) : bool
  (match node
    [(FmtCstComment _) true]
    [_ false]))

(define (format-rules-gap) : Doc
  (doc-append (doc-hard-line) (doc-hard-line)))

(define (format-rules-forms-separator
  [previous-comment : bool]
  [node : FormatCst]) : Doc
  (if previous-comment
    (doc-hard-line)
    (format-rules-gap)))

(define (format-rules-space [doc : Doc]) : Doc
  (doc-append (doc-text " ") doc))

(define (format-rules-inline-tail-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (format-rules-space (format-rules-cst-doc node))
        (format-rules-inline-tail-doc rest))]))

(define (format-rules-hard-tail-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (doc-hard-line)
        (doc-append
          (format-rules-cst-doc node)
          (match rest
            [(FmtCstNil)
              (if (format-rules-node-comment? node)
                (doc-hard-line)
                (doc-empty))]
            [_ (format-rules-hard-tail-doc rest)])))]))

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
      (doc-append
        (format-rules-tail-separator previous-comment node)
        (doc-append
          (format-rules-cst-doc node)
          (match rest
            [(FmtCstNil)
              (if (format-rules-node-comment? node)
                (doc-hard-line)
                (doc-empty))]
            [_
              (format-rules-list-tail-doc
                (format-rules-node-comment? node)
                rest)])))]))

(define (format-rules-list-items-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (format-rules-cst-doc node)
        (match rest
          [(FmtCstNil)
            (if (format-rules-node-comment? node)
              (doc-hard-line)
              (doc-empty))]
          [_
            (format-rules-list-tail-doc (format-rules-node-comment? node) rest)]))]))

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
    [(FmtCstCons first tail) (format-rules-first-line-form-doc head first tail)]))

(define (format-rules-list-append
  [left : FormatCstList]
  [right : FormatCstList]) : FormatCstList
  (match left
    [(FmtCstNil) right]
    [(FmtCstCons node rest)
      (FmtCstCons node (format-rules-list-append rest right))]))

(define (format-rules-bracket-binding-items?
  [items : FormatCstList]
  [seen : bool]) : bool
  (match items
    [(FmtCstNil) seen]
    [(FmtCstCons node rest)
      (match node
        [(FmtCstComment _) (format-rules-bracket-binding-items? rest seen)]
        [(FmtCstBracketList _) (format-rules-bracket-binding-items? rest true)]
        [_ false])]))

(define (format-rules-bracket-binding-list? [items : FormatCstList]) : bool
  (format-rules-bracket-binding-items? items false))

(define (format-rules-let-rest [rest : FormatCstList]) : FormatCstList
  (match rest
    [(FmtCstCons first tail)
      (match first
        [(FmtCstList bindings)
          (if (format-rules-bracket-binding-list? bindings)
            (format-rules-list-append bindings tail)
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

(define (format-rules-let-item-doc [node : FormatCst]) : Doc
  (match node
    [(FmtCstBracketList items)
      (match items
        [(FmtCstCons
            name
            (FmtCstCons colon (FmtCstCons typ (FmtCstCons init FmtCstNil))))
          (if (format-rules-node-colon? colon)
            (format-rules-let-binding-annotated-doc name colon typ init)
            (format-rules-delimited-doc "[" items "]"))]
        [(FmtCstCons name (FmtCstCons init FmtCstNil))
          (format-rules-let-binding-unannotated-doc name init)]
        [_ (format-rules-delimited-doc "[" items "]")])]
    [_ (format-rules-cst-doc node)]))

(define (format-rules-let-tail-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (doc-hard-line)
        (doc-append
          (format-rules-let-item-doc node)
          (match rest
            [(FmtCstNil)
              (if (format-rules-node-comment? node)
                (doc-hard-line)
                (doc-empty))]
            [_ (format-rules-let-tail-doc rest)])))]))

(define (format-rules-let-doc [rest : FormatCstList]) : Doc
  (doc-append
    (doc-text "(")
    (doc-append
      (doc-text "let")
      (doc-append
        (doc-nest 2 (format-rules-let-tail-doc (format-rules-let-rest rest)))
        (doc-text ")")))))

(define (format-rules-define-doc [rest : FormatCstList]) : Doc
  (match rest
    [(FmtCstCons
        target
        (FmtCstCons colon (FmtCstCons typ (FmtCstCons body (FmtCstNil)))))
      (doc-append
        (doc-text "(")
        (doc-append
          (doc-text "define")
          (doc-append
            (format-rules-space (format-rules-cst-doc target))
            (doc-append
              (format-rules-space (format-rules-cst-doc colon))
              (doc-append
                (format-rules-space (format-rules-cst-doc typ))
                (doc-append
                  (doc-nest
                    2
                    (doc-append (doc-hard-line) (format-rules-cst-doc body)))
                  (doc-text ")")))))))]
    [(FmtCstCons target (FmtCstCons body (FmtCstNil)))
      (doc-append
        (doc-text "(")
        (doc-append
          (doc-text "define")
          (doc-append
            (format-rules-space (format-rules-cst-doc target))
            (doc-append
              (doc-nest
                2
                (doc-append (doc-hard-line) (format-rules-cst-doc body)))
              (doc-text ")")))))]
    [_ (format-rules-first-or-line-form-doc "define" rest)]))

(define (format-rules-special-list-doc
  [head : FormatCst]
  [rest : FormatCstList]) : Doc
  (cond
    [(format-rules-node-symbol? head "import")
      (format-rules-inline-form-doc "import" rest)]
    [(format-rules-node-symbol? head "extern")
      (format-rules-inline-form-doc "extern" rest)]
    [(format-rules-node-symbol? head "define") (format-rules-define-doc rest)]
    [(format-rules-node-symbol? head "defenum")
      (format-rules-first-or-line-form-doc "defenum" rest)]
    [(format-rules-node-symbol? head "defstruct")
      (format-rules-first-or-line-form-doc "defstruct" rest)]
    [(format-rules-node-symbol? head "let") (format-rules-let-doc rest)]
    [(format-rules-node-symbol? head "if")
      (format-rules-first-or-line-form-doc "if" rest)]
    [(format-rules-node-symbol? head "while")
      (format-rules-first-or-line-form-doc "while" rest)]
    [(format-rules-node-symbol? head "begin")
      (format-rules-line-form-doc "begin" rest)]
    [(format-rules-node-symbol? head "unsafe")
      (format-rules-line-form-doc "unsafe" rest)]
    [(format-rules-node-symbol? head "match")
      (format-rules-first-or-line-form-doc "match" rest)]
    [else (format-rules-delimited-doc "(" (FmtCstCons head rest) ")")]))

(define (format-rules-list-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (format-rules-delimited-doc "(" FmtCstNil ")")]
    [(FmtCstCons head rest) (format-rules-special-list-doc head rest)]))

(define (format-rules-forms-tail-doc
  [previous-comment : bool]
  [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (format-rules-forms-separator previous-comment node)
        (doc-append
          (format-rules-cst-doc node)
          (format-rules-forms-tail-doc (format-rules-node-comment? node) rest)))]))

(define (format-rules-forms-doc [items : FormatCstList]) : Doc
  (match items
    [(FmtCstNil) (doc-empty)]
    [(FmtCstCons node rest)
      (doc-append
        (format-rules-cst-doc node)
        (format-rules-forms-tail-doc (format-rules-node-comment? node) rest))]))

(define (format-rules-cst-doc [node : FormatCst]) : Doc
  (match node
    [(FmtCstAtom tok) (doc-text (format-token-text tok))]
    [(FmtCstComment text) (doc-text text)]
    [(FmtCstPrefix tok child)
      (doc-append
        (doc-text (format-token-text tok))
        (format-rules-cst-doc child))]
    [(FmtCstList items) (format-rules-list-doc items)]
    [(FmtCstBracketList items) (format-rules-delimited-doc "[" items "]")]
    [(FmtCstForms items) (format-rules-forms-doc items)]))

(define (format-rules-source-doc [src : String]) : Doc
  (format-rules-cst-doc (parse-format-source src)))

(define (format-rules-render [node : FormatCst]) : String
  (render-doc (format-rules-cst-doc node)))

(define (format-rules-render-width [node : FormatCst] [width : i64]) : String
  (render-doc-width (format-rules-cst-doc node) width))

(define (format-rules-render-source [src : String]) : String
  (render-doc (format-rules-source-doc src)))

(define (format-rules-render-source-width [src : String] [width : i64]) : String
  (render-doc-width (format-rules-source-doc src) width))

(define (format-rules-decls-source) : String
  "(import \"std.tl\") (extern print-string : (-> String unit)) (defenum Maybe (Some i64) (None)) (defstruct Point (x i64) (y i64))")

(define (format-rules-decls-expected) : String
  "(import \"std.tl\")\n\n(extern print-string : (-> String unit))\n\n(defenum Maybe\n  (Some i64)\n  (None))\n\n(defstruct Point\n  (x i64)\n  (y i64))")

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
    (begin
      (unless (string-eq decls (format-rules-decls-expected)) (return 1))
      (unless (string-eq flow (format-rules-flow-expected)) (return 2))
      (unless (string-eq comments (format-rules-comments-expected)) (return 3))
      (unless (string-eq quote (format-rules-quote-expected)) (return 4))
      (unless (string-eq unsafe (format-rules-unsafe-expected)) (return 5))
      42)))