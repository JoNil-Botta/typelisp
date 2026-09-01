;; doc_local_site.tl - Reusable package-local static documentation site.
;;
;; This composes the generic HTML renderer and search artifact without pulling
;; in the TypeLisp language-guide/bookshelf layer from tools/doc-site.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.vector)
(import doc_html)
(import doc_render)
(import doc_site_search_asset as search_asset)
(import (vector.vector doc_render.DocModule core) as doc_module_vec)

(define (doc-local-site-package-identity
  [package-name : String]
  [package-version : String]) : String
  (str_cat.str-cat package-name "@" package-version))

(define (doc-local-site-source-identity [source-digest : i64]) : String
  (str_cat.str-cat "package-source-v1:" (string.int->string source-digest) ""))

(define (doc-local-site-css) : String
  ":root { color-scheme: light dark; --bg: #f8fafc; --panel: #ffffff; --text: #172033; --muted: #5e6b82; --line: #d7deea; --link: #245fbd; --code: #eef3fb; --accent: #7257d8; }\n@media (prefers-color-scheme: dark) { :root { --bg: #111522; --panel: #181e2d; --text: #edf1f8; --muted: #aab4c7; --line: #343e54; --link: #8dbbff; --code: #20283a; --accent: #b5a2ff; } }\n* { box-sizing: border-box; }\nhtml { scroll-behavior: smooth; }\nbody { margin: 0; color: var(--text); background: var(--bg); font: 16px/1.55 system-ui, sans-serif; }\na { color: var(--link); }\ncode, pre { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }\ncode { overflow-wrap: anywhere; }\npre { overflow-x: auto; padding: 1rem; border: 1px solid var(--line); border-radius: .5rem; background: var(--code); }\n.tl-doc-header { padding: 2rem max(1rem, calc((100% - 72rem) / 2)); color: white; background: linear-gradient(120deg, #334c86, #6748b8); }\n.tl-doc-header h1 { margin: 0; }\n.tl-doc-header p { margin: .35rem 0 0; }\n.tl-doc-build-identity, .tl-doc-search, .tl-doc-module-nav, main { width: min(72rem, calc(100% - 2rem)); margin-inline: auto; }\n.tl-doc-build-identity { color: var(--muted); font-size: .9rem; }\n.tl-doc-search { position: relative; margin-block: 1rem; padding: 1rem; border: 1px solid var(--line); border-radius: .6rem; background: var(--panel); }\n.tl-doc-search label { display: block; font-weight: 650; }\n.tl-doc-search input { width: 100%; margin-top: .5rem; padding: .65rem .75rem; border: 1px solid var(--line); border-radius: .4rem; color: var(--text); background: var(--bg); font: inherit; }\n.tl-doc-search-status { min-height: 1.5rem; margin: .35rem 0 0; color: var(--muted); }\n.tl-doc-search-results { position: absolute; z-index: 2; left: 1rem; right: 1rem; max-height: 24rem; overflow-y: auto; margin: 0; padding: .25rem; border: 1px solid var(--line); border-radius: .4rem; list-style: none; background: var(--panel); box-shadow: 0 .5rem 1.5rem #0003; }\n.tl-doc-search-results a { display: flex; justify-content: space-between; gap: 1rem; padding: .55rem; text-decoration: none; }\n.tl-doc-search-results a:hover, .tl-doc-search-results a:focus { background: var(--code); outline: none; }\n.tl-doc-search-results span { color: var(--muted); font-size: .9rem; text-align: right; }\n.tl-doc-module-nav { margin-block: 1rem; padding: 1rem; border: 1px solid var(--line); border-radius: .6rem; background: var(--panel); }\n.tl-doc-module-nav h2 { margin-top: 0; }\n.tl-doc-module-nav ul, .tl-doc-item-nav ul { columns: 2 18rem; padding-left: 1.25rem; }\nmain { padding-bottom: 4rem; }\n.tl-doc-module { margin-top: 1.25rem; padding: 1.25rem; border: 1px solid var(--line); border-radius: .6rem; background: var(--panel); }\n.tl-doc-module > h2 { margin-top: 0; border-bottom: 1px solid var(--line); padding-bottom: .5rem; }\n.tl-doc-item { margin-top: 1rem; padding-top: 1rem; border-top: 1px solid var(--line); }\n.tl-doc-item h3 { margin-bottom: .35rem; }\n.tl-doc-kind, .tl-doc-source, .tl-doc-empty { color: var(--muted); }\n.tl-doc-meta { display: grid; grid-template-columns: max-content 1fr; gap: .25rem .75rem; }\n.tl-doc-meta dt { font-weight: 650; }\n.tl-doc-meta dd { margin: 0; }\n.tl-syn-comment, .tl-syn-doc-comment { color: #718096; }\n.tl-syn-string { color: #18825b; }\n.tl-syn-number { color: #b44d14; }\n.tl-syn-keyword { color: var(--accent); font-weight: 650; }\n@media (max-width: 40rem) { .tl-doc-search-results a { display: block; } .tl-doc-search-results span { display: block; text-align: left; } }\n")

