;; Checked source facts, generated HTML identities and protocol mappings must
;; agree without retaining request, document or site-owner arena storage.
(import compiler_owned_view as owned_view)
(import compiler_semantic_documentation as semantic_docs)
(import compiler_semantic_index as semantic)
(import compiler_semantic_index_tests as semantic_tests)
(import doc_extract)
(import doc_render)
(import lsp_documentation_core as targets)
(import lsp_documentation_sites as sites)
(import lsp_frame_core as lsp)
(import lsp_vector_families as lvf)
(import (vector.vector lvf.LspDocument core) as document_vec)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.fs)
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.json)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import (vector.vector doc_extract.DocItem core) as doc_item_vec)

(define test-compiler : String
  "dddddddddddddddddddddddddddddddddddddddd")

(define (initialize-message [bindings : json.JsonSeq]) : json.Json
  (lsp.lsp-json-object1
    "params"
    (lsp.lsp-json-object2
      "capabilities"
      (lsp.lsp-json-object1
        "experimental"
        (lsp.lsp-json-object1 "typelispDocumentationTargets" (JsonBool true)))
      "initializationOptions"
      (lsp.lsp-json-object1
        "typelisp"
        (lsp.lsp-json-object1 "documentationSites" (JsonArray (box bindings)))))))

(define (binding
  [docs : (& docs semantic_docs.SemanticDocumentation)]
  [anchor : String]) : json.Json
  (let
    [fields : json.JsonMemberSeq (json.member-list-empty)]
    (set!
      fields
      (json.member-cons "packageIdentity" (JsonString "package-one@v1") fields))
    (set!
      fields
      (json.member-cons
        "sourceIdentity"
        (JsonString "source-sha256:1111")
        fields))
    (set!
      fields
      (json.member-cons
        "compilerIdentity"
        (JsonString (string.copy (& test-compiler)))
        fields))
    (set!
      fields
      (json.member-cons
        "sourcePath"
        (JsonString (string.copy (& docs.source-path)))
        fields))
    (set!
      fields
      (json.member-cons
        "sourceSha256"
        (JsonString (string.copy (& docs.source-sha256)))
        fields))
    (set!
      fields
      (json.member-cons
        "moduleIdentity"
        (JsonString (string.copy (& docs.module)))
        fields))
    (set!
      fields
      (json.member-cons "docModule" (JsonString "pkg/api.tl") fields))
    (set!
      fields
      (json.member-cons
        "localUri"
        (JsonString "file:///docs/one/api.html")
        fields))
    (set!
      fields
      (json.member-cons
        "hostedUri"
        (JsonString
          "https://docs.example/dddddddddddddddddddddddddddddddddddddddd/api.html")
        fields))
    (set!
      fields
      (json.member-cons
        "revision"
        (JsonString (string.copy (& test-compiler)))
        fields))
    (set!
      fields
      (json.member-cons
        "anchors"
        (JsonArray (box (json.list-cons (JsonString anchor) (json.list-empty))))
        fields))
    (JsonObject (box fields))))

(define (replace-field
  [value : json.Json]
  [key : String]
  [replacement : json.Json]) : json.Json
  (match value
    [(JsonObject members)
      (let
        [fields : (& members json.JsonMemberSeq) (& (__tl-box-place members))]
        [result : json.JsonMemberSeq (json.member-list-empty)]
        (for [i (iterator.range 0 fields.len)]
          (let
            [member : json.JsonMember (clone (array-ref fields.slots i))]
            (unless
              (string.eq member.key key)
              (set! result (json.member-cons member.key member.value result)))))
        (JsonObject (box (json.member-cons key replacement result))))]
    [_ JsonNull]))

(define (parse-one [value : json.Json]) : sites.ResultDocumentationSites
  (let
    [message : json.Json
      (initialize-message (json.list-cons value (json.list-empty)))]
    (lsp.lsp-documentation-sites-initialize (& message))))

(define (request [digest : String]) : targets.DocumentationTargetRequest
  (targets.DocumentationTargetRequest (string.copy (& test-compiler)) digest))

(define (missing?
  [bindings : (& bindings sites.DocumentationSites)]
  [docs : (& docs semantic_docs.SemanticDocumentation)]
  [input : targets.DocumentationTargetRequest]) : bool
  (match (targets.target bindings docs input)
    [(Missing) true]
    [_ false]))

