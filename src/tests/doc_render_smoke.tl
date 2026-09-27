;; doc_render_smoke.tl - Runnable golden smoke for doc_render.tl.
(import doc_render)
(import stdlib.io)
(import doc_extract)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector doc_render.DocModule core) as doc_module_vec)
(import (vector.vector doc_extract.DocItem core) as doc_item_vec)

(define (main) : i64
  (doc-render-smoke))

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
      (doc_render.doc-render-markdown
        (doc_extract.doc-extract-source
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
  (y i64))"))]
    [empty-rendered : String
      (doc_render.doc-render-markdown
        (doc_extract.doc-extract-source "(define hidden : i64 1)\n"))]
    (if (string.eq rendered (doc-render-smoke-expected))
      (if (string.eq empty-rendered (doc-render-empty-expected))
        42
        (io.panic "doc-render: empty markdown smoke mismatch"))
      (io.panic "doc-render: markdown smoke mismatch"))))