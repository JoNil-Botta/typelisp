;; doc_render.tl - Deterministic Markdown renderer for extracted docs (#388).
;;
;; The #387 extractor exposes module docs and documented top-level items. It
;; does not expose undocumented declarations as separate records yet, so this
;; renderer emits exactly the declarations present in the extracted model.
(import stdlib.io as io_mod)

(import "doc_extract.tl")

(import stdlib.string as string_mod)

(defenum DocModule
  (DocModule String DocExtraction))

(defenum DocModuleList
  (DocModuleNil)
  (DocModuleCons DocModule (Box DocModuleList)))

(define (doc-module-path [module : DocModule]) : String
  (match module
    [(DocModule path _) path]))

(define (doc-module-docs [module : DocModule]) : DocExtraction
  (match module
    [(DocModule _ docs) docs]))

(define (doc-render-code [c : char]) : i64
  (cast c : i64))

(define (doc-render-alpha? [c : char]) : bool
  (or (and (>= c #A') (<= c #Z')) (and (>= c #a') (<= c #z'))))

(define (doc-render-digit? [c : char]) : bool
  (and (>= c #0') (<= c #9')))

(define (doc-render-anchor-char? [c : char]) : bool
  (or (doc-render-alpha? c) (doc-render-digit? c) (= c #-') (= c #_')))

(define (doc-render-anchor [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [out : String "tl-"]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref name i)]
          (begin
            (if (doc-render-anchor-char? c)
              (set!
                out
                (string_mod.string-append out (string_mod.substring name i 1)))
              (set!
                out
                (string_mod.string-append
                  out
                  (string_mod.string-append
                    "-"
                    (string_mod.int->string (doc-render-code c))))))
            (set! i (+ i 1)))))
      out)))

(define (doc-render-escape-one [text : String] [idx : i64]) : String
  (let
    [c : char (string-ref text idx)]
    (if (= c #&')
      "&amp;"
      (if (= c #<')
        "&lt;"
        (if (= c #>')
          "&gt;"
          (if (= c #\\')
            "\\\\"
            (if (= c #`')
              "\\`"
              (if (= c #[')
                "\\["
                (if (= c #]')
                  "\\]"
                  (if (= c #*')
                    "\\*"
                    (if (= c #_')
                      "\\_"
                      (if (= c ##')
                        "\\#"
                        (if (= c #|')
                          "\\|"
                          (string_mod.substring text idx 1))))))))))))))

(define (doc-render-escape-markdown [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (string_mod.string-append out (doc-render-escape-one text i)))
          (set! i (+ i 1))))
      out)))

(define (doc-render-code-block [source : String]) : String
  (string_mod.string-append
    "```typelisp\n"
    (string_mod.string-append source "\n```\n")))

(define (doc-render-module-doc [module-doc : String]) : String
  (if (= (string-length module-doc) 0)
    "_No module docs._\n\n"
    (string_mod.string-append (doc-render-escape-markdown module-doc) "\n\n")))

(define (doc-render-item-doc [doc-text : String]) : String
  (if (= (string-length doc-text) 0)
    "_No item docs._\n"
    (string_mod.string-append (doc-render-escape-markdown doc-text) "\n")))

(define (doc-render-item-heading [item : DocItem]) : String
  (let
    [name : String (doc-item-name item)]
    [anchor : String (doc-render-anchor (doc-item-name item))]
    (string_mod.string-append
      "<a id=\""
      (string_mod.string-append
        anchor
        (string_mod.string-append
          "\"></a>\n\n### "
          (string_mod.string-append (doc-render-escape-markdown name) "\n\n"))))))

(define (doc-render-item [item : DocItem]) : String
  (string_mod.string-append
    (doc-render-item-heading item)
    (string_mod.string-append
      "Kind: "
      (string_mod.string-append
        (doc-kind-name (doc-item-kind item))
        (string_mod.string-append
          "\n\n"
          (string_mod.string-append
            (doc-render-code-block (doc-item-signature item))
            (string_mod.string-append
              "\n"
              (string_mod.string-append
                (doc-render-item-doc (doc-item-doc item))
                "\n"))))))))

(define (doc-render-item-list [items : DocItemList]) : String
  (match items
    [(DocItemNil) ""]
    [(DocItemCons item rest)
      (string_mod.string-append
        (doc-render-item item)
        (doc-render-item-list (box-get rest)))]))

(define (doc-render-items [items : DocItemList]) : String
  (match items
    [(DocItemNil) "_No documented declarations._\n"]
    [_ (doc-render-item-list items)]))

(define (doc-render-markdown [docs : DocExtraction]) : String
  (string_mod.string-append
    "# TypeLisp Documentation\n\n"
    (string_mod.string-append
      (doc-render-module-doc (doc-extraction-module-doc docs))
      (string_mod.string-append
        "## Items\n\n"
        (doc-render-items (doc-extraction-items docs))))))

(define (doc-render-module-nav-item [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    (string_mod.string-append
      "- ["
      (string_mod.string-append
        (doc-render-escape-markdown path)
        (string_mod.string-append
          "](#"
          (string_mod.string-append (doc-render-anchor path) ")\n"))))))

(define (doc-render-module-nav [modules : DocModuleList]) : String
  (match modules
    [(DocModuleNil) ""]
    [(DocModuleCons module rest)
      (string_mod.string-append
        (doc-render-module-nav-item module)
        (doc-render-module-nav (box-get rest)))]))

(define (doc-render-module-section [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    [docs : DocExtraction (doc-module-docs module)]
    (string_mod.string-append
      "<a id=\""
      (string_mod.string-append
        (doc-render-anchor path)
        (string_mod.string-append
          "\"></a>\n\n## "
          (string_mod.string-append
            (doc-render-escape-markdown path)
            (string_mod.string-append
              "\n\nSource: `"
              (string_mod.string-append
                (doc-render-escape-markdown path)
                (string_mod.string-append
                  "`\n\n"
                  (string_mod.string-append
                    (doc-render-module-doc (doc-extraction-module-doc docs))
                    (doc-render-items (doc-extraction-items docs))))))))))))

(define (doc-render-module-sections [modules : DocModuleList]) : String
  (match modules
    [(DocModuleNil) ""]
    [(DocModuleCons module rest)
      (string_mod.string-append
        (doc-render-module-section module)
        (doc-render-module-sections (box-get rest)))]))

(define (doc-render-module-graph-markdown [modules : DocModuleList]) : String
  (string_mod.string-append
    "# TypeLisp Documentation\n\n"
    (string_mod.string-append
      "## Modules\n\n"
      (string_mod.string-append
        (doc-render-module-nav modules)
        (string_mod.string-append "\n" (doc-render-module-sections modules))))))

(define (doc-render-smoke-source) : String
  ";# Module docs with `code`, [links], <tag>, & amp.

;; ignored ordinary comment
;: Global docs for answer.
(define answer : i64 42)

;: Function docs with `tick` and [arg].
(define (add-one [x : i64]) : i64 (+ x 1))

;: Extern docs for host-log.
(extern (host-log [arg0 : String]) : unit)

;: Enum docs mention variants.
(defenum MaybeNumber
  (NoNumber)
  (SomeNumber i64))

;: Struct docs mention fields.
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
(extern (host-log [arg0 : String]) : unit)
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
  (let
    [rendered : String
      (doc-render-markdown (doc-extract-source (doc-render-smoke-source)))]
    [empty-rendered : String
      (doc-render-markdown (doc-extract-source "(define hidden : i64 1)\n"))]
    (if (string_mod.string-eq rendered (doc-render-smoke-expected))
      (if (string_mod.string-eq empty-rendered (doc-render-empty-expected))
        42
        (begin
          (io_mod.panic "doc-render: empty markdown smoke mismatch")
          0))
      (begin
        (io_mod.panic "doc-render: markdown smoke mismatch")
        0))))