;; doc_site_core.tl - Static documentation site builder core (#964, #1296).
;;
;; The TypeLisp site composition layer combines language guides and reusable API
;; trees. API pages still use the source/module documentation extractor and HTML
;; renderer without hard-coding TypeLisp guide-page knowledge into that path.
(import "../stdlib/io.tl")

(import "doc_html.tl")

(import "doc_md.tl")

(import "../stdlib/fs.tl")

(import "../stdlib/string.tl")

(defenum DocSiteModule
  (DocSiteModule String String))

(defenum DocSiteModuleList
  (DocSiteModuleNil)
  (DocSiteModuleCons DocSiteModule (Box DocSiteModuleList)))

(defenum DocSiteGuidePage
  (DocSiteGuidePage String String String String))

(defenum DocSiteGuidePageList
  (DocSiteGuidePageNil)
  (DocSiteGuidePageCons DocSiteGuidePage (Box DocSiteGuidePageList)))

(defenum DocSiteApiTree
  (DocSiteApiTree String String DocSiteModuleList))

(defenum DocSiteSection
  (DocSiteGuideSection String DocSiteGuidePageList)
  (DocSiteApiTreeSection DocSiteApiTree))

(defenum DocSiteSectionList
  (DocSiteSectionNil)
  (DocSiteSectionCons DocSiteSection (Box DocSiteSectionList)))

(define doc-site-status-ok : i64
  0)

(define doc-site-stdlib-manifest-size : i64
  19)

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

(define (doc-site-guide-title [guide : DocSiteGuidePage]) : String
  (match guide
    [(DocSiteGuidePage title _ _ _) title]))

(define (doc-site-guide-source [guide : DocSiteGuidePage]) : String
  (match guide
    [(DocSiteGuidePage _ source _ _) source]))

(define (doc-site-guide-output [guide : DocSiteGuidePage]) : String
  (match guide
    [(DocSiteGuidePage _ _ output _) output]))

(define (doc-site-guide-label [guide : DocSiteGuidePage]) : String
  (match guide
    [(DocSiteGuidePage _ _ _ label) label]))

(define (doc-site-api-tree-root [tree : DocSiteApiTree]) : String
  (match tree
    [(DocSiteApiTree root _ _) root]))

(define (doc-site-api-tree-output [tree : DocSiteApiTree]) : String
  (match tree
    [(DocSiteApiTree _ output _) output]))

(define (doc-site-api-tree-modules [tree : DocSiteApiTree]) : DocSiteModuleList
  (match tree
    [(DocSiteApiTree _ _ modules) modules]))

(define (doc-site-module-cons
  [module : DocSiteModule]
  [rest : DocSiteModuleList]) : DocSiteModuleList
  (DocSiteModuleCons module (box rest)))

(define (doc-site-guide-page-cons
  [guide : DocSiteGuidePage]
  [rest : DocSiteGuidePageList]) : DocSiteGuidePageList
  (DocSiteGuidePageCons guide (box rest)))

(define (doc-site-section-cons
  [section : DocSiteSection]
  [rest : DocSiteSectionList]) : DocSiteSectionList
  (DocSiteSectionCons section (box rest)))

(define (doc-site-stdlib-modules) : DocSiteModuleList
  (doc-site-module-cons
    (DocSiteModule "stdlib/arena.tl" "stdlib-arena.html")
    (doc-site-module-cons
      (DocSiteModule "stdlib/cpu.tl" "stdlib-cpu.html")
      (doc-site-module-cons
        (DocSiteModule "stdlib/env.tl" "stdlib-env.html")
        (doc-site-module-cons
          (DocSiteModule "stdlib/ffi.tl" "stdlib-ffi.html")
          (doc-site-module-cons
            (DocSiteModule "stdlib/fs.tl" "stdlib-fs.html")
            (doc-site-module-cons
              (DocSiteModule "stdlib/hash.tl" "stdlib-hash.html")
              (doc-site-module-cons
                (DocSiteModule "stdlib/hashmap.tl" "stdlib-hashmap.html")
                (doc-site-module-cons
                  (DocSiteModule "stdlib/io.tl" "stdlib-io.html")
                  (doc-site-module-cons
                    (DocSiteModule "stdlib/json.tl" "stdlib-json.html")
                    (doc-site-module-cons
                      (DocSiteModule "stdlib/list.tl" "stdlib-list.html")
                      (doc-site-module-cons
                        (DocSiteModule "stdlib/msvc.tl" "stdlib-msvc.html")
                        (doc-site-module-cons
                          (DocSiteModule
                            "stdlib/process.tl"
                            "stdlib-process.html")
                          (doc-site-module-cons
                            (DocSiteModule
                              "stdlib/queue.tl"
                              "stdlib-queue.html")
                            (doc-site-module-cons
                              (DocSiteModule
                                "stdlib/random.tl"
                                "stdlib-random.html")
                              (doc-site-module-cons
                                (DocSiteModule
                                  "stdlib/string.tl"
                                  "stdlib-string.html")
                                (doc-site-module-cons
                                  (DocSiteModule
                                    "stdlib/test.tl"
                                    "stdlib-test.html")
                                  (doc-site-module-cons
                                    (DocSiteModule
                                      "stdlib/text_buf.tl"
                                      "stdlib-text-buf.html")
                                    (doc-site-module-cons
                                      (DocSiteModule
                                        "stdlib/text_buf_borrowed.tl"
                                        "stdlib-text-buf-borrowed.html")
                                      (doc-site-module-cons
                                        (DocSiteModule
                                          "stdlib/vector.tl"
                                          "stdlib-vector.html")
                                        DocSiteModuleNil))))))))))))))))))))

(define (doc-site-language-guides) : DocSiteGuidePageList
  (doc-site-guide-page-cons
    (DocSiteGuidePage "TypeLisp Overview" "README.md" "readme.html" "Overview")
    (doc-site-guide-page-cons
      (DocSiteGuidePage
        "TypeLisp Language Reference"
        "SPEC.md"
        "spec.html"
        "Specification")
      DocSiteGuidePageNil)))

(define (doc-site-stdlib-api-tree) : DocSiteApiTree
  (DocSiteApiTree "stdlib" "stdlib.html" (doc-site-stdlib-modules)))

(define (doc-site-typelisp-sections) : DocSiteSectionList
  (doc-site-section-cons
    (DocSiteGuideSection "Language" (doc-site-language-guides))
    (doc-site-section-cons
      (DocSiteApiTreeSection (doc-site-stdlib-api-tree))
      DocSiteSectionNil)))

(define (doc-site-module-list-count [modules : DocSiteModuleList]) : i64
  (match modules
    [(DocSiteModuleNil) 0]
    [(DocSiteModuleCons _ rest)
      (+ 1 (doc-site-module-list-count (box-get rest)))]))

(define (doc-site-output-in-list?
  [output : String]
  [modules : DocSiteModuleList]) : bool
  (match modules
    [(DocSiteModuleNil) false]
    [(DocSiteModuleCons module rest)
      (or
        (string-eq output (doc-site-module-output module))
        (doc-site-output-in-list? output (box-get rest)))]))

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
          (doc-site-output-in-list?
            (doc-site-module-output module)
            (box-get rest))
          (doc-site-output-list-has-duplicate? (box-get rest))))]))

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

