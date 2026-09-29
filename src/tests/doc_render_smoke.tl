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

;; Anchors are injective: letters, digits and `-` stay, every other byte is
;; `_` and two hex digits (the marker escapes itself), and item identities join
;; separately encoded fields with `.`, which a field never contains (#7776).
(define (doc-render-anchor-is?
  [text : (& text str)]
  [expected : (& expected str)]) : bool
  (string.eq (doc_render.doc-render-anchor text) expected))

(define (doc-render-anchor-table-ok?) : bool
  (and
    (doc-render-anchor-is? "ready?" "tl-ready_3f")
    (doc-render-anchor-is? "ready-63" "tl-ready-63")
    (doc-render-anchor-is? "a_b" "tl-a_5fb")
    (doc-render-anchor-is? "a_5fb" "tl-a_5f5fb")
    (doc-render-anchor-is? "a.b" "tl-a_2eb")
    (doc-render-anchor-is? "?!" "tl-_3f_21")
    (doc-render-anchor-is? "" "tl-")
    (doc-render-anchor-is?
      "Language Specification"
      "tl-Language_20Specification")
    (doc-render-anchor-is? "src/a.tl" "tl-src_2fa_2etl")
    (doc-render-anchor-is? "é" "tl-_c3_a9")
    (string.eq
      (doc_render.doc-render-identity-anchor "a.b" "define" "c")
      "tl-a_2eb.define.c")
    (string.eq
      (doc_render.doc-render-identity-anchor "a" "b.define" "c")
      "tl-a.b_2edefine.c")
    (string.eq
      (doc_render.doc-render-identity-anchor "m" "define-function" "")
      "tl-m.define-function.")))

(define (doc-render-distinct-names-ok?) : bool
  (let
    [rendered : String
      (doc_render.doc-render-markdown
        (doc_extract.doc-extract-source
          ";: Predicate.
(define (ready? [x : i64]) : bool (> x 0))

;: Escape-looking twin.
(define (ready-63 [x : i64]) : i64 x)"))]
    (and
      (string.contains rendered "<a id=\"tl-ready_3f\"></a>")
      (string.contains rendered "<a id=\"tl-ready-63\"></a>"))))

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
    (cond
      [(not (string.eq rendered (doc-render-smoke-expected)))
        (io.panic "doc-render: markdown smoke mismatch")]
      [(not (string.eq empty-rendered (doc-render-empty-expected)))
        (io.panic "doc-render: empty markdown smoke mismatch")]
      [(not (doc-render-anchor-table-ok?))
        (io.panic "doc-render: anchor encoding table mismatch")]
      [(not (doc-render-distinct-names-ok?))
        (io.panic "doc-render: escape-looking names share an anchor")]
      [else 42])))