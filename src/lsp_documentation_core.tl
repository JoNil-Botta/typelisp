;; Targets join checked declaration facts to an explicit immutable site binding.
;; Source freshness is supplied by the LSP's current overlay/disk provider;
;; neither a displayed signature nor a package name authorizes a URL.
(import compiler_load as load)
(import compiler_semantic_documentation as semantic_docs)
(import doc_extract)
(import doc_render)
(import lsp_documentation_sites as sites)
(import lsp_vector_families)
(import (vector.vector lsp_vector_families.LspDocument core) as document_vec)
(import compiler_semantic_index as semantic)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.vector)
(import stdlib.iterator)
(import stdlib.json)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(defstruct DocumentationTargetRequest
  (compiler String)
  (current-source-sha256 String))

(defstruct DocumentationTarget
  (uri String)
  (data json.Json)
  (definition-index i64))

(defenum MaybeDocumentationTarget
  (Found DocumentationTarget)
  (Missing))

(defstruct SourceDigestCache
  (paths (__tl_dyn-array String))
  (digests (__tl_dyn-array String))
  (len i64))

(define (source-cache [capacity : i64]) : SourceDigestCache
  (SourceDigestCache
    (__tl_make-array String capacity)
    (__tl_make-array String capacity)
    0))

(define (source-digest
  [documents : (& documents document_vec.Vec)]
  [path : (& path str)]) : String
  (let
    [canonical : String (load.compiler-load-canonical-path path)]
    (for [i (iterator.range 0 documents.len)]
      (let
        [document : (& documents lsp_vector_families.LspDocument)
          (& (array-ref documents.slots i))]
        (when
          (and
            (>= document.version 0)
            (string.eq
              (load.compiler-load-canonical-path (& document.path))
              canonical))
          (return (semantic.compiler-semantic-source-sha256 (& document.text))))))
    (match (io.try-read-file (& canonical))
      [(OkIoBytes bytes)
        (let
          [source : String (byte_buf.to-string bytes)]
          (semantic.compiler-semantic-source-sha256 (& source)))]
      [(ErrIoBytes _) ""])))

;; A documentation-link response may contain many uses of the same source.
;; Verify each physical source once in this request, with open buffers taking
;; precedence over disk and without persisting a mutable digest across events.
(define (current-source-digest
  [documents : (& documents document_vec.Vec)]
  [cache : (&mut cache SourceDigestCache)]
  [path : (& path str)]) : String
  (let
    [canonical : String (load.compiler-load-canonical-path path)]
    (for [i (iterator.range 0 cache.len)]
      (when
        (string.eq (array-ref cache.paths i) canonical)
        (return (string.copy (& (array-ref cache.digests i))))))
    (let
      [digest : String (source-digest documents (& canonical))]
      (when
        (< cache.len (array-length cache.paths))
        (set! (array-ref cache.paths cache.len) canonical)
        (set! (array-ref cache.digests cache.len) (string.copy (& digest)))
        (+= cache.len 1))
      digest)))

(define (origin-json [origin : (& origin doc_extract.DocOrigin)]) : json.Json
  (match origin
    [(Source)
      (JsonObject
        (box
          (json.member-cons
            "kind"
            (JsonString "source")
            (json.member-list-empty))))]
    [(Generated generator item key)
      (JsonObject
        (box
          (json.member-cons
            "kind"
            (JsonString "generated")
            (json.member-cons
              "generator"
              (JsonString (string.copy (& generator)))
              (json.member-cons
                "item"
                (JsonString (string.copy (& item)))
                (json.member-cons
                  "key"
                  (JsonString (string.copy (& key)))
                  (json.member-list-empty)))))))]))

(define (make-target
  [site : (& site sites.DocumentationSite)]
  [docs : (& docs semantic_docs.SemanticDocumentation)]
  [anchor : String]) : DocumentationTarget
  (let
    [uri : String
      (str_cat.str-cat
        (string.copy (& site.page-uri))
        "#"
        (string.copy (& anchor)))]
    [member : bool (not (string.eq docs.identity.parent ""))]
    [source : json.Json
      (JsonObject
        (box
          (json.member-cons
            "sha256"
            (JsonString (string.copy (& docs.source-sha256)))
            (json.member-cons
              "path"
              (JsonString (string.copy (& docs.source-path)))
              (json.member-cons
                "line"
                (JsonNumber (string.int->string docs.source-line))
                (json.member-list-empty))))))]
    [fields : json.JsonMemberSeq (json.member-list-empty)]
    (set!
      fields
      (json.member-cons "uri" (JsonString (string.copy (& uri))) fields))
    (set! fields (json.member-cons "anchor" (JsonString anchor) fields))
    (set!
      fields
      (json.member-cons "origin" (origin-json (& docs.identity.origin)) fields))
    (set! fields (json.member-cons "source" source fields))
    (set!
      fields
      (json.member-cons
        "member"
        (if member
          (JsonString (string.copy (& docs.identity.name)))
          JsonNull)
        fields))
    (set!
      fields
      (json.member-cons
        "declaration"
        (JsonString
          (if member
            (string.copy (& docs.identity.parent))
            (string.copy (& docs.identity.name))))
        fields))
    (set!
      fields
      (json.member-cons
        "kind"
        (JsonString (doc_extract.doc-kind-name (& docs.identity.kind)))
        fields))
    (set!
      fields
      (json.member-cons
        "moduleIdentity"
        (JsonString (string.copy (& docs.module)))
        fields))
    (set!
      fields
      (json.member-cons
        "module"
        (JsonString (string.copy (& site.doc-module)))
        fields))
    (set!
      fields
      (json.member-cons
        "sourceIdentity"
        (JsonString (string.copy (& site.source)))
        fields))
    (set!
      fields
      (json.member-cons
        "compilerIdentity"
        (JsonString (string.copy (& site.compiler)))
        fields))
    (set!
      fields
      (json.member-cons
        "packageIdentity"
        (JsonString (string.copy (& site.package)))
        fields))
    (set! fields (json.member-cons "schemaVersion" (JsonNumber "1") fields))
    (DocumentationTarget uri (JsonObject (box fields)) docs.definition-index)))

(define (target
  [bindings : (& bindings sites.DocumentationSites)]
  [docs : (& docs semantic_docs.SemanticDocumentation)]
  [request : DocumentationTargetRequest]) : MaybeDocumentationTarget
  (unless
    (and
      bindings.enabled
      (> bindings.owner-arena 0)
      (sites.hex? request.compiler 40)
      (string.eq request.current-source-sha256 docs.source-sha256))
    (return Missing))
  (let
    [path : String (load.compiler-load-canonical-path (& docs.source-path))]
    [found : i64 -1]
    [selected-anchor : String ""]
    (for [i (iterator.range 0 bindings.len)]
      (let
        [site : (& bindings sites.DocumentationSite)
          (& (array-ref bindings.items i))]
        (when
          (and
            (string.eq site.compiler request.compiler)
            (string.eq site.source-path path)
            (string.eq site.source-sha256 docs.source-sha256)
            (string.eq site.module docs.module))
          (let
            [anchor : String
              (doc_render.doc-render-documentation-anchor
                (& site.doc-module)
                (& docs.identity))]
            (when
              (sites.contains-anchor? site anchor)
              ;; An ambiguous package/site assignment fails closed. Do not let
              ;; mapping order select one same-source package accidentally.
              (when (>= found 0) (return Missing))
              (set! found i)
              (set! selected-anchor anchor))))))
    (if (< found 0)
      Missing
      (Found
        (make-target (& (array-ref bindings.items found)) docs selected-anchor)))))