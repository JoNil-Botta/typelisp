;; doc_site_core.tl - Static documentation site builder core.
;;
;; The TypeLisp site composition layer combines language guides and reusable API
;; trees. API pages still use the source/module documentation extractor and HTML
;; renderer without hard-coding TypeLisp guide-page knowledge into that path.
(import stdlib.io)
(import stdlib.fs)
(import stdlib.string)
(import stdlib.str_cat)
(import stdlib.vector)
(import doc_site_doc_bridge as doc_bridge)
(import doc_md)

(defenum DocSiteModule
  (Module String String))

(vector.family DocSiteModule DocSiteModuleList doc-site-module-list)

(defenum DocSiteGuidePage
  (GuidePage String String String String))

(vector.family DocSiteGuidePage DocSiteGuidePageList doc-site-guide-page-list)

(defenum DocSiteApiTree
  (ApiTree String String DocSiteModuleList))

(defenum DocSiteSection
  (Guide String DocSiteGuidePageList)
  (ApiTree DocSiteApiTree))

(vector.family DocSiteSection DocSiteSectionList doc-site-section-list)

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
    [(DocSiteModule.Module source _) source]))

(define (doc-site-module-output [module : DocSiteModule]) : String
  (match module
    [(DocSiteModule.Module _ output) output]))

(define (doc-site-guide-title [guide : DocSiteGuidePage]) : String
  (match guide
    [(DocSiteGuidePage.GuidePage title _ _ _) title]))

(define (doc-site-guide-source [guide : DocSiteGuidePage]) : String
  (match guide
    [(DocSiteGuidePage.GuidePage _ source _ _) source]))

(define (doc-site-guide-output [guide : DocSiteGuidePage]) : String
  (match guide
    [(DocSiteGuidePage.GuidePage _ _ output _) output]))

(define (doc-site-guide-label [guide : DocSiteGuidePage]) : String
  (match guide
    [(DocSiteGuidePage.GuidePage _ _ _ label) label]))

(define (doc-site-api-tree-root [tree : DocSiteApiTree]) : String
  (match tree
    [(DocSiteApiTree.ApiTree root _ _) root]))

(define (doc-site-api-tree-output [tree : DocSiteApiTree]) : String
  (match tree
    [(DocSiteApiTree.ApiTree _ output _) output]))

(define (doc-site-api-tree-modules [tree : DocSiteApiTree]) : DocSiteModuleList
  (match tree
    [(DocSiteApiTree.ApiTree _ _ modules) modules]))

(define (doc-site-module-list-empty) : DocSiteModuleList
  (doc-site-module-list-new))

(define (doc-site-module-list-ref [modules : DocSiteModuleList] [index : i64]) : DocSiteModule
  (doc-site-module-list-get (& modules) index (DocSiteModule.Module "" "")))

(define (doc-site-guide-page-list-empty) : DocSiteGuidePageList
  (doc-site-guide-page-list-new))

(define (doc-site-guide-page-list-count [guides : DocSiteGuidePageList]) : i64
  (doc-site-guide-page-list-len (& guides)))

(define (doc-site-guide-page-list-ref
  [guides : DocSiteGuidePageList]
  [index : i64]) : DocSiteGuidePage
  (doc-site-guide-page-list-get
    (& guides)
    index
    (DocSiteGuidePage.GuidePage "" "" "" "")))

(define (doc-site-section-list-empty) : DocSiteSectionList
  (doc-site-section-list-new))

(define (doc-site-section-list-count [sections : DocSiteSectionList]) : i64
  (doc-site-section-list-len (& sections)))

(define (doc-site-section-list-ref
  [sections : DocSiteSectionList]
  [index : i64]) : DocSiteSection
  (doc-site-section-list-get
    (& sections)
    index
    (DocSiteSection.Guide "" (doc-site-guide-page-list-empty))))

(define (doc-site-stdlib-modules) : DocSiteModuleList
  (let
    [modules : DocSiteModuleList
      (doc-site-module-list-with-capacity doc-site-stdlib-manifest-size)]
    (begin
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/arena.tl" "stdlib-arena.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/cpu.tl" "stdlib-cpu.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/env.tl" "stdlib-env.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/ffi.tl" "stdlib-ffi.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/fs.tl" "stdlib-fs.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/hash.tl" "stdlib-hash.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/hashmap.tl" "stdlib-hashmap.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/io.tl" "stdlib-io.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module
          "stdlib/byte_buf_core.tl"
          "stdlib-byte-buf-core.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/json.tl" "stdlib-json.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/msvc.tl" "stdlib-msvc.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/process.tl" "stdlib-process.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/queue.tl" "stdlib-queue.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/random.tl" "stdlib-random.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/string.tl" "stdlib-string.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/test.tl" "stdlib-test.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/text_buf.tl" "stdlib-text-buf.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module
          "stdlib/text_buf_borrowed.tl"
          "stdlib-text-buf-borrowed.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/vector.tl" "stdlib-vector.html"))
      modules)))