(define (doc-site-string-prefix? [text : String] [prefix : String]) : bool
  (doc-string-prefix-at? text prefix 0))

(define (doc-site-find-prefix [text : String] [prefix : String] [from : i64]) : i64
  (let
    [i : i64 from]
    [n : i64 (string-length text)]
    [found : i64 (string-length text)]
    (begin
      (while (and (< i n) (= found n))
        (begin
          (if (doc-string-prefix-at? text prefix i)
            (set! found i)
            unit)
          (set! i (+ i 1))))
      found)))

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

(define (doc-site-guide-output-for-source
  [target : String]
  [guides : DocSiteGuidePageList]) : String
  (match guides
    [(DocSiteGuidePageNil) ""]
    [(DocSiteGuidePageCons guide rest)
      (if (string-eq target (doc-site-guide-source guide))
        (doc-site-guide-output guide)
        (doc-site-guide-output-for-source target (box-get rest)))]))

(define (doc-site-module-output-for-source
  [target : String]
  [modules : DocSiteModuleList]) : String
  (match modules
    [(DocSiteModuleNil) ""]
    [(DocSiteModuleCons module rest)
      (if (string-eq target (doc-site-module-source module))
        (doc-site-module-output module)
        (doc-site-module-output-for-source target (box-get rest)))]))

