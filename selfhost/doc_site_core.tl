;; doc_site_core.tl - Static stdlib/API HTML site builder core (#964).
;;
;; The site builder owns only the directory/page layout. It reuses the selfhost
;; documentation extractor and HTML renderer for module contents.
(import "doc_html.tl")

(import "doc_md.tl")

(defenum DocSiteModule
  (DocSiteModule String String))

(defenum DocSiteModuleList
  (DocSiteModuleNil)
  (DocSiteModuleCons DocSiteModule DocSiteModuleList))

(define doc-site-status-ok : i64
  0)

(define doc-site-status-already-exists : i64
  17)

(define doc-site-stdlib-manifest-size : i64
  12)

(define doc-site-repo-blob-root : String
  "https://github.com/JoNil-Botta/typelisp/blob/main/")

(define doc-site-repo-tree-root : String
  "https://github.com/JoNil-Botta/typelisp/tree/main/")

(define (doc-site-module-source [module : DocSiteModule]) : String
  (match module
    [(DocSiteModule source _) source]))

(define (doc-site-module-output [module : DocSiteModule]) : String
  (match module
    [(DocSiteModule _ output) output]))

(define (doc-site-stdlib-modules) : DocSiteModuleList
  (DocSiteModuleCons
    (DocSiteModule "stdlib/env.tl" "stdlib-env.html")
    (DocSiteModuleCons
      (DocSiteModule "stdlib/fs.tl" "stdlib-fs.html")
      (DocSiteModuleCons
        (DocSiteModule "stdlib/hash.tl" "stdlib-hash.html")
        (DocSiteModuleCons
          (DocSiteModule "stdlib/io.tl" "stdlib-io.html")
          (DocSiteModuleCons
            (DocSiteModule "stdlib/json.tl" "stdlib-json.html")
            (DocSiteModuleCons
              (DocSiteModule "stdlib/process.tl" "stdlib-process.html")
              (DocSiteModuleCons
                (DocSiteModule "stdlib/random.tl" "stdlib-random.html")
                (DocSiteModuleCons
                  (DocSiteModule "stdlib/string.tl" "stdlib-string.html")
                  (DocSiteModuleCons
                    (DocSiteModule "stdlib/test.tl" "stdlib-test.html")
                    (DocSiteModuleCons
                      (DocSiteModule
                        "stdlib/text_buf.tl"
                        "stdlib-text-buf.html")
                      (DocSiteModuleCons
                        (DocSiteModule
                          "stdlib/windows_registry.tl"
                          "stdlib-windows-registry.html")
                        (DocSiteModuleCons
                          (DocSiteModule
                            "stdlib/windows_sdk.tl"
                            "stdlib-windows-sdk.html")
                          DocSiteModuleNil)))))))))))))

(define (doc-site-module-list-count [modules : DocSiteModuleList]) : i64
  (match modules
    [(DocSiteModuleNil) 0]
    [(DocSiteModuleCons _ rest) (+ 1 (doc-site-module-list-count rest))]))

(define (doc-site-output-in-list?
  [output : String]
  [modules : DocSiteModuleList]) : bool
  (match modules
    [(DocSiteModuleNil) false]
    [(DocSiteModuleCons module rest)
      (or
        (string-eq output (doc-site-module-output module))
        (doc-site-output-in-list? output rest))]))

(define (doc-site-output-reserved? [output : String]) : bool
  (or
    (string-eq output "index.html")
    (or
      (string-eq output "readme.html")
      (or
        (string-eq output "spec.html")
        (or
          (string-eq output "stdlib.html")
          (string-eq output "typelisp-docs.css"))))))

(define (doc-site-output-list-has-duplicate? [modules : DocSiteModuleList]) : bool
  (match modules
    [(DocSiteModuleNil) false]
    [(DocSiteModuleCons module rest)
      (or
        (doc-site-output-reserved? (doc-site-module-output module))
        (or
          (doc-site-output-in-list? (doc-site-module-output module) rest)
          (doc-site-output-list-has-duplicate? rest)))]))

(define (doc-site-expected-manifest-size? [modules : DocSiteModuleList]) : bool
  (= (doc-site-module-list-count modules) doc-site-stdlib-manifest-size))

(define (doc-site-panic-unit [message : String]) : unit
  (begin
    (panic message)
    unit))

(define (doc-site-empty-docs) : DocExtraction
  (DocExtraction "" DocItemNil))

(define (doc-site-validate-stdlib-manifest [modules : DocSiteModuleList]) : unit
  (if (not (doc-site-expected-manifest-size? modules))
    (doc-site-panic-unit "doc-site: missing stdlib manifest entry")
    (if (doc-site-output-list-has-duplicate? modules)
      (doc-site-panic-unit "doc-site: duplicate output path in stdlib manifest")
      unit)))

(define (doc-site-path-separator? [c : char]) : bool
  (or (= c #/') (= c #\\')))

(define (doc-site-path-ends-separator? [path : String]) : bool
  (let
    [n : i64 (string-length path)]
    (and (> n 0) (doc-site-path-separator? (string-ref path (- n 1))))))

(define (doc-site-path-join [dir : String] [leaf : String]) : String
  (if (= (string-length dir) 0)
    leaf
    (if (doc-site-path-ends-separator? dir)
      (string-append dir leaf)
      (string-append (string-append dir "/") leaf))))

(define (doc-site-string-prefix? [text : String] [prefix : String]) : bool
  (doc-string-prefix-at? text prefix 0))

(define (doc-site-href-anchor? [target : String]) : bool
  (and (> (string-length target) 0) (= (string-ref target 0) ##')))

(define (doc-site-href-external? [target : String]) : bool
  (or
    (doc-string-contains? target "://")
    (doc-site-string-prefix? target "mailto:")))

(define (doc-site-href-file-like? [target : String]) : bool
  (doc-string-contains? target "."))

(define (doc-site-repo-source-url [target : String]) : String
  (string-append
    (if (doc-site-href-file-like? target)
      doc-site-repo-blob-root
      doc-site-repo-tree-root)
    target))

(define (doc-site-rewrite-language-link-target [target : String]) : String
  (cond
    [(doc-site-href-anchor? target) target]
    [(doc-site-href-external? target) target]
    [(string-eq target "README.md") "readme.html"]
    [(string-eq target "SPEC.md") "spec.html"]
    [else (doc-site-repo-source-url target)]))

(define (doc-site-rewrite-language-links [html : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length html)]
    [out : String ""]
    (begin
      (while (< i n)
        (if (doc-string-prefix-at? html "href=\"" i)
          (let
            [target-start : i64 (+ i 6)]
            [target-end : i64 (md-find-char html target-start #"')]
            (if (< target-end n)
              (let
                [target : String
                  (substring html target-start (- target-end target-start))]
                (begin
                  (set!
                    out
                    (doc-html-cat5
                      out
                      "href=\""
                      (doc-site-rewrite-language-link-target target)
                      "\""
                      ""))
                  (set! i (+ target-end 1))))
              (begin
                (set! out (string-append out (substring html i 1)))
                (set! i (+ i 1)))))
          (begin
            (set! out (string-append out (substring html i 1)))
            (set! i (+ i 1)))))
      out)))

(define (doc-site-css) : String
  "body.tl-docs {
  margin: 0;
  color: #1f2933;
  background: #f6f8fb;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif;
  line-height: 1.55;
}
.tl-doc-header {
  background: #ffffff;
  border-bottom: 1px solid #d9e2ec;
  padding: 2rem clamp(1rem, 4vw, 3rem);
}
.tl-doc-header h1 {
  margin: 0 0 0.25rem;
  font-size: 2rem;
}
.tl-doc-header p {
  margin: 0;
  color: #52606d;
}
main {
  max-width: 72rem;
  margin: 0 auto;
  padding: 1.5rem clamp(1rem, 4vw, 3rem) 3rem;
}
.tl-doc-shell {
  display: grid;
  grid-template-columns: minmax(12rem, 16rem) minmax(0, 1fr);
  gap: 1.5rem;
  max-width: 92rem;
  margin: 0 auto;
  padding: 1.5rem clamp(1rem, 4vw, 3rem) 3rem;
}
.tl-doc-shell main {
  min-width: 0;
  max-width: none;
  margin: 0;
  padding: 0;
}
a {
  color: #075985;
}
code,
pre {
  font-family: ui-monospace, SFMono-Regular, Consolas, \"Liberation Mono\", monospace;
}
pre {
  overflow-x: auto;
  background: #111827;
  color: #f9fafb;
  padding: 1rem;
  border-radius: 6px;
}
.tl-doc-site-nav,
.tl-doc-module-nav,
.tl-doc-item-nav,
.tl-doc-stdlib-sidebar {
  background: #ffffff;
  border: 1px solid #d9e2ec;
  border-radius: 6px;
  padding: 1rem;
}
.tl-doc-site-nav ul,
.tl-doc-module-nav ul,
.tl-doc-item-nav ul,
.tl-doc-stdlib-sidebar ul {
  margin: 0;
  padding-left: 1.25rem;
}
.tl-doc-stdlib-sidebar {
  position: sticky;
  top: 1rem;
  align-self: start;
  max-height: calc(100vh - 2rem);
  overflow: auto;
}
.tl-doc-stdlib-tree {
  list-style: none;
  padding-left: 0 !important;
}
.tl-doc-stdlib-tree ul {
  margin-top: 0.5rem;
}
.tl-doc-stdlib-tree > li + li {
  margin-top: 0.75rem;
}
.tl-doc-tree-root,
.tl-doc-tree-link {
  display: block;
  border-radius: 4px;
  padding: 0.25rem 0.4rem;
  text-decoration: none;
}
.tl-doc-tree-root {
  font-weight: 700;
}
.tl-doc-tree-link.is-current,
.tl-doc-tree-root.is-current {
  background: #e0f2fe;
  color: #0c4a6e;
  font-weight: 700;
}
.tl-doc-module,
.tl-doc-item {
  margin-top: 1.5rem;
}
.tl-doc-module-text,
.tl-doc-item-text {
  background: #ffffff;
  border-left: 4px solid #0f766e;
  padding: 0.75rem 1rem;
}
.tl-doc-meta {
  display: grid;
  grid-template-columns: max-content 1fr;
  gap: 0.25rem 0.75rem;
}
.tl-doc-empty {
  color: #6b7280;
}
.tl-doc-language h1,
.tl-doc-language h2,
.tl-doc-language h3,
.tl-doc-language h4,
.tl-doc-language h5,
.tl-doc-language h6 {
  scroll-margin-top: 1rem;
}
.tl-doc-language table {
  border-collapse: collapse;
  width: 100%;
  background: #ffffff;
}
.tl-doc-language th,
.tl-doc-language td {
  border: 1px solid #d9e2ec;
  padding: 0.35rem 0.5rem;
  vertical-align: top;
}
.tl-doc-language blockquote {
  margin: 1rem 0;
  border-left: 4px solid #94a3b8;
  padding-left: 1rem;
  color: #334155;
}
@media (max-width: 760px) {
  .tl-doc-shell {
    display: block;
  }
  .tl-doc-stdlib-sidebar {
    position: static;
    max-height: 16rem;
    margin-bottom: 1rem;
  }
}")

(define (doc-site-index-entry [module : DocSiteModule]) : String
  (doc-html-cat5
    "<li><a href=\""
    (doc-html-escape (doc-site-module-output module))
    "\"><code>"
    (doc-html-escape (doc-site-module-source module))
    "</code></a></li>\n"))

(define (doc-site-index-entries [modules : DocSiteModuleList]) : String
  (match modules
    [(DocSiteModuleNil) ""]
    [(DocSiteModuleCons module rest)
      (string-append
        (doc-site-index-entry module)
        (doc-site-index-entries rest))]))

(define (doc-site-module-label [module : DocSiteModule]) : String
  (let
    [source : String (doc-site-module-source module)]
    (let
      [i : i64 0]
      [n : i64 (string-length source)]
      [start : i64 0]
      [end : i64 (string-length source)]
      (begin
        (while (< i n)
          (begin
            (if (doc-site-path-separator? (string-ref source i))
              (begin
                (set! start (+ i 1))
                (set! end n))
              unit)
            (if (= (string-ref source i) #.')
              (set! end i)
              unit)
            (set! i (+ i 1))))
        (substring source start (- end start))))))

(define (doc-site-sidebar-link-open [href : String] [current : String]) : String
  (if (string-eq href current)
    (doc-html-cat3
      "<a class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\""
      (doc-html-escape href)
      "\">")
    (doc-html-cat3
      "<a class=\"tl-doc-tree-link\" href=\""
      (doc-html-escape href)
      "\">")))

(define (doc-site-sidebar-root-link [current : String]) : String
  (if (string-eq current "stdlib.html")
    "<a class=\"tl-doc-tree-root is-current\" aria-current=\"page\" href=\"stdlib.html\">stdlib</a>\n"
    "<a class=\"tl-doc-tree-root\" href=\"stdlib.html\">stdlib</a>\n"))

(define (doc-site-sidebar-language-entry
  [href : String]
  [label : String]
  [current : String]) : String
  (doc-html-cat5
    "<li>"
    (doc-site-sidebar-link-open href current)
    (doc-html-escape label)
    "</a></li>\n"
    ""))

(define (doc-site-sidebar-entry [module : DocSiteModule] [current : String]) : String
  (doc-html-cat5
    "<li>"
    (doc-site-sidebar-link-open (doc-site-module-output module) current)
    "<code>"
    (doc-html-escape (doc-site-module-label module))
    "</code></a></li>\n"))

(define (doc-site-sidebar-entries
  [modules : DocSiteModuleList]
  [current : String]) : String
  (match modules
    [(DocSiteModuleNil) ""]
    [(DocSiteModuleCons module rest)
      (string-append
        (doc-site-sidebar-entry module current)
        (doc-site-sidebar-entries rest current))]))

(define (doc-site-stdlib-sidebar
  [modules : DocSiteModuleList]
  [current : String]) : String
  (doc-html-cat5
    "<nav class=\"tl-doc-stdlib-sidebar\" aria-label=\"Stdlib module tree\">\n<ul class=\"tl-doc-stdlib-tree\">\n<li>"
    "<span class=\"tl-doc-tree-root\">Language</span>\n<ul>\n"
    (doc-site-sidebar-language-entry "readme.html" "Overview" current)
    (doc-site-sidebar-language-entry "spec.html" "Specification" current)
    (doc-html-cat5
      "</ul>\n</li>\n<li>"
      (doc-site-sidebar-root-link current)
      "<ul>\n"
      (doc-site-sidebar-entries modules current)
      "</ul>\n</li>\n</ul>\n</nav>\n")))

(define (doc-site-render-page
  [title : String]
  [subtitle : String]
  [modules : DocSiteModuleList]
  [current : String]
  [body : String]) : String
  (doc-html-cat5
    (doc-html-page-open title)
    (doc-html-header "TypeLisp API" subtitle)
    "<div class=\"tl-doc-shell\">\n"
    (doc-site-stdlib-sidebar modules current)
    (doc-html-cat5
      "<main class=\"tl-doc-content\">\n"
      body
      "</main>\n</div>\n"
      (doc-html-page-close)
      "")))

(define (doc-site-render-index [modules : DocSiteModuleList] [current : String]) : String
  (doc-site-render-page
    "TypeLisp API"
    "language reference and stdlib API"
    modules
    current
    (string-append
      "<nav class=\"tl-doc-site-nav\" aria-label=\"Language reference\">\n<h2>Language reference</h2>\n<ul>\n<li><a href=\"readme.html\">Project overview</a></li>\n<li><a href=\"spec.html\">Language specification</a></li>\n</ul>\n</nav>\n"
      (doc-html-cat5
        "<nav class=\"tl-doc-site-nav\" aria-label=\"Stdlib modules\">\n<h2>Stdlib modules</h2>\n<ul>\n"
        (doc-site-index-entries modules)
        "</ul>\n</nav>\n"
        ""
        ""))))

(define (doc-site-render-language-page
  [modules : DocSiteModuleList]
  [source : String]
  [output : String]
  [title : String]
  [markdown : String]) : String
  (doc-site-render-page
    title
    source
    modules
    output
    (doc-html-cat3
      "<article class=\"tl-doc-language\">\n"
      (doc-site-rewrite-language-links (md-render-html markdown))
      "</article>\n")))

(define (doc-site-render-module-page
  [modules : DocSiteModuleList]
  [module : DocSiteModule]
  [docs : DocExtraction]) : String
  (let
    [source : String (doc-site-module-source module)]
    [title : String (doc-html-cat3 "TypeLisp API: " source "")]
    (doc-site-render-page
      title
      source
      modules
      (doc-site-module-output module)
      (doc-html-module-section (DocModule source docs)))))

(define (doc-site-read-module-docs [source : String]) : DocExtraction
  (let
    [status : i64 (read-file-status source)]
    (if (= status doc-site-status-ok)
      (doc-extract-source (read-file source))
      (begin
        (panic (string-append "doc-site: missing input module: " source))
        (doc-site-empty-docs)))))

(define (doc-site-read-markdown [source : String]) : String
  (let
    [status : i64 (read-file-status source)]
    (if (= status doc-site-status-ok)
      (read-file source)
      (begin
        (panic (string-append "doc-site: missing language reference: " source))
        ""))))

(define (doc-site-write-file [path : String] [contents : String]) : unit
  (let
    [status : i64 (write-file-status path contents)]
    (if (= status doc-site-status-ok)
      unit
      (doc-site-panic-unit (string-append "doc-site: could not write: " path)))))

(define (doc-site-ensure-dir [path : String]) : unit
  (if (= (string-length path) 0)
    (doc-site-panic-unit "doc-site: empty output directory")
    (let
      [status : i64 (fs-mkdir-status path)]
      (if (or
        (= status doc-site-status-ok)
        (= status doc-site-status-already-exists))
        unit
        (doc-site-panic-unit
          (string-append "doc-site: could not create output directory: " path))))))

(define (doc-site-write-module-page
  [output-dir : String]
  [modules : DocSiteModuleList]
  [module : DocSiteModule]) : unit
  (let
    [source : String (doc-site-module-source module)]
    [output : String
      (doc-site-path-join output-dir (doc-site-module-output module))]
    [docs : DocExtraction (doc-site-read-module-docs source)]
    (doc-site-write-file
      output
      (doc-site-render-module-page modules module docs))))

(define (doc-site-write-module-pages
  [output-dir : String]
  [modules : DocSiteModuleList]
  [remaining : DocSiteModuleList]) : unit
  (match remaining
    [(DocSiteModuleNil) unit]
    [(DocSiteModuleCons module rest)
      (begin
        (doc-site-write-module-page output-dir modules module)
        (doc-site-write-module-pages output-dir modules rest))]))

(define (doc-site-write-language-page
  [output-dir : String]
  [modules : DocSiteModuleList]
  [source : String]
  [output : String]
  [title : String]) : unit
  (doc-site-write-file
    (doc-site-path-join output-dir output)
    (doc-site-render-language-page
      modules
      source
      output
      title
      (doc-site-read-markdown source))))

(define (doc-site-build [output-dir : String]) : i64
  (let
    [modules : DocSiteModuleList (doc-site-stdlib-modules)]
    (begin
      (doc-site-validate-stdlib-manifest modules)
      (doc-site-ensure-dir output-dir)
      (doc-site-write-file
        (doc-site-path-join output-dir "typelisp-docs.css")
        (doc-site-css))
      (doc-site-write-file
        (doc-site-path-join output-dir "index.html")
        (doc-site-render-index modules "index.html"))
      (doc-site-write-file
        (doc-site-path-join output-dir "stdlib.html")
        (doc-site-render-index modules "stdlib.html"))
      (doc-site-write-language-page
        output-dir
        modules
        "README.md"
        "readme.html"
        "TypeLisp Overview")
      (doc-site-write-language-page
        output-dir
        modules
        "SPEC.md"
        "spec.html"
        "TypeLisp Language Reference")
      (doc-site-write-module-pages output-dir modules modules)
      0)))

(define (doc-site-smoke-source) : String
  ";# Smoke module docs mention <api>, & value, and \"quote\".

;: Smoke value docs include <value> and &.
(define doc-site-smoke-value : i64 42)")

(define (doc-site-second-smoke-source) : String
  ";# Second smoke module docs.

(define doc-site-second-hidden : i64 1)")

(define (doc-site-language-smoke-source) : String
  "# Language Reference

See [the spec](SPEC.md) and [the builder](selfhost/doc_site.tl).

```typelisp
(define answer : i64 42)
```")

(define (doc-site-smoke-modules) : DocSiteModuleList
  (DocSiteModuleCons
    (DocSiteModule "stdlib/smoke<&>.tl" "stdlib-smoke.html")
    (DocSiteModuleCons
      (DocSiteModule "stdlib/second.tl" "stdlib-second.html")
      DocSiteModuleNil)))

(define (doc-site-require [ok : bool] [message : String]) : bool
  (if ok
    true
    (begin
      (panic message)
      false)))

(define (doc-site-smoke) : i64
  (let
    [modules : DocSiteModuleList (doc-site-smoke-modules)]
    [index : String (doc-site-render-index modules "index.html")]
    [page : String
      (doc-site-render-module-page
        modules
        (DocSiteModule "stdlib/smoke<&>.tl" "stdlib-smoke.html")
        (doc-extract-source (doc-site-smoke-source)))]
    [second-page : String
      (doc-site-render-module-page
        modules
        (DocSiteModule "stdlib/second.tl" "stdlib-second.html")
        (doc-extract-source (doc-site-second-smoke-source)))]
    [language-page : String
      (doc-site-render-language-page
        modules
        "README.md"
        "readme.html"
        "TypeLisp Overview"
        (doc-site-language-smoke-source))]
    (begin
      (doc-html-require-contains
        index
        "<nav class=\"tl-doc-site-nav\" aria-label=\"Stdlib modules\">"
        "doc-site: site nav missing")
      (doc-html-require-contains
        index
        "<nav class=\"tl-doc-site-nav\" aria-label=\"Language reference\">"
        "doc-site: language nav missing")
      (doc-html-require-contains
        index
        "href=\"readme.html\""
        "doc-site: readme link missing")
      (doc-html-require-contains
        index
        "href=\"spec.html\""
        "doc-site: spec link missing")
      (doc-html-require-contains
        index
        "<nav class=\"tl-doc-stdlib-sidebar\" aria-label=\"Stdlib module tree\">"
        "doc-site: sidebar missing")
      (doc-html-require-contains
        index
        "href=\"stdlib.html\">stdlib</a>"
        "doc-site: sidebar root missing")
      (doc-html-require-contains
        index
        "href=\"stdlib-smoke.html\""
        "doc-site: module link missing")
      (doc-html-require-contains
        index
        "<code>second</code>"
        "doc-site: sidebar module label missing")
      (doc-html-require-contains
        index
        "stdlib/smoke&lt;&amp;&gt;.tl"
        "doc-site: index escaping missing")
      (doc-html-require-contains
        page
        "<title>TypeLisp API: stdlib/smoke&lt;&amp;&gt;.tl</title>"
        "doc-site: module title missing")
      (doc-html-require-contains
        page
        "class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"stdlib-smoke.html\""
        "doc-site: current sidebar link missing")
      (doc-html-require-contains
        page
        "<code>smoke&lt;&amp;&gt;</code>"
        "doc-site: sidebar current label escaping missing")
      (doc-html-require-contains
        page
        "id=\"tl-stdlib-47smoke-60-38-62-46tl\""
        "doc-site: module anchor missing")
      (doc-html-require-contains
        page
        "Smoke module docs mention &lt;api&gt;, &amp; value, and &quot;quote&quot;."
        "doc-site: module docs escaping missing")
      (doc-html-require-contains
        page
        "href=\"#tl-doc-site-smoke-value\""
        "doc-site: item anchor link missing")
      (doc-html-require-contains
        second-page
        "Second smoke module docs."
        "doc-site: second page missing")
      (doc-html-require-contains
        second-page
        "class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"stdlib-second.html\""
        "doc-site: second current sidebar link missing")
      (doc-html-require-contains
        language-page
        "<title>TypeLisp Overview</title>"
        "doc-site: language page title missing")
      (doc-html-require-contains
        language-page
        "class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"readme.html\""
        "doc-site: language current sidebar link missing")
      (doc-html-require-contains
        language-page
        "<h1 id=\"tl-Language-32Reference\">Language Reference</h1>"
        "doc-site: language heading anchor missing")
      (doc-html-require-contains
        language-page
        "href=\"spec.html\""
        "doc-site: language spec link rewrite missing")
      (doc-html-require-contains
        language-page
        "href=\"https://github.com/JoNil-Botta/typelisp/blob/main/selfhost/doc_site.tl\""
        "doc-site: language repo link rewrite missing")
      (doc-html-require-contains
        language-page
        "<pre><code class=\"language-typelisp\">(define answer : i64 42)"
        "doc-site: language code fence missing")
      (doc-html-require-contains
        (doc-site-css)
        ".tl-doc-header"
        "doc-site: css marker missing")
      (doc-site-require
        (doc-site-output-list-has-duplicate?
          (DocSiteModuleCons
            (DocSiteModule "a.tl" "same.html")
            (DocSiteModuleCons
              (DocSiteModule "b.tl" "same.html")
              DocSiteModuleNil)))
        "doc-site: duplicate output detection missing")
      (doc-site-require
        (not (doc-site-expected-manifest-size? DocSiteModuleNil))
        "doc-site: missing manifest detection missing")
      42)))