(define (doc-site-language-guides) : DocSiteGuidePageList
  (let
    [guides : DocSiteGuidePageList (doc-site-guide-page-list-with-capacity 2)]
    (begin
      (doc-site-guide-page-list-push
        (&mut guides)
        (DocSiteGuidePage.GuidePage
          "TypeLisp Overview"
          "README.md"
          "readme.html"
          "Overview"))
      (doc-site-guide-page-list-push
        (&mut guides)
        (DocSiteGuidePage.GuidePage
          "TypeLisp Language Reference"
          "SPEC.md"
          "spec.html"
          "Specification"))
      guides)))

(define (doc-site-stdlib-api-tree) : DocSiteApiTree
  (DocSiteApiTree.ApiTree "stdlib" "stdlib.html" (doc-site-stdlib-modules)))

(define (doc-site-typelisp-sections) : DocSiteSectionList
  (let
    [sections : DocSiteSectionList (doc-site-section-list-with-capacity 2)]
    (begin
      (doc-site-section-list-push
        (&mut sections)
        (DocSiteSection.Guide "Language" (doc-site-language-guides)))
      (doc-site-section-list-push
        (&mut sections)
        (DocSiteSection.ApiTree (doc-site-stdlib-api-tree)))
      sections)))

(define (doc-site-module-list-count [modules : DocSiteModuleList]) : i64
  (doc-site-module-list-len (& modules)))

