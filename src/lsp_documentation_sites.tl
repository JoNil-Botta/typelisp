;; Exact documentation-site bindings have the initialize-to-shutdown lifetime,
;; independent of document snapshots. All retained strings are copied here.
(import compiler_load as load)
(import compiler_owned_view as owned_view)
(import stdlib.iterator)
(import stdlib.json)
(import stdlib.net.url)
(import stdlib.sort)
(import stdlib.vector)
(import (stdlib.vector.vector String) as anchor_vec)
(import (stdlib.sort.vec String) as anchor_sort)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(defstruct DocumentationSite
  (package String)
  (source String)
  (compiler String)
  (source-path String)
  (source-sha256 String)
  (module String)
  (doc-module String)
  (page-uri String)
  (anchors anchor_vec.Vec))

(defstruct DocumentationSites
  (owner-arena i64)
  (enabled bool)
  (items (__tl_dyn-array DocumentationSite))
  (len i64))

(defenum ResultDocumentationSites
  (Ok DocumentationSites)
  (Err String))

(define (empty [enabled : bool]) : DocumentationSites
  (DocumentationSites 0 enabled (__tl_make-array DocumentationSite 0) 0))

(define (field [value : (& value json.Json)] [key : (& key str)]) : json.Json
  (match (json.object-get
    (owned_view.compiler-owned-reference-shared-view value)
    key)
    [(JsonFound result) result]
    [(JsonMissing) JsonNull]))

(define (text [value : (& value json.Json)] [key : (& key str)]) : String
  (match (field value key)
    [(JsonString result) (string.copy (& result))]
    [_ ""]))

(define (text-field?
  [value : (& value json.Json)]
  [key : (& key str)]
  [optional : bool]) : bool
  (match (json.object-get
    (owned_view.compiler-owned-reference-shared-view value)
    key)
    [(JsonFound result)
      (match result
        [(JsonString _) true]
        [_ false])]
    [(JsonMissing) optional]))

(define (hex? [value : (& value str)] [length : i64]) : bool
  (unless (= (string.string-length value) length) (return false))
  (for [i (iterator.range 0 length)]
    (let
      [c : char (string.string-ref value i)]
      (unless
        (or (and (>= c '0') (<= c '9')) (and (>= c 'a') (<= c 'f')))
        (return false))))
  true)

(define (immutable-hosted-uri?
  [uri : (& uri str)]
  [revision : (& revision str)]) : bool
  (unless (hex? revision 40) (return false))
  (match (url.parse-http-url uri (url.default-url-limits))
    [(HttpUrlErr _) false]
    [(HttpUrlOk parsed)
      (and
        (match parsed.scheme
          [(HttpSchemeHttps) true]
          [_ false])
        (not (url.url-part-present? (& parsed.query)))
        (not (url.url-part-present? (& parsed.fragment)))
        ;; Check normalized path segments, so an encoded dot segment or a
        ;; query cannot supply a revision that the actual page path discards.
        (string.contains
          parsed.path
          (str_cat.str-cat "/" (string.copy revision) "/"))
        (not (string.contains parsed.path "/main/"))
        (not (string.contains parsed.path "/master/"))
        (not (string.contains parsed.path "/HEAD/")))]))

(define (uri-bytes-valid? [uri : (& uri str)]) : bool
  (for [i (iterator.range 0 (string.string-length uri))]
    (let
      [c : char (string.string-ref uri i)]
      (when
        (or
          (<= (cast c : i64) 32)
          (= (cast c : i64) 127)
          (= c '"')
          (= c '<')
          (= c '>')
          (= c '\\'))
        (return false))))
  true)

