;; doc_render.tl - Deterministic Markdown renderer for extracted docs.
;;
;; The extractor exposes module docs and documented top-level items. It
;; does not expose undocumented declarations as separate records, so this
;; renderer emits exactly the declarations present in the extracted model.
(import stdlib.io)
(import doc_extract)
(import stdlib.string)

(defenum DocModule
  (Module String doc_extract.DocExtraction))

(defstruct DocModuleList
  (slots (Array DocModule))
  (len i64))

(define (doc-module-fallback) : DocModule
  (DocModule.Module "" (doc_extract.doc-extraction-empty)))

(define (doc-module-list-slots [modules : (& modules DocModuleList)]) : (&
    modules
    (Array DocModule))
  (& (struct-get modules slots)))

(define (doc-module-list-count [modules : DocModuleList]) : i64
  (doc-module-list-len (& modules)))

(define (doc-module-list-len [modules : (& modules DocModuleList)]) : i64
  (struct-get modules len))

(define (doc-module-list-ref [modules : DocModuleList] [index : i64]) : DocModule
  (doc-module-list-get (& modules) index (doc-module-fallback)))

(define (doc-module-list-with-capacity [capacity : i64]) : DocModuleList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (DocModuleList (make-array DocModule cap) 0)))

(define (doc-module-list-new) : DocModuleList
  (doc-module-list-with-capacity 4))

(define (doc-module-list-get
  [modules : (& modules DocModuleList)]
  [index : i64]
  [fallback : DocModule]) : DocModule
  (if (if (>= index 0)
    (< index (doc-module-list-len modules))
    false)
    (array-ref (doc-module-list-slots modules) index)
    fallback))

(define (doc-module-list-copy-range
  [dst : (&mut dst (Array DocModule))]
  [src : (& src (Array DocModule))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (doc-module-list-copy-range dst src (+ index 1) count))))

(define (doc-module-list-grow [modules : (&mut modules DocModuleList)]) : unit
  (let
    [n : i64 (struct-get modules len)]
    [old-cap : i64 (array-length (struct-get modules slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array DocModule) (make-array DocModule new-cap)]
    (begin
      (doc-module-list-copy-range
        (&mut bigger)
        (& (struct-get modules slots))
        0
        n)
      (set! (struct-get modules slots) bigger))))

(define (doc-module-list-push
  [modules : (&mut modules DocModuleList)]
  [module : DocModule]) : unit
  (begin
    (if (< (struct-get modules len) (array-length (struct-get modules slots)))
      unit
      (doc-module-list-grow modules))
    (let
      [index : i64 (struct-get modules len)]
      (begin
        (array-set! (struct-get modules slots) index module)
        (set! (struct-get modules len) (+ index 1))))))

(define (doc-module-list-append-from
  [out : (&mut out DocModuleList)]
  [src : DocModuleList]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (doc-module-list-push out (doc-module-list-ref src index))
      (doc-module-list-append-from out src (+ index 1) count))))

(define (doc-module-list-append [left : DocModuleList] [right : DocModuleList]) : DocModuleList
  (let
    [left-count : i64 (doc-module-list-count left)]
    [right-count : i64 (doc-module-list-count right)]
    [out : DocModuleList
      (doc-module-list-with-capacity (+ left-count right-count))]
    (begin
      (doc-module-list-append-from (&mut out) left 0 left-count)
      (doc-module-list-append-from (&mut out) right 0 right-count)
      out)))

(define (doc-module-path [module : DocModule]) : String
  (match module
    [(DocModule.Module path _) path]))

(define (doc-module-docs [module : DocModule]) : doc_extract.DocExtraction
  (match module
    [(DocModule.Module _ docs) docs]))

(define (doc-render-code [c : char]) : i64
  (cast c : i64))

(define (doc-render-alpha? [c : char]) : bool
  (or (and (>= c 'A') (<= c 'Z')) (and (>= c 'a') (<= c 'z'))))

(define (doc-render-digit? [c : char]) : bool
  (and (>= c '0') (<= c '9')))

(define (doc-render-anchor-char? [c : char]) : bool
  (or (doc-render-alpha? c) (doc-render-digit? c) (= c '-') (= c '_')))

(define (doc-render-anchor [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    [out : String "tl-"]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref name i)]
          (begin
            (if (doc-render-anchor-char? c)
              (set! out (string.concat3 out (string.substring name i 1) ""))
              (set!
                out
                (string.concat3
                  out
                  "-"
                  (string.int->string (doc-render-code c)))))
            (set! i (+ i 1)))))
      out)))

(define (doc-render-escape-one [text : String] [idx : i64]) : String
  (let
    [c : char (string.string-ref text idx)]
    (cond
      [(= c '&') "&amp;"]
      [(= c '<') "&lt;"]
      [(= c '>') "&gt;"]
      [(= c '\\') "\\\\"]
      [(= c '`') "\\`"]
      [(= c '[') "\\["]
      [(= c ']') "\\]"]
      [(= c '*') "\\*"]
      [(= c '_') "\\_"]
      [(= c '#') "\\#"]
      [(= c '|') "\\|"]
      [else (string.substring text idx 1)])))

