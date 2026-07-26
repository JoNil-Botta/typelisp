;; doc_site_stdlib_manifest.tl - The derived set of published stdlib modules.
;;
;; The site builder (doc_site_core.tl) and the generated-module expansion pass
;; (doc_site_expand_pages_core.tl) are separate programs that must publish the
;; same set of pages under the same names. Both read this directory-derived
;; manifest, and both derive the source path and output page name from the
;; module name, so they cannot drift apart or disagree about a filename.
;;
;; Every top-level stdlib/*.tl module is published, including the internal twins
;; such as byte_buf_core and io_core: those are importable modules that already
;; carry ;# and ;: documentation, which scripts/verify-stdlib-docs.sh requires.
;; There are no exclusions.
;;
;; scripts/verify-doc-site.sh compares the generated stdlib-*.html pages against
;; stdlib/*.tl, so it catches either a broken walk or stale generated output.
(import stdlib.fs)
(import stdlib.io)
(import stdlib.sort)
(import stdlib.string)
(import stdlib.str_cat)
(import stdlib.test)
(import stdlib.vector)
(import (vector.vector String) as doc_site_manifest_names)
(import (sort.vec String) as doc_site_manifest_sort)

(define doc-site-stdlib-dir : String
  "stdlib")
(define doc-site-stdlib-module-suffix : String
  ".tl")

(define (doc-site-stdlib-module-file? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (< n 4)
      false
      (string.eq
        (string.substring name (- n 3) 3)
        doc-site-stdlib-module-suffix))))

(define (doc-site-stdlib-module-stem [name : String]) : String
  (string.substring name 0 (- (string.string-length name) 3)))

(define (doc-site-stdlib-module-names) : doc_site_manifest_names.Vec
  (let
    [dir : String doc-site-stdlib-dir]
    (match (fs.try-read-dir (& dir))
      [(fs.OkIoStringVector entries)
        (let
          [names : doc_site_manifest_names.Vec (doc_site_manifest_names.new)]
          [i : i64 0]
          [n : i64 (fs.string-vector-len (& entries))]
          (begin
            (while (< i n)
              (let
                [file : String (fs.string-vector-get (& entries) i "")]
                (begin
                  (if (doc-site-stdlib-module-file? file)
                    (doc_site_manifest_names.push
                      (&mut names)
                      (doc-site-stdlib-module-stem file))
                    unit)
                  (set! i (+ i 1)))))
            ;; Host directory order is not stable. Sorting the stems keeps the
            ;; sidebar, index, expansion pass, and generated files reproducible.
            (doc_site_manifest_sort.sort! (&mut names) sort.string-less?)
            names))]
      [(fs.ErrIoStringVector _)
        (io.panic
          (str_cat.str-cat
            "doc-site: could not read stdlib module directory: "
            dir))])))

(define (doc-site-stdlib-module-count
  [names : (& names doc_site_manifest_names.Vec)]) : i64
  (doc_site_manifest_names.len names))

(define (doc-site-stdlib-module-name
  [names : (& names doc_site_manifest_names.Vec)]
  [index : i64]) : String
  (doc_site_manifest_names.get names index ""))

(define (doc-site-stdlib-module-names-strictly-sorted?
  [names : (& names doc_site_manifest_names.Vec)]) : bool
  (let
    [i : i64 1]
    [n : i64 (doc-site-stdlib-module-count names)]
    [sorted : bool true]
    (begin
      (while (and sorted (< i n))
        (let
          [previous : String (doc-site-stdlib-module-name names (- i 1))]
          [current : String (doc-site-stdlib-module-name names i)]
          (begin
            (if (sort.string-less? previous current)
              unit
              (set! sorted false))
            (set! i (+ i 1)))))
      sorted)))

(define (doc-site-stdlib-module-names-contain?
  [names : (& names doc_site_manifest_names.Vec)]
  [target : (& target str)]) : bool
  (let
    [i : i64 0]
    [n : i64 (doc-site-stdlib-module-count names)]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (begin
          (if (string.eq (doc-site-stdlib-module-name names i) target)
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

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
    [source : String (doc-site-stdlib-module-source "arena")]
    [page : String (doc-site-stdlib-module-page "arena")]
    [twin : String (doc-site-stdlib-hyphenate "byte_buf_core")]
    [nested : String (doc-site-stdlib-module-page "text_buf_borrowed")]
    [tail : String (doc-site-stdlib-module-source "vector_slice")]
    [stem : String (doc-site-stdlib-module-stem "text_buf_borrowed.tl")]
    (begin
      ;; This test intentionally runs from the repository root. The builder
      ;; already has the same working-directory contract when it opens sources.
      (test.assert-true
        (> (doc-site-stdlib-module-count (& names)) 0)
        "doc-site derived stdlib module set is populated")
      (test.assert-true
        (doc-site-stdlib-module-names-strictly-sorted? (& names))
        "doc-site derived stdlib module set is sorted and duplicate-free")
      (test.assert-true
        (doc-site-stdlib-module-names-contain? (& names) "io")
        "doc-site derived stdlib modules include io")
      (test.assert-true
        (doc-site-stdlib-module-names-contain? (& names) "str_cat")
        "doc-site derived stdlib modules include str_cat")
      (test.assert-true
        (doc-site-stdlib-module-names-contain? (& names) "byte_buf")
        "doc-site derived stdlib modules include byte_buf")
      (test.assert-true
        (doc-site-stdlib-module-names-contain? (& names) "thread")
        "doc-site derived stdlib modules include thread")
      (test.assert-true
        (doc-site-stdlib-module-names-contain? (& names) "sync")
        "doc-site derived stdlib modules include sync")
      (test.assert-true
        (doc-site-stdlib-module-file? "byte_buf_core.tl")
        "doc-site module file detection")
      (test.assert-false
        (doc-site-stdlib-module-file? "README.md")
        "doc-site rejects non-tl entries")
      (test.assert-false
        (doc-site-stdlib-module-file? ".tl")
        "doc-site rejects extension-only entries")
      (test.assert-string-eq
        (& stem)
        "text_buf_borrowed"
        "doc-site module stem")
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