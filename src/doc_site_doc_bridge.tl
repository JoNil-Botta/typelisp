(module doc_site_doc_bridge)

;; Keep the doc-site tools on dotted imports while the shared doc renderer stack
;; still uses legacy path imports in the compiler CLI.
(import "doc_extract.tl")
(import "doc_render.tl")
(import "doc_html.tl")

(define (bridge-doc-string-prefix-at?
  [text : String]
  [prefix : String]
  [offset : i64]) : bool
  (doc-string-prefix-at? text prefix offset))

(define (bridge-doc-string-contains? [text : String] [needle : String]) : bool
  (doc-string-contains? text needle))

(define (bridge-doc-render-anchor [text : String]) : String
  (doc-render-anchor text))

(define (bridge-doc-html-escape [text : String]) : String
  (doc-html-escape text))

(define (bridge-doc-html-page-open [title : String]) : String
  (doc-html-page-open title))

(define (bridge-doc-html-header [title : String] [subtitle : String]) : String
  (doc-html-header title subtitle))

(define (bridge-doc-html-page-close) : String
  (doc-html-page-close))

(define (bridge-doc-html-code-block-with-info
  [language : String]
  [meta : String]
  [source : String]) : String
  (doc-html-code-block-with-info language meta source))

(define (bridge-doc-html-require-contains
  [rendered : String]
  [needle : String]
  [message : String]) : bool
  (doc-html-require-contains rendered needle message))

(define (bridge-doc-html-module-section-source
  [path : String]
  [source : String]) : String
  (doc-html-module-section (DocModule.Module path (doc-extract-source source))))