(define (doc-site-output-in-list-from?
  [output : String]
  [modules : DocSiteModuleList]
  [start : i64]) : bool
  (let
    [i : i64 start]
    [n : i64 (doc-site-module-list-count modules)]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (if (string.eq
            output
            (doc-site-module-output (doc-site-module-list-ref modules i)))
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

(define (doc-site-output-reserved? [output : String]) : bool
  (or
    (string.eq output "index.html")
    (string.eq output "readme.html")
    (string.eq output "spec.html")
    (string.eq output "stdlib.html")
    (string.eq output "typelisp-docs.css")))

(define (doc-site-output-list-has-duplicate? [modules : DocSiteModuleList]) : bool
  (let
    [i : i64 0]
    [n : i64 (doc-site-module-list-count modules)]
    [duplicate : bool false]
    (begin
      (while (and (< i n) (not duplicate))
        (let
          [output : String
            (doc-site-module-output (doc-site-module-list-ref modules i))]
          (begin
            (if (or
              (doc-site-output-reserved? output)
              (doc-site-output-in-list-from? output modules (+ i 1)))
              (set! duplicate true)
              unit)
            (set! i (+ i 1)))))
      duplicate)))

(define (doc-site-expected-manifest-size? [modules : DocSiteModuleList]) : bool
  (= (doc-site-module-list-count modules) doc-site-stdlib-manifest-size))

(define (doc-site-panic-unit [message : String]) : unit
  (io.panic message))

(define (doc-site-validate-stdlib-manifest [modules : DocSiteModuleList]) : unit
  (if (not (doc-site-expected-manifest-size? modules))
    (doc-site-panic-unit "doc-site: missing stdlib manifest entry")
    (if (doc-site-output-list-has-duplicate? modules)
      (doc-site-panic-unit "doc-site: duplicate output path in stdlib manifest")
      unit)))

(define (doc-site-string-prefix? [text : String] [prefix : String]) : bool
  (doc_bridge.bridge-doc-string-prefix-at? text prefix 0))

(define (doc-site-find-prefix [text : String] [prefix : String] [from : i64]) : i64
  (let
    [i : i64 from]
    [n : i64 (string.string-length text)]
    [found : i64 (string.string-length text)]
    (begin
      (while (and (< i n) (= found n))
        (begin
          (if (doc_bridge.bridge-doc-string-prefix-at? text prefix i)
            (set! found i)
            unit)
          (set! i (+ i 1))))
      found)))

(define (doc-site-href-anchor? [target : String]) : bool
  (and (> (string.string-length target) 0) (= (string.string-ref target 0) '#')))

(define (doc-site-href-external? [target : String]) : bool
  (or
    (doc_bridge.bridge-doc-string-contains? target "://")
    (doc-site-string-prefix? target "mailto:")))

(define (doc-site-href-file-like? [target : String]) : bool
  (doc_bridge.bridge-doc-string-contains? target "."))

(define (doc-site-repo-source-url [target : String]) : String
  (str_cat.str-cat
    (if (doc-site-href-file-like? target)
      doc-site-repo-blob-root
      doc-site-repo-tree-root)
    target
    ""))

(define (doc-site-guide-output-for-source
  [target : String]
  [guides : DocSiteGuidePageList]) : String
  (let
    [i : i64 0]
    [n : i64 (doc-site-guide-page-list-count guides)]
    [output : String ""]
    (begin
      (while (and (< i n) (= (string.string-length output) 0))
        (let
          [guide : DocSiteGuidePage (doc-site-guide-page-list-ref guides i)]
          (begin
            (if (string.eq target (doc-site-guide-source guide))
              (set! output (doc-site-guide-output guide))
              unit)
            (set! i (+ i 1)))))
      output)))

(define (doc-site-module-output-for-source
  [target : String]
  [modules : DocSiteModuleList]) : String
  (let
    [i : i64 0]
    [n : i64 (doc-site-module-list-count modules)]
    [output : String ""]
    (begin
      (while (and (< i n) (= (string.string-length output) 0))
        (let
          [module : DocSiteModule (doc-site-module-list-ref modules i)]
          (begin
            (if (string.eq target (doc-site-module-source module))
              (set! output (doc-site-module-output module))
              unit)
            (set! i (+ i 1)))))
      output)))

(define (doc-site-section-output-for-source
  [target : String]
  [section : DocSiteSection]) : String
  (match section
    [(DocSiteSection.Guide _ guides)
      (doc-site-guide-output-for-source target guides)]
    [(DocSiteSection.ApiTree tree)
      (doc-site-module-output-for-source
        target
        (doc-site-api-tree-modules tree))]))

(define (doc-site-sections-output-for-source
  [target : String]
  [sections : DocSiteSectionList]) : String
  (let
    [i : i64 0]
    [n : i64 (doc-site-section-list-count sections)]
    [output : String ""]
    (begin
      (while (and (< i n) (= (string.string-length output) 0))
        (begin
          (set!
            output
            (doc-site-section-output-for-source
              target
              (doc-site-section-list-ref sections i)))
          (set! i (+ i 1))))
      output)))

(define (doc-site-rewrite-language-link-target
  [sections : DocSiteSectionList]
  [target : String]) : String
  (if (doc-site-href-anchor? target)
    target
    (if (doc-site-href-external? target)
      target
      (let
        [site-target : String
          (doc-site-sections-output-for-source target sections)]
        (if (> (string.string-length site-target) 0)
          site-target
          (doc-site-repo-source-url target))))))

(define (doc-site-rewrite-language-links
  [sections : DocSiteSectionList]
  [html : String]) : String
  (let
    [cursor : i64 0]
    [n : i64 (string.string-length html)]
    [out : String ""]
    (begin
      (while (< cursor n)
        (let
          [href-start : i64 (doc-site-find-prefix html "href=\"" cursor)]
          (if (< href-start n)
            (let
              [target-start : i64 (+ href-start 6)]
              [target-end : i64 (doc_md.md-find-char html target-start '"')]
              (if (< target-end n)
                (let
                  [target : String
                    (string.substring
                      html
                      target-start
                      (- target-end target-start))]
                  (begin
                    (set!
                      out
                      (str_cat.str-cat
                        out
                        (string.substring html cursor (- href-start cursor))
                        "href=\""
                        (doc-site-rewrite-language-link-target sections target)
                        "\""))
                    (set! cursor (+ target-end 1))))
                (begin
                  (set!
                    out
                    (str_cat.str-cat
                      out
                      (string.substring html cursor (- n cursor))
                      ""))
                  (set! cursor n))))
            (begin
              (set!
                out
                (str_cat.str-cat
                  out
                  (string.substring html cursor (- n cursor))
                  ""))
              (set! cursor n)))))
      out)))

(define (doc-site-css) : String
  "body.tl-docs {
  margin: 0;
  color-scheme: dark;
  color: #d6deea;
  background: #0b1120;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif;
  line-height: 1.55;
}
.tl-doc-header {
  background: #111827;
  border-bottom: 1px solid #263244;
  padding: 2rem clamp(1rem, 4vw, 3rem);
}
.tl-doc-header h1 {
  margin: 0 0 0.25rem;
  font-size: 2rem;
  color: #f8fafc;
}
.tl-doc-header p {
  margin: 0;
  color: #95a3b8;
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
  color: #67e8f9;
}
a:hover {
  color: #a7f3d0;
}
code,
pre {
  font-family: ui-monospace, SFMono-Regular, Consolas, \"Liberation Mono\", monospace;
}
p code,
li code,
dt code,
dd code,
td code,
th code {
  background: #111827;
  color: #e2e8f0;
  border: 1px solid #263244;
  border-radius: 4px;
  padding: 0.05rem 0.25rem;
}
pre {
  overflow-x: auto;
  background: #020617;
  color: #e5e7eb;
  border: 1px solid #1f2a3a;
  padding: 1rem;
  border-radius: 6px;
}
.tl-syn-doc-comment {
  color: #93c5fd;
  font-style: italic;
}
.tl-syn-comment {
  color: #94a3b8;
}
.tl-syn-string {
  color: #fbbf24;
}
.tl-syn-escape {
  color: #fde68a;
  font-weight: 700;
}
.tl-syn-number {
  color: #c4b5fd;
}
.tl-syn-keyword {
  color: #f472b6;
}
.tl-syn-builtin {
  color: #67e8f9;
}
.tl-syn-operator {
  color: #f9a8d4;
}
.tl-syn-boolean {
  color: #fca5a5;
}
.tl-syn-type {
  color: #86efac;
}
.tl-syn-definition {
  color: #bfdbfe;
  font-weight: 700;
}
.tl-syn-binding {
  color: #a7f3d0;
}
.tl-syn-call {
  color: #93c5fd;
}
.tl-doc-site-nav,
.tl-doc-module-nav,
.tl-doc-item-nav,
.tl-doc-stdlib-sidebar {
  background: #111827;
  border: 1px solid #263244;
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
  background: #164e63;
  color: #ecfeff;
  font-weight: 700;
}
.tl-doc-module,
.tl-doc-item {
  margin-top: 1.5rem;
}
.tl-doc-module-text,
.tl-doc-item-text {
  background: #0f172a;
  border-left: 4px solid #14b8a6;
  color: #dbeafe;
  padding: 0.75rem 1rem;
}
.tl-doc-meta {
  display: grid;
  grid-template-columns: max-content 1fr;
  gap: 0.25rem 0.75rem;
}
.tl-doc-empty {
  color: #94a3b8;
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
  background: #0f172a;
}
.tl-doc-language th {
  background: #111c2e;
  color: #f8fafc;
}
.tl-doc-language th,
.tl-doc-language td {
  border: 1px solid #263244;
  padding: 0.35rem 0.5rem;
  vertical-align: top;
}
.tl-doc-language blockquote {
  margin: 1rem 0;
  border-left: 4px solid #64748b;
  padding-left: 1rem;
  color: #cbd5e1;
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
  (str_cat.str-cat
    "<li><a href=\""
    (doc_bridge.bridge-doc-html-escape (doc-site-module-output module))
    "\"><code>"
    (doc_bridge.bridge-doc-html-escape (doc-site-module-source module))
    "</code></a></li>\n"))

(define (doc-site-index-module-entries [modules : DocSiteModuleList]) : String
  (let
    [i : i64 0]
    [n : i64 (doc-site-module-list-count modules)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (doc-site-index-module-entry (doc-site-module-list-ref modules i))
              ""))
          (set! i (+ i 1))))
      out)))

