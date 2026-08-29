;; doc_render.tl - Deterministic Markdown renderer for extracted docs.
;;
;; The extractor exposes module docs and documented top-level items. It
;; does not expose undocumented declarations as separate records, so this
;; renderer emits exactly the declarations present in the extracted model.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import doc_extract)
(import stdlib.string)
(import stdlib.vector)

(defenum DocModule
  (Module String doc_extract.DocExtraction))

(import (vector.vector DocModule core) as doc_module_vec)
(import (vector.vector doc_extract.DocItem core) as doc_item_vec)

(define (doc-module-fallback) : DocModule
  (DocModule.Module "" (doc_extract.doc-extraction-empty)))

(define (doc-module-list-count [modules : doc_module_vec.Vec]) : i64
  (doc_module_vec.len (& modules)))

(define (doc-module-list-ref [modules : doc_module_vec.Vec] [index : i64]) : DocModule
  (doc_module_vec.get (& modules) index (doc-module-fallback)))

(define (doc-module-list-append-from
  [out : (&mut out doc_module_vec.Vec)]
  [src : doc_module_vec.Vec]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (doc_module_vec.push-ref!
        out
        (doc-module-list-ref (owned_view.compiler-owned-shared-view src) index))
      (doc-module-list-append-from out src (+ index 1) count))))

(define (doc-module-list-append
  [left : doc_module_vec.Vec]
  [right : doc_module_vec.Vec]) : doc_module_vec.Vec
  (let
    [left-count : i64
      (doc-module-list-count (owned_view.compiler-owned-shared-view left))]
    [right-count : i64
      (doc-module-list-count (owned_view.compiler-owned-shared-view right))]
    [out : doc_module_vec.Vec
      (doc_module_vec.with-capacity (+ left-count right-count))]
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

(define (doc-render-anchor [name : (& name str)]) : String
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
              (set! out (str_cat.str-cat out (string.substring name i 1) ""))
              (set!
                out
                (str_cat.str-cat
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
          (set!
            out
            (str_cat.str-cat
              out
              (doc-render-escape-one
                (owned_view.compiler-owned-shared-view text)
                i)
              ""))
          (set! i (+ i 1))))
      out)))

(define (doc-render-code-block [source : String]) : String
  (str_cat.str-cat "```typelisp\n" source "\n```\n"))

(define (doc-render-module-doc [module-doc : String]) : String
  (if (= (string.string-length module-doc) 0)
    "_No module docs._\n\n"
    (str_cat.str-cat (doc-render-escape-markdown module-doc) "\n\n")))

(define (doc-render-item-doc [doc-text : String]) : String
  (if (= (string.string-length doc-text) 0)
    "_No item docs._\n"
    (str_cat.str-cat (doc-render-escape-markdown doc-text) "\n")))

(define (doc-render-item-heading [item : doc_extract.DocItem]) : String
  (let
    [name : String
      (doc_extract.doc-item-name (owned_view.compiler-owned-shared-view item))]
    [anchor : String (doc-render-anchor (doc_extract.doc-item-name item))]
    (str_cat.str-cat
      "<a id=\""
      anchor
      "\"></a>\n\n### "
      (doc-render-escape-markdown name)
      "\n\n")))

(define (doc-render-item [item : doc_extract.DocItem]) : String
  (str_cat.str-cat
    (doc-render-item-heading (owned_view.compiler-owned-shared-view item))
    "Kind: "
    (doc_extract.doc-kind-name
      (doc_extract.doc-item-kind (owned_view.compiler-owned-shared-view item)))
    "\n\n"
    (doc-render-code-block
      (doc_extract.doc-item-signature
        (owned_view.compiler-owned-shared-view item)))
    "\n"
    (doc-render-item-doc (doc_extract.doc-item-doc item))
    "\n"))

(define (doc-render-item-list-from
  [items : doc_item_vec.Vec]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (doc-render-item
        (doc_extract.doc-item-list-ref
          (owned_view.compiler-owned-shared-view items)
          index))
      (doc-render-item-list-from items (+ index 1) count))))

(define (doc-render-item-list [items : doc_item_vec.Vec]) : String
  (doc-render-item-list-from
    (owned_view.compiler-owned-shared-view items)
    0
    (doc_extract.doc-item-list-count items)))

(define (doc-render-items [items : doc_item_vec.Vec]) : String
  (if (=
    (doc_extract.doc-item-list-count
      (owned_view.compiler-owned-shared-view items))
    0)
    "_No documented declarations._\n"
    (doc-render-item-list items)))

(define (doc-render-markdown [docs : doc_extract.DocExtraction]) : String
  (str_cat.str-cat
    "# TypeLisp Documentation\n\n"
    (doc-render-module-doc
      (doc_extract.doc-extraction-module-doc
        (owned_view.compiler-owned-shared-view docs)))
    "## Items\n\n"
    (doc-render-items (doc_extract.doc-extraction-items docs))))

(define (doc-render-module-nav-item [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    (str_cat.str-cat
      "- ["
      (doc-render-escape-markdown (owned_view.compiler-owned-shared-view path))
      "](#"
      (doc-render-anchor path)
      ")\n")))

(define (doc-render-module-nav-from
  [modules : doc_module_vec.Vec]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (doc-render-module-nav-item
        (doc-module-list-ref
          (owned_view.compiler-owned-shared-view modules)
          index))
      (doc-render-module-nav-from modules (+ index 1) count))))

(define (doc-render-module-nav [modules : doc_module_vec.Vec]) : String
  (doc-render-module-nav-from
    (owned_view.compiler-owned-shared-view modules)
    0
    (doc-module-list-count modules)))

(define (doc-render-module-section [module : DocModule]) : String
  (let
    [path : String
      (doc-module-path (owned_view.compiler-owned-shared-view module))]
    [docs : doc_extract.DocExtraction (doc-module-docs module)]
    (str_cat.str-cat
      "<a id=\""
      (doc-render-anchor (owned_view.compiler-owned-shared-view path))
      "\"></a>\n\n## "
      (doc-render-escape-markdown (owned_view.compiler-owned-shared-view path))
      "\n\nSource: `"
      (doc-render-escape-markdown path)
      "`\n\n"
      (doc-render-module-doc
        (doc_extract.doc-extraction-module-doc
          (owned_view.compiler-owned-shared-view docs)))
      (doc-render-items (doc_extract.doc-extraction-items docs)))))

(define (doc-render-module-sections-from
  [modules : doc_module_vec.Vec]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (doc-render-module-section
        (doc-module-list-ref
          (owned_view.compiler-owned-shared-view modules)
          index))
      (doc-render-module-sections-from modules (+ index 1) count))))

(define (doc-render-module-sections [modules : doc_module_vec.Vec]) : String
  (doc-render-module-sections-from
    (owned_view.compiler-owned-shared-view modules)
    0
    (doc-module-list-count (owned_view.compiler-owned-shared-view modules))))

(define (doc-render-module-graph-markdown [modules : doc_module_vec.Vec]) : String
  (str_cat.str-cat
    "# TypeLisp Documentation\n\n"
    "## Modules\n\n"
    (doc-render-module-nav (owned_view.compiler-owned-shared-view modules))
    "\n"
    (doc-render-module-sections modules)))

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