(define (parse-bindings [bindings : (& bindings json.JsonSeq)] [owner : i64]) : ResultDocumentationSites
  (let
    [count : i64 (json.list-count-ref bindings)]
    [items : (__tl_dyn-array DocumentationSite)
      (__tl_make-array DocumentationSite count)]
    (for [i (iterator.range 0 count)]
      (let
        [binding : (& bindings json.Json) (& (array-ref bindings.slots i))]
        (unless
          (and
            (text-field? binding "packageIdentity" false)
            (text-field? binding "sourceIdentity" false)
            (text-field? binding "compilerIdentity" false)
            (text-field? binding "sourcePath" false)
            (text-field? binding "sourceSha256" false)
            (text-field? binding "moduleIdentity" false)
            (text-field? binding "docModule" false)
            (text-field? binding "localUri" true)
            (text-field? binding "hostedUri" true)
            (text-field? binding "revision" true))
          (return
            (Err
              "lsp: documentationSites requires exact string identity and source fields")))
        (let
          [package : String (text binding "packageIdentity")]
          [source : String (text binding "sourceIdentity")]
          [compiler : String (text binding "compilerIdentity")]
          [path : String (text binding "sourcePath")]
          [digest : String (text binding "sourceSha256")]
          [module : String (text binding "moduleIdentity")]
          [doc-module : String (text binding "docModule")]
          [local : String (text binding "localUri")]
          [hosted : String (text binding "hostedUri")]
          [revision : String (text binding "revision")]
          (when
            (or
              (string.eq package "")
              (string.eq source "")
              (not (hex? compiler 40))
              (string.eq source "main")
              (string.eq source "master")
              (string.eq source "HEAD")
              (string.eq path "")
              (string.eq doc-module "")
              (not (hex? digest 64)))
            (return
              (Err
                "lsp: documentationSites requires nonempty exact identities and a lowercase source SHA256")))
          (when
            (and (string.eq local "") (string.eq hosted ""))
            (return
              (Err
                "lsp: documentationSites requires localUri or immutable hostedUri")))
          (unless
            (and (uri-bytes-valid? local) (uri-bytes-valid? hosted))
            (return
              (Err
                "lsp: documentationSites URIs must escape spaces, controls and markup delimiters")))
          (when
            (and
              (not (string.eq local ""))
              (or
                (not (string.is-string-prefix-at local "file://" 0))
                (string.contains local "#")))
            (return
              (Err
                "lsp: documentationSites localUri must be a file URI without a fragment")))
          (when
            (and
              (not (string.eq hosted ""))
              (not (immutable-hosted-uri? hosted revision)))
            (return
              (Err
                "lsp: documentationSites hostedUri must contain its exact 40-hex revision path")))
          (match (field binding "anchors")
            [(JsonArray values-box)
              (let
                [values : (& values-box json.JsonSeq)
                  (& (__tl-box-place values-box))]
                [length : i64 (json.list-count-ref values)]
                [anchors : anchor_vec.Vec (anchor_vec.with-capacity length)]
                (for [j (iterator.range 0 length)]
                  (match (owned_view.compiler-owned-array-element-shared-view
                    values.slots
                    j)
                    [(JsonString anchor)
                      (unless
                        (string.is-string-prefix-at anchor "tl-" 0)
                        (return
                          (Err
                            "lsp: documentationSites anchors must be canonical documentation identities")))
                      (anchor_vec.push-ref!
                        (&mut anchors)
                        (string.copy (& anchor)))]
                    [_
                      (return
                        (Err
                          "lsp: documentationSites anchors must contain strings"))]))
                (anchor_sort.sort! (&mut anchors) sort.string-less?)
                (set!
                  (array-ref items i)
                  (DocumentationSite
                    package
                    source
                    compiler
                    (load.compiler-load-canonical-path path)
                    digest
                    module
                    doc-module
                    (if (string.eq local "")
                      hosted
                      local)
                    anchors)))]
            [_
              (return (Err "lsp: documentationSites anchors must be an array"))]))))
    (Ok (DocumentationSites owner true items count))))

(define (contains-anchor?
  [site : (& site DocumentationSite)]
  [anchor : (& anchor str)]) : bool
  (let
    [low : i64 0]
    [high : i64 (anchor_vec.len (& site.anchors))]
    [slots : (& site (__tl_dyn-array String))
      (anchor_vec.slots (& site.anchors))]
    (while (< low high)
      (let
        [middle : i64 (+ low (/ (- high low) 2))]
        [value : (& site str) (& (array-ref slots middle))]
        (cond
          [(string.eq value anchor) (return true)]
          [(sort.string-less-borrowed? value anchor) (set! low (+ middle 1))]
          [else (set! high middle)])))
    false))