(define (doc-site-index-guide-entry [guide : DocSiteGuidePage]) : String
  (str_cat.str-cat
    "<li><a href=\""
    (doc_bridge.bridge-doc-html-escape (doc-site-guide-output guide))
    "\">"
    (doc_bridge.bridge-doc-html-escape (doc-site-guide-label guide))
    "</a></li>\n"))

(define (doc-site-index-guide-entries [guides : DocSiteGuidePageList]) : String
  (let
    [i : i64 0]
    [n : i64 (doc-site-guide-page-list-count guides)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (doc-site-index-guide-entry
                (doc-site-guide-page-list-ref guides i))
              ""))
          (set! i (+ i 1))))
      out)))

(define (doc-site-render-guide-index-section
  [title : String]
  [guides : DocSiteGuidePageList]) : String
  (str_cat.str-cat
    "<nav class=\"tl-doc-site-nav\" aria-label=\""
    (doc_bridge.bridge-doc-html-escape title)
    "\">\n<h2>"
    (doc_bridge.bridge-doc-html-escape title)
    "</h2>\n<ul>\n"
    (doc-site-index-guide-entries guides)
    "</ul>\n</nav>\n"))

(define (doc-site-render-api-index-section [tree : DocSiteApiTree]) : String
  (let
    [root : String (doc-site-api-tree-root tree)]
    (str_cat.str-cat
      "<nav class=\"tl-doc-site-nav\" aria-label=\""
      (doc_bridge.bridge-doc-html-escape root)
      " API\">\n<h2>"
      (doc_bridge.bridge-doc-html-escape root)
      "</h2>\n<ul>\n"
      (doc-site-index-module-entries (doc-site-api-tree-modules tree))
      "</ul>\n</nav>\n")))