(define (doc-site-section-output-for-source
  [target : String]
  [section : DocSiteSection]) : String
  (match section
    [(DocSiteGuideSection _ guides)
      (doc-site-guide-output-for-source target guides)]
    [(DocSiteApiTreeSection tree)
      (doc-site-module-output-for-source
        target
        (doc-site-api-tree-modules tree))]))

(define (doc-site-sections-output-for-source
  [target : String]
  [sections : DocSiteSectionList]) : String
  (match sections
    [(DocSiteSectionNil) ""]
    [(DocSiteSectionCons section rest)
      (let
        [output : String (doc-site-section-output-for-source target section)]
        (if (> (string-length output) 0)
          output
          (doc-site-sections-output-for-source target (box-get rest))))]))

(define (doc-site-rewrite-language-link-target
  [sections : DocSiteSectionList]
  [target : String]) : String
  (cond
    [(doc-site-href-anchor? target) target]
    [(doc-site-href-external? target) target]
    [else
      (let
        [site-target : String
          (doc-site-sections-output-for-source target sections)]
        (if (> (string-length site-target) 0)
          site-target
          (doc-site-repo-source-url target)))]))

(define (doc-site-rewrite-language-links
  [sections : DocSiteSectionList]
  [html : String]) : String
  (let
    [cursor : i64 0]
    [n : i64 (string-length html)]
    [out : String ""]
    (begin
      (while (< cursor n)
        (let
          [href-start : i64 (doc-site-find-prefix html "href=\"" cursor)]
          (if (< href-start n)
            (let
              [target-start : i64 (+ href-start 6)]
              [target-end : i64 (md-find-char html target-start #"')]
              (if (< target-end n)
                (let
                  [target : String
                    (substring html target-start (- target-end target-start))]
                  (begin
                    (set!
                      out
                      (doc-html-cat5
                        (string-append
                          out
                          (substring html cursor (- href-start cursor)))
                        "href=\""
                        (doc-site-rewrite-language-link-target sections target)
                        "\""
                        ""))
                    (set! cursor (+ target-end 1))))
                (begin
                  (set!
                    out
                    (string-append out (substring html cursor (- n cursor))))
                  (set! cursor n))))
            (begin
              (set!
                out
                (string-append out (substring html cursor (- n cursor))))
              (set! cursor n)))))
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

(define (doc-site-index-module-entry [module : DocSiteModule]) : String
  (doc-html-cat5
    "<li><a href=\""
    (doc-html-escape (doc-site-module-output module))
    "\"><code>"
    (doc-html-escape (doc-site-module-source module))
    "</code></a></li>\n"))

(define (doc-site-index-module-entries [modules : DocSiteModuleList]) : String
  (match modules
    [(DocSiteModuleNil) ""]
    [(DocSiteModuleCons module rest)
      (string-append
        (doc-site-index-module-entry module)
        (doc-site-index-module-entries (box-get rest)))]))

(define (doc-site-index-guide-entry [guide : DocSiteGuidePage]) : String
  (doc-html-cat5
    "<li><a href=\""
    (doc-html-escape (doc-site-guide-output guide))
    "\">"
    (doc-html-escape (doc-site-guide-label guide))
    "</a></li>\n"))

(define (doc-site-index-guide-entries [guides : DocSiteGuidePageList]) : String
  (match guides
    [(DocSiteGuidePageNil) ""]
    [(DocSiteGuidePageCons guide rest)
      (string-append
        (doc-site-index-guide-entry guide)
        (doc-site-index-guide-entries (box-get rest)))]))

(define (doc-site-render-guide-index-section
  [title : String]
  [guides : DocSiteGuidePageList]) : String
  (doc-html-cat3
    (doc-html-cat5
      "<nav class=\"tl-doc-site-nav\" aria-label=\""
      (doc-html-escape title)
      "\">\n<h2>"
      (doc-html-escape title)
      "</h2>\n<ul>\n")
    (doc-site-index-guide-entries guides)
    "</ul>\n</nav>\n"))

(define (doc-site-render-api-index-section [tree : DocSiteApiTree]) : String
  (let
    [root : String (doc-site-api-tree-root tree)]
    (doc-html-cat3
      (doc-html-cat5
        "<nav class=\"tl-doc-site-nav\" aria-label=\""
        (doc-html-escape root)
        " API\">\n<h2>"
        (doc-html-escape root)
        "</h2>\n<ul>\n")
      (doc-site-index-module-entries (doc-site-api-tree-modules tree))
      "</ul>\n</nav>\n")))

(define (doc-site-render-index-section [section : DocSiteSection]) : String
  (match section
    [(DocSiteGuideSection title guides)
      (doc-site-render-guide-index-section title guides)]
    [(DocSiteApiTreeSection tree) (doc-site-render-api-index-section tree)]))

(define (doc-site-render-index-sections [sections : DocSiteSectionList]) : String
  (match sections
    [(DocSiteSectionNil) ""]
    [(DocSiteSectionCons section rest)
      (string-append
        (doc-site-render-index-section section)
        (doc-site-render-index-sections (box-get rest)))]))

(define (doc-site-module-label [module : DocSiteModule]) : String
  (let
    [source : String (doc-site-module-source module)]
    [i : i64 0]
    [n : i64 (string-length source)]
    [start : i64 0]
    [end : i64 (string-length source)]
    (begin
      (while (< i n)
        (begin
          (if (fs-path-separator? (string-ref source i))
            (begin
              (set! start (+ i 1))
              (set! end n))
            unit)
          (if (= (string-ref source i) #.')
            (set! end i)
            unit)
          (set! i (+ i 1))))
      (substring source start (- end start)))))

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

(define (doc-site-sidebar-root-link
  [href : String]
  [label : String]
  [current : String]) : String
  (if (string-eq href current)
    (doc-html-cat5
      "<a class=\"tl-doc-tree-root is-current\" aria-current=\"page\" href=\""
      (doc-html-escape href)
      "\">"
      (doc-html-escape label)
      "</a>\n")
    (doc-html-cat5
      "<a class=\"tl-doc-tree-root\" href=\""
      (doc-html-escape href)
      "\">"
      (doc-html-escape label)
      "</a>\n")))

(define (doc-site-sidebar-guide-entry
  [guide : DocSiteGuidePage]
  [current : String]) : String
  (doc-html-cat5
    "<li>"
    (doc-site-sidebar-link-open (doc-site-guide-output guide) current)
    (doc-html-escape (doc-site-guide-label guide))
    "</a></li>\n"
    ""))

(define (doc-site-sidebar-guide-entries
  [guides : DocSiteGuidePageList]
  [current : String]) : String
  (match guides
    [(DocSiteGuidePageNil) ""]
    [(DocSiteGuidePageCons guide rest)
      (string-append
        (doc-site-sidebar-guide-entry guide current)
        (doc-site-sidebar-guide-entries (box-get rest) current))]))

(define (doc-site-sidebar-module-entry
  [module : DocSiteModule]
  [current : String]) : String
  (doc-html-cat5
    "<li>"
    (doc-site-sidebar-link-open (doc-site-module-output module) current)
    "<code>"
    (doc-html-escape (doc-site-module-label module))
    "</code></a></li>\n"))

(define (doc-site-sidebar-module-entries
  [modules : DocSiteModuleList]
  [current : String]) : String
  (match modules
    [(DocSiteModuleNil) ""]
    [(DocSiteModuleCons module rest)
      (string-append
        (doc-site-sidebar-module-entry module current)
        (doc-site-sidebar-module-entries (box-get rest) current))]))

(define (doc-site-sidebar-guide-section
  [title : String]
  [guides : DocSiteGuidePageList]
  [current : String]) : String
  (doc-html-cat5
    "<li><span class=\"tl-doc-tree-root\">"
    (doc-html-escape title)
    "</span>\n<ul>\n"
    (doc-site-sidebar-guide-entries guides current)
    "</ul>\n</li>\n"))

(define (doc-site-sidebar-api-tree [tree : DocSiteApiTree] [current : String]) : String
  (doc-html-cat3
    "<li>"
    (doc-site-sidebar-root-link
      (doc-site-api-tree-output tree)
      (doc-site-api-tree-root tree)
      current)
    (doc-html-cat3
      "<ul>\n"
      (doc-site-sidebar-module-entries (doc-site-api-tree-modules tree) current)
      "</ul>\n</li>\n")))

(define (doc-site-sidebar-section [section : DocSiteSection] [current : String]) : String
  (match section
    [(DocSiteGuideSection title guides)
      (doc-site-sidebar-guide-section title guides current)]
    [(DocSiteApiTreeSection tree) (doc-site-sidebar-api-tree tree current)]))

(define (doc-site-sidebar-sections
  [sections : DocSiteSectionList]
  [current : String]) : String
  (match sections
    [(DocSiteSectionNil) ""]
    [(DocSiteSectionCons section rest)
      (string-append
        (doc-site-sidebar-section section current)
        (doc-site-sidebar-sections (box-get rest) current))]))

(define (doc-site-sidebar [sections : DocSiteSectionList] [current : String]) : String
  (doc-html-cat5
    "<nav class=\"tl-doc-stdlib-sidebar\" aria-label=\"Documentation tree\">\n<ul class=\"tl-doc-stdlib-tree\">\n"
    (doc-site-sidebar-sections sections current)
    "</ul>\n</nav>\n"
    ""
    ""))

(define (doc-site-render-page
  [title : String]
  [subtitle : String]
  [sections : DocSiteSectionList]
  [current : String]
  [body : String]) : String
  (doc-html-cat5
    (doc-html-page-open title)
    (doc-html-header "TypeLisp Docs" subtitle)
    "<div class=\"tl-doc-shell\">\n"
    (doc-site-sidebar sections current)
    (doc-html-cat5
      "<main class=\"tl-doc-content\">\n"
      body
      "</main>\n</div>\n"
      (doc-html-page-close)
      "")))

(define (doc-site-render-index
  [sections : DocSiteSectionList]
  [current : String]) : String
  (doc-site-render-page
    "TypeLisp Docs"
    "language guides and API reference"
    sections
    current
    (doc-site-render-index-sections sections)))

(define (doc-site-render-guide-page
  [sections : DocSiteSectionList]
  [guide : DocSiteGuidePage]
  [markdown : String]) : String
  (doc-site-render-page
    (doc-site-guide-title guide)
    (doc-site-guide-source guide)
    sections
    (doc-site-guide-output guide)
    (doc-html-cat3
      "<article class=\"tl-doc-language\">\n"
      (doc-site-rewrite-language-links sections (md-render-html markdown))
      "</article>\n")))

(define (doc-site-render-api-tree-index
  [sections : DocSiteSectionList]
  [tree : DocSiteApiTree]) : String
  (doc-site-render-page
    (doc-html-cat3 "TypeLisp API: " (doc-site-api-tree-root tree) "")
    (doc-site-api-tree-root tree)
    sections
    (doc-site-api-tree-output tree)
    (doc-site-render-api-index-section tree)))

(define (doc-site-render-module-page
  [sections : DocSiteSectionList]
  [module : DocSiteModule]
  [docs : DocExtraction]) : String
  (let
    [source : String (doc-site-module-source module)]
    [title : String (doc-html-cat3 "TypeLisp API: " source "")]
    (doc-site-render-page
      title
      source
      sections
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
    (match (try-mkdir-if-missing (& path))
      [(OkIoUnit) unit]
      [(ErrIoUnit _)
        (doc-site-panic-unit
          (string-append "doc-site: could not create output directory: " path))])))

(define (doc-site-path-join [left : String] [right : String]) : String
  (fs-path-join (& left) (& right)))

(define (doc-site-write-module-page
  [output-dir : String]
  [sections : DocSiteSectionList]
  [module : DocSiteModule]) : unit
  (let
    [source : String (doc-site-module-source module)]
    [output : String
      (doc-site-path-join output-dir (doc-site-module-output module))]
    [docs : DocExtraction (doc-site-read-module-docs source)]
    (doc-site-write-file
      output
      (doc-site-render-module-page sections module docs))))

(define (doc-site-write-module-pages
  [output-dir : String]
  [sections : DocSiteSectionList]
  [remaining : DocSiteModuleList]) : unit
  (match remaining
    [(DocSiteModuleNil) unit]
    [(DocSiteModuleCons module rest)
      (begin
        (doc-site-write-module-page output-dir sections module)
        (doc-site-write-module-pages output-dir sections (box-get rest)))]))

(define (doc-site-write-guide-page
  [output-dir : String]
  [sections : DocSiteSectionList]
  [guide : DocSiteGuidePage]) : unit
  (doc-site-write-file
    (doc-site-path-join output-dir (doc-site-guide-output guide))
    (doc-site-render-guide-page
      sections
      guide
      (doc-site-read-markdown (doc-site-guide-source guide)))))

(define (doc-site-write-guide-pages
  [output-dir : String]
  [sections : DocSiteSectionList]
  [guides : DocSiteGuidePageList]) : unit
  (match guides
    [(DocSiteGuidePageNil) unit]
    [(DocSiteGuidePageCons guide rest)
      (begin
        (doc-site-write-guide-page output-dir sections guide)
        (doc-site-write-guide-pages output-dir sections (box-get rest)))]))

(define (doc-site-write-api-tree
  [output-dir : String]
  [sections : DocSiteSectionList]
  [tree : DocSiteApiTree]) : unit
  (begin
    (doc-site-write-file
      (doc-site-path-join output-dir (doc-site-api-tree-output tree))
      (doc-site-render-api-tree-index sections tree))
    (doc-site-write-module-pages
      output-dir
      sections
      (doc-site-api-tree-modules tree))))

(define (doc-site-write-section
  [output-dir : String]
  [sections : DocSiteSectionList]
  [section : DocSiteSection]) : unit
  (match section
    [(DocSiteGuideSection _ guides)
      (doc-site-write-guide-pages output-dir sections guides)]
    [(DocSiteApiTreeSection tree)
      (doc-site-write-api-tree output-dir sections tree)]))

(define (doc-site-write-sections
  [output-dir : String]
  [sections : DocSiteSectionList]
  [remaining : DocSiteSectionList]) : unit
  (match remaining
    [(DocSiteSectionNil) unit]
    [(DocSiteSectionCons section rest)
      (begin
        (doc-site-write-section output-dir sections section)
        (doc-site-write-sections output-dir sections (box-get rest)))]))

(define (doc-site-build [output-dir : String]) : i64
  (let
    [sections : DocSiteSectionList (doc-site-typelisp-sections)]
    [stdlib : DocSiteApiTree (doc-site-stdlib-api-tree)]
    (begin
      (doc-site-validate-stdlib-manifest (doc-site-api-tree-modules stdlib))
      (doc-site-ensure-dir output-dir)
      (doc-site-write-file
        (doc-site-path-join output-dir "typelisp-docs.css")
        (doc-site-css))
      (doc-site-write-file
        (doc-site-path-join output-dir "index.html")
        (doc-site-render-index sections "index.html"))
      (doc-site-write-sections output-dir sections sections)
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

See [the spec](SPEC.md), [the second module](stdlib/second.tl), and [the builder](selfhost/doc_site.tl).

```typelisp
(define answer : i64 42)
```")

(define (doc-site-smoke-modules) : DocSiteModuleList
  (doc-site-module-cons
    (DocSiteModule "stdlib/smoke<&>.tl" "stdlib-smoke.html")
    (doc-site-module-cons
      (DocSiteModule "stdlib/second.tl" "stdlib-second.html")
      DocSiteModuleNil)))

(define (doc-site-smoke-guides) : DocSiteGuidePageList
  (doc-site-guide-page-cons
    (DocSiteGuidePage "TypeLisp Overview" "README.md" "readme.html" "Overview")
    (doc-site-guide-page-cons
      (DocSiteGuidePage
        "TypeLisp Language Reference"
        "SPEC.md"
        "spec.html"
        "Specification")
      DocSiteGuidePageNil)))

(define (doc-site-smoke-api-tree) : DocSiteApiTree
  (DocSiteApiTree "stdlib" "stdlib.html" (doc-site-smoke-modules)))

(define (doc-site-smoke-sections) : DocSiteSectionList
  (doc-site-section-cons
    (DocSiteGuideSection "Language" (doc-site-smoke-guides))
    (doc-site-section-cons
      (DocSiteApiTreeSection (doc-site-smoke-api-tree))
      DocSiteSectionNil)))

(define (doc-site-require [ok : bool] [message : String]) : bool
  (if ok
    true
    (begin
      (panic message)
      false)))

(define (doc-site-smoke) : i64
  (let
    [sections : DocSiteSectionList (doc-site-smoke-sections)]
    [index : String (doc-site-render-index sections "index.html")]
    [page : String
      (doc-site-render-module-page
        sections
        (DocSiteModule "stdlib/smoke<&>.tl" "stdlib-smoke.html")
        (doc-extract-source (doc-site-smoke-source)))]
    [second-page : String
      (doc-site-render-module-page
        sections
        (DocSiteModule "stdlib/second.tl" "stdlib-second.html")
        (doc-extract-source (doc-site-second-smoke-source)))]
    [language-page : String
      (doc-site-render-guide-page
        sections
        (DocSiteGuidePage
          "TypeLisp Overview"
          "README.md"
          "readme.html"
          "Overview")
        (doc-site-language-smoke-source))]
    (begin
      (doc-html-require-contains
        index
        "<nav class=\"tl-doc-site-nav\" aria-label=\"stdlib API\">"
        "doc-site: site nav missing")
      (doc-html-require-contains
        index
        "<nav class=\"tl-doc-site-nav\" aria-label=\"Language\">"
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
        "<nav class=\"tl-doc-stdlib-sidebar\" aria-label=\"Documentation tree\">"
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
        "href=\"stdlib-second.html\""
        "doc-site: language api link rewrite missing")
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
          (doc-site-module-cons
            (DocSiteModule "a.tl" "same.html")
            (doc-site-module-cons
              (DocSiteModule "b.tl" "same.html")
              DocSiteModuleNil)))
        "doc-site: duplicate output detection missing")
      (doc-site-require
        (not (doc-site-expected-manifest-size? DocSiteModuleNil))
        "doc-site: missing manifest detection missing")
      42)))