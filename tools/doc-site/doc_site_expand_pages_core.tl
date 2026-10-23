;; doc_site_expand_pages_core.tl - Generated-module API section post-processing.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.fs)
(import stdlib.string)
(import stdlib.iterator)
(import compiler_owned_view as owned_view)
(import compiler_load)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_typecheck_core as tc)
(import doc_expand)
(import doc_extract)
(import doc_render)
(import doc_html)
(import (vector.vector String) as doc_svec)
(import stdlib.str_cat)
(import stdlib.vector)
(import doc_site_stdlib_manifest as stdlib_manifest)
(import (vector.vector String) as doc_site_name_vec)

(define doc-site-expand-status-ok : i64
  0)
(define doc-site-expand-current-output : String
  "")
(define doc-site-expand-search-records : String
  "")

(define (doc-site-expand-write-text [path : (& path str)] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (doc-site-expand-path-join
  [left : (& left str)]
  [right : (& right str)]) : String
  (fs.path-join left right))

(define (doc-site-expand-prefix-at?
  [text : (& text str)]
  [prefix : (& prefix str)]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (while (and ok (< i prefix-len))
            (if (=
              (string.string-ref text (+ start i))
              (string.string-ref prefix i))
              (set! i (+ i 1))
              (set! ok false)))
          ok)))))

(define (doc-site-expand-find-prefix
  [text : (& text str)]
  [prefix : (& prefix str)]
  [from : i64]) : i64
  (let
    [i : i64 from]
    [n : i64 (string.string-length text)]
    [found : i64 n]
    (while (and (< i n) (= found n))
      (if (doc-site-expand-prefix-at? text prefix i)
        (set! found i)
        unit)
      (set! i (+ i 1)))
    found))

(define (doc-site-expand-string-contains?
  [text : (& text str)]
  [needle : (& needle str)]) : bool
  (< (doc-site-expand-find-prefix text needle 0) (string.string-length text)))

;; Render the compiler's actual expansion, including generator/item/key metadata
;; and member identities. The site must not infer a second generated API surface.
(define (doc-site-expand-generated-sections [source : (& source str)]) : String
  (let
    [modules : doc_expand.ResultDocExpandedModules
      (doc_expand.doc-expanded-generated-modules-from-source-docs-with-state-and-pools-and-intern-state
        (compiler_load.compiler-load-serial-test-session-state)
        (tc.tc-serial-job-state)
        (string.copy source)
        (doc_extract.doc-extract-file (string.copy source))
        (doc_svec.new)
        (ast.ast-node-pool-context-capture-active)
        (ci.intern-compat-state-capture-active))]
    (match modules
      [(Err message) (io.panic message)]
      [(Ok expanded)
        (let
          [sections : String ""]
          (for [i
            (iterator.range
              0
              (doc_render.doc-module-list-count
                (owned_view.compiler-owned-shared-view expanded)))]
            (let
              [module : doc_render.DocModule
                (doc_render.doc-module-list-ref (& expanded) i)]
              [records : String
                (doc_html.doc-html-search-records-for-module
                  (string.copy (& doc-site-expand-current-output))
                  (owned_view.compiler-owned-shared-view module))]
              (unless
                (string.eq records "")
                (set!
                  doc-site-expand-search-records
                  (str_cat.str-cat
                    (string.copy (& doc-site-expand-search-records))
                    ","
                    records)))
              (set!
                sections
                (str_cat.str-cat
                  sections
                  (doc_html.doc-html-module-section module)))))
          sections)])))

(define (doc-site-expand-generated-source? [source : (& source str)]) : bool
  (or
    (string.eq source "stdlib/vector.tl")
    (string.eq source "stdlib/queue.tl")))

(define (doc-site-expand-insert-before-main-close
  [html : (& html str)]
  [insert : String]) : String
  (let
    [marker : String "</main>"]
    [n : i64 (string.string-length html)]
    [idx : i64 (doc-site-expand-find-prefix html marker 0)]
    (if (< idx n)
      (str_cat.str-cat
        (string.substring html 0 idx)
        insert
        (string.substring html idx (- n idx)))
      (str_cat.str-cat html insert ""))))

(define (doc-site-expand-search-index-append
  [site-dir : (& site-dir str)]
  [records : (& records str)]) : unit
  (if (= (string.string-length records) 0)
    unit
    (let
      [path : String
        (doc-site-expand-path-join site-dir "typelisp-docs-search-index.js")]
      [status : i64 (io.read-file-status (string.copy (& path)))]
      (if (= status doc-site-expand-status-ok)
        (let
          [index : String
            (byte_buf.to-string (io.read-file (string.copy (& path))))]
          (if (doc-site-expand-string-contains? (& index) records)
            unit
            (let
              [marker : String "])});"]
              [n : i64 (string.string-length index)]
              [at : i64 (doc-site-expand-find-prefix (& index) (& marker) 0)]
              (if (< at n)
                (doc-site-expand-write-text
                  (& path)
                  (str_cat.str-cat
                    (string.substring index 0 at)
                    (string.copy records)
                    (string.substring index at (- n at))))
                (io.panic
                  "doc-site-expand: malformed typelisp-docs-search-index.js")))))
        (io.panic
          (str_cat.str-cat "doc-site-expand: missing search index: " path ""))))))

(define (doc-site-expand-page-generated
  [site-dir : (& site-dir str)]
  [source : String]
  [output : String]) : unit
  (set! doc-site-expand-current-output (string.copy (& output)))
  (set! doc-site-expand-search-records "")
  (let
    [sections : String (doc-site-expand-generated-sections source)]
    (if (= (string.string-length sections) 0)
      unit
      (let
        [path : String (doc-site-expand-path-join site-dir output)]
        [status : i64 (io.read-file-status (string.copy (& path)))]
        (if (= status doc-site-expand-status-ok)
          (let
            [html : String
              (byte_buf.to-string (io.read-file (string.copy (& path))))]
            (if (doc-site-expand-string-contains?
              (& html)
              "generated-module-import")
              unit
              (doc-site-expand-write-text
                (& path)
                (doc-site-expand-insert-before-main-close (& html) sections)))
            (doc-site-expand-search-index-append
              site-dir
              (& doc-site-expand-search-records)))
          (io.panic (str_cat.str-cat "doc-site-expand: missing page: " path "")))))))

(define (doc-site-expand-page
  [site-dir : (& site-dir str)]
  [source : String]
  [output : String]) : unit
  (if (doc-site-expand-generated-source? (& source))
    (doc-site-expand-page-generated site-dir source output)
    unit))

(define (doc-site-expand-pages [site-dir : (& site-dir str)]) : i64
  (let
    [names : doc_site_name_vec.Vec
      (stdlib_manifest.doc-site-stdlib-module-names)]
    [count : i64 (stdlib_manifest.doc-site-stdlib-module-count (& names))]
    [i : i64 0]
    (while (< i count)
      (let
        [name : String
          (stdlib_manifest.doc-site-stdlib-module-name (& names) i)]
        [source : String
          (stdlib_manifest.doc-site-stdlib-module-source (& name))]
        [output : String (stdlib_manifest.doc-site-stdlib-module-page (& name))]
        (doc-site-expand-page site-dir source output)
        (set! i (+ i 1))))
    0))