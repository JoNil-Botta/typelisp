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
(import doc_site_stdlib_manifest as stdlib_manifest)
(import (vector.vector String) as doc_site_name_vec)

(defenum DocSiteModule
  (Module String String))

(import (vector.vector DocSiteModule core) as doc_site_modules)

(defenum DocSiteGuidePage
  (GuidePage String String String String))

(import (vector.vector DocSiteGuidePage core) as doc_site_guides)

(defenum DocSiteApiTree
  (ApiTree String String doc_site_modules.Vec))

(defenum DocSiteSection
  (Guide String doc_site_guides.Vec)
  (ApiTree DocSiteApiTree))

(import (vector.vector DocSiteSection core) as doc_site_sections)

(define doc-site-status-ok : i64
  0)
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

(define (doc-site-api-tree-modules [tree : DocSiteApiTree]) : doc_site_modules.Vec
  (match tree
    [(DocSiteApiTree.ApiTree _ _ modules) modules]))

(define (doc-site-module-list-empty) : doc_site_modules.Vec
  (doc_site_modules.new))

(define (doc-site-module-list-ref
  [modules : doc_site_modules.Vec]
  [index : i64]) : DocSiteModule
  (doc_site_modules.get (& modules) index (DocSiteModule.Module "" "")))

(define (doc-site-guide-page-list-empty) : doc_site_guides.Vec
  (doc_site_guides.new))

(define (doc-site-guide-page-list-count [guides : doc_site_guides.Vec]) : i64
  (doc_site_guides.len (& guides)))

(define (doc-site-guide-page-list-ref
  [guides : doc_site_guides.Vec]
  [index : i64]) : DocSiteGuidePage
  (doc_site_guides.get
    (& guides)
    index
    (DocSiteGuidePage.GuidePage "" "" "" "")))

(define (doc-site-section-list-empty) : doc_site_sections.Vec
  (doc_site_sections.new))

(define (doc-site-section-list-count [sections : doc_site_sections.Vec]) : i64
  (doc_site_sections.len (& sections)))

(define (doc-site-section-list-ref
  [sections : doc_site_sections.Vec]
  [index : i64]) : DocSiteSection
  (doc_site_sections.get
    (& sections)
    index
    (DocSiteSection.Guide "" (doc-site-guide-page-list-empty))))

(define (doc-site-section-guide-title-eq?
  [section : DocSiteSection]
  [expected : String]) : bool
  (match section
    [(DocSiteSection.Guide title _) (string.eq title expected)]
    [(DocSiteSection.ApiTree _) false]))

(define (doc-site-vector-core-growth-order?) : bool
  (let
    [modules : doc_site_modules.Vec (doc_site_modules.with-capacity 1)]
    [guides : doc_site_guides.Vec (doc_site_guides.with-capacity 1)]
    [sections : doc_site_sections.Vec (doc_site_sections.with-capacity 1)]
    (begin
      (doc_site_modules.push
        (&mut modules)
        (DocSiteModule.Module "first.tl" "first.html"))
      (doc_site_modules.push
        (&mut modules)
        (DocSiteModule.Module "second.tl" "second.html"))
      (doc_site_modules.push
        (&mut modules)
        (DocSiteModule.Module "third.tl" "third.html"))
      (doc_site_guides.push
        (&mut guides)
        (DocSiteGuidePage.GuidePage "First" "first.md" "first.html" "One"))
      (doc_site_guides.push
        (&mut guides)
        (DocSiteGuidePage.GuidePage "Second" "second.md" "second.html" "Two"))
      (doc_site_guides.push
        (&mut guides)
        (DocSiteGuidePage.GuidePage "Third" "third.md" "third.html" "Three"))
      (doc_site_sections.push
        (&mut sections)
        (DocSiteSection.Guide "First" (doc-site-guide-page-list-empty)))
      (doc_site_sections.push
        (&mut sections)
        (DocSiteSection.Guide "Second" (doc-site-guide-page-list-empty)))
      (doc_site_sections.push
        (&mut sections)
        (DocSiteSection.Guide "Third" (doc-site-guide-page-list-empty)))
      (and
        (= (doc_site_modules.len (& modules)) 3)
        (= (doc_site_modules.capacity (& modules)) 4)
        (string.eq
          (doc-site-module-source (doc-site-module-list-ref modules 0))
          "first.tl")
        (string.eq
          (doc-site-module-output (doc-site-module-list-ref modules 2))
          "third.html")
        (= (doc_site_guides.len (& guides)) 3)
        (= (doc_site_guides.capacity (& guides)) 4)
        (string.eq
          (doc-site-guide-title (doc-site-guide-page-list-ref guides 0))
          "First")
        (string.eq
          (doc-site-guide-label (doc-site-guide-page-list-ref guides 2))
          "Three")
        (= (doc_site_sections.len (& sections)) 3)
        (= (doc_site_sections.capacity (& sections)) 4)
        (doc-site-section-guide-title-eq?
          (doc-site-section-list-ref sections 0)
          "First")
        (doc-site-section-guide-title-eq?
          (doc-site-section-list-ref sections 2)
          "Third")))))