(define (doc-site-render-index-section [section : DocSiteSection]) : String
  (match section
    [(DocSiteSection.Guide title guides)
      (doc-site-render-guide-index-section title guides)]
    [(DocSiteSection.ApiTree tree) (doc-site-render-api-index-section tree)]))

(define (doc-site-render-index-sections [sections : DocSiteSectionList]) : String
  (let
    [i : i64 0]
    [n : i64 (doc-site-section-list-count sections)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (doc-site-render-index-section
                (doc-site-section-list-ref sections i))
              ""))
          (set! i (+ i 1))))
      out)))

(define (doc-site-module-label [module : DocSiteModule]) : String
  (let
    [source : String (doc-site-module-source module)]
    [i : i64 0]
    [n : i64 (string.string-length source)]
    [start : i64 0]
    [end : i64 (string.string-length source)]
    (begin
      (while (< i n)
        (begin
          (if (fs.path-separator? (string.string-ref source i))
            (begin
              (set! start (+ i 1))
              (set! end n))
            unit)
          (if (= (string.string-ref source i) '.')
            (set! end i)
            unit)
          (set! i (+ i 1))))
      (string.substring source start (- end start)))))

(define (doc-site-sidebar-link-open [href : String] [current : String]) : String
  (if (string.eq href current)
    (str_cat.str-cat
      "<a class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\""
      (doc_bridge.bridge-doc-html-escape href)
      "\">")
    (str_cat.str-cat
      "<a class=\"tl-doc-tree-link\" href=\""
      (doc_bridge.bridge-doc-html-escape href)
      "\">")))

(define (doc-site-sidebar-root-link
  [href : String]
  [label : String]
  [current : String]) : String
  (if (string.eq href current)
    (str_cat.str-cat
      "<a class=\"tl-doc-tree-root is-current\" aria-current=\"page\" href=\""
      (doc_bridge.bridge-doc-html-escape href)
      "\">"
      (doc_bridge.bridge-doc-html-escape label)
      "</a>\n")
    (str_cat.str-cat
      "<a class=\"tl-doc-tree-root\" href=\""
      (doc_bridge.bridge-doc-html-escape href)
      "\">"
      (doc_bridge.bridge-doc-html-escape label)
      "</a>\n")))

(define (doc-site-sidebar-guide-entry
  [guide : DocSiteGuidePage]
  [current : String]) : String
  (str_cat.str-cat
    "<li>"
    (doc-site-sidebar-link-open (doc-site-guide-output guide) current)
    (doc_bridge.bridge-doc-html-escape (doc-site-guide-label guide))
    "</a></li>\n"
    ""))

(define (doc-site-sidebar-guide-entries
  [guides : DocSiteGuidePageList]
  [current : String]) : String
  (let
    [i : i64 0]
    [n : i64 (doc-site-guide-page-list-count guides)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (doc-site-sidebar-guide-entry
                (doc-site-guide-page-list-ref guides i)
                current)
              ""))
          (set! i (+ i 1))))
      out)))

(define (doc-site-sidebar-module-entry
  [module : DocSiteModule]
  [current : String]) : String
  (str_cat.str-cat
    "<li>"
    (doc-site-sidebar-link-open (doc-site-module-output module) current)
    "<code>"
    (doc_bridge.bridge-doc-html-escape (doc-site-module-label module))
    "</code></a></li>\n"))

(define (doc-site-sidebar-module-entries
  [modules : DocSiteModuleList]
  [current : String]) : String
  (let
    [i : i64 0]
    [n : i64 (doc-site-module-list-count modules)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (doc-site-sidebar-module-entry
                (doc-site-module-list-ref modules i)
                current)
              ""))
          (set! i (+ i 1))))
      out)))

(define (doc-site-sidebar-guide-section
  [title : String]
  [guides : DocSiteGuidePageList]
  [current : String]) : String
  (str_cat.str-cat
    "<li><span class=\"tl-doc-tree-root\">"
    (doc_bridge.bridge-doc-html-escape title)
    "</span>\n<ul>\n"
    (doc-site-sidebar-guide-entries guides current)
    "</ul>\n</li>\n"))

(define (doc-site-sidebar-api-tree [tree : DocSiteApiTree] [current : String]) : String
  (str_cat.str-cat
    "<li>"
    (doc-site-sidebar-root-link
      (doc-site-api-tree-output tree)
      (doc-site-api-tree-root tree)
      current)
    "<ul>\n"
    (doc-site-sidebar-module-entries (doc-site-api-tree-modules tree) current)
    "</ul>\n</li>\n"))

