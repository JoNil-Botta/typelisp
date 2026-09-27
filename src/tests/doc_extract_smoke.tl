;; doc_extract_smoke.tl - Runnable structural smoke for doc_extract.tl.
(import doc_extract)
(import compiler_owned_view as owned_view)
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
    [(doc_extract.DocItem.Item kind item-name item-doc signature _)
      (begin
        (unless (= (doc_extract.doc-kind-tag kind) kind-tag) (return false))
        (unless (string.eq item-name name) (return false))
        (unless (string.eq item-doc doc-text) (return false))
        (string.contains signature signature-fragment))]))

(define (doc-extract-smoke-items-ok? [items : doc_item_vec.Vec]) : bool
  (begin
    (unless
      (=
        (doc_extract.doc-item-list-count
          (owned_view.compiler-owned-shared-view items))
        6)
      (return false))
    (unless
      (doc-item-ok?
        (doc_extract.doc-item-list-ref
          (owned_view.compiler-owned-shared-view items)
          0)
        1
        "answer"
        "answer doc\nstill answer"
        "(define answer : i64 42)")
      (return false))
    (unless
      (doc-item-ok?
        (doc_extract.doc-item-list-ref
          (owned_view.compiler-owned-shared-view items)
          1)
        2
        "main"
        "function doc"
        "(define (main [argc : i64])")
      (return false))
    (unless
      (doc-item-ok?
        (doc_extract.doc-item-list-ref
          (owned_view.compiler-owned-shared-view items)
          2)
        4
        "Maybe"
        "enum doc"
        "(defenum Maybe")
      (return false))
    (unless
      (doc-item-ok?
        (doc_extract.doc-item-list-ref
          (owned_view.compiler-owned-shared-view items)
          3)
        3
        "io.emit"
        "external doc"
        "(extern (io.emit")
      (return false))
    (unless
      (doc-item-ok?
        (doc_extract.doc-item-list-ref
          (owned_view.compiler-owned-shared-view items)
          4)
        5
        "Point"
        "struct doc"
        "(defstruct Point")
      (return false))
    (doc-item-ok?
      (doc_extract.doc-item-list-ref items 5)
      6
      "guard"
      "macro doc"
      "(defmacro (guard")))

(define (doc-extract-declaration-smoke-ok?) : bool
  (match (doc_extract.doc-extract-source
    ";: box doc
(defstruct Box_String
  (value String))

;: helper doc
(define (box-string-value [value : Box_String]) : String
  value.value)")
    [(doc_extract.DocExtraction.Extraction _ items)
      (and
        (=
          (doc_extract.doc-item-list-count
            (owned_view.compiler-owned-shared-view items))
          2)
        (doc-item-ok?
          (doc_extract.doc-item-list-ref
            (owned_view.compiler-owned-shared-view items)
            0)
          5
          "Box_String"
          "box doc"
          "(defstruct Box_String")
        (doc-item-ok?
          (doc_extract.doc-item-list-ref items 1)
          2
          "box-string-value"
          "helper doc"
          "(define (box-string-value"))]))

(define (doc-extract-source-line-smoke-ok?) : bool
  (match (doc_extract.doc-extract-source ";: docs\n(define answer : i64 42)\n")
    [(doc_extract.DocExtraction.Extraction _ items)
      (and
        (=
          (doc_extract.doc-item-list-count
            (owned_view.compiler-owned-shared-view items))
          1)
        (=
          (doc_extract.doc-item-source-line
            (doc_extract.doc-item-list-ref items 0))
          2))]))

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
    [(doc_extract.DocExtraction.Extraction module-doc items)
      (begin
        (unless
          (string.eq
            module-doc
            "Module title\nsecond module line\nlater module")
          (return (io.panic "doc-extract: module doc smoke mismatch")))
        (unless
          (=
            (doc_extract.doc-item-list-count
              (owned_view.compiler-owned-shared-view items))
            6)
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
        (match (doc_extract.doc-extract-source
          ";# Legacy module
;: legacy item
(define legacy : i64 1)")
          [(doc_extract.DocExtraction.Extraction legacy-module legacy-items)
            (begin
              (unless
                (string.eq legacy-module "Legacy module")
                (return (io.panic "doc-extract: legacy module doc mismatch")))
              (unless
                (=
                  (doc_extract.doc-item-list-count
                    (owned_view.compiler-owned-shared-view legacy-items))
                  1)
                (return (io.panic "doc-extract: legacy item count mismatch")))
              (unless
                (doc-item-ok?
                  (doc_extract.doc-item-list-ref legacy-items 0)
                  1
                  "legacy"
                  "legacy item"
                  "(define legacy : i64 1)")
                (return (io.panic "doc-extract: legacy item mismatch")))
              42)]))]))