(define (doc-site-stdlib-modules) : doc_site_modules.Vec
  (let
    [names : doc_site_name_vec.Vec
      (stdlib_manifest.doc-site-stdlib-module-names)]
    [count : i64 (stdlib_manifest.doc-site-stdlib-module-count (& names))]
    [modules : doc_site_modules.Vec (doc_site_modules.with-capacity count)]
    [i : i64 0]
    (begin
      (while (< i count)
        (let
          [name : String
            (stdlib_manifest.doc-site-stdlib-module-name (& names) i)]
          (begin
            (doc_site_modules.push
              (&mut modules)
              (DocSiteModule.Module
                (stdlib_manifest.doc-site-stdlib-module-source (& name))
                (stdlib_manifest.doc-site-stdlib-module-page (& name))))
            (set! i (+ i 1)))))
      modules)))

(define (doc-site-language-guides) : doc_site_guides.Vec
  (let
    [guides : doc_site_guides.Vec (doc_site_guides.with-capacity 2)]
    (begin
      (doc_site_guides.push
        (&mut guides)
        (DocSiteGuidePage.GuidePage
          "TypeLisp Overview"
          "README.md"
          "readme.html"
          "Overview"))
      (doc_site_guides.push
        (&mut guides)
        (DocSiteGuidePage.GuidePage
          "TypeLisp Language Reference"
          "SPEC.md"
          "spec.html"
          "Specification"))
      guides)))

(define (doc-site-stdlib-api-tree) : DocSiteApiTree
  (DocSiteApiTree.ApiTree "stdlib" "stdlib.html" (doc-site-stdlib-modules)))

;; The getting-started guide is a `.tl` module rather than a Markdown page so
;; that `typelisp doc --test` compiles every example in it. A Markdown guide
;; would be prose the language could drift away from. Refs #5672.
(define (doc-site-guide-modules) : doc_site_modules.Vec
  (let
    [modules : doc_site_modules.Vec (doc_site_modules.with-capacity 1)]
    (begin
      (doc_site_modules.push
        (&mut modules)
        (DocSiteModule.Module "docs/getting_started.tl" "getting-started.html"))
      modules)))

(define (doc-site-guide-api-tree) : DocSiteApiTree
  (DocSiteApiTree.ApiTree "guide" "guide.html" (doc-site-guide-modules)))

(define (doc-site-typelisp-sections) : doc_site_sections.Vec
  (let
    [sections : doc_site_sections.Vec (doc_site_sections.with-capacity 3)]
    (begin
      (doc_site_sections.push
        (&mut sections)
        (DocSiteSection.Guide "Language" (doc-site-language-guides)))
      (doc_site_sections.push
        (&mut sections)
        (DocSiteSection.ApiTree (doc-site-guide-api-tree)))
      (doc_site_sections.push
        (&mut sections)
        (DocSiteSection.ApiTree (doc-site-stdlib-api-tree)))
      sections)))

(define (doc-site-module-list-count [modules : doc_site_modules.Vec]) : i64
  (doc_site_modules.len (& modules)))

