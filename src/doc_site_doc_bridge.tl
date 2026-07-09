;; Keep the doc-site tools on dotted imports while the compiler CLI finishes
;; migrating the remaining doc command dependencies.
(import doc_extract)
(import doc_render)
(import doc_html)

(define (bridge-doc-string-prefix-at?
  [text : String]
  [prefix : String]
  [offset : i64]) : bool
  (doc_extract.doc-string-prefix-at? text prefix offset))

(define (bridge-doc-string-contains? [text : String] [needle : String]) : bool
  (doc_extract.doc-string-contains? text needle))

(define (bridge-doc-render-anchor [text : String]) : String
  (doc_render.doc-render-anchor text))

(define (bridge-doc-html-escape [text : String]) : String
  (doc_html.doc-html-escape text))

(define (bridge-doc-html-page-open [title : String]) : String
  (doc_html.doc-html-page-open title))

(define (bridge-doc-html-header [title : String] [subtitle : String]) : String
  (doc_html.doc-html-header title subtitle))

(define (bridge-doc-html-page-close) : String
  (doc_html.doc-html-page-close))

(define (bridge-doc-html-code-block-with-info
  [language : String]
  [meta : String]
  [source : String]) : String
  (doc_html.doc-html-code-block-with-info language meta source))

(define (bridge-doc-html-require-contains
  [rendered : String]
  [needle : String]
  [message : String]) : bool
  (doc_html.doc-html-require-contains rendered needle message))

(define (bridge-doc-html-module-section-source
  [path : String]
  [source : String]) : String
  (doc_html.doc-html-module-section
    (doc_render.DocModule.Module path (doc_extract.doc-extract-source source))))