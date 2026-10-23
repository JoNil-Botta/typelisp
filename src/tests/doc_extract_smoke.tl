;; doc_extract_smoke.tl - Runnable structural smoke for doc_extract.tl.
(import doc_extract)
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector doc_extract.DocItem core) as doc_item_vec)

(define (main) : i64
  (doc-extract-smoke))

(define (doc-item-ok?
  [item : doc_extract.DocItem]
  [kind-tag : i64]
  [name : String]
  [doc-text : String]
  [signature-fragment : String]) : bool
  (match item
    [(Item kind item-name item-doc signature _)
      (unless (= (doc_extract.doc-kind-tag kind) kind-tag) (return false))
      (unless (string.eq item-name name) (return false))
      (unless (string.eq item-doc doc-text) (return false))
      (string.contains signature signature-fragment)]
    [_ false]))

(define (doc-extract-smoke-items-ok? [items : doc_item_vec.Vec]) : bool
  (unless (= (doc_extract.doc-item-list-count items) 10) (return false))
  (unless
    (doc-item-ok?
      (doc_extract.doc-item-list-ref items 0)
      1
      "answer"
      "answer doc\nstill answer"
      "(define answer : i64 42)")
    (return false))
  (unless
    (doc-item-ok?
      (doc_extract.doc-item-list-ref items 1)
      2
      "main"
      "function doc"
      "(define (main [argc : i64])")
    (return false))
  (unless
    (doc-item-ok?
      (doc_extract.doc-item-list-ref items 2)
      4
      "Maybe"
      "enum doc"
      "(defenum Maybe")
    (return false))
  (unless
    (doc-item-ok?
      (doc_extract.doc-item-list-ref items 5)
      3
      "io.emit"
      "external doc"
      "(extern (io.emit")
    (return false))
  (unless
    (doc-item-ok?
      (doc_extract.doc-item-list-ref items 6)
      5
      "Point"
      "struct doc"
      "(defstruct Point")
    (return false))
  (doc-item-ok?
    (doc_extract.doc-item-list-ref items 9)
    6
    "guard"
    "macro doc"
    "(defmacro (guard"))

