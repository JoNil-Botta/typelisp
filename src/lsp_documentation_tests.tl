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
(import stdlib.str_cat_runtime as str_cat)
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

(define (anchor-list-cases-ok?
  [docs : (& docs semantic_docs.SemanticDocumentation)]
  [anchor : String]) : bool
  (let
    [counts : (Array i64 3) (array 0 1 4)]
    [values : (Array String 4)
      (array "tl-z" (clone anchor) "tl-a" (clone anchor))]
    (for [case (iterator.range 0 3)]
      (let
        [count : i64 (array-ref counts case)]
        [items : json.JsonSeq (json.list-empty)]
        (for [i (iterator.range 0 count)]
          (set!
            items
            (json.list-cons
              (JsonString
                (if (= count 1)
                  (clone anchor)
                  (clone (array-ref values i))))
              items)))
        (match (parse-one
          (replace-field
            (binding docs (clone anchor))
            "anchors"
            (JsonArray (box items))))
          [(Err _) (return false)]
          [(Ok configured)
            (let
              [site : (& configured sites.DocumentationSite)
                (& (array-ref configured.items 0))]
              [ok : bool
                (and
                  (= (sites.contains-anchor? site anchor) (> count 0))
                  (= (sites.contains-anchor? site "tl-a") (= count 4))
                  (= (sites.contains-anchor? site "tl-z") (= count 4))
                  (not (sites.contains-anchor? site ""))
                  (not (sites.contains-anchor? site "tl-missing"))
                  (=
                    (missing?
                      (& configured)
                      docs
                      (request (string.copy (& docs.source-sha256))))
                    (= count 0)))]
              (lsp.lsp-documentation-sites-release! (&mut configured))
              (unless ok (return false)))])))
    true))

