;; doc_site_stdlib_manifest.tl - The single in-tree list of published stdlib
;; modules.
;;
;; The site builder (doc_site_core.tl) and the generated-module expansion pass
;; (doc_site_expand_pages_core.tl) are separate programs that must publish the
;; same set of pages under the same names. Both read this list, and both derive
;; the source path and the output page name from the module name, so they cannot
;; drift apart or disagree about a filename.
;;
;; Every top-level stdlib/*.tl module is published, including the internal twins
;; such as byte_buf_core and io_core: those are importable modules that already
;; carry ;# and ;: documentation, which scripts/verify-stdlib-docs.sh requires.
;; There are no exclusions.
;;
;; scripts/verify-doc-site.sh compares the generated stdlib-*.html pages against
;; stdlib/*.tl, so adding a stdlib module without adding it here fails CI instead
;; of silently missing the site.
(import stdlib.string)
(import stdlib.str_cat)
(import stdlib.test)
(import stdlib.vector)
(import (vector.vector String) as doc_site_manifest_names)

;; Growth hint only. The published module count is the list's own length, so
;; there is no second copy of it to keep in sync.
(define doc-site-stdlib-manifest-capacity : i64
  64)

(define (doc-site-stdlib-module-names) : doc_site_manifest_names.Vec
  (let
    [names : doc_site_manifest_names.Vec
      (doc_site_manifest_names.with-capacity doc-site-stdlib-manifest-capacity)]
    (begin
      (doc_site_manifest_names.push (&mut names) "arena")
      (doc_site_manifest_names.push (&mut names) "args")
      (doc_site_manifest_names.push (&mut names) "array")
      (doc_site_manifest_names.push (&mut names) "atomic")
      (doc_site_manifest_names.push (&mut names) "byte_buf")
      (doc_site_manifest_names.push (&mut names) "byte_buf_core")
      (doc_site_manifest_names.push (&mut names) "clone")
      (doc_site_manifest_names.push (&mut names) "comptime")
      (doc_site_manifest_names.push (&mut names) "core_macros")
      (doc_site_manifest_names.push (&mut names) "cpu")
      (doc_site_manifest_names.push (&mut names) "env")
      (doc_site_manifest_names.push (&mut names) "eq")
      (doc_site_manifest_names.push (&mut names) "ffi")
      (doc_site_manifest_names.push (&mut names) "format")
      (doc_site_manifest_names.push (&mut names) "fs")
      (doc_site_manifest_names.push (&mut names) "hash")
      (doc_site_manifest_names.push (&mut names) "hashmap")
      (doc_site_manifest_names.push (&mut names) "io")
      (doc_site_manifest_names.push (&mut names) "io_caller_result")
      (doc_site_manifest_names.push (&mut names) "io_core")
      (doc_site_manifest_names.push (&mut names) "iterator")
      (doc_site_manifest_names.push (&mut names) "json")
      (doc_site_manifest_names.push (&mut names) "math")
      (doc_site_manifest_names.push (&mut names) "msvc")
      (doc_site_manifest_names.push (&mut names) "option")
      (doc_site_manifest_names.push (&mut names) "process")
      (doc_site_manifest_names.push (&mut names) "process_borrowed")
      (doc_site_manifest_names.push (&mut names) "process_runtime")
      (doc_site_manifest_names.push (&mut names) "profile")
      (doc_site_manifest_names.push (&mut names) "queue")
      (doc_site_manifest_names.push (&mut names) "random")
      (doc_site_manifest_names.push (&mut names) "result")
      (doc_site_manifest_names.push (&mut names) "runtime")
      (doc_site_manifest_names.push (&mut names) "serialize")
      (doc_site_manifest_names.push (&mut names) "set")
      (doc_site_manifest_names.push (&mut names) "sort")
      (doc_site_manifest_names.push (&mut names) "str_cat")
      (doc_site_manifest_names.push (&mut names) "str_cat_runtime")
      (doc_site_manifest_names.push (&mut names) "string")
      (doc_site_manifest_names.push (&mut names) "string_caller_result")
      (doc_site_manifest_names.push (&mut names) "sync")
      (doc_site_manifest_names.push (&mut names) "test")
      (doc_site_manifest_names.push (&mut names) "text_buf")
      (doc_site_manifest_names.push (&mut names) "text_buf_borrowed")
      (doc_site_manifest_names.push (&mut names) "text_buf_family")
      (doc_site_manifest_names.push (&mut names) "thread")
      (doc_site_manifest_names.push (&mut names) "time")
      (doc_site_manifest_names.push (&mut names) "vector")
      (doc_site_manifest_names.push (&mut names) "vector_slice")
      names)))

(define (doc-site-stdlib-module-count
  [names : (& names doc_site_manifest_names.Vec)]) : i64
  (doc_site_manifest_names.len names))

(define (doc-site-stdlib-module-name
  [names : (& names doc_site_manifest_names.Vec)]
  [index : i64]) : String
  (doc_site_manifest_names.get names index ""))

;; Repository-relative source path for a published module.
(define (doc-site-stdlib-module-source [name : (& name str)]) : String
  (str_cat.str-cat "stdlib/" name ".tl"))

;; Module names separate words with `_`; the published page names use `-`, which
;; is the convention every existing stdlib page already follows.
(define (doc-site-stdlib-hyphenate [text : String]) : String
  (if (string.contains-char (& text) '_')
    (doc-site-stdlib-hyphenate (string.replace text "_" "-"))
    text))

;; Output page name for a published module.
(define (doc-site-stdlib-module-page [name : (& name str)]) : String
  (str_cat.str-cat
    "stdlib-"
    (doc-site-stdlib-hyphenate (string.copy name))
    ".html"))

(test
  doc-site-stdlib-manifest-derives-paths
  (let
    [names : doc_site_manifest_names.Vec (doc-site-stdlib-module-names)]
    [first : String (doc-site-stdlib-module-name (& names) 0)]
    [source : String (doc-site-stdlib-module-source "arena")]
    [page : String (doc-site-stdlib-module-page "arena")]
    [twin : String (doc-site-stdlib-hyphenate "byte_buf_core")]
    [nested : String (doc-site-stdlib-module-page "text_buf_borrowed")]
    [tail : String (doc-site-stdlib-module-source "vector_slice")]
    (begin
      ;; Every top-level stdlib module is published; bump this with the list.
      (test.assert-i64-eq
        (doc-site-stdlib-module-count (& names))
        49
        "doc-site stdlib manifest module count")
      (test.assert-string-eq (& first) "arena" "doc-site manifest first module")
      (test.assert-string-eq
        (& source)
        "stdlib/arena.tl"
        "doc-site manifest source path")
      (test.assert-string-eq
        (& page)
        "stdlib-arena.html"
        "doc-site manifest page name")
      (test.assert-string-eq
        (& twin)
        "byte-buf-core"
        "doc-site manifest hyphenation")
      (test.assert-string-eq
        (& nested)
        "stdlib-text-buf-borrowed.html"
        "doc-site manifest multi-word page name")
      (test.assert-string-eq
        (& tail)
        "stdlib/vector_slice.tl"
        "doc-site manifest underscored source path"))))