(define (doc-render-escape-markdown [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set! out (string.concat3 out (doc-render-escape-one text i) ""))
          (set! i (+ i 1))))
      out)))

(define (doc-render-code-block [source : String]) : String
  (string.append "```typelisp\n" (string.append source "\n```\n")))

(define (doc-render-module-doc [module-doc : String]) : String
  (if (= (string.string-length module-doc) 0)
    "_No module docs._\n\n"
    (string.append (doc-render-escape-markdown module-doc) "\n\n")))

(define (doc-render-item-doc [doc-text : String]) : String
  (if (= (string.string-length doc-text) 0)
    "_No item docs._\n"
    (string.append (doc-render-escape-markdown doc-text) "\n")))

(define (doc-render-item-heading [item : doc_extract.DocItem]) : String
  (let
    [name : String (doc_extract.doc-item-name item)]
    [anchor : String (doc-render-anchor (doc_extract.doc-item-name item))]
    (string.append
      "<a id=\""
      (string.append
        anchor
        (string.append
          "\"></a>\n\n### "
          (string.append (doc-render-escape-markdown name) "\n\n"))))))

(define (doc-render-item [item : doc_extract.DocItem]) : String
  (string.append
    (doc-render-item-heading item)
    (string.append
      "Kind: "
      (string.append
        (doc_extract.doc-kind-name (doc_extract.doc-item-kind item))
        (string.append
          "\n\n"
          (string.append
            (doc-render-code-block (doc_extract.doc-item-signature item))
            (string.append
              "\n"
              (string.append
                (doc-render-item-doc (doc_extract.doc-item-doc item))
                "\n"))))))))

(define (doc-render-item-list-from
  [items : doc_extract.DocItemList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (string.append
      (doc-render-item (doc_extract.doc-item-list-ref items index))
      (doc-render-item-list-from items (+ index 1) count))))

(define (doc-render-item-list [items : doc_extract.DocItemList]) : String
  (doc-render-item-list-from items 0 (doc_extract.doc-item-list-count items)))

(define (doc-render-items [items : doc_extract.DocItemList]) : String
  (if (= (doc_extract.doc-item-list-count items) 0)
    "_No documented declarations._\n"
    (doc-render-item-list items)))

(define (doc-render-markdown [docs : doc_extract.DocExtraction]) : String
  (string.append
    "# TypeLisp Documentation\n\n"
    (string.append
      (doc-render-module-doc (doc_extract.doc-extraction-module-doc docs))
      (string.append
        "## Items\n\n"
        (doc-render-items (doc_extract.doc-extraction-items docs))))))

(define (doc-render-module-nav-item [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    (string.append
      "- ["
      (string.append
        (doc-render-escape-markdown path)
        (string.append "](#" (string.append (doc-render-anchor path) ")\n"))))))

(define (doc-render-module-nav-from
  [modules : DocModuleList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (string.append
      (doc-render-module-nav-item (doc-module-list-ref modules index))
      (doc-render-module-nav-from modules (+ index 1) count))))

(define (doc-render-module-nav [modules : DocModuleList]) : String
  (doc-render-module-nav-from modules 0 (doc-module-list-count modules)))

(define (doc-render-module-section [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    [docs : doc_extract.DocExtraction (doc-module-docs module)]
    (string.append
      "<a id=\""
      (string.append
        (doc-render-anchor path)
        (string.append
          "\"></a>\n\n## "
          (string.append
            (doc-render-escape-markdown path)
            (string.append
              "\n\nSource: `"
              (string.append
                (doc-render-escape-markdown path)
                (string.append
                  "`\n\n"
                  (string.append
                    (doc-render-module-doc
                      (doc_extract.doc-extraction-module-doc docs))
                    (doc-render-items (doc_extract.doc-extraction-items docs))))))))))))

(define (doc-render-module-sections-from
  [modules : DocModuleList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (string.append
      (doc-render-module-section (doc-module-list-ref modules index))
      (doc-render-module-sections-from modules (+ index 1) count))))

(define (doc-render-module-sections [modules : DocModuleList]) : String
  (doc-render-module-sections-from modules 0 (doc-module-list-count modules)))

(define (doc-render-module-graph-markdown [modules : DocModuleList]) : String
  (string.append
    "# TypeLisp Documentation\n\n"
    (string.append
      "## Modules\n\n"
      (string.append
        (doc-render-module-nav modules)
        (string.append "\n" (doc-render-module-sections modules))))))

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
  (No)
  (Some i64))

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
  (No)
  (Some i64))
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
      (doc-render-markdown
        (doc_extract.doc-extract-source (doc-render-smoke-source)))]
    [empty-rendered : String
      (doc-render-markdown
        (doc_extract.doc-extract-source "(define hidden : i64 1)\n"))]
    (if (string.eq rendered (doc-render-smoke-expected))
      (if (string.eq empty-rendered (doc-render-empty-expected))
        42
        (io.panic "doc-render: empty markdown smoke mismatch"))
      (io.panic "doc-render: markdown smoke mismatch"))))