(define (doc-site-output-in-list-from?
  [output : String]
  [modules : doc_site_modules.Vec]
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

(define (doc-site-output-list-has-duplicate? [modules : doc_site_modules.Vec]) : bool
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

;; Completeness against stdlib/ is a filesystem question, and
;; scripts/verify-doc-site.sh answers it by comparing the generated pages with
;; stdlib/*.tl. What the builder can still catch on its own is an empty manifest,
;; which would publish an API tree with no modules under it.
(define (doc-site-manifest-populated? [modules : doc_site_modules.Vec]) : bool
  (> (doc-site-module-list-count modules) 0))

(define (doc-site-panic-unit [message : String]) : unit
  (io.panic message))

(define (doc-site-validate-stdlib-manifest [modules : doc_site_modules.Vec]) : unit
  (if (not (doc-site-manifest-populated? modules))
    (doc-site-panic-unit "doc-site: empty stdlib manifest")
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
  [guides : doc_site_guides.Vec]) : String
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
  [modules : doc_site_modules.Vec]) : String
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
  [sections : doc_site_sections.Vec]) : String
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
  [sections : doc_site_sections.Vec]
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
  [sections : doc_site_sections.Vec]
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

(define (doc-site-index-module-entries [modules : doc_site_modules.Vec]) : String
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

(define (doc-site-index-guide-entries [guides : doc_site_guides.Vec]) : String
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
  [guides : doc_site_guides.Vec]) : String
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

(define (doc-site-render-index-sections [sections : doc_site_sections.Vec]) : String
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
  [guides : doc_site_guides.Vec]
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
  [modules : doc_site_modules.Vec]
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
  [guides : doc_site_guides.Vec]
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
  [sections : doc_site_sections.Vec]
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

(define (doc-site-sidebar [sections : doc_site_sections.Vec] [current : String]) : String
  (str_cat.str-cat
    "<nav class=\"tl-doc-stdlib-sidebar\" aria-label=\"Documentation tree\">\n<ul class=\"tl-doc-stdlib-tree\">\n"
    (doc-site-sidebar-sections sections current)
    "</ul>\n</nav>\n"
    ""
    ""))

(define (doc-site-render-page
  [title : String]
  [subtitle : String]
  [sections : doc_site_sections.Vec]
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
  [sections : doc_site_sections.Vec]
  [current : String]) : String
  (doc-site-render-page
    "TypeLisp Docs"
    "language guides and API reference"
    sections
    current
    (doc-site-render-index-sections sections)))

(define (doc-site-render-guide-page
  [sections : doc_site_sections.Vec]
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
  [sections : doc_site_sections.Vec]
  [tree : DocSiteApiTree]) : String
  (doc-site-render-page
    (str_cat.str-cat "TypeLisp API: " (doc-site-api-tree-root tree) "")
    (doc-site-api-tree-root tree)
    sections
    (doc-site-api-tree-output tree)
    (doc-site-render-api-index-section tree)))

(define (doc-site-render-module-page
  [sections : doc_site_sections.Vec]
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
  [sections : doc_site_sections.Vec]
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
  [sections : doc_site_sections.Vec]
  [remaining : doc_site_modules.Vec]) : unit
  (let
    [i : i64 0]
    [n : i64 (doc-site-module-list-count remaining)]
    (while (< i n)
      (let
        [module : DocSiteModule (doc-site-module-list-ref remaining i)]
        (begin
          (with-arena
            page
            (doc-site-write-module-page output-dir sections module))
          (set! i (+ i 1)))))))

(define (doc-site-write-guide-page
  [output-dir : String]
  [sections : doc_site_sections.Vec]
  [guide : DocSiteGuidePage]) : unit
  (doc-site-write-file
    (doc-site-path-join output-dir (doc-site-guide-output guide))
    (doc-site-render-guide-page
      sections
      guide
      (doc-site-read-markdown (doc-site-guide-source guide)))))

(define (doc-site-write-guide-pages
  [output-dir : String]
  [sections : doc_site_sections.Vec]
  [guides : doc_site_guides.Vec]) : unit
  (let
    [i : i64 0]
    [n : i64 (doc-site-guide-page-list-count guides)]
    (while (< i n)
      (let
        [guide : DocSiteGuidePage (doc-site-guide-page-list-ref guides i)]
        (begin
          (with-arena
            page
            (doc-site-write-guide-page output-dir sections guide))
          (set! i (+ i 1)))))))

(define (doc-site-write-api-tree
  [output-dir : String]
  [sections : doc_site_sections.Vec]
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
  [sections : doc_site_sections.Vec]
  [section : DocSiteSection]) : unit
  (match section
    [(DocSiteSection.Guide _ guides)
      (doc-site-write-guide-pages output-dir sections guides)]
    [(DocSiteSection.ApiTree tree)
      (doc-site-write-api-tree output-dir sections tree)]))

(define (doc-site-write-sections
  [output-dir : String]
  [sections : doc_site_sections.Vec]
  [remaining : doc_site_sections.Vec]) : unit
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
    [sections : doc_site_sections.Vec (doc-site-typelisp-sections)]
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

(define (doc-site-smoke-modules) : doc_site_modules.Vec
  (let
    [modules : doc_site_modules.Vec (doc_site_modules.with-capacity 2)]
    (begin
      (doc_site_modules.push
        (&mut modules)
        (DocSiteModule.Module "stdlib/smoke<&>.tl" "stdlib-smoke.html"))
      (doc_site_modules.push
        (&mut modules)
        (DocSiteModule.Module "stdlib/second.tl" "stdlib-second.html"))
      modules)))

(define (doc-site-smoke-guides) : doc_site_guides.Vec
  (let
    [guides : doc_site_guides.Vec (doc_site_guides.with-capacity 2)]
    (begin
      (doc_site_guides.push
        (&mut guides)
        (DocSiteGuidePage.GuidePage
          "TypeLisp Overview"
          "README.md"
          "readme.html"
          "Overview"))
      (doc_site_guides.push
        (&mut guides)
        (DocSiteGuidePage.GuidePage
          "TypeLisp Language Reference"
          "SPEC.md"
          "spec.html"
          "Specification"))
      guides)))

(define (doc-site-smoke-api-tree) : DocSiteApiTree
  (DocSiteApiTree.ApiTree "stdlib" "stdlib.html" (doc-site-smoke-modules)))

(define (doc-site-smoke-sections) : doc_site_sections.Vec
  (let
    [sections : doc_site_sections.Vec (doc_site_sections.with-capacity 2)]
    (begin
      (doc_site_sections.push
        (&mut sections)
        (DocSiteSection.Guide "Language" (doc-site-smoke-guides)))
      (doc_site_sections.push
        (&mut sections)
        (DocSiteSection.ApiTree (doc-site-smoke-api-tree)))
      sections)))

(define (doc-site-require [ok : bool] [message : String]) : bool
  (if ok
    true
    (io.panic message)))

(define (doc-site-smoke) : i64
  (let
    [sections : doc_site_sections.Vec (doc-site-smoke-sections)]
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
      (doc-site-require
        (doc-site-vector-core-growth-order?)
        "doc-site: canonical vector core growth/order mismatch")
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
            [modules : doc_site_modules.Vec (doc_site_modules.with-capacity 2)]
            (begin
              (doc_site_modules.push
                (&mut modules)
                (DocSiteModule.Module "a.tl" "same.html"))
              (doc_site_modules.push
                (&mut modules)
                (DocSiteModule.Module "b.tl" "same.html"))
              modules)))
        "doc-site: duplicate output detection missing")
      (doc-site-require
        (not (doc-site-manifest-populated? (doc-site-module-list-empty)))
        "doc-site: empty manifest detection missing")
      (doc-site-require
        (doc-site-manifest-populated? (doc-site-stdlib-modules))
        "doc-site: stdlib manifest is empty")
      (doc-site-require
        (not (doc-site-output-list-has-duplicate? (doc-site-stdlib-modules)))
        "doc-site: stdlib manifest has a duplicate or reserved output")
      42)))