(define (doc-extract-declaration-smoke-ok?) : bool
  (match (doc_extract.doc-extract-source
    ";: box doc
(defstruct Box_String
  (value String))

;: helper doc
(define (box-string-value [value : Box_String]) : String
  value.value)")
    [(Extraction _ items)
      (and
        (= (doc_extract.doc-item-list-count items) 3)
        (doc-item-ok?
          (doc_extract.doc-item-list-ref items 0)
          5
          "Box_String"
          "box doc"
          "(defstruct Box_String")
        (doc-item-ok?
          (doc_extract.doc-item-list-ref items 2)
          2
          "box-string-value"
          "helper doc"
          "(define (box-string-value"))]))

(define (doc-extract-source-line-smoke-ok?) : bool
  (match (doc_extract.doc-extract-source ";: docs\n(define answer : i64 42)\n")
    [(Extraction _ items)
      (and
        (= (doc_extract.doc-item-list-count items) 1)
        (=
          (doc_extract.doc-item-source-line
            (& (doc_extract.doc-item-list-ref items 0)))
          2))]))

(define (doc-extract-repeated-alias-ok?) : bool
  (match (doc_extract.doc-extract-source
    "(import stdlib.string)\n;: added docs\n(import stdlib.string)")
    [(Extraction _ items)
      (unless
        (and
          (= items.len 1)
          (doc-item-ok?
            (doc_extract.doc-item-list-ref items 0)
            8
            "string"
            "added docs"
            "(import stdlib.string)\n(import stdlib.string)"))
        (return false))])
  (match (doc_extract.doc-extract-source
    ";: initial docs
(import stdlib.string)
;: output docs
(import stdlib.io as output)
;; ordinary comment
;: later docs
(import ; preserve the original form
  stdlib.string as string)
(import stdlib.vector as arrays)
(import stdlib.string)")
    [(Extraction _ items)
      (unless (= items.len 3) (return false))
      (let
        [alias : doc_extract.DocItem (doc_extract.doc-item-list-ref items 0)]
        [identity : doc_extract.DocIdentity
          (doc_extract.doc-item-identity (& alias))]
        (and
          (string.eq (doc_extract.doc-item-name (& alias)) "string")
          (string.eq
            (doc_extract.doc-item-doc (& alias))
            "initial docs\n\nlater docs")
          (string.eq
            (doc_extract.doc-item-signature (& alias))
            "(import stdlib.string)\n(import ; preserve the original form\n  stdlib.string as string)\n(import stdlib.string)")
          (= (doc_extract.doc-item-source-line (& alias)) 2)
          (= (doc_extract.doc-kind-tag identity.kind) 8)
          (string.eq identity.name "string")
          (string.eq identity.parent "")
          (match (& identity.origin)
            [(Source) true]
            [_ false])
          (doc-item-ok?
            (doc_extract.doc-item-list-ref items 1)
            8
            "output"
            "output docs"
            "(import stdlib.io as output)")
          (doc-item-ok?
            (doc_extract.doc-item-list-ref items 2)
            8
            "arrays"
            ""
            "(import stdlib.vector as arrays)")))]))

(define (doc-borrowed-getters-own-results? [scoped : bool]) : bool
  (let
    [owner (arena.make)]
    [original : doc_extract.DocItem
      (if scoped
        (doc_extract.ScopedItem
          (doc_extract.DocIdentity
            Field
            (string.copy "value")
            (string.copy "Box")
            (doc_extract.Generated
              (string.copy "vector")
              (string.copy "Box")
              (string.copy "String")))
          (string.copy "field docs")
          (string.copy "(value String)")
          0)
        (doc_extract.Item
          GeneratedImport
          (string.copy "value")
          (string.copy "field docs")
          (string.copy "(value String)")
          7))]
    [item (in-arena owner (clone original))]
    [kind : doc_extract.DocItemKind (doc_extract.doc-item-kind (& item))]
    [name : String (doc_extract.doc-item-name (& item))]
    [docs : String (doc_extract.doc-item-doc (& item))]
    [signature : String (doc_extract.doc-item-signature (& item))]
    [line : i64 (doc_extract.doc-item-source-line (& item))]
    [identity : doc_extract.DocIdentity
      (doc_extract.doc-item-identity (& item))]
    [label : String (doc_extract.doc-item-label (& item))]
    (arena.destroy-safe! owner)
    (and
      (=
        (doc_extract.doc-kind-tag kind)
        (if scoped
          9
          7))
      (string.eq name "value")
      (string.eq docs "field docs")
      (string.eq signature "(value String)")
      (=
        line
        (if scoped
          0
          7))
      (=
        (doc_extract.doc-kind-tag identity.kind)
        (if scoped
          9
          7))
      (string.eq identity.name "value")
      (string.eq
        identity.parent
        (if scoped
          "Box"
          "(value String)"))
      (string.eq
        label
        (if scoped
          "Box.value"
          "value"))
      (match (& identity.origin)
        [(Source) (not scoped)]
        [(Generated generator item key)
          (and
            scoped
            (string.eq generator "vector")
            (string.eq item "Box")
            (string.eq key "String"))]))))

(define (doc-extract-smoke) : i64
  (match (doc_extract.doc-extract-source
    ";# Module title
;# second module line

;; ordinary comment ignored
;: answer doc
;: still answer
(define answer : i64 42)

;: lost before ordinary comment
;; ordinary comment clears pending docs
(define missed : i64 0)
(define ignored-quote-char : char '\"')
(define ignored-paren-char : char '(')
;: function doc
(define (main [argc : i64]) : i64
  answer)
; ordinary comment clears pending docs
;: enum doc
(defenum Maybe (None) (Some i64))

;# later module
;: external doc
(extern (io.emit [arg0 : String]) : unit)
;: struct doc
(defstruct Point (x i64) (y i64))
;: macro doc
(defmacro (guard [condition : bool] [body : unit]) : unit
  `(if ,condition ,body unit))
;: EOF unattached")
    [(Extraction module-doc items)
      (unless
        (string.eq module-doc "Module title\nsecond module line\nlater module")
        (return (io.panic "doc-extract: module doc smoke mismatch")))
      (unless
        (= (doc_extract.doc-item-list-count items) 10)
        (return (io.panic "doc-extract: item count smoke mismatch")))
      (unless
        (doc-extract-smoke-items-ok? items)
        (return (io.panic "doc-extract: item doc smoke mismatch")))
      (unless
        (doc-extract-declaration-smoke-ok?)
        (return (io.panic "doc-extract: declaration item mismatch")))
      (unless
        (doc-extract-source-line-smoke-ok?)
        (return (io.panic "doc-extract: declaration source line mismatch")))
      (unless
        (doc-extract-repeated-alias-ok?)
        (return (io.panic "doc-extract: repeated alias identity mismatch")))
      (unless
        (and
          (doc-borrowed-getters-own-results? false)
          (doc-borrowed-getters-own-results? true))
        (return
          (io.panic "doc-extract: borrowed getter result lifetime mismatch")))
      (match (doc_extract.doc-extract-source
        ";# Legacy module
;: legacy item
(define legacy : i64 1)")
        [(Extraction legacy-module legacy-items)
          (unless
            (string.eq legacy-module "Legacy module")
            (return (io.panic "doc-extract: legacy module doc mismatch")))
          (unless
            (= (doc_extract.doc-item-list-count legacy-items) 1)
            (return (io.panic "doc-extract: legacy item count mismatch")))
          (unless
            (doc-item-ok?
              (doc_extract.doc-item-list-ref legacy-items 0)
              1
              "legacy"
              "legacy item"
              "(define legacy : i64 1)")
            (return (io.panic "doc-extract: legacy item mismatch")))
          42])]))