(define (doc-site-sidebar-section [section : DocSiteSection] [current : String]) : String
  (match section
    [(DocSiteSection.Guide title guides)
      (doc-site-sidebar-guide-section title guides current)]
    [(DocSiteSection.ApiTree tree) (doc-site-sidebar-api-tree tree current)]))

(define (doc-site-sidebar-sections
  [sections : DocSiteSectionList]
  [current : String]) : String
  (let
    [i : i64 0]
    [n : i64 (doc-site-section-list-count sections)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (str_cat.str-cat
              out
              (doc-site-sidebar-section
                (doc-site-section-list-ref sections i)
                current)
              ""))
          (set! i (+ i 1))))
      out)))

(define (doc-site-sidebar [sections : DocSiteSectionList] [current : String]) : String
  (str_cat.str-cat
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
  (str_cat.str-cat
    (doc_bridge.bridge-doc-html-page-open title)
    (doc_bridge.bridge-doc-html-header "TypeLisp Docs" subtitle)
    "<div class=\"tl-doc-shell\">\n"
    (doc-site-sidebar sections current)
    "<main class=\"tl-doc-content\">\n"
    body
    "</main>\n</div>\n"
    (doc_bridge.bridge-doc-html-page-close)))

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
    (str_cat.str-cat
      "<article class=\"tl-doc-language\">\n"
      (doc-site-rewrite-language-links
        sections
        (doc_md.md-render-html markdown))
      "</article>\n")))

(define (doc-site-render-api-tree-index
  [sections : DocSiteSectionList]
  [tree : DocSiteApiTree]) : String
  (doc-site-render-page
    (str_cat.str-cat "TypeLisp API: " (doc-site-api-tree-root tree) "")
    (doc-site-api-tree-root tree)
    sections
    (doc-site-api-tree-output tree)
    (doc-site-render-api-index-section tree)))

(define (doc-site-render-module-page
  [sections : DocSiteSectionList]
  [module : DocSiteModule]
  [source-text : String]) : String
  (let
    [source : String (doc-site-module-source module)]
    [title : String (str_cat.str-cat "TypeLisp API: " source "")]
    (doc-site-render-page
      title
      source
      sections
      (doc-site-module-output module)
      (doc_bridge.bridge-doc-html-module-section-source source source-text))))

(define (doc-site-read-module-source [source : String]) : String
  (let
    [status : i64 (io.read-file-status source)]
    (if (= status doc-site-status-ok)
      (io.read-file source)
      (io.panic (string.append "doc-site: missing input module: " source)))))

(define (doc-site-read-markdown [source : String]) : String
  (let
    [status : i64 (io.read-file-status source)]
    (if (= status doc-site-status-ok)
      (io.read-file source)
      (io.panic (string.append "doc-site: missing language reference: " source)))))

(define (doc-site-write-file [path : String] [contents : String]) : unit
  (let
    [status : i64 (io.write-file-status path contents)]
    (if (= status doc-site-status-ok)
      unit
      (doc-site-panic-unit (string.append "doc-site: could not write: " path)))))

(define (doc-site-ensure-dir [path : String]) : unit
  (if (= (string.string-length path) 0)
    (doc-site-panic-unit "doc-site: empty output directory")
    (match (fs.try-mkdir-if-missing (& path))
      [(io.OkIoUnit) unit]
      [(io.ErrIoUnit _)
        (doc-site-panic-unit
          (string.append "doc-site: could not create output directory: " path))])))

(define (doc-site-path-join [left : String] [right : String]) : String
  (fs.path-join (& left) (& right)))

(define (doc-site-write-module-page
  [output-dir : String]
  [sections : DocSiteSectionList]
  [module : DocSiteModule]) : unit
  (let
    [source : String (doc-site-module-source module)]
    [output : String
      (doc-site-path-join output-dir (doc-site-module-output module))]
    [source-text : String (doc-site-read-module-source source)]
    (doc-site-write-file
      output
      (doc-site-render-module-page sections module source-text))))

