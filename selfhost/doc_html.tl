;; doc_html.tl - Deterministic HTML renderer for extracted docs (#870).
;;
;; The renderer stays in TypeLisp and consumes the same extracted documentation
;; model as the Markdown renderer. Anchors intentionally reuse `doc-render-anchor`
;; so standalone item links remain compatible with existing Markdown anchors.
(import "doc_render.tl")

(define (doc-html-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (doc-html-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string-append a (string-append b (string-append c d))))

(define (doc-html-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string-append a (string-append b (string-append c (string-append d e)))))

(define (doc-html-escape-one [text : String] [idx : i64]) : String
  (let
    [c : char (string-ref text idx)]
    (if (= c #&')
      "&amp;"
      (if (= c #<')
        "&lt;"
        (if (= c #>')
          "&gt;"
          (if (= c #"')
            "&quot;"
            (substring text idx 1)))))))

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
  (doc-html-cat5
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>"
    (doc-html-escape title)
    "</title>\n<link rel=\"stylesheet\" href=\"typelisp-docs.css\">\n</head>\n<body class=\"tl-docs\">\n"
    ""
    ""))

(define (doc-html-page-close) : String
  "</body>\n</html>\n")

(define (doc-html-header [title : String] [subtitle : String]) : String
  (doc-html-cat5
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
    (doc-html-cat3
      "<p class=\"tl-doc-empty\">"
      (doc-html-escape empty-text)
      "</p>\n")
    (doc-html-cat5
      "<div class=\""
      class-name
      "\"><p>"
      (doc-html-escape-text doc-text)
      "</p></div>\n")))

(define (doc-html-code-block [source : String]) : String
  (doc-html-cat3
    "<pre><code class=\"language-typelisp\">"
    (doc-html-escape source)
    "</code></pre>\n"))

(define (doc-html-item-nav-entry [item : DocItem]) : String
  (let
    [name : String (doc-item-name item)]
    [anchor : String (doc-render-anchor (doc-item-name item))]
    (doc-html-cat5
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
        (doc-html-item-nav-entries rest))]))

(define (doc-html-item-nav [items : DocItemList]) : String
  (match items
    [(DocItemNil) ""]
    [_
      (doc-html-cat3
        "<nav class=\"tl-doc-item-nav\" aria-label=\"Declarations\">\n<h3>Declarations</h3>\n<ul>\n"
        (doc-html-item-nav-entries items)
        "</ul>\n</nav>\n")]))

(define (doc-html-item [item : DocItem]) : String
  (let
    [name : String (doc-item-name item)]
    [anchor : String (doc-render-anchor (doc-item-name item))]
    [kind : String (doc-kind-name (doc-item-kind item))]
    (doc-html-cat5
      "<a id=\""
      anchor
      "\"></a>\n<section class=\"tl-doc-item\">\n<h3><a href=\"#"
      anchor
      (doc-html-cat5
        "\">"
        (doc-html-escape name)
        "</a></h3>\n<dl class=\"tl-doc-meta\"><dt>Kind</dt><dd>"
        (doc-html-escape kind)
        (doc-html-cat5
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
      (string-append (doc-html-item item) (doc-html-item-list rest))]))

(define (doc-html-items [items : DocItemList]) : String
  (match items
    [(DocItemNil) "<p class=\"tl-doc-empty\">No documented declarations.</p>\n"]
    [_ (doc-html-item-list items)]))

(define (doc-html-module-nav-entry [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    [anchor : String (doc-render-anchor (doc-module-path module))]
    (doc-html-cat5
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
        (doc-html-module-nav-entries rest))]))

(define (doc-html-module-nav [modules : DocModuleList]) : String
  (match modules
    [(DocModuleNil) "<p class=\"tl-doc-empty\">No modules.</p>\n"]
    [_
      (doc-html-cat3
        "<nav class=\"tl-doc-module-nav\" aria-label=\"Modules\">\n<h2>Modules</h2>\n<ul>\n"
        (doc-html-module-nav-entries modules)
        "</ul>\n</nav>\n")]))

(define (doc-html-module-section [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    [docs : DocExtraction (doc-module-docs module)]
    [anchor : String (doc-render-anchor (doc-module-path module))]
    (doc-html-cat5
      "<section class=\"tl-doc-module\" id=\""
      anchor
      "\">\n<h2><a href=\"#"
      anchor
      (doc-html-cat5
        "\">"
        (doc-html-escape path)
        "</a></h2>\n<p class=\"tl-doc-source\"><code>"
        (doc-html-escape path)
        (doc-html-cat5
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
        (doc-html-module-sections rest))]))

(define (doc-html-render-module-page [path : String] [docs : DocExtraction]) : String
  (let
    [title : String (doc-html-cat3 "TypeLisp API: " path "")]
    (doc-html-cat5
      (doc-html-page-open title)
      (doc-html-header "TypeLisp API" path)
      "<main>\n"
      (doc-html-module-section (DocModule path docs))
      (doc-html-cat3 "</main>\n" (doc-html-page-close) ""))))

(define (doc-html-render-source [path : String] [source : String]) : String
  (doc-html-render-module-page path (doc-extract-source source)))

(define (doc-html-render-module-graph [modules : DocModuleList]) : String
  (doc-html-cat5
    (doc-html-page-open "TypeLisp API")
    (doc-html-header "TypeLisp API" "module index")
    (doc-html-module-nav modules)
    "<main>\n"
    (doc-html-cat3
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
    (let
      [page : String (doc-html-render-module-page "smoke<&>.tl" docs)]
      [graph : String
        (doc-html-render-module-graph
          (DocModuleCons
            (DocModule "smoke<&>.tl" docs)
            (DocModuleCons (DocModule "second.tl" second-docs) DocModuleNil)))]
      (if (and
        (doc-html-require-contains
          page
          "<!doctype html>"
          "doc-html: doctype missing")
        (and
          (doc-html-require-contains
            page
            "<title>TypeLisp API: smoke&lt;&amp;&gt;.tl</title>"
            "doc-html: title escaping missing")
          (and
            (doc-html-require-contains
              page
              "id=\"tl-smoke-60-38-62-46tl\""
              "doc-html: module anchor missing")
            (and
              (doc-html-require-contains
                page
                "Module docs with `code`, [links], &lt;tag&gt;, &amp; amp.<br>"
                "doc-html: module doc escaping missing")
              (and
                (doc-html-require-contains
                  page
                  "Quote docs say &quot;hello&quot;."
                  "doc-html: quote escaping missing")
                (and
                  (doc-html-require-contains
                    page
                    "id=\"tl-answer\""
                    "doc-html: item anchor missing")
                  (and
                    (doc-html-require-contains
                      page
                      "<code class=\"language-typelisp\">(define answer : i64 42)</code>"
                      "doc-html: signature code block missing")
                    (and
                      (doc-html-require-contains
                        page
                        "Global docs for answer mention &lt;answer&gt;, &amp; value, and &quot;quote&quot;."
                        "doc-html: item doc escaping missing")
                      (and
                        (doc-html-require-contains
                          page
                          "href=\"#tl-add-one\""
                          "doc-html: item nav link missing")
                        (and
                          (doc-html-require-contains
                            graph
                            "<nav class=\"tl-doc-module-nav\" aria-label=\"Modules\">"
                            "doc-html: module nav missing")
                          (and
                            (doc-html-require-contains
                              graph
                              "href=\"#tl-second-46tl\""
                              "doc-html: second module nav link missing")
                            (and
                              (doc-html-require-contains
                                graph
                                "Second module docs."
                                "doc-html: second module docs missing")
                              (doc-html-require-contains
                                graph
                                "No documented declarations."
                                "doc-html: empty item message missing")))))))))))))
        42
        0))))