(define (configuration-cases-ok?
  [docs : (& docs semantic_docs.SemanticDocumentation)]
  [anchor : String]) : bool
  (unless (anchor-list-cases-ok? docs (clone anchor)) (return false))
  (let
    [base : json.Json (binding docs anchor)]
    [bad : (Array (Tuple String json.Json) 14)
      (array
        (tuple "packageIdentity" (JsonString ""))
        (tuple "sourceIdentity" (JsonString "main"))
        (tuple "compilerIdentity" (JsonString "unknown"))
        (tuple "sourceSha256" (JsonString "ABC"))
        (tuple "moduleIdentity" (JsonNumber "1"))
        (tuple "localUri" (JsonString "file:///docs/unsafe name.html"))
        (tuple
          "localUri"
          (JsonString
            (byte_buf.to-string
              (byte_buf.push
                (byte_buf.from-string "file:///docs/")
                (cast 127 : u8)))))
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

(define (link-positions-smoke-ok?) : bool
  (let
    [source : String "λx\r\n𝄞y"]
    [offsets : (Array i64 3) (array 2 9 2)]
    [ok : bool true]
    (for [encoding (iterator.range 0 2)]
      (if (= encoding 0)
        (lsp.lsp-position-encoding-use-utf16!)
        (lsp.lsp-position-encoding-use-utf8!))
      (let
        [cache : lsp.LspLineColCache (lsp.LspLineColCache -1 1 1)]
        (for [i (iterator.range 0 3)]
          (let
            [offset : i64 (array-ref offsets i)]
            [link : json.Json
              (lsp.lsp-document-link-json
                source
                (lsp.LspDocumentLinkRequest
                  "file:///docs/api.html#value"
                  offset
                  (+ offset 1)
                  JsonNull)
                (&mut cache))]
            [range : json.Json (sites.field (& link) "range")]
            [start : json.Json (sites.field (& range) "start")]
            [end : json.Json (sites.field (& range) "end")]
            [line : i64
              (if (= i 1)
                1
                0)]
            [column : i64
              (if (= i 1)
                (if (= encoding 0)
                  2
                  4)
                (if (= encoding 0)
                  1
                  2))]
            (unless
              (and
                (= (lsp.lsp-json-int-field-default start "line" -1) line)
                (= (lsp.lsp-json-int-field-default end "line" -1) line)
                (= (lsp.lsp-json-int-field-default start "character" -1) column)
                (=
                  (lsp.lsp-json-int-field-default end "character" -1)
                  (+ column 1)))
              (set! ok false))))))
    (lsp.lsp-position-encoding-use-utf16!)
    ok))

(define (documentation-target-smoke-ok?) : bool
  (unless (source-cache-smoke-ok?) (return false))
  (unless (namespace-targets-smoke-ok?) (return false))
  (unless (link-positions-smoke-ok?) (return false))
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

(define (checked-member [path : String] [module : String]) : semantic_docs.MaybeSemanticDocumentation
  (let
    [source : String
      (str_cat.str-cat
        "(module "
        (string.copy (& module))
        ")\r\n(defstruct Item (value i64))\r\n")]
    (match (semantic_tests.compiler-check-source-index-with-roots
      path
      source
      (svec.new))
      [(Ok _ index)
        (let
          [found : semantic_docs.MaybeSemanticDocumentation None]
          (for [i (iterator.range 0 index.len)]
            (match (semantic_docs.documentation-at (& index) i)
              [(Some docs)
                (when
                  (and
                    (string.eq docs.module module)
                    (string.eq docs.identity.parent "Item")
                    (string.eq docs.identity.name "value"))
                  (set! found (Some docs))
                  (break))]
              [(None) unit]))
          (semantic.compiler-semantic-source-index-release! (&mut index))
          found)]
      [(Partial _ index)
        (semantic.compiler-semantic-source-index-release! (&mut index))
        None]
      [(Err _) None])))

(define (namespace-targets-smoke-ok?) : bool
  (let
    [first : semantic_docs.MaybeSemanticDocumentation
      (checked-member "src/tests/docs_package_one.tl" "docs.one")]
    [second : semantic_docs.MaybeSemanticDocumentation
      (checked-member "src/tests/docs_package_two.tl" "docs.two")]
    (match first
      [(None) false]
      [(Some one)
        (match second
          [(None) false]
          [(Some two)
            ;; Both checked members have the same type/name. Retained identities
            ;; outlive each source index and the next independent frontend job.
            (let
              [docs : (Array semantic_docs.SemanticDocumentation 2)
                (array one two)]
              [packages : (Array String 2)
                (array "package-one@v1" "package-two@v2")]
              [modules : (Array String 4)
                (array "one/api.tl" "two/api.tl" "api.tl" "api.tl")]
              [pages : (Array String 2)
                (array "file:///docs/one/api.html" "file:///docs/two/api.html")]
              (for [namespace-case (iterator.range 0 2)]
                (let
                  [bindings : (Array json.Json 2) (array JsonNull JsonNull)]
                  [anchors : (Array String 2) (array "" "")]
                  (for [i (iterator.range 0 2)]
                    (let
                      [item : (& docs semantic_docs.SemanticDocumentation)
                        (& (array-ref docs i))]
                      [anchor : String
                        (doc_render.doc-render-documentation-anchor
                          (& (array-ref modules (+ (* namespace-case 2) i)))
                          (owned_view.compiler-owned-reference-shared-view
                            (& item.identity)))]
                      [configured : json.Json
                        (replace-field
                          (replace-field
                            (replace-field
                              (binding item (string.copy (& anchor)))
                              "packageIdentity"
                              (JsonString
                                (string.copy (& (array-ref packages i)))))
                            "docModule"
                            (JsonString
                              (string.copy
                                (&
                                  (array-ref modules (+ (* namespace-case 2) i))))))
                          "localUri"
                          (JsonString (string.copy (& (array-ref pages i)))))]
                      (set! (array-ref anchors i) anchor)
                      (set! (array-ref bindings i) configured)))
                  ;; Distinct module paths have distinct anchors. Equal relative
                  ;; paths in separate packages may share an anchor, but not a page.
                  (when
                    (if (= namespace-case 0)
                      (string.eq (array-ref anchors 0) (array-ref anchors 1))
                      (not
                        (string.eq (array-ref anchors 0) (array-ref anchors 1))))
                    (return false))
                  (for [order (iterator.range 0 2)]
                    (let
                      [message : json.Json
                        (initialize-message
                          (json.list-cons
                            (clone (array-ref bindings order))
                            (json.list-cons
                              (clone (array-ref bindings (- 1 order)))
                              (json.list-empty))))]
                      (match (lsp.lsp-documentation-sites-initialize
                        (& message))
                        [(Err _) (return false)]
                        [(Ok configured)
                          (let
                            [ok : bool true]
                            (for [i (iterator.range 0 2)]
                              (let
                                [item : (&
                                  docs
                                  semantic_docs.SemanticDocumentation)
                                  (& (array-ref docs i))]
                                (match (targets.target
                                  (& configured)
                                  item
                                  (request (string.copy (& item.source-sha256))))
                                  [(Missing) (set! ok false)]
                                  [(Found target)
                                    (unless
                                      (and
                                        (string.eq
                                          (sites.text
                                            (& target.data)
                                            "packageIdentity")
                                          (array-ref packages i))
                                        (string.eq
                                          (sites.text
                                            (& target.data)
                                            "moduleIdentity")
                                          item.module)
                                        (string.eq
                                          (sites.text (& target.data) "anchor")
                                          (array-ref anchors i))
                                        (string.eq
                                          target.uri
                                          (str_cat.str-cat
                                            (string.copy
                                              (& (array-ref pages i)))
                                            "#"
                                            (string.copy
                                              (& (array-ref anchors i))))))
                                      (set! ok false))])))
                            (lsp.lsp-documentation-sites-release!
                              (&mut configured))
                            (unless ok (return false)))])))))
              true)])])))

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