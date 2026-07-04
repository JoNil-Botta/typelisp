;; doc_site_expand_pages_core.tl - Generated-module API section post-processing.
(import "../../stdlib/io.tl")
(import "../../stdlib/fs.tl")
(import "../../stdlib/string.tl")
(import "../../stdlib/str_cat.tl")
(import "../../src/doc_expand.tl")
(import "../../src/doc_html.tl")

(define doc-site-expand-status-ok : i64
  0)

(define (doc-site-expand-path-join [left : String] [right : String]) : String
  (path-join (& left) (& right)))

(define (doc-site-expand-find-prefix
  [text : String]
  [prefix : String]
  [from : i64]) : i64
  (let
    [i : i64 from]
    [n : i64 (string-length text)]
    [found : i64 n]
    (begin
      (while (and (< i n) (= found n))
        (begin
          (if (doc-string-prefix-at? text prefix i)
            (set! found i)
            unit)
          (set! i (+ i 1))))
      found)))

(define (doc-site-expand-module-list-empty? [modules : DocModuleList]) : bool
  (match modules
    [(DocModuleList.Nil) true]
    [_ false]))

(define (doc-site-expand-generated-sections [source : String]) : String
  (let
    [docs : DocExtraction (doc-extract-file source)]
    (match (doc-expanded-generated-modules-from-source-docs-default source docs)
      [(ResultDocExpandedModules.Ok modules)
        (if (doc-site-expand-module-list-empty? modules)
          ""
          (doc-html-module-sections modules))]
      [(ResultDocExpandedModules.Err message)
        (panic
          (str-cat
            "doc-site-expand: generated docs expansion failed for "
            source
            ": "
            message))])))

(define (doc-site-expand-insert-before-main-close
  [html : String]
  [insert : String]) : String
  (let
    [marker : String "</main>"]
    [n : i64 (string-length html)]
    [idx : i64 (doc-site-expand-find-prefix html marker 0)]
    (if (< idx n)
      (str-cat (substring html 0 idx) insert (substring html idx (- n idx)))
      (str-cat html insert ""))))

(define (doc-site-expand-page
  [site-dir : String]
  [source : String]
  [output : String]) : unit
  (let
    [sections : String (doc-site-expand-generated-sections source)]
    (if (= (string-length sections) 0)
      unit
      (let
        [path : String (doc-site-expand-path-join site-dir output)]
        [status : i64 (read-file-status path)]
        (if (= status doc-site-expand-status-ok)
          (let
            [html : String (read-file path)]
            (if (doc-string-contains? html "generated-module-import")
              unit
              (write-file
                path
                (doc-site-expand-insert-before-main-close html sections))))
          (panic (str-cat "doc-site-expand: missing page: " path "")))))))

(define (doc-site-expand-pages [site-dir : String]) : i64
  (begin
    (doc-site-expand-page site-dir "stdlib/arena.tl" "stdlib-arena.html")
    (doc-site-expand-page site-dir "stdlib/cpu.tl" "stdlib-cpu.html")
    (doc-site-expand-page site-dir "stdlib/env.tl" "stdlib-env.html")
    (doc-site-expand-page site-dir "stdlib/ffi.tl" "stdlib-ffi.html")
    (doc-site-expand-page site-dir "stdlib/fs.tl" "stdlib-fs.html")
    (doc-site-expand-page site-dir "stdlib/hash.tl" "stdlib-hash.html")
    (doc-site-expand-page site-dir "stdlib/hashmap.tl" "stdlib-hashmap.html")
    (doc-site-expand-page site-dir "stdlib/io.tl" "stdlib-io.html")
    (doc-site-expand-page
      site-dir
      "stdlib/byte_buf_core.tl"
      "stdlib-byte-buf-core.html")
    (doc-site-expand-page site-dir "stdlib/json.tl" "stdlib-json.html")
    (doc-site-expand-page site-dir "stdlib/msvc.tl" "stdlib-msvc.html")
    (doc-site-expand-page site-dir "stdlib/process.tl" "stdlib-process.html")
    (doc-site-expand-page site-dir "stdlib/queue.tl" "stdlib-queue.html")
    (doc-site-expand-page site-dir "stdlib/random.tl" "stdlib-random.html")
    (doc-site-expand-page site-dir "stdlib/string.tl" "stdlib-string.html")
    (doc-site-expand-page site-dir "stdlib/test.tl" "stdlib-test.html")
    (doc-site-expand-page site-dir "stdlib/text_buf.tl" "stdlib-text-buf.html")
    (doc-site-expand-page
      site-dir
      "stdlib/text_buf_borrowed.tl"
      "stdlib-text-buf-borrowed.html")
    (doc-site-expand-page site-dir "stdlib/vector.tl" "stdlib-vector.html")
    0))