;; Keep the doc-site tools on dotted imports while the compiler CLI finishes
;; migrating the remaining doc command dependencies.
(import doc_extract)
(import doc_render)
(import doc_html)

(define (bridge-doc-string-prefix-at?
  [text : (& text str)]
  [prefix : (& prefix str)]
  [offset : i64]) : bool
  (doc_extract.doc-string-prefix-at? text prefix offset))

(define (bridge-doc-string-contains?
  [text : (& text str)]
  [needle : (& needle str)]) : bool
  (doc_extract.doc-string-contains? text needle))

(define (bridge-doc-render-anchor [text : (& text str)]) : String
  (doc_render.doc-render-anchor text))

(define (bridge-doc-html-escape [text : (& text str)]) : String
  (doc_html.doc-html-escape text))

(define (bridge-doc-html-page-open [title : String]) : String
  (doc_html.doc-html-page-open title))

(define (bridge-doc-html-page-open-with-metadata
  [title : String]
  [compiler-identity : String]
  [source-identity : String]
  [package-identity : String]) : String
  (doc_html.doc-html-page-open-with-metadata
    title
    compiler-identity
    source-identity
    package-identity))

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
  [rendered : (& rendered str)]
  [needle : String]
  [message : String]) : bool
  (doc_html.doc-html-require-contains rendered needle message))

(define (bridge-doc-html-module-section-source
  [path : String]
  [source : String]) : String
  (doc_html.doc-html-module-section
    (doc_render.DocModule.Module path (doc_extract.doc-extract-source source))))

(define (bridge-doc-html-module-section-source-url
  [path : String]
  [source : String]
  [source-url : String]) : String
  (doc_html.doc-html-module-section-with-source-url
    (doc_render.DocModule.Module path (doc_extract.doc-extract-source source))
    source-url))

(define (bridge-doc-html-search-records-for-module
  [page : String]
  [path : String]
  [source : String]) : String
  (doc_html.doc-html-search-records-for-module
    page
    (doc_render.DocModule.Module path (doc_extract.doc-extract-source source))))

(define (bridge-doc-html-json-string [text : (& text str)]) : String
  (doc_html.doc-html-json-string text))

(define (bridge-doc-html-search-record
  [identity : String]
  [kind : String]
  [label : String]
  [module-path : String]
  [href : String]
  [signature : String]
  [doc-text : String]
  [source-line : i64]) : String
  (doc_html.doc-html-search-record
    identity
    kind
    label
    module-path
    href
    signature
    doc-text
    source-line))