(define (doc-site-write-module-pages
  [output-dir : String]
  [sections : DocSiteSectionList]
  [remaining : DocSiteModuleList]) : unit
  (let
    [i : i64 0]
    [n : i64 (doc-site-module-list-count remaining)]
    (while (< i n)
      (begin
        (doc-site-write-module-page
          output-dir
          sections
          (doc-site-module-list-ref remaining i))
        (set! i (+ i 1))))))

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
  (let
    [i : i64 0]
    [n : i64 (doc-site-guide-page-list-count guides)]
    (while (< i n)
      (begin
        (doc-site-write-guide-page
          output-dir
          sections
          (doc-site-guide-page-list-ref guides i))
        (set! i (+ i 1))))))

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
    [(DocSiteSection.Guide _ guides)
      (doc-site-write-guide-pages output-dir sections guides)]
    [(DocSiteSection.ApiTree tree)
      (doc-site-write-api-tree output-dir sections tree)]))

(define (doc-site-write-sections
  [output-dir : String]
  [sections : DocSiteSectionList]
  [remaining : DocSiteSectionList]) : unit
  (let
    [i : i64 0]
    [n : i64 (doc-site-section-list-count remaining)]
    (while (< i n)
      (begin
        (doc-site-write-section
          output-dir
          sections
          (doc-site-section-list-ref remaining i))
        (set! i (+ i 1))))))

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

See [the spec](SPEC.md), [the second module](stdlib/second.tl), and [the builder](tools/doc-site/doc_site.tl).

```typelisp
(define answer : i64 42)
```")

(define (doc-site-smoke-modules) : DocSiteModuleList
  (let
    [modules : DocSiteModuleList (doc-site-module-list-with-capacity 2)]
    (begin
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/smoke<&>.tl" "stdlib-smoke.html"))
      (doc-site-module-list-push
        (&mut modules)
        (DocSiteModule.Module "stdlib/second.tl" "stdlib-second.html"))
      modules)))

(define (doc-site-smoke-guides) : DocSiteGuidePageList
  (let
    [guides : DocSiteGuidePageList (doc-site-guide-page-list-with-capacity 2)]
    (begin
      (doc-site-guide-page-list-push
        (&mut guides)
        (DocSiteGuidePage.GuidePage
          "TypeLisp Overview"
          "README.md"
          "readme.html"
          "Overview"))
      (doc-site-guide-page-list-push
        (&mut guides)
        (DocSiteGuidePage.GuidePage
          "TypeLisp Language Reference"
          "SPEC.md"
          "spec.html"
          "Specification"))
      guides)))

(define (doc-site-smoke-api-tree) : DocSiteApiTree
  (DocSiteApiTree.ApiTree "stdlib" "stdlib.html" (doc-site-smoke-modules)))

(define (doc-site-smoke-sections) : DocSiteSectionList
  (let
    [sections : DocSiteSectionList (doc-site-section-list-with-capacity 2)]
    (begin
      (doc-site-section-list-push
        (&mut sections)
        (DocSiteSection.Guide "Language" (doc-site-smoke-guides)))
      (doc-site-section-list-push
        (&mut sections)
        (DocSiteSection.ApiTree (doc-site-smoke-api-tree)))
      sections)))

(define (doc-site-require [ok : bool] [message : String]) : bool
  (if ok
    true
    (io.panic message)))

