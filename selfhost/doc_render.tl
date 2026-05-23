;; doc_render.tl - Deterministic Markdown renderer for extracted docs (#388).
;;
;; The #387 extractor exposes module docs and documented top-level items. It
;; does not expose undocumented declarations as separate records yet, so this
;; renderer emits exactly the declarations present in the extracted model.

(import "doc_extract.tl")

(define (doc-render-code [c : char]) : i64
  (cast c : i64))

(define (doc-render-char-code-at [src : String] [idx : i64]) : i64
  (doc-render-code (string-ref src idx)))

(define (doc-render-alpha-code? [k : i64]) : bool
  (or (and (>= k 65) (<= k 90))
      (and (>= k 97) (<= k 122))))

(define (doc-render-digit-code? [k : i64]) : bool
  (and (>= k 48) (<= k 57)))

(define (doc-render-anchor-code? [k : i64]) : bool
  (or (doc-render-alpha-code? k)
      (or (doc-render-digit-code? k)
          (or (= k 45) (= k 95)))))

(define (doc-render-anchor [name : String]) : String
  (let ([i : i64 0]
        [n : i64 (string-length name)]
        [out : String "tl-"])
    (begin
      (while (< i n)
        (let ([k : i64 (doc-render-char-code-at name i)])
          (begin
            (if (doc-render-anchor-code? k)
                (set! out (string-append out (substring name i 1)))
                (set! out
                      (string-append out
                                     (string-append "-" (int->string k)))))
            (set! i (+ i 1)))))
      out)))

(define (doc-render-escape-one [text : String] [idx : i64]) : String
  (let ([k : i64 (doc-render-char-code-at text idx)])
    (if (= k 38)
        "&amp;"
        (if (= k 60)
            "&lt;"
            (if (= k 62)
                "&gt;"
                (if (= k 92)
                    "\\\\"
                    (if (= k 96)
                        "\\`"
                        (if (= k 91)
                            "\\["
                            (if (= k 93)
                                "\\]"
                                (if (= k 42)
                                    "\\*"
                                    (if (= k 95)
                                        "\\_"
                                        (if (= k 35)
                                            "\\#"
                                            (if (= k 124)
                                                "\\|"
                                                (substring text idx 1))))))))))))))

(define (doc-render-escape-markdown [text : String]) : String
  (let ([i : i64 0]
        [n : i64 (string-length text)]
        [out : String ""])
    (begin
      (while (< i n)
        (begin
          (set! out (string-append out (doc-render-escape-one text i)))
          (set! i (+ i 1))))
      out)))

(define (doc-render-code-block [source : String]) : String
  (string-append "```typelisp\n"
                 (string-append source "\n```\n")))

(define (doc-render-module-doc [module-doc : String]) : String
  (if (= (string-length module-doc) 0)
      "_No module docs._\n\n"
      (string-append (doc-render-escape-markdown module-doc) "\n\n")))

(define (doc-render-item-doc [doc-text : String]) : String
  (if (= (string-length doc-text) 0)
      "_No item docs._\n"
      (string-append (doc-render-escape-markdown doc-text) "\n")))

(define (doc-render-item-heading [item : DocItem]) : String
  (let ([name : String (doc-item-name item)]
        [anchor : String (doc-render-anchor (doc-item-name item))])
    (string-append "<a id=\""
                   (string-append anchor
                                  (string-append "\"></a>\n\n### "
                                                 (string-append
                                                   (doc-render-escape-markdown name)
                                                   "\n\n"))))))

(define (doc-render-item [item : DocItem]) : String
  (string-append
    (doc-render-item-heading item)
    (string-append
      "Kind: "
      (string-append
        (doc-kind-name (doc-item-kind item))
        (string-append
          "\n\n"
          (string-append
            (doc-render-code-block (doc-item-signature item))
            (string-append "\n"
                           (string-append (doc-render-item-doc (doc-item-doc item))
                                          "\n"))))))))

(define (doc-render-item-list [items : DocItemList]) : String
  (match items
    [(DocItemNil) ""]
    [(DocItemCons item rest)
     (string-append (doc-render-item item)
                    (doc-render-item-list rest))]))

(define (doc-render-items [items : DocItemList]) : String
  (match items
    [(DocItemNil) "_No documented declarations._\n"]
    [_ (doc-render-item-list items)]))

(define (doc-render-markdown [docs : DocExtraction]) : String
  (string-append
    "# TypeLisp Documentation\n\n"
    (string-append
      (doc-render-module-doc (doc-extraction-module-doc docs))
      (string-append "## Items\n\n"
                     (doc-render-items (doc-extraction-items docs))))))

(define (doc-render-smoke-source) : String
  ";;;; Module docs with `code`, [links], <tag>, & amp.

;; ignored ordinary comment
;;; Global docs for answer.
(define answer : i64 42)

;;; Function docs with `tick` and [arg].
(define (add-one [x : i64]) : i64 (+ x 1))

;;; Extern docs for host-log.
(extern host-log : (-> String unit))

;;; Enum docs mention variants.
(defenum MaybeNumber
  (NoNumber)
  (SomeNumber i64))

;;; Struct docs mention fields.
(defstruct Point
  (x i64)
  (y i64))")

(define (doc-render-smoke-expected) : String
  "# TypeLisp Documentation

Module docs with \\`code\\`, \\[links\\], &lt;tag&gt;, &amp; amp.

## Items

<a id=\"tl-answer\"></a>

### answer

Kind: define

```typelisp
(define answer : i64 42)
```

Global docs for answer.

<a id=\"tl-add-one\"></a>

### add-one

Kind: define-function

```typelisp
(define (add-one [x : i64]) : i64 (+ x 1))
```

Function docs with \\`tick\\` and \\[arg\\].

<a id=\"tl-host-log\"></a>

### host-log

Kind: extern

```typelisp
(extern host-log : (-> String unit))
```

Extern docs for host-log.

<a id=\"tl-MaybeNumber\"></a>

### MaybeNumber

Kind: defenum

```typelisp
(defenum MaybeNumber
  (NoNumber)
  (SomeNumber i64))
```

Enum docs mention variants.

<a id=\"tl-Point\"></a>

### Point

Kind: defstruct

```typelisp
(defstruct Point
  (x i64)
  (y i64))
```

Struct docs mention fields.

")

(define (doc-render-empty-expected) : String
  "# TypeLisp Documentation

_No module docs._

## Items

_No documented declarations._
")

(define (doc-render-smoke) : i64
  (let ([rendered : String
         (doc-render-markdown (doc-extract-source (doc-render-smoke-source)))]
        [empty-rendered : String
         (doc-render-markdown (doc-extract-source "(define hidden : i64 1)\n"))])
    (if (string-eq rendered (doc-render-smoke-expected))
        (if (string-eq empty-rendered (doc-render-empty-expected))
            42
            (begin
              (panic "doc-render: empty markdown smoke mismatch")
              0))
        (begin
          (panic "doc-render: markdown smoke mismatch")
          0))))