(define (doc-local-site-search-client) : String
  (search_asset.doc-site-search-client))

(define (doc-local-site-search-records-from
  [modules : doc_module_vec.Vec]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (if (= index 0)
        ""
        ",")
      (doc_html.doc-html-search-records-for-module
        "index.html"
        (doc_render.doc-module-list-ref
          (owned_view.compiler-owned-shared-view modules)
          index))
      (doc-local-site-search-records-from modules (+ index 1) count))))

(define (doc-local-site-search-records [modules : doc_module_vec.Vec]) : String
  (doc-local-site-search-records-from
    (owned_view.compiler-owned-shared-view modules)
    0
    (doc_render.doc-module-list-count modules)))

(define (doc-local-site-search-index
  [compiler-identity : String]
  [source-identity : String]
  [package-identity : String]
  [modules : doc_module_vec.Vec]) : String
  (str_cat.str-cat
    "globalThis.TYPELISP_DOC_SEARCH=Object.freeze({\"schema\":1,\"compilerIdentity\":"
    (doc_html.doc-html-json-string (& compiler-identity))
    ",\"sourceIdentity\":"
    (doc_html.doc-html-json-string (& source-identity))
    ",\"packageIdentity\":"
    (doc_html.doc-html-json-string (& package-identity))
    ",\"records\":Object.freeze(["
    (doc-local-site-search-records modules)
    "])});\n"))

(define (doc-local-site-render-index
  [package-name : String]
  [compiler-identity : String]
  [source-identity : String]
  [package-identity : String]
  [modules : doc_module_vec.Vec]) : String
  (let
    [title : String (str_cat.str-cat package-name " API")]
    (str_cat.str-cat
      (doc_html.doc-html-page-open-with-metadata
        (owned_view.compiler-owned-shared-view title)
        (owned_view.compiler-owned-shared-view compiler-identity)
        (owned_view.compiler-owned-shared-view source-identity)
        (owned_view.compiler-owned-shared-view package-identity))
      (doc_html.doc-html-header
        (owned_view.compiler-owned-shared-view title)
        "package documentation")
      "<p class=\"tl-doc-build-identity\">Package <code>"
      (doc_html.doc-html-escape
        (owned_view.compiler-owned-shared-view package-identity))
      "</code> · compiler <code>"
      (doc_html.doc-html-escape
        (owned_view.compiler-owned-shared-view compiler-identity))
      "</code> · source <code>"
      (doc_html.doc-html-escape
        (owned_view.compiler-owned-shared-view source-identity))
      "</code></p>\n"
      "<div class=\"tl-doc-search\" role=\"search\">\n<label for=\"tl-doc-search-input\">Search documentation <small>(press /)</small></label>\n<input id=\"tl-doc-search-input\" data-doc-search-input type=\"search\" autocomplete=\"off\" aria-controls=\"tl-doc-search-results\" aria-describedby=\"tl-doc-search-status\">\n<p id=\"tl-doc-search-status\" class=\"tl-doc-search-status\" data-doc-search-status aria-live=\"polite\"></p>\n<ul id=\"tl-doc-search-results\" class=\"tl-doc-search-results\" data-doc-search-results hidden></ul>\n</div>\n"
      (doc_html.doc-html-module-nav
        (owned_view.compiler-owned-shared-view modules))
      "<main>\n"
      (doc_html.doc-html-module-sections modules)
      "</main>\n"
      (doc_html.doc-html-page-close))))