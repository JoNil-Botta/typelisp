;; doc_html.tl - Deterministic HTML renderer for extracted docs (#870).
;;
;; The renderer stays in TypeLisp and consumes the same extracted documentation
;; model as the Markdown renderer. Anchors intentionally reuse `doc-render-anchor`
;; so standalone item links remain compatible with existing Markdown anchors.
(import "../stdlib/io.tl")

(import "doc_render.tl")

(import "../stdlib/string.tl")

(import "../stdlib/str_cat.tl")

(define (doc-html-escape-one [text : String] [idx : i64]) : String
  (let
    [c : char (string-ref text idx)]
    (cond
      (= c #&')
      "&amp;"
      (= c #<')
      "&lt;"
      (= c #>')
      "&gt;"
      (= c #"')
      "&quot;"
      (substring text idx 1))))

(define (doc-html-escape [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set! out (string-append out (doc-html-escape-one text i)))
          (set! i (+ i 1))))
      out)))

(define (doc-html-escape-text-one [text : String] [idx : i64]) : String
  (let
    [c : char (string-ref text idx)]
    (if (= c #\newline')
      "<br>\n"
      (if (= c #\return')
        ""
        (doc-html-escape-one text idx)))))

(define (doc-html-escape-text [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set! out (string-append out (doc-html-escape-text-one text i)))
          (set! i (+ i 1))))
      out)))

(define (doc-html-page-open [title : String]) : String
  (str-cat
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>"
    (doc-html-escape title)
    "</title>\n<link rel=\"stylesheet\" href=\"typelisp-docs.css\">\n</head>\n<body class=\"tl-docs\">\n"
    ""
    ""))

(define (doc-html-page-close) : String
  "</body>\n</html>\n")

(define (doc-html-header [title : String] [subtitle : String]) : String
  (str-cat
    "<header class=\"tl-doc-header\">\n<h1>"
    (doc-html-escape title)
    "</h1>\n<p><code>"
    (doc-html-escape subtitle)
    "</code></p>\n</header>\n"))

(define (doc-html-doc-block
  [class-name : String]
  [doc-text : String]
  [empty-text : String]) : String
  (if (= (string-length doc-text) 0)
    (str-cat "<p class=\"tl-doc-empty\">" (doc-html-escape empty-text) "</p>\n")
    (str-cat
      "<div class=\""
      class-name
      "\"><p>"
      (doc-html-escape-text doc-text)
      "</p></div>\n")))

(define (doc-html-code-block-meta-attr [meta : String]) : String
  (if (= (string-length meta) 0)
    ""
    (str-cat " data-meta=\"" (doc-html-escape meta) "\"")))

(define (doc-html-code-block-with-info
  [language : String]
  [meta : String]
  [source : String]) : String
  (str-cat
    (str-cat
      "<pre><code class=\"language-"
      (doc-html-escape language)
      "\""
      (doc-html-code-block-meta-attr meta)
      ">")
    (doc-html-escape source)
    "</code></pre>\n"))

(define (doc-html-code-block [source : String]) : String
  (doc-html-code-block-with-info "typelisp" "" source))

(define (doc-html-item-nav-entry [item : DocItem]) : String
  (let
    [name : String (doc-item-name item)]
    [anchor : String (doc-render-anchor (doc-item-name item))]
    (str-cat
      "<li><a href=\"#"
      anchor
      "\"><code>"
      (doc-html-escape name)
      "</code></a></li>\n")))

(define (doc-html-item-nav-entries [items : DocItemList]) : String
  (match items
    [(DocItemNil) ""]
    [(DocItemCons item rest)
      (string-append
        (doc-html-item-nav-entry item)
        (doc-html-item-nav-entries (box-get rest)))]))

(define (doc-html-item-nav [items : DocItemList]) : String
  (match items
    [(DocItemNil) ""]
    [_
      (str-cat
        "<nav class=\"tl-doc-item-nav\" aria-label=\"Declarations\">\n<h3>Declarations</h3>\n<ul>\n"
        (doc-html-item-nav-entries items)
        "</ul>\n</nav>\n")]))

(define (doc-html-item [item : DocItem]) : String
  (let
    [name : String (doc-item-name item)]
    [anchor : String (doc-render-anchor (doc-item-name item))]
    [kind : String (doc-kind-name (doc-item-kind item))]
    (str-cat
      "<a id=\""
      anchor
      "\"></a>\n<section class=\"tl-doc-item\">\n<h3><a href=\"#"
      anchor
      (str-cat
        "\">"
        (doc-html-escape name)
        "</a></h3>\n<dl class=\"tl-doc-meta\"><dt>Kind</dt><dd>"
        (doc-html-escape kind)
        (str-cat
          "</dd></dl>\n"
          (doc-html-code-block (doc-item-signature item))
          (doc-html-doc-block
            "tl-doc-item-text"
            (doc-item-doc item)
            "No item docs.")
          "</section>\n"
          "")))))

(define (doc-html-item-list [items : DocItemList]) : String
  (match items
    [(DocItemNil) ""]
    [(DocItemCons item rest)
      (string-append (doc-html-item item) (doc-html-item-list (box-get rest)))]))

(define (doc-html-items [items : DocItemList]) : String
  (match items
    [(DocItemNil) "<p class=\"tl-doc-empty\">No documented declarations.</p>\n"]
    [_ (doc-html-item-list items)]))

(define (doc-html-module-nav-entry [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    [anchor : String (doc-render-anchor (doc-module-path module))]
    (str-cat
      "<li><a href=\"#"
      anchor
      "\">"
      (doc-html-escape path)
      "</a></li>\n")))

(define (doc-html-module-nav-entries [modules : DocModuleList]) : String
  (match modules
    [(DocModuleNil) ""]
    [(DocModuleCons module rest)
      (string-append
        (doc-html-module-nav-entry module)
        (doc-html-module-nav-entries (box-get rest)))]))

(define (doc-html-module-nav [modules : DocModuleList]) : String
  (match modules
    [(DocModuleNil) "<p class=\"tl-doc-empty\">No modules.</p>\n"]
    [_
      (str-cat
        "<nav class=\"tl-doc-module-nav\" aria-label=\"Modules\">\n<h2>Modules</h2>\n<ul>\n"
        (doc-html-module-nav-entries modules)
        "</ul>\n</nav>\n")]))

(define (doc-html-module-section [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    [docs : DocExtraction (doc-module-docs module)]
    [anchor : String (doc-render-anchor (doc-module-path module))]
    (str-cat
      "<section class=\"tl-doc-module\" id=\""
      anchor
      "\">\n<h2><a href=\"#"
      anchor
      (str-cat
        "\">"
        (doc-html-escape path)
        "</a></h2>\n<p class=\"tl-doc-source\"><code>"
        (doc-html-escape path)
        (str-cat
          "</code></p>\n"
          (doc-html-doc-block
            "tl-doc-module-text"
            (doc-extraction-module-doc docs)
            "No module docs.")
          (doc-html-item-nav (doc-extraction-items docs))
          (doc-html-items (doc-extraction-items docs))
          "</section>\n")))))

(define (doc-html-module-sections [modules : DocModuleList]) : String
  (match modules
    [(DocModuleNil) ""]
    [(DocModuleCons module rest)
      (string-append
        (doc-html-module-section module)
        (doc-html-module-sections (box-get rest)))]))

(define (doc-html-render-module-page [path : String] [docs : DocExtraction]) : String
  (let
    [title : String (str-cat "TypeLisp API: " path "")]
    (str-cat
      (doc-html-page-open title)
      (doc-html-header "TypeLisp API" path)
      "<main>\n"
      (doc-html-module-section (DocModule path docs))
      (str-cat "</main>\n" (doc-html-page-close) ""))))

(define (doc-html-render-source [path : String] [source : String]) : String
  (doc-html-render-module-page path (doc-extract-source source)))

(define (doc-html-render-module-graph [modules : DocModuleList]) : String
  (str-cat
    (doc-html-page-open "TypeLisp API")
    (doc-html-header "TypeLisp API" "module index")
    (doc-html-module-nav modules)
    "<main>\n"
    (str-cat
      (doc-html-module-sections modules)
      "</main>\n"
      (doc-html-page-close))))

(define (doc-html-smoke-source) : String
  ";# Module docs with `code`, [links], <tag>, & amp.
;# Quote docs say \"hello\".

;; ignored ordinary comment
;: Global docs for answer mention <answer>, & value, and \"quote\".
(define answer : i64 42)

;: Function docs with `tick` and [arg].
(define (add-one [x : i64]) : i64 (+ x 1))")

(define (doc-html-second-smoke-source) : String
  ";# Second module docs.

(define hidden : i64 1)")

(define (doc-html-require-contains
  [rendered : String]
  [needle : String]
  [message : String]) : bool
  (if (doc-string-contains? rendered needle)
    true
    (begin
      (panic message)
      false)))

(define (doc-html-smoke) : i64
  (let
    [docs : DocExtraction (doc-extract-source (doc-html-smoke-source))]
    [second-docs : DocExtraction
      (doc-extract-source (doc-html-second-smoke-source))]
    [page : String (doc-html-render-module-page "smoke<&>.tl" docs)]
    [graph : String
      (doc-html-render-module-graph
        (DocModuleCons
          (DocModule "smoke<&>.tl" docs)
          (box
            (DocModuleCons
              (DocModule "second.tl" second-docs)
              (box DocModuleNil)))))]
    (if (and
      (doc-html-require-contains
        page
        "<!doctype html>"
        "doc-html: doctype missing")
      (doc-html-require-contains
        page
        "<title>TypeLisp API: smoke&lt;&amp;&gt;.tl</title>"
        "doc-html: title escaping missing")
      (doc-html-require-contains
        page
        "id=\"tl-smoke-60-38-62-46tl\""
        "doc-html: module anchor missing")
      (doc-html-require-contains
        page
        "Module docs with `code`, [links], &lt;tag&gt;, &amp; amp.<br>"
        "doc-html: module doc escaping missing")
      (doc-html-require-contains
        page
        "Quote docs say &quot;hello&quot;."
        "doc-html: quote escaping missing")
      (doc-html-require-contains
        page
        "id=\"tl-answer\""
        "doc-html: item anchor missing")
      (doc-html-require-contains
        page
        "<code class=\"language-typelisp\">(define answer : i64 42)</code>"
        "doc-html: signature code block missing")
      (doc-html-require-contains
        page
        "Global docs for answer mention &lt;answer&gt;, &amp; value, and &quot;quote&quot;."
        "doc-html: item doc escaping missing")
      (doc-html-require-contains
        page
        "href=\"#tl-add-one\""
        "doc-html: item nav link missing")
      (doc-html-require-contains
        graph
        "<nav class=\"tl-doc-module-nav\" aria-label=\"Modules\">"
        "doc-html: module nav missing")
      (doc-html-require-contains
        graph
        "href=\"#tl-second-46tl\""
        "doc-html: second module nav link missing")
      (doc-html-require-contains
        graph
        "Second module docs."
        "doc-html: second module docs missing")
      (doc-html-require-contains
        graph
        "No documented declarations."
        "doc-html: empty item message missing"))
      42
      0)))