(define (doc-site-smoke) : i64
  (let
    [sections : DocSiteSectionList (doc-site-smoke-sections)]
    [index : String (doc-site-render-index sections "index.html")]
    [page : String
      (doc-site-render-module-page
        sections
        (DocSiteModule.Module "stdlib/smoke<&>.tl" "stdlib-smoke.html")
        (doc-site-smoke-source))]
    [second-page : String
      (doc-site-render-module-page
        sections
        (DocSiteModule.Module "stdlib/second.tl" "stdlib-second.html")
        (doc-site-second-smoke-source))]
    [language-page : String
      (doc-site-render-guide-page
        sections
        (DocSiteGuidePage.GuidePage
          "TypeLisp Overview"
          "README.md"
          "readme.html"
          "Overview")
        (doc-site-language-smoke-source))]
    (begin
      (doc_bridge.bridge-doc-html-require-contains
        index
        "<nav class=\"tl-doc-site-nav\" aria-label=\"stdlib API\">"
        "doc-site: site nav missing")
      (doc_bridge.bridge-doc-html-require-contains
        index
        "<nav class=\"tl-doc-site-nav\" aria-label=\"Language\">"
        "doc-site: language nav missing")
      (doc_bridge.bridge-doc-html-require-contains
        index
        "href=\"readme.html\""
        "doc-site: readme link missing")
      (doc_bridge.bridge-doc-html-require-contains
        index
        "href=\"spec.html\""
        "doc-site: spec link missing")
      (doc_bridge.bridge-doc-html-require-contains
        index
        "<nav class=\"tl-doc-stdlib-sidebar\" aria-label=\"Documentation tree\">"
        "doc-site: sidebar missing")
      (doc_bridge.bridge-doc-html-require-contains
        index
        "href=\"stdlib.html\">stdlib</a>"
        "doc-site: sidebar root missing")
      (doc_bridge.bridge-doc-html-require-contains
        index
        "href=\"stdlib-smoke.html\""
        "doc-site: module link missing")
      (doc_bridge.bridge-doc-html-require-contains
        index
        "<code>second</code>"
        "doc-site: sidebar module label missing")
      (doc_bridge.bridge-doc-html-require-contains
        index
        "stdlib/smoke&lt;&amp;&gt;.tl"
        "doc-site: index escaping missing")
      (doc_bridge.bridge-doc-html-require-contains
        page
        "<title>TypeLisp API: stdlib/smoke&lt;&amp;&gt;.tl</title>"
        "doc-site: module title missing")
      (doc_bridge.bridge-doc-html-require-contains
        page
        "class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"stdlib-smoke.html\""
        "doc-site: current sidebar link missing")
      (doc_bridge.bridge-doc-html-require-contains
        page
        "<code>smoke&lt;&amp;&gt;</code>"
        "doc-site: sidebar current label escaping missing")
      (doc_bridge.bridge-doc-html-require-contains
        page
        "id=\"tl-stdlib-47smoke-60-38-62-46tl\""
        "doc-site: module anchor missing")
      (doc_bridge.bridge-doc-html-require-contains
        page
        "Smoke module docs mention &lt;api&gt;, &amp; value, and &quot;quote&quot;."
        "doc-site: module docs escaping missing")
      (doc_bridge.bridge-doc-html-require-contains
        page
        "href=\"#tl-doc-site-smoke-value\""
        "doc-site: item anchor link missing")
      (doc_bridge.bridge-doc-html-require-contains
        second-page
        "Second smoke module docs."
        "doc-site: second page missing")
      (doc_bridge.bridge-doc-html-require-contains
        second-page
        "class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"stdlib-second.html\""
        "doc-site: second current sidebar link missing")
      (doc_bridge.bridge-doc-html-require-contains
        language-page
        "<title>TypeLisp Overview</title>"
        "doc-site: language page title missing")
      (doc_bridge.bridge-doc-html-require-contains
        language-page
        "class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"readme.html\""
        "doc-site: language current sidebar link missing")
      (doc_bridge.bridge-doc-html-require-contains
        language-page
        "<h1 id=\"tl-Language-32Reference\">Language Reference</h1>"
        "doc-site: language heading anchor missing")
      (doc_bridge.bridge-doc-html-require-contains
        language-page
        "href=\"spec.html\""
        "doc-site: language spec link rewrite missing")
      (doc_bridge.bridge-doc-html-require-contains
        language-page
        "href=\"stdlib-second.html\""
        "doc-site: language api link rewrite missing")
      (doc_bridge.bridge-doc-html-require-contains
        language-page
        "href=\"https://github.com/JoNil-Botta/typelisp/blob/main/tools/doc-site/doc_site.tl\""
        "doc-site: language repo link rewrite missing")
      (doc_bridge.bridge-doc-html-require-contains
        language-page
        "<pre><code class=\"language-typelisp\">(<span class=\"tl-syn-keyword\">define</span> <span class=\"tl-syn-definition\">answer</span> : <span class=\"tl-syn-type\">i64</span> <span class=\"tl-syn-number\">42</span>)"
        "doc-site: language code fence missing")
      (doc_bridge.bridge-doc-html-require-contains
        (doc-site-css)
        ".tl-syn-keyword"
        "doc-site: syntax css marker missing")
      (doc_bridge.bridge-doc-html-require-contains
        (doc-site-css)
        "color-scheme: dark;"
        "doc-site: dark color-scheme marker missing")
      (doc_bridge.bridge-doc-html-require-contains
        (doc-site-css)
        "background: #0b1120;"
        "doc-site: dark page background missing")
      (doc_bridge.bridge-doc-html-require-contains
        (doc-site-css)
        "background: #164e63;"
        "doc-site: dark current-nav background missing")
      (doc-site-require
        (doc-site-output-list-has-duplicate?
          (let
            [modules : DocSiteModuleList (doc-site-module-list-with-capacity 2)]
            (begin
              (doc-site-module-list-push
                (&mut modules)
                (DocSiteModule.Module "a.tl" "same.html"))
              (doc-site-module-list-push
                (&mut modules)
                (DocSiteModule.Module "b.tl" "same.html"))
              modules)))
        "doc-site: duplicate output detection missing")
      (doc-site-require
        (not (doc-site-expected-manifest-size? (doc-site-module-list-empty)))
        "doc-site: missing manifest detection missing")
      42)))