(define (target-cases-ok?
  [docs : (& docs semantic_docs.SemanticDocumentation)]
  [anchor : String]) : bool
  (let
    [base : json.Json (binding docs (string.copy (& anchor)))]
    [mismatches : (Array (Tuple String json.Json) 5)
      (array
        (tuple
          "sourceSha256"
          (JsonString
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        (tuple "sourcePath" (JsonString "elsewhere/api.tl"))
        (tuple "moduleIdentity" (JsonString "other.module"))
        (tuple
          "compilerIdentity"
          (JsonString "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        (tuple "anchors" (JsonArray (box (json.list-empty)))))]
    (for [i (iterator.range 0 (array-length mismatches))]
      (let
        [row : (Tuple String json.Json) (clone (array-ref mismatches i))]
        (match (parse-one
          (replace-field (clone base) (tuple-ref row 0) (tuple-ref row 1)))
          [(Err _) (return false)]
          [(Ok configured)
            (let
              [ok : bool
                (missing?
                  (& configured)
                  docs
                  (request (string.copy (& docs.source-sha256))))]
              (lsp.lsp-documentation-sites-release! (&mut configured))
              (unless ok (return false)))])))
    (match (parse-one (clone base))
      [(Err _) false]
      [(Ok configured)
        (let
          [ok : bool
            (and
              (missing? (& configured) docs (request "stale"))
              (missing?
                (& configured)
                docs
                (targets.DocumentationTargetRequest
                  "unknown"
                  (string.copy (& docs.source-sha256)))))]
          (match (targets.target
            (& configured)
            docs
            (request (string.copy (& docs.source-sha256))))
            [(Missing) (set! ok false)]
            [(Found found)
              (unless
                (and
                  (string.is-string-prefix-at
                    found.uri
                    "file:///docs/one/api.html#tl-"
                    0)
                  (string.eq
                    (sites.text (& found.data) "packageIdentity")
                    "package-one@v1")
                  (string.eq
                    (sites.text (& found.data) "moduleIdentity")
                    docs.module)
                  (string.eq (sites.text (& found.data) "anchor") anchor))
                (set! ok false))])
          (lsp.lsp-documentation-sites-release! (&mut configured))
          (and
            ok
            (not configured.enabled)
            (= configured.owner-arena 0)
            (= configured.len 0)))])))

(define (configuration-cases-ok?
  [docs : (& docs semantic_docs.SemanticDocumentation)]
  [anchor : String]) : bool
  (let
    [base : json.Json (binding docs anchor)]
    [bad : (Array (Tuple String json.Json) 13)
      (array
        (tuple "packageIdentity" (JsonString ""))
        (tuple "sourceIdentity" (JsonString "main"))
        (tuple "compilerIdentity" (JsonString "unknown"))
        (tuple "sourceSha256" (JsonString "ABC"))
        (tuple "moduleIdentity" (JsonNumber "1"))
        (tuple "localUri" (JsonString "file:///docs/unsafe name.html"))
        (tuple "hostedUri" (JsonString "https://docs.example/main/api.html"))
        (tuple
          "hostedUri"
          (JsonString
            "https://docs.example/api.html?revision=/dddddddddddddddddddddddddddddddddddddddd/"))
        (tuple
          "hostedUri"
          (JsonString
            "https:///dddddddddddddddddddddddddddddddddddddddd/api.html"))
        (tuple
          "hostedUri"
          (JsonString
            "https://docs.example/dddddddddddddddddddddddddddddddddddddddd/../latest/api.html"))
        (tuple
          "hostedUri"
          (JsonString
            "https://docs.example/dddddddddddddddddddddddddddddddddddddddd/%2e%2e/latest/api.html"))
        (tuple "anchors" (JsonString "tl-x"))
        (tuple
          "anchors"
          (JsonArray (box (json.list-cons (JsonNumber "1") (json.list-empty))))))]
    (for [i (iterator.range 0 (array-length bad))]
      (let
        [row : (Tuple String json.Json) (clone (array-ref bad i))]
        (match (parse-one
          (replace-field (clone base) (tuple-ref row 0) (tuple-ref row 1)))
          [(Err _) unit]
          [(Ok configured)
            (lsp.lsp-documentation-sites-release! (&mut configured))
            (return false)])))
    (match (parse-one (replace-field (clone base) "localUri" (JsonString "")))
      [(Err _) (return false)]
      [(Ok configured)
        (let
          [valid : bool
            (match (targets.target
              (& configured)
              docs
              (request (string.copy (& docs.source-sha256))))
              [(Missing) false]
              [(Found found)
                (string.is-string-prefix-at
                  found.uri
                  "https://docs.example/dddddddddddddddddddddddddddddddddddddddd/api.html#"
                  0)])]
          (lsp.lsp-documentation-sites-release! (&mut configured))
          (unless valid (return false)))])
    ;; Two exact packages for the same source cannot be selected by list order.
    (let
      [message : json.Json
        (initialize-message
          (json.list-cons
            (clone base)
            (json.list-cons
              (replace-field
                base
                "packageIdentity"
                (JsonString "package-two@v1"))
              (json.list-empty))))]
      (match (lsp.lsp-documentation-sites-initialize (& message))
        [(Err _) false]
        [(Ok configured)
          (let
            [ok : bool
              (missing?
                (& configured)
                docs
                (request (string.copy (& docs.source-sha256))))]
            (lsp.lsp-documentation-sites-release! (&mut configured))
            ok)]))))

(define (owner-lifecycle-ok?
  [docs : (& docs semantic_docs.SemanticDocumentation)]
  [anchor : String]) : bool
  (let
    [original : json.Json
      (initialize-message
        (json.list-cons (binding docs anchor) (json.list-empty)))]
    [scratch (arena.make)]
    [message (in-arena scratch (clone original))]
    [parsed : sites.ResultDocumentationSites
      (lsp.lsp-documentation-sites-initialize (& message))]
    (arena.destroy-safe! scratch)
    (match parsed
      [(Err _) false]
      [(Ok configured)
        (let
          [site-owner : i64 configured.owner-arena]
          [state : lvf.LspServerState
            (lsp.lsp-server-state-initialize-workspaces
              (lsp.lsp-server-state-new)
              JsonNull
              configured)]
          [ok : bool true]
          [retained : json.Json JsonNull]
          (for [_ (iterator.range 0 12)]
            (let
              [old-owner : i64 state.owner-arena]
              [documents : document_vec.Vec
                (owned_view.compiler-owned-shared-view state.documents)]
              (unless
                (= state.documentation-sites.owner-arena site-owner)
                (set! ok false))
              ;; The production mutation path retires the old document owner.
              (set!
                state
                (match (lsp.lsp-server-state-copy-document-result
                  state
                  (Continue documents)
                  false)
                  [(Continue next) next]
                  [(Exit next) next]))
              (when (= old-owner state.owner-arena) (set! ok false))
              (match (targets.target
                (& state.documentation-sites)
                docs
                (request (string.copy (& docs.source-sha256))))
                [(Missing) (set! ok false)]
                [(Found found) (set! retained found.data)])))
          (set!
            state
            (lsp.lsp-server-state-initialize-workspaces
              state
              JsonNull
              (sites.empty false)))
          (unless
            (and
              (not state.documentation-sites.enabled)
              (= state.documentation-sites.owner-arena 0)
              (string.eq
                (sites.text (& retained) "packageIdentity")
                "package-one@v1")
              (string.eq (sites.text (& retained) "moduleIdentity") docs.module))
            (set! ok false))
          (lsp.lsp-server-state-destroy! state)
          ok)])))

(define (documentation-target-smoke-ok?) : bool
  (unless (source-cache-smoke-ok?) (return false))
  (let
    [path : String "src/tests/semantic_documentation_target_entry.tl"]
    [source : String
      "(module docs.example)\r\n(import semantic.index.import_dep as dep)\r\n(import semantic.index.import_dep.imported-value as direct)\r\n(defstruct Left (value i64))\r\n(defstruct Right (value i64))\r\n(defenum Mode (Same) (Other i64))\r\n(defmacro (emit-doc) : Decls `(define generated-value : i64 7))\r\n(emit-doc)\r\n(define (use [private : i64]) : i64 (let [hidden : i64 private] (+ (+ hidden generated-value) (+ dep.imported-value direct))))\r\n"]
    (match (semantic_tests.compiler-check-source-index-with-roots
      path
      (owned_view.compiler-owned-shared-view source)
      (svec.new))
      [(Ok _ index)
        (let
          [ok : bool (source-identities-ok? (& source) (& index))]
          [public-count : i64 0]
          [private-count : i64 0]
          [seen-field : bool false]
          (for [i (iterator.range 0 index.len)]
            (let
              [record : semantic.CompilerSemanticRecord
                (semantic.compiler-semantic-source-index-get (& index) i)]
              (match (semantic_docs.documentation-at (& index) i)
                [(None)
                  (when
                    (match record.kind
                      [(or (Local) (Parameter)) true]
                      [_ false])
                    (+= private-count 1))]
                [(Some docs)
                  (+= public-count 1)
                  (let
                    [anchor : String
                      (doc_render.doc-render-documentation-anchor
                        "pkg/api.tl"
                        (owned_view.compiler-owned-shared-view docs.identity))]
                    (unless
                      (target-cases-ok? (& docs) (string.copy (& anchor)))
                      (io.print-error "documentation: exact target cases\n")
                      (set! ok false))
                    (when
                      (and
                        (not seen-field)
                        (string.eq docs.identity.parent "Left"))
                      (set! seen-field true)
                      (unless
                        (and
                          (configuration-cases-ok?
                            (& docs)
                            (string.copy (& anchor)))
                          (owner-lifecycle-ok? (& docs) anchor))
                        (io.print-error
                          "documentation: mapping or owner lifecycle\n")
                        (set! ok false))))])))
          (semantic.compiler-semantic-source-index-release! (&mut index))
          (and ok seen-field (> public-count 7) (> private-count 1)))]
      [(Partial _ index)
        (semantic.compiler-semantic-source-index-release! (&mut index))
        false]
      [(Err _) false])))

(define (source-identities-ok?
  [source : (& source str)]
  [index : (& index semantic.CompilerSemanticSourceIndex)]) : bool
  (let
    [items : doc_item_vec.Vec
      (doc_extract.doc-extraction-items
        (doc_extract.doc-extract-source (string.copy source)))]
    [count : i64 0]
    [ok : bool true]
    (for [i (iterator.range 0 items.len)]
      (let
        [item : doc_extract.DocItem (doc_extract.doc-item-list-ref items i)]
        (when
          (>=
            (doc_extract.doc-kind-tag
              (doc_extract.doc-item-kind
                (owned_view.compiler-owned-shared-view item)))
            8)
          (let
            [expected : String
              (doc_render.doc-render-item-anchor "pkg/api.tl" item)]
            [found : bool false]
            (for [r (iterator.range 0 index.len)]
              (let
                [record : semantic.CompilerSemanticRecord
                  (semantic.compiler-semantic-source-index-get index r)]
                (when
                  (match record.role
                    [(Definition) true]
                    [_ false])
                  (match (semantic_docs.documentation-at index r)
                    [(None) unit]
                    [(Some docs)
                      (when
                        (and
                          (string.eq docs.module "docs.example")
                          (string.eq
                            expected
                            (doc_render.doc-render-documentation-anchor
                              "pkg/api.tl"
                              docs.identity)))
                        (set! found true))]))))
            (if found
              (+= count 1)
              (begin
                (io.print-error "documentation unmatched source identity: ")
                (io.print-error (& expected))
                (io.print-error "\n")
                (set! ok false)))))))
    (and ok (>= count 6))))

(define (source-cache-smoke-ok?) : bool
  (let
    [path : String "target/documentation-source-cache-7157.tl"]
    [uri : String (lsp.lsp-resolved-path-to-file-uri (string.copy (& path)))]
    [disk : String "disk source"]
    [first : String "first overlay"]
    [second : String "second overlay"]
    [first-digest : String (semantic.compiler-semantic-source-sha256 (& first))]
    [second-digest : String
      (semantic.compiler-semantic-source-sha256 (& second))]
    [disk-digest : String (semantic.compiler-semantic-source-sha256 (& disk))]
    [cache : targets.SourceDigestCache (targets.source-cache 1)]
    [documents : document_vec.Vec
      (lsp.lsp-documents-set-versioned
        (document_vec.new)
        (string.copy (& uri))
        (string.copy (& path))
        first
        1
        (lsp.lsp-diagnostic-uris-empty))]
    [ok : bool true]
    (io.write-file (& path) (byte_buf.str-as-bytes (& disk)))
    (unless
      (string.eq
        (targets.current-source-digest (& documents) (&mut cache) (& path))
        first-digest)
      (set! ok false))
    (set!
      documents
      (lsp.lsp-documents-set-versioned
        documents
        (string.copy (& uri))
        (string.copy (& path))
        (string.copy (& second))
        2
        (lsp.lsp-diagnostic-uris-empty)))
    ;; An in-flight request keeps one digest; the next request must observe
    ;; the replacement buffer. Canonically equal paths share one cache slot.
    (unless
      (and
        (= cache.len 1)
        (string.eq
          (targets.current-source-digest
            (& documents)
            (&mut cache)
            "target/./documentation-source-cache-7157.tl")
          first-digest))
      (set! ok false))
    (let
      [next : targets.SourceDigestCache (targets.source-cache 1)]
      (unless
        (string.eq
          (targets.current-source-digest (& documents) (&mut next) (& path))
          second-digest)
        (set! ok false)))
    (set!
      documents
      (lsp.lsp-documents-set-versioned
        documents
        (string.copy (& uri))
        (string.copy (& path))
        second
        -1
        (lsp.lsp-diagnostic-uris-empty)))
    (unless
      (string.eq (targets.source-digest (& documents) (& path)) disk-digest)
      (set! ok false))
    (match (fs.try-remove-file-if-exists (& path))
      [(OkIoUnit) unit]
      [(ErrIoUnit _) (set! ok false)])
    (unless
      (string.eq (targets.source-digest (& documents) (& path)) "")
      (set! ok false))
    (unless
      ok
      (io.print-error "documentation: overlay/disk request freshness\n"))
    ok))