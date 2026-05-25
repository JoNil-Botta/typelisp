;; doc_site_core.tl - Static stdlib/API HTML site builder core (#964).
;;
;; The site builder owns only the directory/page layout. It reuses the selfhost
;; documentation extractor and HTML renderer for module contents.
(import "doc_html.tl")

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
  11)

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
                          "stdlib/windows_sdk.tl"
                          "stdlib-windows-sdk.html")
                        DocSiteModuleNil))))))))))))

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
    (or (string-eq output "stdlib.html") (string-eq output "typelisp-docs.css"))))

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
.tl-doc-item-nav {
  background: #ffffff;
  border: 1px solid #d9e2ec;
  border-radius: 6px;
  padding: 1rem;
}
.tl-doc-site-nav ul,
.tl-doc-module-nav ul,
.tl-doc-item-nav ul {
  margin: 0;
  padding-left: 1.25rem;
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

(define (doc-site-render-index [modules : DocSiteModuleList]) : String
  (doc-html-cat5
    (doc-html-page-open "TypeLisp API")
    (doc-html-header "TypeLisp API" "stdlib static site")
    "<main>\n<nav class=\"tl-doc-site-nav\" aria-label=\"Stdlib modules\">\n<h2>Stdlib modules</h2>\n<ul>\n"
    (doc-site-index-entries modules)
    "</ul>\n</nav>\n</main>\n</body>\n</html>\n"))

(define (doc-site-read-module-docs [source : String]) : DocExtraction
  (let
    [status : i64 (read-file-status source)]
    (if (= status doc-site-status-ok)
      (doc-extract-source (read-file source))
      (begin
        (panic (string-append "doc-site: missing input module: " source))
        (doc-site-empty-docs)))))

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
  [module : DocSiteModule]) : unit
  (let
    [source : String (doc-site-module-source module)]
    [output : String
      (doc-site-path-join output-dir (doc-site-module-output module))]
    [docs : DocExtraction (doc-site-read-module-docs source)]
    (doc-site-write-file output (doc-html-render-module-page source docs))))

(define (doc-site-write-module-pages
  [output-dir : String]
  [modules : DocSiteModuleList]) : unit
  (match modules
    [(DocSiteModuleNil) unit]
    [(DocSiteModuleCons module rest)
      (begin
        (doc-site-write-module-page output-dir module)
        (doc-site-write-module-pages output-dir rest))]))

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
        (doc-site-render-index modules))
      (doc-site-write-file
        (doc-site-path-join output-dir "stdlib.html")
        (doc-site-render-index modules))
      (doc-site-write-module-pages output-dir modules)
      0)))

(define (doc-site-smoke-source) : String
  ";# Smoke module docs mention <api>, & value, and \"quote\".

;: Smoke value docs include <value> and &.
(define doc-site-smoke-value : i64 42)")

(define (doc-site-second-smoke-source) : String
  ";# Second smoke module docs.

(define doc-site-second-hidden : i64 1)")

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
    [index : String (doc-site-render-index modules)]
    [page : String
      (doc-html-render-module-page
        "stdlib/smoke<&>.tl"
        (doc-extract-source (doc-site-smoke-source)))]
    [second-page : String
      (doc-html-render-module-page
        "stdlib/second.tl"
        (doc-extract-source (doc-site-second-smoke-source)))]
    (begin
      (doc-html-require-contains
        index
        "<nav class=\"tl-doc-site-nav\" aria-label=\"Stdlib modules\">"
        "doc-site: site nav missing")
      (doc-html-require-contains
        index
        "href=\"stdlib-smoke.html\""
        "doc-site: module link missing")
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