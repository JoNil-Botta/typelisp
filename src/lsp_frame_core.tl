;; lsp_frame_core.tl - Main-free selfhost LSP stdio framing and JSON-RPC slice.
;;
;; This driver owns JSON-RPC/LSP Content-Length framing over stdin/stdout plus
;; the first selfhost protocol loop: initialize/shutdown, document tracking, and
;; diagnostics for full-document open/change notifications.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.arena)
(import stdlib.byte_buf)
(import compiler_incremental_binary)
(import stdlib.json)
(import stdlib.sort)
(import stdlib.vector)
(import (vector.vector String) as lsp_svec)
(import lex as lexer)
(import read as reader)
(import compiler_builtin_ids as cbi)
(import compiler_module_name as module_name)
(import compiler_target_cfg_core as target_cfg)
(import compiler_check_core)
(import compiler_semantic_index)
(import compiler_ast_types as ast)
(import compiler_ctfe as ctfe)
(import compiler_diagnostic as cdiag)
(import compiler_load)
(import compiler_parse_core as parser)
(import compiler_typecheck_core as tc)
(import format_tokens)
(import format_rules)
(import lint_core as lint)
(import lint_driver_core)
(import package_source_core)
(import lsp_vector_families)
(import (vector.vector lsp_vector_families.LspDeclEntry core) as lsp_decl_vec)
(import (vector.vector lsp_vector_families.LspDocument core) as lsp_document_vec)
(import stdlib.string)
(import source_text_core as source_text)
(import token)
(import sym_i64_env)

(defmacro (lsp-global-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(define (lsp-read-file-text-or [path : (& source str)] [fallback : String]) : String
  (byte_buf.to-string (io.read-file-or path (byte_buf.from-string fallback))))

(define (lsp-write-file-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (lsp-str2 [a : String] [b : String]) : String
  (str_cat.str-cat a b ""))

(define (lsp-str3 [a : String] [b : String] [c : String]) : String
  (str_cat.str-cat a b c))

(define (lsp-str4 [a : String] [b : String] [c : String] [d : String]) : String
  (str_cat.str-cat a b c d))

(define (lsp-str5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (str_cat.str-cat a b c d e))

(define (lsp-str7
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]
  [g : String]) : String
  (str_cat.str-cat (lsp-str4 a b c d) (lsp-str3 e f g) ""))

(defenum LspFrameRead
  (Ok String)
  (Eof)
  (Err String))

;; Exact bytes captured from one in-process transcript run. JSON-RPC ids do
;; not appear here because they are owned by each input message and echoed by
;; the shared handlers; there is no process/session id counter to reset.
(defstruct LspTranscriptResult
  (stdout String)
  (stderr String)
  (status i64))

(defstruct LspTranscriptBatchEntry
  (case-id String)
  (input-path String)
  (stdout-path String)
  (stderr-path String)
  (status-path String))

(defenum ResultLspTranscriptBatchEntry
  (Ok LspTranscriptBatchEntry)
  (Err String))

(defenum LspTranscriptBatchOption
  (None)
  (Path String)
  (Err String))

(defenum LspLengthParse
  (Ignore)
  (Ok i64)
  (Err String))

(defenum LspStringResult
  (Ok String)
  (Err String))

(defenum LspUriPath
  (Ok String)
  (Err String))

(defenum LspJsonText
  (Ok String)
  (Missing))

(defenum LspJsonValue
  (Found json.Json)
  (Missing))

(defenum LspCodeActionDocument
  (Found String String i64)
  (Missing))

(defenum LspInitializeLanguageConfig
  (Ok target_cfg.CompilerTargetCfg lsp_svec.Vec)
  (Err String))

(defenum LspDocumentLookup
  (Found String String lsp_vector_families.LspDiagnosticUris)
  (Missing))

;; Narrow lookup for providers that must inspect the retained semantic owner.
;; Keeping this separate avoids widening the common text-only lookup contract.
(defenum LspSemanticDocumentLookup
  (Found lsp_vector_families.LspDocument)
  (Missing))

(defenum LspDocumentDeclsLookup
  (Found String String lsp_vector_families.LspDiagnosticUris lsp_decl_vec.Vec)
  (Missing))

(defenum LspDocumentHandleResult
  (Continue lsp_document_vec.Vec)
  (Exit lsp_document_vec.Vec))

(defenum LspHandleResult
  (Continue lsp_vector_families.LspServerState)
  (Exit lsp_vector_families.LspServerState))

;; Bounded, request-local workspace-symbol candidates. `rank` is 0 for an
;; exact match, 1 for a prefix match, and 2 for a substring match. Empty
;; queries assign rank 0 to every declaration and use the same tie-breaks.
(defstruct LspWorkspaceSymbolCandidate
  (rank i64)
  (row lsp_vector_families.LspWorkspaceDeclRow))

(defstruct LspWorkspaceSymbolResults
  (slots (__tl_dyn-array LspWorkspaceSymbolCandidate))
  (len i64))

;; Request-local completion rows.  The provider keeps only the best fixed
;; prefix, so a large workspace cannot make one keystroke allocate an
;; unbounded candidate vector.  `stable-key` is an opaque semantic identity
;; (or an explicit language/workspace identity for non-semantic candidates).
(defstruct LspCompletionCandidate
  (match-rank i64)
  (source-rank i64)
  (namespace-rank i64)
  (kind i64)
  (label String)
  (detail String)
  (documentation String)
  (module String)
  (path String)
  (line i64)
  (col i64)
  (stable-key String)
  (new-text String))

(defstruct LspCompletionResults
  (slots (__tl_dyn-array LspCompletionCandidate))
  (len i64)
  (incomplete bool))

(defstruct LspWorkspaceSemanticQuery
  (slots (__tl_dyn-array lsp_vector_families.LspWorkspaceSemanticFact))
  (len i64)
  ;; 0 complete, 1 refreshable, 2 currently incomplete.
  (completeness i64))

(defstruct LspRenameTarget
  (canonical-key String)
  ;; Exact source spelling selected by the user. Import aliases and module
  ;; components can share a canonical declaration while remaining separate
  ;; rename surfaces.
  (surface-name String)
  (kind compiler_semantic_index.CompilerSemanticSymbolKind)
  (record-span compiler_semantic_index.CompilerSemanticSpan)
  (edit-span compiler_semantic_index.CompilerSemanticSpan))

(defenum LspRenameTargetLookup
  (Found LspRenameTarget)
  (Missing))

(defenum LspRenameSourceLookup
  (Found String)
  (Missing))

(defenum LspRenameValidation
  (Ok i64)
  (Err String))

(defenum LspRenameModuleMove
  (Found String String)
  (Missing))

(defenum LspRenameModuleMoveLookup
  (Ok LspRenameModuleMove)
  (Err String))

(defstruct LspLineCol
  (line i64)
  (col i64))

(defstruct LspLineColCache
  (offset i64)
  (line i64)
  (col i64))

;; One request-local semantic-token candidate. Byte ranges remain the common
;; merge key; negotiated line/character positions are computed once after the
;; radix sort. `priority` resolves equal-start overlaps (exact semantic facts
;; precede lexical classifications).
(defstruct LspSemanticTokenCandidate
  (start-byte i64)
  (end-byte i64)
  (token-type i64)
  (modifiers i64)
  (priority i64))

(defstruct LspSemanticTokenCandidates
  (slots (__tl_dyn-array LspSemanticTokenCandidate))
  (len i64))

(defstruct LspDocumentHighlightCandidate
  (start-byte i64)
  (end-byte i64)
  (start-line i64)
  (start-col i64)
  (end-line i64)
  (end-col i64)
  (utf16-start-col i64)
  (utf16-end-col i64)
  (kind i64))

(defstruct LspDocumentHighlightResults
  (slots (__tl_dyn-array LspDocumentHighlightCandidate))
  (len i64)
  ;; Exposed to tests and measurements so the provider's single occurrence
  ;; pass remains observable without production counters.
  (record-visits i64))

;; Pure lexical context used by signature-help providers. Every offset is a
;; byte offset into the current document; position conversion happens only at
;; the public position-based entry point.
(defstruct LspCallContext
  (form-start i64)
  (head-start i64)
  (head-end i64)
  (active-argument i64))

(defenum LspCallContextLookup
  (Found LspCallContext)
  (Missing))

;; Syntax-only completion context. Dotted import paths deliberately remain
;; ambiguous between a module and a selected item until the semantic provider
;; resolves the receiver. `token` is the whole token written before the cursor;
;; `prefix` is its replaceable suffix after the final dot, and replacement ends
;; at the cursor. All offsets are exact UTF-8 byte offsets.
(defenum LspCompletionContextKind
  (Value)
  (CallHead)
  (Type)
  (ImportPathOrItem)
  (ImportAlias)
  (DottedMember)
  (Field)
  (Suppressed))

(defstruct LspCompletionContext
  (kind LspCompletionContextKind)
  (cursor-byte i64)
  (replace-start i64)
  (replace-end i64)
  (token-start i64)
  (token String)
  (prefix String)
  (receiver String)
  (head String)
  (form-start i64)
  (head-start i64)
  (head-end i64)
  (active-argument i64))

(defenum LspCompletionContextLookup
  (Found LspCompletionContext)
  (Missing))

(defstruct LspCursorContextScan
  (call LspCallContextLookup)
  (completion LspCompletionContextLookup))

(defstruct LspCompletionTokenScan
  (end i64)
  (last-dot i64))

(defenum LspOffsetLookup
  (Found i64)
  (Missing))

;; Folding-range scan position: 1-based line, 1-based negotiated column, and
;; whether anything other than whitespace has been seen on the current line.
(defstruct LspFoldCursor
  (line i64)
  (col i64)
  (code bool))

;; A token at the end of an unfinished document may still extend to a valid
;; identity. Only Complete can resolve an import; Prefix never changes grammar.
(defenum LspDottedImportNameKind
  (Complete)
  (Prefix)
  (Invalid))

(defenum LspImportTarget
  (Found String i64 i64)
  (Missing))

(defenum LspEditResult
  (Ok String)
  (Err String))

(defenum LspSaveResult
  (Ok lsp_document_vec.Vec)
  (Err String))

(defenum LspBatchOpResult
  (Ok String json.Json)
  (Err String json.Json))

(defenum LspBatchRunResult
  (Ok String json.JsonSeq)
  (Err String i64 String json.Json))

(defenum LspPathParam
  (Ok json.JsonSeq)
  (Err String))

(defenum LspPathLookup
  (Found i64 i64 String)
  (Err String))

(defenum LspValidationResult
  (Valid)
  (Invalid i64 i64 String String))

(defenum LspSemanticSnapshotStatus
  (Missing)
  (Current i64 bool)
  (Stale i64 bool))

;; One identity-first query shared by definition and hover. Both records are
;; immutable values owned by the current document's semantic snapshot.
(defenum LspSemanticSymbolQuery
  (Found
    compiler_semantic_index.CompilerSemanticRecord
    compiler_semantic_index.CompilerSemanticRecord)
  (Missing))

(defstruct LspAnalyzeResult
  (diagnostic-uris lsp_vector_families.LspDiagnosticUris)
  (check-cache lsp_vector_families.LspCheckCache)
  (semantic-index compiler_semantic_index.CompilerSemanticSourceIndex)
  (semantic-present bool))

(define (lsp-frame-space? [c : char]) : bool
  (or (= c ' ') (= c '\t')))

(define (lsp-frame-trim-right-space-cr [text : String]) : String
  (let
    [i : i64 (string.string-length text)]
    [end : i64 (string.string-length text)]
    [done : bool false]
    (begin
      (while (> i 0)
        (if done
          (set! i 0)
          (let
            [c : char (string.string-ref text (- i 1))]
            (if (or (lsp-frame-space? c) (= c '\r'))
              (begin
                (set! end (- i 1))
                (set! i (- i 1)))
              (set! done true)))))
      (string.substring text 0 end))))

(define (lsp-frame-trim-left-space [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [start : i64 0]
    [done : bool false]
    (begin
      (while (< i n)
        (if done
          (set! i n)
          (if (lsp-frame-space? (string.string-ref text i))
            (begin
              (set! start (+ i 1))
              (set! i (+ i 1)))
            (set! done true))))
      (string.substring text start (- n start)))))

(define (lsp-frame-trim-header-value [text : String]) : String
  (lsp-frame-trim-left-space (lsp-frame-trim-right-space-cr text)))

(define (lsp-frame-digit? [c : char]) : bool
  (and (>= c '0') (<= c '9')))

(define (lsp-frame-decimal? [text : (& text str)]) : bool
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [ok : bool true]
    (if (= n 0)
      false
      (begin
        (while (< i n)
          (if ok
            (if (lsp-frame-digit? (string.string-ref text i))
              (set! i (+ i 1))
              (begin
                (set! ok false)
                (set! i n)))
            (set! i n)))
        ok))))

(define (lsp-frame-parse-content-length [line : String]) : LspLengthParse
  (if (source_text.starts-with? line "Content-Length:")
    (let
      [value : String
        (lsp-frame-trim-header-value
          (string.substring line 15 (- (string.string-length line) 15)))]
      (if (lsp-frame-decimal? value)
        (let
          [n : i64 (string.>int value)]
          (if (< n 0)
            (Err "lsp: invalid Content-Length")
            (Ok n)))
        (Err "lsp: invalid Content-Length")))
    Ignore))

;; The LSP is serial, so the narrow frame boundary can select one active
;; memory transport without plumbing transport arguments through every request
;; handler. Stdio remains the default. The transport's arena handle, input
;; snapshot, cursor, EOF flag and captured output form one value: install and
;; reset replace it whole, so no field outlives the owner it was built in, and
;; the transcript wrapper resets it before its arenas are retired.
(defstruct LspFrameMemoryState
  (active bool)
  (owner arena.Arena)
  (input String)
  (input-offset i64)
  (eof bool)
  (stdout String)
  (stderr String))

(define lsp-frame-memory-state : LspFrameMemoryState
  (LspFrameMemoryState false (arena.Arena 0) "" 0 false "" ""))

(define (lsp-frame-memory-reset!) : unit
  (set!
    lsp-frame-memory-state
    (LspFrameMemoryState false (arena.Arena 0) "" 0 false "" "")))

(define (lsp-frame-memory-install!
  [input : (& input str)]
  [transport-arena : i64]) : unit
  (set!
    lsp-frame-memory-state
    (in-arena
      (arena.Arena transport-arena)
      (LspFrameMemoryState
        true
        (arena.Arena transport-arena)
        (string.copy input)
        0
        false
        ""
        ""))))

(define (lsp-frame-memory-stdout-append! [text : String]) : unit
  (in-arena
    lsp-frame-memory-state.owner
    (set!
      lsp-frame-memory-state.stdout
      (str_cat.str-cat-scoped lsp-frame-memory-state.stdout text))))

(define (lsp-frame-memory-stderr-append! [text : String]) : unit
  (in-arena
    lsp-frame-memory-state.owner
    (set!
      lsp-frame-memory-state.stderr
      (str_cat.str-cat-scoped lsp-frame-memory-state.stderr text))))

(define (lsp-frame-memory-read-line) : io.StdinRead
  (let
    [n : i64 (string.string-length lsp-frame-memory-state.input)]
    [start : i64 lsp-frame-memory-state.input-offset]
    (if (or lsp-frame-memory-state.eof (>= start n))
      (begin
        (set! lsp-frame-memory-state.eof true)
        (io.StdinRead (byte_buf.new) true))
      (let
        [end : i64 start]
        [found-newline : bool false]
        (begin
          (while (and (< end n) (not found-newline))
            (if (= (string.string-ref lsp-frame-memory-state.input end) '\n')
              (set! found-newline true)
              (set! end (+ end 1))))
          (if found-newline
            (begin
              (set! lsp-frame-memory-state.input-offset (+ end 1))
              (io.StdinRead
                (byte_buf.from-string
                  (string.substring
                    lsp-frame-memory-state.input
                    start
                    (- end start)))
                false))
            (begin
              (set! lsp-frame-memory-state.input-offset n)
              (set! lsp-frame-memory-state.eof true)
              (io.StdinRead
                (byte_buf.from-string
                  (string.substring
                    lsp-frame-memory-state.input
                    start
                    (- n start)))
                true))))))))

(define (lsp-frame-memory-read-bytes [count : i64]) : io.StdinRead
  (let
    [n : i64 (string.string-length lsp-frame-memory-state.input)]
    [start : i64 lsp-frame-memory-state.input-offset]
    [available : i64 (- n lsp-frame-memory-state.input-offset)]
    [take : i64
      (if (< available count)
        available
        count)]
    [next : i64 (+ lsp-frame-memory-state.input-offset take)]
    [short : bool (< available count)]
    (begin
      (set! lsp-frame-memory-state.input-offset next)
      (if short
        (set! lsp-frame-memory-state.eof true)
        unit)
      (io.StdinRead
        (byte_buf.from-string
          (string.substring lsp-frame-memory-state.input start take))
        lsp-frame-memory-state.eof))))

(define (lsp-frame-input-read-line) : io.StdinRead
  (if lsp-frame-memory-state.active
    (lsp-frame-memory-read-line)
    (io.stdin-read-line)))

(define (lsp-frame-input-read-bytes [count : i64]) : io.StdinRead
  (if lsp-frame-memory-state.active
    (lsp-frame-memory-read-bytes count)
    (io.stdin-read-bytes count)))

(define (lsp-frame-read-message) : LspFrameRead
  (let
    [content-length : i64 -1]
    [saw-header : bool false]
    [done : bool false]
    [clean-eof : bool false]
    [err : String ""]
    [has-error : bool false]
    (begin
      (while (not done)
        (let
          [line-read : io.StdinRead (lsp-frame-input-read-line)]
          [line : String
            (lsp-frame-trim-right-space-cr
              (byte_buf.to-string
                (io.stdin-read-buffer
                  (owned_view.compiler-owned-shared-view line-read))))]
          (if (io.stdin-read-eof? line-read)
            (if (= (string.string-length line) 0)
              (if saw-header
                (begin
                  (set! err "lsp: EOF before header terminator")
                  (set! has-error true)
                  (set! done true))
                (begin
                  (set! clean-eof true)
                  (set! done true)))
              (begin
                (set! saw-header true)
                (match (lsp-frame-parse-content-length line)
                  [(Ignore) unit]
                  [(Ok n) (set! content-length n)]
                  [(Err message)
                    (begin
                      (set! err message)
                      (set! has-error true)
                      (set! done true))])))
            (if (string.eq line "")
              (set! done true)
              (begin
                (set! saw-header true)
                (match (lsp-frame-parse-content-length line)
                  [(Ignore) unit]
                  [(Ok n) (set! content-length n)]
                  [(Err message)
                    (begin
                      (set! err message)
                      (set! has-error true)
                      (set! done true))]))))))
      (cond
        [clean-eof Eof]
        [has-error (Err err)]
        [(< content-length 0) (Err "lsp: missing Content-Length")]
        [else
          (let
            [payload-read : io.StdinRead
              (lsp-frame-input-read-bytes content-length)]
            [payload : String
              (byte_buf.to-string
                (io.stdin-read-buffer
                  (owned_view.compiler-owned-shared-view payload-read)))]
            (if (and
              (io.stdin-read-eof? payload-read)
              (< (string.string-length payload) content-length))
              (Err "lsp: truncated payload")
              (Ok payload)))]))))

(define (lsp-frame-stdout-write [text : String]) : unit
  (if lsp-frame-memory-state.active
    (lsp-frame-memory-stdout-append! text)
    (io.stdout-write (byte_buf.str-as-bytes (& text)))))

(define (lsp-frame-stderr-write [text : String]) : unit
  (if lsp-frame-memory-state.active
    (lsp-frame-memory-stderr-append! text)
    (io.stderr-write (byte_buf.str-as-bytes (& text)))))

(define (lsp-frame-stdout-flush) : unit
  (if lsp-frame-memory-state.active
    unit
    (io.stdout-flush)))

(define (lsp-frame-write-body [body : String]) : unit
  (begin
    (lsp-frame-stdout-write
      (lsp-str5
        "Content-Length: "
        (string.int->string (string.string-length body))
        "\r\n\r\n"
        body
        ""))
    (lsp-frame-stdout-flush)))

(define (lsp-json-number [value : i64]) : json.Json
  (JsonNumber (string.int->string value)))

(define (lsp-json-member
  [k : String]
  [v : json.Json]
  [rest : json.JsonMemberSeq]) : json.JsonMemberSeq
  (json.member-cons k v rest))

(define (lsp-json-object [members : json.JsonMemberSeq]) : json.Json
  (JsonObject (box members)))

(define (lsp-json-list-cons [value : json.Json] [rest : json.JsonSeq]) : json.JsonSeq
  (json.list-cons value rest))

(define (lsp-json-array [items : json.JsonSeq]) : json.Json
  (JsonArray (box items)))

(define (lsp-json-rpc-member [rest : json.JsonMemberSeq]) : json.JsonMemberSeq
  (lsp-json-member "jsonrpc" (JsonString "2.0") rest))

(define (lsp-json-object1 [k : String] [v : json.Json]) : json.Json
  (lsp-json-object (lsp-json-member k v (json.member-list-empty))))

(define (lsp-json-object2
  [k1 : String]
  [v1 : json.Json]
  [k2 : String]
  [v2 : json.Json]) : json.Json
  (lsp-json-object
    (lsp-json-member k1 v1 (lsp-json-member k2 v2 (json.member-list-empty)))))

(define (lsp-json-object3
  [k1 : String]
  [v1 : json.Json]
  [k2 : String]
  [v2 : json.Json]
  [k3 : String]
  [v3 : json.Json]) : json.Json
  (lsp-json-object
    (lsp-json-member
      k1
      v1
      (lsp-json-member k2 v2 (lsp-json-member k3 v3 (json.member-list-empty))))))

(define (lsp-json-object4
  [k1 : String]
  [v1 : json.Json]
  [k2 : String]
  [v2 : json.Json]
  [k3 : String]
  [v3 : json.Json]
  [k4 : String]
  [v4 : json.Json]) : json.Json
  (lsp-json-object
    (lsp-json-member
      k1
      v1
      (lsp-json-member
        k2
        v2
        (lsp-json-member k3 v3 (lsp-json-member k4 v4 (json.member-list-empty)))))))

(define (lsp-json-string-field [value : (& value json.Json)] [key : String]) : LspJsonText
  (let
    [value : json.Json (owned_view.compiler-owned-reference-shared-view value)]
    (match (json.object-get value (& key))
      [(JsonFound field)
        (match field
          [(JsonString text) (Ok text)]
          [_ Missing])]
      [(JsonMissing) Missing])))

(define (lsp-json-string-field-default
  [value : json.Json]
  [key : String]
  [fallback : String]) : String
  (match (lsp-json-string-field value key)
    [(Ok text) text]
    [(Missing) fallback]))

(define lsp-language-target : target_cfg.CompilerTargetCfg
  (target_cfg.compiler-target-cfg-host))
(define lsp-language-cfg-names : lsp_svec.Vec
  (lsp_svec.new))
(define lsp-position-encoding-utf8 : bool
  false)

(define (lsp-language-config-reset!) : unit
  (begin
    (set! lsp-language-target (target_cfg.compiler-target-cfg-host))
    (set! lsp-language-cfg-names (lsp_svec.new))
    (set! lsp-position-encoding-utf8 false)))

(define (lsp-language-config-install!
  [target : target_cfg.CompilerTargetCfg]
  [cfg-names : lsp_svec.Vec]) : unit
  (begin
    (set! lsp-language-target target)
    (set! lsp-language-cfg-names cfg-names)))

(define (lsp-language-cfgs) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-cfgs-with-names
    lsp-language-target
    (lsp-global-shared-view lsp-language-cfg-names)))

(define (lsp-position-encoding-name) : String
  (if lsp-position-encoding-utf8
    "utf-8"
    "utf-16"))

(define (lsp-position-encoding-use-utf16!) : unit
  (set! lsp-position-encoding-utf8 false))

(define (lsp-position-encoding-use-utf8!) : unit
  (set! lsp-position-encoding-utf8 true))

(define (lsp-position-encodings-offer-utf8? [items : json.JsonSeq]) : bool
  (let
    [i : i64 0]
    [n : i64 (json.list-count (owned_view.compiler-owned-shared-view items))]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (match (json.list-get-index
            (owned_view.compiler-owned-shared-view items)
            i)
            [(JsonFound entry)
              (match entry
                [(JsonString name)
                  (if (string.eq name "utf-8")
                    (set! found true)
                    unit)]
                [_ unit])]
            [(JsonMissing) unit])
          (set! i (+ i 1))))
      found)))

;; LSP 3.17 defaults to UTF-16. TypeLisp also supports UTF-8 positions and
;; selects them whenever the client explicitly offers that encoding.
(define (lsp-initialize-position-encoding-utf8? [message : json.Json]) : bool
  (let
    [params-key : String "params"]
    [capabilities-key : String "capabilities"]
    [general-key : String "general"]
    [encodings-key : String "positionEncodings"]
    (match (json.object-get message (& params-key))
      [(JsonFound params)
        (match (json.object-get params (& capabilities-key))
          [(JsonFound capabilities)
            (match (json.object-get capabilities (& general-key))
              [(JsonFound general)
                (match (json.object-get general (& encodings-key))
                  [(JsonFound encodings)
                    (match encodings
                      [(JsonArray items)
                        (if (lsp-position-encodings-offer-utf8? (deref items))
                          true
                          false)]
                      [_ false])]
                  [(JsonMissing) false])]
              [(JsonMissing) false])]
          [(JsonMissing) false])]
      [(JsonMissing) false])))

(define (lsp-initialize-cfg-names [options : json.Json]) : LspInitializeLanguageConfig
  (let
    [target : target_cfg.CompilerTargetCfg
      (target_cfg.compiler-target-cfg-host)]
    [cfg-names : lsp_svec.Vec (lsp_svec.new)]
    [error : String ""]
    [target-key : String "target"]
    [cfg-key : String "cfg"]
    (begin
      (match (json.object-get
        (owned_view.compiler-owned-shared-view options)
        (& target-key))
        [(JsonMissing) unit]
        [(JsonFound target-value)
          (match target-value
            [(JsonString target-name)
              (match (target_cfg.compiler-target-cfg-parse target-name)
                [(Ok parsed-target) (set! target parsed-target)]
                [(Err message) (set! error (str_cat.str-cat "lsp: " message))])]
            [_
              (set! error "lsp: initializationOptions.target must be a string")])])
      (if (= (string.string-length error) 0)
        (match (json.object-get options (& cfg-key))
          [(JsonMissing) unit]
          [(JsonFound cfg-value)
            (match cfg-value
              [(JsonArray items-box)
                (let
                  [items : json.JsonSeq (deref items-box)]
                  [index : i64 0]
                  (while (and
                    (= (string.string-length error) 0)
                    (< index items.len))
                    (begin
                      (match (array-ref items.slots index)
                        [(JsonString name)
                          (lsp_svec.push-ref!
                            (&mut cfg-names)
                            (string.copy (& name)))]
                        [_
                          (set!
                            error
                            "lsp: initializationOptions.cfg must contain strings")])
                      (set! index (+ index 1)))))]
              [_ (set! error "lsp: initializationOptions.cfg must be an array")])])
        unit)
      (if (= (string.string-length error) 0)
        (LspInitializeLanguageConfig.Ok target cfg-names)
        (Err error)))))

(define (lsp-initialize-language-config [message : json.Json]) : LspInitializeLanguageConfig
  (let
    [params-key : String "params"]
    [options-key : String "initializationOptions"]
    [typelisp-key : String "typelisp"]
    (match (json.object-get message (& params-key))
      [(JsonMissing)
        (LspInitializeLanguageConfig.Ok
          (target_cfg.compiler-target-cfg-host)
          (lsp_svec.new))]
      [(JsonFound params)
        (match (json.object-get params (& options-key))
          [(JsonMissing)
            (LspInitializeLanguageConfig.Ok
              (target_cfg.compiler-target-cfg-host)
              (lsp_svec.new))]
          [(JsonFound options)
            (match (json.object-get
              (owned_view.compiler-owned-shared-view options)
              (& typelisp-key))
              [(JsonFound typelisp-options)
                (lsp-initialize-cfg-names typelisp-options)]
              [(JsonMissing) (lsp-initialize-cfg-names options)])])])))

(define (lsp-write-json [value : json.Json]) : unit
  (lsp-frame-write-body (json.stringify value)))

(define (lsp-write-response [id : json.Json] [result : json.Json]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "id"
          id
          (lsp-json-member "result" result (json.member-list-empty)))))))

(define (lsp-write-error [id : json.Json] [code : i64] [message : String]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "id"
          id
          (lsp-json-member
            "error"
            (lsp-json-object2
              "code"
              (lsp-json-number code)
              "message"
              (JsonString message))
            (json.member-list-empty)))))))

(define (lsp-write-error-with-data
  [id : json.Json]
  [code : i64]
  [message : String]
  [data : json.Json]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "id"
          id
          (lsp-json-member
            "error"
            (lsp-json-object3
              "code"
              (lsp-json-number code)
              "message"
              (JsonString message)
              "data"
              data)
            (json.member-list-empty)))))))

(define (lsp-write-error-with-context
  [id : json.Json]
  [code : i64]
  [message : String]
  [context : json.Json]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "id"
          id
          (lsp-json-member
            "error"
            (lsp-json-object
              (lsp-json-member
                "code"
                (lsp-json-number code)
                (lsp-json-member
                  "message"
                  (JsonString (owned_view.compiler-owned-shared-view message))
                  (lsp-json-member
                    "data"
                    (lsp-json-object3
                      "success"
                      (JsonBool false)
                      "error"
                      (JsonString message)
                      "context"
                      context)
                    (json.member-list-empty)))))
            (json.member-list-empty)))))))

(define (lsp-write-parse-error [message : String]) : unit
  (lsp-write-error JsonNull -32700 message))

(define (lsp-semantic-token-legend-types) : json.Json
  (let
    [items : (__tl_dyn-array json.Json) (__tl_make-array json.Json 13)]
    (begin
      (set! (array-ref items 0) (json.JsonString "namespace"))
      (set! (array-ref items 1) (json.JsonString "type"))
      (set! (array-ref items 2) (json.JsonString "enumMember"))
      (set! (array-ref items 3) (json.JsonString "function"))
      (set! (array-ref items 4) (json.JsonString "macro"))
      (set! (array-ref items 5) (json.JsonString "parameter"))
      (set! (array-ref items 6) (json.JsonString "variable"))
      (set! (array-ref items 7) (json.JsonString "property"))
      (set! (array-ref items 8) (json.JsonString "keyword"))
      (set! (array-ref items 9) (json.JsonString "comment"))
      (set! (array-ref items 10) (json.JsonString "string"))
      (set! (array-ref items 11) (json.JsonString "number"))
      (set! (array-ref items 12) (json.JsonString "operator"))
      (lsp-json-array (json.JsonSeq items 13)))))

(define (lsp-semantic-token-legend-modifiers) : json.Json
  (let
    [items : (__tl_dyn-array json.Json) (__tl_make-array json.Json 4)]
    (begin
      (set! (array-ref items 0) (json.JsonString "declaration"))
      (set! (array-ref items 1) (json.JsonString "definition"))
      (set! (array-ref items 2) (json.JsonString "readonly"))
      (set! (array-ref items 3) (json.JsonString "defaultLibrary"))
      (lsp-json-array (json.JsonSeq items 4)))))

(define (lsp-semantic-token-provider-capability) : json.Json
  (lsp-json-object2
    "legend"
    (lsp-json-object2
      "tokenTypes"
      (lsp-semantic-token-legend-types)
      "tokenModifiers"
      (lsp-semantic-token-legend-modifiers))
    "full"
    (JsonBool true)))

(define (lsp-initialize-result) : json.Json
  (lsp-json-object2
    "capabilities"
    (lsp-json-object
      (lsp-json-member
        "positionEncoding"
        (JsonString (lsp-position-encoding-name))
        (lsp-json-member
          "textDocumentSync"
          (lsp-json-object2
            "openClose"
            (JsonBool true)
            "change"
            (lsp-json-number 1))
          (lsp-json-member
            "definitionProvider"
            (JsonBool true)
            (lsp-json-member
              "referencesProvider"
              (JsonBool true)
              (lsp-json-member
                "renameProvider"
                (lsp-json-object1 "prepareProvider" (JsonBool true))
                (lsp-json-member
                  "documentSymbolProvider"
                  (JsonBool true)
                  (lsp-json-member
                    "documentHighlightProvider"
                    (JsonBool true)
                    (lsp-json-member
                      "completionProvider"
                      (lsp-json-object1 "resolveProvider" (JsonBool false))
                      (lsp-json-member
                        "signatureHelpProvider"
                        (lsp-json-object2
                          "triggerCharacters"
                          (lsp-json-array
                            (lsp-json-list-cons
                              (JsonString " ")
                              (json.list-empty)))
                          "retriggerCharacters"
                          (lsp-json-array
                            (lsp-json-list-cons
                              (JsonString ")")
                              (json.list-empty))))
                        (lsp-json-member
                          "codeActionProvider"
                          (lsp-json-object1
                            "codeActionKinds"
                            (lsp-json-array
                              (lsp-json-list-cons
                                (JsonString "quickfix")
                                (json.list-empty))))
                          (lsp-json-member
                            "inlayHintProvider"
                            (JsonBool true)
                            (lsp-json-member
                              "documentFormattingProvider"
                              (JsonBool true)
                              (lsp-json-member
                                "hoverProvider"
                                (JsonBool true)
                                (lsp-json-member
                                  "documentLinkProvider"
                                  (lsp-json-object1
                                    "resolveProvider"
                                    (JsonBool false))
                                  (lsp-json-member
                                    "foldingRangeProvider"
                                    (JsonBool true)
                                    (lsp-json-member
                                      "semanticTokensProvider"
                                      (lsp-semantic-token-provider-capability)
                                      (lsp-json-member
                                        "workspaceSymbolProvider"
                                        (JsonBool true)
                                        (lsp-json-member
                                          "workspace"
                                          (lsp-json-object1
                                            "workspaceFolders"
                                            (lsp-json-object2
                                              "supported"
                                              (JsonBool true)
                                              "changeNotifications"
                                              (JsonBool true)))
                                          (json.member-list-empty))))))))))))))))))))
    "serverInfo"
    (lsp-json-object2
      "name"
      (JsonString "typelisp")
      "version"
      (JsonString "selfhost"))))

(define (lsp-diagnostic-uris-empty) : lsp_vector_families.LspDiagnosticUris
  (lsp_vector_families.LspDiagnosticUris (__tl_make-array String 0) 0))

(define (lsp-diagnostic-uris-len
  [uris : (& uris lsp_vector_families.LspDiagnosticUris)]) : i64
  uris.len)

(define (lsp-diagnostic-uris-get
  [uris : lsp_vector_families.LspDiagnosticUris]
  [index : i64]) : String
  (array-ref uris.slots index))

(define (lsp-diagnostic-uris-contains-from?
  [uris : lsp_vector_families.LspDiagnosticUris]
  [uri : String]
  [index : i64]) : bool
  (if (>= index (lsp-diagnostic-uris-len uris))
    false
    (if (string.eq
      (lsp-diagnostic-uris-get
        (owned_view.compiler-owned-shared-view uris)
        index)
      uri)
      true
      (lsp-diagnostic-uris-contains-from? uris uri (+ index 1)))))

(define (lsp-diagnostic-uris-contains?
  [uris : lsp_vector_families.LspDiagnosticUris]
  [uri : String]) : bool
  (lsp-diagnostic-uris-contains-from? uris uri 0))

(define (lsp-diagnostic-uris-add
  [uris : lsp_vector_families.LspDiagnosticUris]
  [uri : String]) : lsp_vector_families.LspDiagnosticUris
  (if (lsp-diagnostic-uris-contains?
    (owned_view.compiler-owned-shared-view uris)
    (owned_view.compiler-owned-shared-view uri))
    uris
    (let
      [n : i64 (lsp-diagnostic-uris-len uris)]
      [slots : (__tl_dyn-array String) uris.slots]
      (begin
        (if (< n (array-length slots))
          unit
          (let
            [old-cap : i64 (array-length slots)]
            [new-cap : i64
              (if (< old-cap 4)
                4
                (* old-cap 2))]
            [bigger : (__tl_dyn-array String) (__tl_make-array String new-cap)]
            [index : i64 0]
            (begin
              (while (< index n)
                (begin
                  (set! (array-ref bigger index) (array-ref slots index))
                  (set! index (+ index 1))))
              (set! slots bigger))))
        (set! (array-ref slots n) uri)
        (lsp_vector_families.LspDiagnosticUris slots (+ n 1))))))

(define (lsp-semantic-snapshot-empty) : lsp_vector_families.LspSemanticSnapshot
  (lsp_vector_families.LspSemanticSnapshot
    (compiler_semantic_index.compiler-semantic-source-index-empty)
    -1
    ""
    ""
    false))

(define (lsp-semantic-snapshot-release!
  [snapshot : (&mut snapshot lsp_vector_families.LspSemanticSnapshot)]) : unit
  (if snapshot.present
    (begin
      (compiler_semantic_index.compiler-semantic-source-index-release!
        (&mut snapshot.index))
      (set! snapshot.version -1)
      (set! snapshot.source-path "")
      (set! snapshot.source-text "")
      (set! snapshot.present false))
    unit))

(define (lsp-document-semantic-snapshot-status
  [doc : (& doc lsp_vector_families.LspDocument)]) : LspSemanticSnapshotStatus
  (let
    [snapshot : lsp_vector_families.LspSemanticSnapshot doc.semantic]
    (if (not snapshot.present)
      Missing
      (let
        [index : compiler_semantic_index.CompilerSemanticSourceIndex
          snapshot.index]
        [version : i64 snapshot.version]
        [complete : bool
          (compiler_semantic_index.compiler-semantic-source-index-complete?
            (& index))]
        [current : bool
          (and
            (= version doc.version)
            (string.eq snapshot.source-path doc.path)
            (string.eq snapshot.source-text doc.text))]
        (if current
          (Current version complete)
          (Stale version complete))))))

(define (lsp-document-semantic-record-at
  [doc : (& doc lsp_vector_families.LspDocument)]
  [byte-position : i64]) : i64
  (match (lsp-document-semantic-snapshot-status doc)
    [(Current _ _)
      (compiler_semantic_index.compiler-semantic-source-index-find-editable-record-at
        (& doc.semantic.index)
        (& doc.path)
        byte-position)]
    [_ -1]))

(define (lsp-semantic-record-exact-editable?
  [record : (& record compiler_semantic_index.CompilerSemanticRecord)]) : bool
  (let
    [span : compiler_semantic_index.CompilerSemanticSpan record.span]
    [source-span : ast.AstSourceSpan span.source]
    (and
      record.editable
      (match record.provenance
        [(EditableSource) true]
        [_ false])
      (not (string.eq span.path ""))
      (>= span.start-byte 0)
      (> span.end-byte span.start-byte)
      (> (cast source-span.start-line : i64) 0)
      (> (cast source-span.start-col : i64) 0)
      (> (cast source-span.end-line : i64) 0)
      (> (cast source-span.end-col : i64) 0)
      (> span.utf16-start-col 0)
      (> span.utf16-end-col 0))))

(define (lsp-document-semantic-symbol-query
  [doc : (& doc lsp_vector_families.LspDocument)]
  [byte-position : i64]) : LspSemanticSymbolQuery
  (match (lsp-document-semantic-snapshot-status doc)
    [(Current _ _)
      (let
        [index : compiler_semantic_index.CompilerSemanticSourceIndex
          doc.semantic.index]
        [cursor-index : i64
          (compiler_semantic_index.compiler-semantic-source-index-find-editable-record-at
            (& index)
            (& doc.path)
            byte-position)]
        [cursor-record : compiler_semantic_index.CompilerSemanticRecord
          (compiler_semantic_index.compiler-semantic-source-index-get
            (& index)
            cursor-index)]
        [definition-index : i64
          (if (< cursor-index 0)
            -1
            (compiler_semantic_index.compiler-semantic-source-index-find-symbol-role
              (& index)
              cursor-record.symbol
              Definition))]
        (if (or (< cursor-index 0) (< definition-index 0))
          Missing
          (let
            [cursor : compiler_semantic_index.CompilerSemanticRecord
              cursor-record]
            [definition : compiler_semantic_index.CompilerSemanticRecord
              (compiler_semantic_index.compiler-semantic-source-index-get
                (& index)
                definition-index)]
            (if (and
              (lsp-semantic-record-exact-editable? cursor)
              (lsp-semantic-record-exact-editable? definition))
              (Found cursor definition)
              Missing))))]
    [_ Missing]))

(define (lsp-document-fallback) : lsp_vector_families.LspDocument
  (lsp_vector_families.LspDocument
    ""
    ""
    ""
    -1
    (lsp-diagnostic-uris-empty)
    (lsp_decl_vec.new)
    false
    LspCheckCacheInvalid
    (lsp-semantic-snapshot-empty)))

(define lsp-document-cache-arena : i64
  0)

(define (lsp-documents-find-index-from
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : (& uri str)]
  [index : i64]) : i64
  (let
    [i : i64 index]
    [found : i64 -1]
    [done : bool false]
    (begin
      (while (< i (lsp_document_vec.len docs))
        (if done
          (set! i (lsp_document_vec.len docs))
          (let
            [doc : lsp_vector_families.LspDocument
              (lsp_document_vec.get docs i (lsp-document-fallback))]
            (if (string.eq doc.uri uri)
              (begin
                (set! found i)
                (set! done true)
                (set! i (lsp_document_vec.len docs)))
              (set! i (+ i 1))))))
      found)))

(define (lsp-documents-find-index
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : (& uri str)]) : i64
  (lsp-documents-find-index-from docs uri 0))

(define (lsp-documents-set-versioned
  [docs : lsp_document_vec.Vec]
  [uri : String]
  [path : String]
  [text : String]
  [version : i64]
  [diagnostic-uris : lsp_vector_families.LspDiagnosticUris]) : lsp_document_vec.Vec
  (let
    [docs : lsp_document_vec.Vec docs]
    [index : i64 (lsp-documents-find-index docs uri)]
    [cached-diagnostic-uris : lsp_vector_families.LspDiagnosticUris
      (lsp-cache-diagnostic-uris-copy diagnostic-uris)]
    (if (>= index 0)
      (let
        [old-doc : lsp_vector_families.LspDocument
          (lsp_document_vec.get (& docs) index (lsp-document-fallback))]
        [old-text : String old-doc.text]
        [old-decls : lsp_decl_vec.Vec old-doc.decls]
        [old-decls-valid : bool old-doc.decls-valid]
        [old-check-cache : lsp_vector_families.LspCheckCache
          old-doc.check-cache]
        [new-decls : lsp_decl_vec.Vec
          (if (string.eq old-text text)
            old-decls
            (lsp_decl_vec.new))]
        [new-decls-valid : bool
          (if (string.eq old-text text)
            old-decls-valid
            false)]
        [new-check-cache : lsp_vector_families.LspCheckCache
          (if (string.eq old-text text)
            old-check-cache
            LspCheckCacheInvalid)]
        (begin
          (lsp_document_vec.set-ref!
            (&mut docs)
            index
            (lsp_vector_families.LspDocument
              uri
              path
              text
              version
              cached-diagnostic-uris
              new-decls
              new-decls-valid
              new-check-cache
              old-doc.semantic))
          docs))
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp_vector_families.LspDocument
            uri
            path
            text
            version
            cached-diagnostic-uris
            (lsp_decl_vec.new)
            false
            LspCheckCacheInvalid
            (lsp-semantic-snapshot-empty))]
        (begin
          ;; Open buffers are correctness state, not an eviction cache. The
          ;; enclosing lsp_vector_families.LspServerState snapshot bounds their retained storage.
          (lsp_document_vec.push-ref! (&mut docs) doc)
          docs)))))

(define (lsp-documents-set
  [docs : lsp_document_vec.Vec]
  [uri : String]
  [path : String]
  [text : String]
  [diagnostic-uris : lsp_vector_families.LspDiagnosticUris]) : lsp_document_vec.Vec
  (lsp-documents-set-versioned docs uri path text -1 diagnostic-uris))

(define (lsp-documents-set-check-cache!
  [docs : (&mut docs lsp_document_vec.Vec)]
  [uri : (& uri str)]
  [check-cache : lsp_vector_families.LspCheckCache]) : unit
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< index (lsp_document_vec.len (& docs))) (< found 0))
        (let
          [doc : lsp_vector_families.LspDocument
            (lsp_document_vec.get (& docs) index (lsp-document-fallback))]
          (if (string.eq doc.uri uri)
            (set! found index)
            (set! index (+ index 1)))))
      (if (>= found 0)
        (let
          [doc : lsp_vector_families.LspDocument
            (lsp_document_vec.get (& docs) found (lsp-document-fallback))]
          (lsp_document_vec.set-ref!
            (&mut docs)
            found
            (lsp_vector_families.LspDocument
              doc.uri
              doc.path
              doc.text
              doc.version
              doc.diagnostic-uris
              doc.decls
              doc.decls-valid
              check-cache
              doc.semantic)))
        unit))))

(define (lsp-documents-set-check-cache
  [docs : lsp_document_vec.Vec]
  [uri : (& uri str)]
  [check-cache : lsp_vector_families.LspCheckCache]) : lsp_document_vec.Vec
  (let
    [docs : lsp_document_vec.Vec docs]
    (begin
      (lsp-documents-set-check-cache! (&mut docs) uri check-cache)
      docs)))

(define (lsp-documents-set-semantic-index
  [docs : lsp_document_vec.Vec]
  [uri : (& uri str)]
  [version : i64]
  [semantic-index : compiler_semantic_index.CompilerSemanticSourceIndex]) : lsp_document_vec.Vec
  (let
    [docs : lsp_document_vec.Vec docs]
    [semantic-index : compiler_semantic_index.CompilerSemanticSourceIndex
      semantic-index]
    [index : i64 (lsp-documents-find-index docs uri)]
    (if (>= index 0)
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp_document_vec.get (& docs) index (lsp-document-fallback))]
        [snapshot : lsp_vector_families.LspSemanticSnapshot
          (in-arena
            (arena.Arena semantic-index.owner-arena)
            (lsp_vector_families.LspSemanticSnapshot
              semantic-index
              version
              (string.copy (& doc.path))
              (string.copy (& doc.text))
              true))]
        (begin
          (lsp-semantic-snapshot-release! (&mut doc.semantic))
          (set! doc.semantic snapshot)
          (lsp_document_vec.set-ref! (&mut docs) index doc)
          docs))
      (begin
        (compiler_semantic_index.compiler-semantic-source-index-release!
          (&mut semantic-index))
        docs))))

(define (lsp-documents-release-index!
  [docs : (&mut docs lsp_document_vec.Vec)]
  [index : i64]) : unit
  (if (and (>= index 0) (< index (lsp_document_vec.len (& docs))))
    (let
      [doc : lsp_vector_families.LspDocument
        (lsp_document_vec.get (& docs) index (lsp-document-fallback))]
      (begin
        (lsp-semantic-snapshot-release! (&mut doc.semantic))
        (lsp_document_vec.set-ref! (&mut docs) index doc)))
    unit))

(define (lsp-documents-release-all! [docs : (&mut docs lsp_document_vec.Vec)]) : unit
  (let
    [index : i64 0]
    (while (< index (lsp_document_vec.len (& docs)))
      (begin
        (lsp-documents-release-index! docs index)
        (set! index (+ index 1))))))

(define (lsp-documents-shift-left!
  [docs : (&mut docs lsp_document_vec.Vec)]
  [index : i64]) : unit
  (let
    [i : i64 index]
    [last : i64 (- (lsp_document_vec.len (& docs)) 1)]
    (while (< i last)
      (let
        [next : lsp_vector_families.LspDocument
          (lsp_document_vec.get (& docs) (+ i 1) (lsp-document-fallback))]
        (begin
          (lsp_document_vec.set-ref! (&mut docs) i next)
          (set! i (+ i 1)))))))

(define (lsp-documents-remove-index [docs : lsp_document_vec.Vec] [index : i64]) : lsp_document_vec.Vec
  (let
    [docs : lsp_document_vec.Vec docs]
    (if (if (>= index 0)
      (< index (lsp_document_vec.len (& docs)))
      false)
      (begin
        (lsp-documents-release-index! (&mut docs) index)
        (lsp-documents-shift-left! (&mut docs) index)
        (lsp_vector_families.lsp-documents-drop-last! (&mut docs))
        docs)
      docs)))

(define (lsp-documents-remove [docs : lsp_document_vec.Vec] [uri : String]) : lsp_document_vec.Vec
  (let
    [index : i64 (lsp-documents-find-index docs uri)]
    (lsp-documents-remove-index docs index)))

(define (lsp-documents-lookup
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : (& uri str)]) : LspDocumentLookup
  (let
    [index : i64 (lsp-documents-find-index docs uri)]
    (if (>= index 0)
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp_document_vec.get (& docs) index (lsp-document-fallback))]
        (Found doc.path doc.text doc.diagnostic-uris))
      Missing)))

(define (lsp-document-refresh-from-disk
  [docs : lsp_document_vec.Vec]
  [index : i64]) : lsp_vector_families.LspDocument
  (let
    [doc : lsp_vector_families.LspDocument
      (lsp_document_vec.get (& docs) index (lsp-document-fallback))]
    [slots : (__tl_dyn-array lsp_vector_families.LspDocument) docs.slots]
    [path : String doc.path]
    ;; Versioned documents are client-owned open buffers. Only unversioned
    ;; entries loaded by tooling may be refreshed from disk.
    (if (or (string.eq path "") (>= doc.version 0))
      doc
      (match (io.try-read-file (& path))
        [(OkIoBytes disk-contents)
          (let
            [disk-text : String (byte_buf.to-string disk-contents)]
            (if (string.eq disk-text doc.text)
              doc
              (let
                [updated : lsp_vector_families.LspDocument
                  (lsp_vector_families.LspDocument
                    doc.uri
                    path
                    disk-text
                    -1
                    doc.diagnostic-uris
                    (lsp_decl_vec.new)
                    false
                    LspCheckCacheInvalid
                    (lsp-semantic-snapshot-empty))]
                (begin
                  (lsp-semantic-snapshot-release! (&mut doc.semantic))
                  (set! (array-ref slots index) updated)
                  updated))))]
        [(ErrIoBytes _) doc]))))

(define (lsp-documents-lookup-resynced
  [docs : lsp_document_vec.Vec]
  [uri : (& uri str)]) : LspDocumentLookup
  (let
    [index : i64 (lsp-documents-find-index docs uri)]
    (if (>= index 0)
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp-document-refresh-from-disk docs index)]
        (Found doc.path doc.text doc.diagnostic-uris))
      Missing)))

(define (lsp-workspace-root-fallback) : lsp_vector_families.LspWorkspaceRoot
  (lsp_vector_families.LspWorkspaceRoot "" ""))

(define (lsp-workspace-source-fallback) : lsp_vector_families.LspWorkspaceSource
  (lsp_vector_families.LspWorkspaceSource
    ""
    ""
    ""
    ""
    ""
    false
    false
    (lsp_decl_vec.new)))

(define (lsp-workspace-roots-new) : lsp_vector_families.LspWorkspaceRoots
  (lsp_vector_families.LspWorkspaceRoots
    (__tl_make-array lsp_vector_families.LspWorkspaceRoot 0)
    0))

(define (lsp-workspace-roots-len
  [roots : (& roots lsp_vector_families.LspWorkspaceRoots)]) : i64
  roots.len)

(define (lsp-workspace-roots-get
  [roots : (& roots lsp_vector_families.LspWorkspaceRoots)]
  [index : i64]) : lsp_vector_families.LspWorkspaceRoot
  (if (and (>= index 0) (< index roots.len))
    (array-ref roots.slots index)
    (lsp-workspace-root-fallback)))

(define (lsp-workspace-roots-copy-range!
  [dst : (&mut dst (__tl_dyn-array lsp_vector_families.LspWorkspaceRoot))]
  [src : (& src (__tl_dyn-array lsp_vector_families.LspWorkspaceRoot))]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (lsp-workspace-roots-grow!
  [roots : (&mut roots lsp_vector_families.LspWorkspaceRoots)]) : unit
  (let
    [old-cap : i64 (array-length roots.slots)]
    [new-cap : i64
      (if (< old-cap 4)
        4
        (* old-cap 2))]
    [bigger : (__tl_dyn-array lsp_vector_families.LspWorkspaceRoot)
      (__tl_make-array lsp_vector_families.LspWorkspaceRoot new-cap)]
    (begin
      (lsp-workspace-roots-copy-range! (&mut bigger) (& roots.slots) roots.len)
      (set! roots.slots bigger))))

(define (lsp-workspace-roots-push!
  [roots : (&mut roots lsp_vector_families.LspWorkspaceRoots)]
  [root : lsp_vector_families.LspWorkspaceRoot]) : unit
  (begin
    (if (>= roots.len (array-length roots.slots))
      (lsp-workspace-roots-grow! roots)
      unit)
    (set! (array-ref roots.slots roots.len) root)
    (set! roots.len (+ roots.len 1))))

(define (lsp-workspace-roots-find-uri
  [roots : (& roots lsp_vector_families.LspWorkspaceRoots)]
  [uri : String]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< index roots.len) (< found 0))
        (if (string.eq
          (__tl-project-field (array-ref roots.slots index) uri)
          uri)
          (set! found index)
          (set! index (+ index 1))))
      found)))

(define (lsp-workspace-roots-remove-index!
  [roots : (&mut roots lsp_vector_families.LspWorkspaceRoots)]
  [index : i64]) : unit
  (if (or (< index 0) (>= index roots.len))
    unit
    (let
      [cursor : i64 index]
      [last : i64 (- roots.len 1)]
      (begin
        (while (< cursor last)
          (begin
            (set!
              (array-ref roots.slots cursor)
              (array-ref roots.slots (+ cursor 1)))
            (set! cursor (+ cursor 1))))
        (set! roots.len last)))))

(define (lsp-workspace-sources-new) : lsp_vector_families.LspWorkspaceSources
  (lsp_vector_families.LspWorkspaceSources
    (__tl_make-array lsp_vector_families.LspWorkspaceSource 0)
    0))

(define (lsp-workspace-sources-len
  [sources : (& sources lsp_vector_families.LspWorkspaceSources)]) : i64
  sources.len)

(define (lsp-workspace-sources-get
  [sources : (& sources lsp_vector_families.LspWorkspaceSources)]
  [index : i64]) : lsp_vector_families.LspWorkspaceSource
  (if (and (>= index 0) (< index sources.len))
    (array-ref sources.slots index)
    (lsp-workspace-source-fallback)))

(define (lsp-workspace-sources-copy-range!
  [dst : (&mut dst (__tl_dyn-array lsp_vector_families.LspWorkspaceSource))]
  [src : (& src (__tl_dyn-array lsp_vector_families.LspWorkspaceSource))]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (lsp-workspace-sources-grow!
  [sources : (&mut sources lsp_vector_families.LspWorkspaceSources)]) : unit
  (let
    [old-cap : i64 (array-length sources.slots)]
    [new-cap : i64
      (if (< old-cap 8)
        8
        (* old-cap 2))]
    [bigger : (__tl_dyn-array lsp_vector_families.LspWorkspaceSource)
      (__tl_make-array lsp_vector_families.LspWorkspaceSource new-cap)]
    (begin
      (lsp-workspace-sources-copy-range!
        (&mut bigger)
        (& sources.slots)
        sources.len)
      (set! sources.slots bigger))))

(define (lsp-workspace-sources-push!
  [sources : (&mut sources lsp_vector_families.LspWorkspaceSources)]
  [source : lsp_vector_families.LspWorkspaceSource]) : unit
  (begin
    (if (>= sources.len (array-length sources.slots))
      (lsp-workspace-sources-grow! sources)
      unit)
    (set! (array-ref sources.slots sources.len) source)
    (set! sources.len (+ sources.len 1))))

(define (lsp-workspace-sources-set!
  [sources : (&mut sources lsp_vector_families.LspWorkspaceSources)]
  [index : i64]
  [source : lsp_vector_families.LspWorkspaceSource]) : unit
  (if (and (>= index 0) (< index sources.len))
    (set! (array-ref sources.slots index) source)
    unit))

(define (lsp-workspace-sources-find-uri
  [sources : (& sources lsp_vector_families.LspWorkspaceSources)]
  [uri : String]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< index sources.len) (< found 0))
        (if (string.eq
          (__tl-project-field (array-ref sources.slots index) uri)
          uri)
          (set! found index)
          (set! index (+ index 1))))
      found)))

(define (lsp-workspace-sources-remove-index!
  [sources : (&mut sources lsp_vector_families.LspWorkspaceSources)]
  [index : i64]) : unit
  (if (or (< index 0) (>= index sources.len))
    unit
    (let
      [cursor : i64 index]
      [last : i64 (- sources.len 1)]
      (begin
        (while (< cursor last)
          (begin
            (set!
              (array-ref sources.slots cursor)
              (array-ref sources.slots (+ cursor 1)))
            (set! cursor (+ cursor 1))))
        (set! sources.len last)))))

(define (lsp-documents-find-path-index
  [docs : (& docs lsp_document_vec.Vec)]
  [path : (& path str)]) : i64
  (let
    [normalized : String (compiler_load.compiler-load-normalize-path path)]
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< index (lsp_document_vec.len docs)) (< found 0))
        (let
          [doc : lsp_vector_families.LspDocument
            (lsp_document_vec.get docs index (lsp-document-fallback))]
          (if (string.eq
            (compiler_load.compiler-load-normalize-path doc.path)
            normalized)
            (set! found index)
            (set! index (+ index 1)))))
      found)))

(define (lsp-hex-value [c : char]) : i64
  (let
    [code : i64 (cast c : i64)]
    (cond
      [(and (>= code 48) (<= code 57)) (- code 48)]
      [(and (>= code 65) (<= code 70)) (+ 10 (- code 65))]
      [(and (>= code 97) (<= code 102)) (+ 10 (- code 97))]
      [else -1])))

;; A file URI percent-encodes the path's bytes (#8376): `%XX` is the byte XX,
;; not the code point U+00XX, so a non-ASCII name such as `%C3%A5` decodes to
;; the two bytes of its UTF-8 spelling. That inverts `lsp-percent-encode-path`
;; for every path it encodes. Decoded bytes that are not well-formed UTF-8, or
;; that contain NUL, are refused rather than repaired.
(define (lsp-percent-decode [text : String]) : LspStringResult
  (let
    [n : i64 (string.string-length text)]
    ;; Decoding never lengthens the text.
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [len : i64 0]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i n))
        (if (= (string.string-ref text i) '%')
          (let
            [hi : i64
              (if (< (+ i 2) n)
                (lsp-hex-value (string.string-ref text (+ i 1)))
                -1)]
            [lo : i64
              (if (< (+ i 2) n)
                (lsp-hex-value (string.string-ref text (+ i 2)))
                -1)]
            (if (and (>= hi 0) (>= lo 0))
              (begin
                (set! (array-ref bytes len) (cast (+ (* hi 16) lo) : u8))
                (set! len (+ len 1))
                (set! i (+ i 3)))
              (set! ok false)))
          (begin
            (set! (array-ref bytes len) (cast (string.string-ref text i) : u8))
            (set! len (+ len 1))
            (set! i (+ i 1)))))
      (cond
        [(not ok) (Err "lsp: invalid percent escape in file URI")]
        [(not
            (compiler_incremental_binary.compiler-incremental-binary-utf8-range-valid?
              (& bytes)
              0
              len))
          (Err "lsp: file URI path is not valid UTF-8")]
        [(= len 0) (Ok "")]
        [else
          (Ok
            (unsafe
              (string-from-bytes
                (ptr-cast (__tl_array-data bytes) : (Ptr u8))
                len)))]))))

(define (lsp-uri-path-strip-windows-leading-slash [path : String]) : String
  (let
    [n : i64 (string.string-length path)]
    (if (and
      (> n 2)
      (= (string.string-ref path 0) '/')
      (= (string.string-ref path 2) ':'))
      (string.substring path 1 (- n 1))
      path)))

(define (lsp-file-uri-to-path [uri : (& uri str)]) : LspUriPath
  (if (source_text.starts-with? uri "file://")
    (match (lsp-percent-decode
      (string.substring uri 7 (- (string.string-length uri) 7)))
      [(Ok decoded)
        (let
          [path : String (lsp-uri-path-strip-windows-leading-slash decoded)]
          (if (> (string.string-length path) 0)
            (Ok path)
            (Err "unsupported TypeLisp LSP URI: empty file path")))]
      [(Err message) (Err message)])
    (Err "unsupported TypeLisp LSP URI: expected file:// URI")))

(define (lsp-uri-safe-code? [code : i64]) : bool
  (or
    (and (>= code 65) (<= code 90))
    (and (>= code 97) (<= code 122))
    (and (>= code 48) (<= code 57))
    (= code 45)
    (= code 46)
    (= code 95)
    (= code 126)
    (= code 47)
    (= code 58)))

(define (lsp-percent-encode-path [path : String]) : String
  (let
    [n : i64 (string.string-length path)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (let
            [code : i64 (cast (string.string-ref path i) : i64)]
            (if (lsp-uri-safe-code? code)
              (set! out (str_cat.str-cat out (string.substring path i 1) ""))
              (set!
                out
                (lsp-str4
                  out
                  "%"
                  (json.hex-digit (/ code 16))
                  (json.hex-digit (- code (* (/ code 16) 16)))))))
          (set! i (+ i 1))))
      out)))

(define (lsp-path-to-file-uri [path : String]) : String
  (if (and (> (string.string-length path) 0) (= (string.string-ref path 0) '/'))
    (lsp-str2 "file://" (lsp-percent-encode-path path))
    (lsp-str2 "file:///" (lsp-percent-encode-path path))))

(define (lsp-resolved-path-to-file-uri [path : (& path str)]) : String
  (let
    [normalized : String (fs.path-normalize (& path))]
    (lsp-path-to-file-uri
      (if (fs.path-absolute? (& normalized))
        normalized
        (let
          [cwd : String (fs.current-dir)]
          [joined : String (fs.path-join (& cwd) (& normalized))]
          (fs.path-normalize (& joined)))))))

(define (lsp-normalized-absolute-path [path : String]) : String
  (let
    [normalized : String (fs.path-normalize (& path))]
    (if (fs.path-absolute? (& normalized))
      normalized
      (let
        [cwd : String (fs.current-dir)]
        [joined : String (fs.path-join (& cwd) (& normalized))]
        (fs.path-normalize (& joined))))))

(define (lsp-workspace-root-from-uri [uri : String]) : lsp_vector_families.LspWorkspaceRootLookup
  (match (lsp-file-uri-to-path uri)
    [(Err _) Missing]
    [(Ok path)
      (let
        [normalized : String (lsp-normalized-absolute-path path)]
        [canonical-uri : String
          (lsp-path-to-file-uri
            (owned_view.compiler-owned-shared-view normalized))]
        (Found
          (lsp_vector_families.LspWorkspaceRoot
            (string.copy (& canonical-uri))
            (string.copy (& normalized)))))]))

(define (lsp-workspace-roots-add-uri!
  [roots : (&mut roots lsp_vector_families.LspWorkspaceRoots)]
  [uri : String]) : unit
  (match (lsp-workspace-root-from-uri uri)
    [(Missing) unit]
    [(Found root)
      (if (>=
        (lsp-workspace-roots-find-uri
          roots
          (owned_view.compiler-owned-shared-view root.uri))
        0)
        unit
        (lsp-workspace-roots-push! roots root))]))

(define (lsp-workspace-roots-add-folder-items!
  [roots : (&mut roots lsp_vector_families.LspWorkspaceRoots)]
  [items : json.JsonSeq]) : unit
  (let
    [index : i64 0]
    [count : i64
      (json.list-count (owned_view.compiler-owned-shared-view items))]
    (while (< index count)
      (begin
        (match (json.list-get-index
          (owned_view.compiler-owned-shared-view items)
          index)
          [(JsonMissing) unit]
          [(JsonFound folder)
            (match (lsp-json-string-field folder "uri")
              [(Missing) unit]
              [(Ok uri) (lsp-workspace-roots-add-uri! roots uri)])])
        (set! index (+ index 1))))))

(define (lsp-initialize-workspace-roots [message : json.Json]) : lsp_vector_families.LspWorkspaceRoots
  (let
    [roots : lsp_vector_families.LspWorkspaceRoots (lsp-workspace-roots-new)]
    [params-key : String "params"]
    (begin
      (match (json.object-get message (& params-key))
        [(JsonMissing) unit]
        [(JsonFound params)
          (let
            [folders-key : String "workspaceFolders"]
            (begin
              (match (json.object-get
                (owned_view.compiler-owned-shared-view params)
                (& folders-key))
                [(JsonMissing) unit]
                [(JsonFound folders)
                  (match folders
                    [(JsonArray items)
                      (lsp-workspace-roots-add-folder-items!
                        (&mut roots)
                        (deref items))]
                    [_ unit])])
              (if (= (lsp-workspace-roots-len (& roots)) 0)
                (match (lsp-json-string-field params "rootUri")
                  [(Missing) unit]
                  [(Ok uri) (lsp-workspace-roots-add-uri! (&mut roots) uri)])
                unit)))])
      roots)))

(define (lsp-zero-based [value : i64]) : i64
  (if (> value 0)
    (- value 1)
    0))

(define (lsp-position [line : i64] [character : i64]) : json.Json
  (lsp-json-object2
    "line"
    (lsp-json-number (lsp-zero-based line))
    "character"
    (lsp-json-number (lsp-zero-based character))))

(define (lsp-range [line : i64] [col : i64]) : json.Json
  (lsp-json-object2
    "start"
    (lsp-position line col)
    "end"
    (lsp-position line (+ col 1))))

(define (lsp-source-for-compiler-span
  [fallback-path : (& fallback-path str)]
  [fallback-text : String]
  [span : (& span cdiag.CompilerDiagnosticSpan)]) : String
  (let
    [path : String (cdiag.compiler-diagnostic-span-path span)]
    (if (or (string.eq path "") (string.eq path fallback-path))
      fallback-text
      (lsp-read-file-text-or (& path) ""))))

(define (lsp-position-from-byte-line-col
  [text : (& text str)]
  [line : i64]
  [col : i64]) : json.Json
  (let
    [offset : i64
      (source_text.source-text-offset-at-byte-position
        text
        (lsp-zero-based line)
        (lsp-zero-based col))]
    [lc : LspLineCol (lsp-line-col-at-offset text offset)]
    (lsp-position lc.line lc.col)))

(define (lsp-range-from-compiler-span
  [fallback-path : String]
  [fallback-text : String]
  [span : (& span cdiag.CompilerDiagnosticSpan)]) : json.Json
  (let
    [text : String
      (lsp-source-for-compiler-span fallback-path fallback-text span)]
    [start-line : i64 (cdiag.compiler-diagnostic-span-start-line span)]
    [start-col : i64 (cdiag.compiler-diagnostic-span-start-col span)]
    [raw-end-line : i64 (cdiag.compiler-diagnostic-span-end-line span)]
    [safe-end-line : i64
      (if (>= raw-end-line start-line)
        raw-end-line
        start-line)]
    [raw-end-col : i64 (cdiag.compiler-diagnostic-span-end-col span)]
    [safe-end-col : i64
      (if (and (= start-line safe-end-line) (<= raw-end-col start-col))
        (+ start-col 1)
        raw-end-col)]
    (lsp-json-object2
      "start"
      (lsp-position-from-byte-line-col text start-line start-col)
      "end"
      (lsp-position-from-byte-line-col text safe-end-line safe-end-col))))

(define (lsp-diagnostic-related-uri
  [fallback-path : String]
  [span : (& span cdiag.CompilerDiagnosticSpan)]) : String
  (let
    [path : String (cdiag.compiler-diagnostic-span-path span)]
    [path-arg
      (if (string.eq path "")
        fallback-path
        path)]
    (lsp-resolved-path-to-file-uri path-arg)))

(define (lsp-diagnostic-related-message
  [label : cdiag.CompilerDiagnosticMaybeString]) : String
  (match label
    [(CompilerDiagnosticSomeString text) text]
    [CompilerDiagnosticNoString "related location"]))

(define (lsp-diagnostic-related-information
  [fallback-path : String]
  [fallback-text : String]
  [entry : cdiag.CompilerDiagnosticLabel]) : json.Json
  (let
    [span : cdiag.CompilerDiagnosticSpan entry.span]
    (lsp-json-object2
      "location"
      (lsp-json-object2
        "uri"
        (JsonString
          (lsp-diagnostic-related-uri
            (owned_view.compiler-owned-shared-view fallback-path)
            span))
        "range"
        (lsp-range-from-compiler-span fallback-path fallback-text span))
      "message"
      (JsonString (lsp-diagnostic-related-message entry.label)))))

(define (lsp-diagnostic-related-information-list
  [fallback-path : String]
  [fallback-text : String]
  [labels : cdiag.CompilerDiagnosticLabelList]) : json.JsonSeq
  (let
    [index : i64 (- (cdiag.compiler-diagnostic-label-list-count labels) 1)]
    [out : json.JsonSeq (json.list-empty)]
    (begin
      (while (>= index 0)
        (begin
          (set!
            out
            (lsp-json-list-cons
              (lsp-diagnostic-related-information
                (owned_view.compiler-owned-shared-view fallback-path)
                (owned_view.compiler-owned-shared-view fallback-text)
                (cdiag.compiler-diagnostic-label-list-get labels index))
              out))
          (set! index (- index 1))))
      out)))

(define (lsp-diagnostic-message-tail [message : String]) : json.JsonMemberSeq
  (lsp-json-member "message" (JsonString message) (json.member-list-empty)))

(define (lsp-diagnostic-data [version : i64] [kind : String] [index : i64]) : json.Json
  (lsp-json-object3
    "version"
    (lsp-json-number version)
    "kind"
    (JsonString kind)
    "index"
    (lsp-json-number index)))

(define (lsp-diagnostic-data-tail
  [version : i64]
  [kind : String]
  [index : i64]
  [tail : json.JsonMemberSeq]) : json.JsonMemberSeq
  (lsp-json-member "data" (lsp-diagnostic-data version kind index) tail))

(define (lsp-diagnostic-code-tail [code : String] [tail : json.JsonMemberSeq]) : json.JsonMemberSeq
  (if (string.eq code "")
    tail
    (lsp-json-member "code" (JsonString code) tail)))

(define (lsp-diagnostic-with-range-tail
  [range : json.Json]
  [code : String]
  [tail : json.JsonMemberSeq]) : json.Json
  (lsp-json-object
    (lsp-json-member
      "range"
      range
      (lsp-json-member
        "severity"
        (lsp-json-number 1)
        (lsp-json-member
          "source"
          (JsonString "typelisp")
          (lsp-diagnostic-code-tail code tail))))))

(define (lsp-diagnostic-with-range
  [range : json.Json]
  [message : String]
  [code : String]) : json.Json
  (lsp-diagnostic-with-range-tail
    range
    code
    (lsp-diagnostic-message-tail message)))

(define (lsp-diagnostic-with-range-data
  [range : json.Json]
  [message : String]
  [code : String]
  [version : i64]
  [kind : String]
  [index : i64]) : json.Json
  (lsp-diagnostic-with-range-tail
    range
    code
    (lsp-diagnostic-data-tail
      version
      kind
      index
      (lsp-diagnostic-message-tail message))))

(define (lsp-diagnostic
  [line : i64]
  [col : i64]
  [message : String]
  [code : String]) : json.Json
  (lsp-diagnostic-with-range (lsp-range line col) message code))

(define (lsp-one-codepoint-range-from-byte-position
  [text : (& text str)]
  [line : i64]
  [col : i64]) : json.Json
  (let
    [n : i64 (string.string-length text)]
    [start : i64
      (source_text.source-text-offset-at-byte-position
        text
        (lsp-zero-based line)
        (lsp-zero-based col))]
    [end : i64
      (if (< start n)
        (+ start 1)
        start)]
    (begin
      (while (and
        (< end n)
        (source_text.source-text-utf8-continuation-byte?
          (string.string-ref text end)))
        (set! end (+ end 1)))
      (lsp-json-object2
        "start"
        (lsp-offset-position-json text start)
        "end"
        (lsp-offset-position-json text end)))))

(define (lsp-diagnostic-from-byte-position-data
  [text : String]
  [line : i64]
  [col : i64]
  [message : String]
  [code : String]
  [version : i64]
  [kind : String]
  [index : i64]) : json.Json
  (lsp-diagnostic-with-range-data
    (lsp-one-codepoint-range-from-byte-position text line col)
    message
    code
    version
    kind
    index))

(define (lsp-compiler-diagnostic-kind
  [diag : (& diag cdiag.CompilerDiagnostic)]) : String
  (if (string.eq
    (cdiag.compiler-diagnostic-code-or-empty diag)
    (cdiag.compiler-diagnostic-code-parse))
    "parse"
    "compiler"))

(define (lsp-compiler-diagnostic-versioned
  [fallback-path : String]
  [fallback-text : String]
  [version : i64]
  [index : i64]
  [diag : cdiag.CompilerDiagnostic]) : json.Json
  (let
    [span : cdiag.CompilerDiagnosticSpan
      (cdiag.compiler-diagnostic-primary-span diag)]
    [path : String (cdiag.compiler-diagnostic-span-path span)]
    [text : String
      (lsp-source-for-compiler-span
        fallback-path
        (owned_view.compiler-owned-shared-view fallback-text)
        span)]
    [labels : cdiag.CompilerDiagnosticLabelList
      (cdiag.compiler-diagnostic-secondary-spans diag)]
    [range : json.Json
      (lsp-range-from-compiler-span fallback-path fallback-text span)]
    [message : String (cdiag.compiler-diagnostic-message diag)]
    [code : String (cdiag.compiler-diagnostic-code-or-empty diag)]
    [tail : json.JsonMemberSeq
      (lsp-diagnostic-data-tail
        version
        (lsp-compiler-diagnostic-kind diag)
        index
        (lsp-diagnostic-message-tail message))]
    (if (= (cdiag.compiler-diagnostic-label-list-count labels) 0)
      (lsp-diagnostic-with-range-tail range code tail)
      (lsp-diagnostic-with-range-tail
        range
        code
        (lsp-json-member
          "relatedInformation"
          (lsp-json-array
            (lsp-diagnostic-related-information-list path text labels))
          tail)))))

(define (lsp-diagnostic-uri
  [root-uri : String]
  [root-path : (& root-path str)]
  [diag : (& diag cdiag.CompilerDiagnostic)]) : String
  (let
    [diag-path : String (cdiag.compiler-diagnostic-path diag)]
    (if (or (string.eq diag-path "") (string.eq diag-path root-path))
      root-uri
      (lsp-resolved-path-to-file-uri diag-path))))

(define (lsp-publish-diagnostics [uri : String] [diagnostics : json.JsonSeq]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "method"
          (JsonString "textDocument/publishDiagnostics")
          (lsp-json-member
            "params"
            (lsp-json-object2
              "uri"
              (JsonString uri)
              "diagnostics"
              (lsp-json-array diagnostics))
            (json.member-list-empty)))))))

(define (lsp-publish-uri-diagnostic [uri : String] [message : String]) : unit
  (lsp-publish-diagnostics
    uri
    (lsp-json-list-cons (lsp-diagnostic 1 1 message "") (json.list-empty))))

(define (lsp-clear-diagnostic-uris-not-in
  [old-uris : lsp_vector_families.LspDiagnosticUris]
  [next-uris : lsp_vector_families.LspDiagnosticUris]) : unit
  (let
    ;; Dense construction appends first-seen URIs. Walk backward so stale
    ;; clears go out newest first, the established wire order.
    [index : i64 (- (lsp-diagnostic-uris-len old-uris) 1)]
    (while (>= index 0)
      (let
        [old-uri : String
          (lsp-diagnostic-uris-get
            (owned_view.compiler-owned-shared-view old-uris)
            index)]
        (begin
          (if (lsp-diagnostic-uris-contains?
            (owned_view.compiler-owned-shared-view next-uris)
            (owned_view.compiler-owned-shared-view old-uri))
            unit
            (lsp-publish-diagnostics old-uri (json.list-empty)))
          (set! index (- index 1)))))))

(define (lsp-clear-stale-diagnostics
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : (& uri str)]
  [next-diagnostic-uris : lsp_vector_families.LspDiagnosticUris]) : unit
  (match (lsp-documents-lookup docs uri)
    [(Found _ _ old-diagnostic-uris)
      (lsp-clear-diagnostic-uris-not-in
        old-diagnostic-uris
        next-diagnostic-uris)]
    [(Missing) unit]))

(define (lsp-clear-close-diagnostics
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : String]) : unit
  (match (lsp-documents-lookup docs uri)
    [(Found _ _ old-diagnostic-uris)
      (begin
        (lsp-publish-diagnostics uri (json.list-empty))
        (lsp-clear-diagnostic-uris-not-in
          old-diagnostic-uris
          (lsp-diagnostic-uris-empty)))]
    [(Missing) (lsp-publish-diagnostics uri (json.list-empty))]))

;; --------------------------------------------------------------------------
;; Lint findings as diagnostics (Warning severity), published for the open
;; document alongside the compiler error diagnostics. Findings carry the rule
;; id as the diagnostic code; `;; lint-allow: <rule-id>` suppressions and
;; derived-origin (macro-expanded) filtering match the `typelisp lint` CLI.
;; --------------------------------------------------------------------------
(define (lsp-lint-diagnostic
  [range : json.Json]
  [message : String]
  [code : String]
  [version : i64]
  [index : i64]) : json.Json
  (lsp-json-object
    (lsp-json-member
      "range"
      range
      (lsp-json-member
        "severity"
        (lsp-json-number 2)
        (lsp-json-member
          "source"
          (JsonString "typelisp-lint")
          (lsp-json-member
            "code"
            (JsonString code)
            (lsp-json-member
              "message"
              (JsonString message)
              (lsp-json-member
                "data"
                (lsp-diagnostic-data version "lint" index)
                (json.member-list-empty)))))))))

(define (lsp-lint-finding-diagnostic
  [text : String]
  [version : i64]
  [index : i64]
  [finding : lint.LintFinding]) : json.Json
  (let
    [span : ast.AstSourceSpan finding.span]
    (lsp-lint-diagnostic
      (lsp-one-codepoint-range-from-byte-position
        text
        (ast.ast-source-span-start-line span)
        (ast.ast-source-span-start-col span))
      finding.message
      finding.rule-id
      version
      index)))

(define (lsp-lint-findings-to-json
  [text : String]
  [version : i64]
  [findings : lint.LintFindings]
  [i : i64]
  [acc : json.JsonSeq]) : json.JsonSeq
  (if (>=
    i
    (lint.lint-findings-count (owned_view.compiler-owned-shared-view findings)))
    acc
    (let
      [finding : lint.LintFinding
        (owned_view.compiler-owned-array-element-shared-view
          (lint.lint-findings-slots
            (owned_view.compiler-owned-shared-view findings))
          i)]
      (if (lint_driver_core.selfhost-lint-suppressed?
        text
        (owned_view.compiler-owned-shared-view finding))
        (lsp-lint-findings-to-json text version findings (+ i 1) acc)
        (lsp-lint-findings-to-json
          (owned_view.compiler-owned-shared-view text)
          version
          findings
          (+ i 1)
          (lsp-json-list-cons
            (lsp-lint-finding-diagnostic text version i finding)
            acc))))))

(define (lsp-lint-diagnostics
  [path : String]
  [text : String]
  [version : i64]
  [stdlib-roots : lsp_svec.Vec]) : json.JsonSeq
  (lsp-lint-findings-to-json
    (owned_view.compiler-owned-shared-view text)
    version
    (lint_driver_core.selfhost-lint-source-with-roots-and-cfg
      path
      text
      stdlib-roots
      (lsp-language-cfgs))
    0
    (json.list-empty)))

(define (lsp-compiler-diagnostics-for-uri
  [uri : String]
  [fallback-path : String]
  [text : String]
  [version : i64]
  [diagnostics : cdiag.CompilerDiagnosticList]
  [index : i64]
  [tail : json.JsonSeq]) : json.JsonSeq
  (let
    [cursor : i64 (- (cdiag.compiler-diagnostic-list-count diagnostics) 1)]
    [out : json.JsonSeq tail]
    (begin
      (while (>= cursor 0)
        (let
          [diag : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-list-get diagnostics cursor)]
          (begin
            (if (string.eq
              (lsp-diagnostic-uri
                (owned_view.compiler-owned-shared-view uri)
                fallback-path
                diag)
              uri)
              (set!
                out
                (lsp-json-list-cons
                  (lsp-compiler-diagnostic-versioned
                    (owned_view.compiler-owned-shared-view fallback-path)
                    (owned_view.compiler-owned-shared-view text)
                    version
                    (+ index cursor)
                    diag)
                  out))
              unit)
            (set! cursor (- cursor 1)))))
      out)))

(define (lsp-publish-external-diagnostic-groups
  [root-uri : String]
  [fallback-path : String]
  [text : String]
  [version : i64]
  [diagnostics : cdiag.CompilerDiagnosticList]
  [remaining : cdiag.CompilerDiagnosticList]
  [published : lsp_vector_families.LspDiagnosticUris]) : lsp_vector_families.LspDiagnosticUris
  (let
    [count : i64 (cdiag.compiler-diagnostic-list-count remaining)]
    [index : i64 0]
    [result : lsp_vector_families.LspDiagnosticUris published]
    (begin
      (while (< index count)
        (let
          [diag : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-list-get remaining index)]
          [diag-uri : String
            (lsp-diagnostic-uri
              (owned_view.compiler-owned-shared-view root-uri)
              fallback-path
              diag)]
          (begin
            (if (or
              (string.eq diag-uri root-uri)
              (lsp-diagnostic-uris-contains?
                (owned_view.compiler-owned-shared-view result)
                (owned_view.compiler-owned-shared-view diag-uri)))
              unit
              (begin
                (lsp-publish-diagnostics
                  (owned_view.compiler-owned-shared-view diag-uri)
                  (lsp-compiler-diagnostics-for-uri
                    (owned_view.compiler-owned-shared-view diag-uri)
                    (owned_view.compiler-owned-shared-view fallback-path)
                    (owned_view.compiler-owned-shared-view text)
                    version
                    (owned_view.compiler-owned-shared-view diagnostics)
                    0
                    (json.list-empty)))
                (set! result (lsp-diagnostic-uris-add result diag-uri))))
            (set! index (+ index 1)))))
      result)))

(define (lsp-analyze-validation-error
  [uri : String]
  [text : String]
  [version : i64]
  [line : i64]
  [col : i64]
  [msg : String]
  [ctx : String]) : LspAnalyzeResult
  (let
    [message : String (lsp-validation-error-message line col msg ctx)]
    (begin
      (lsp-publish-diagnostics
        uri
        (lsp-json-list-cons
          (lsp-diagnostic-from-byte-position-data
            text
            line
            col
            (owned_view.compiler-owned-shared-view message)
            (cdiag.compiler-diagnostic-code-parse)
            version
            "parse"
            0)
          (json.list-empty)))
      (LspAnalyzeResult
        (lsp-diagnostic-uris-empty)
        (LspCheckCacheErr message)
        (compiler_semantic_index.compiler-semantic-source-index-empty)
        false))))

(define (lsp-analyze-partial-result
  [uri : String]
  [path : String]
  [text : String]
  [version : i64]
  [lint-diags : json.JsonSeq]
  [diag : (Box cdiag.CompilerDiagnosticList)]
  [semantic-index : compiler_semantic_index.CompilerSemanticSourceIndex]) : LspAnalyzeResult
  (let
    [diagnostics : cdiag.CompilerDiagnosticList (deref diag)]
    [first-diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-list-first diagnostics)]
    [check-cache : lsp_vector_families.LspCheckCache
      (LspCheckCacheErr (cdiag.compiler-diagnostic-message first-diag))]
    [uri-diags : json.JsonSeq
      (lsp-compiler-diagnostics-for-uri
        (owned_view.compiler-owned-shared-view uri)
        (owned_view.compiler-owned-shared-view path)
        (owned_view.compiler-owned-shared-view text)
        version
        (owned_view.compiler-owned-shared-view diagnostics)
        0
        lint-diags)]
    (begin
      (lsp-publish-diagnostics
        (owned_view.compiler-owned-shared-view uri)
        uri-diags)
      (LspAnalyzeResult
        (lsp-publish-external-diagnostic-groups
          uri
          path
          text
          version
          (owned_view.compiler-owned-shared-view diagnostics)
          diagnostics
          (lsp-diagnostic-uris-empty))
        check-cache
        semantic-index
        true))))

(define (lsp-analyze-document
  [uri : String]
  [path : String]
  [text : String]
  [version : i64]
  [stdlib-roots : lsp_svec.Vec]) : LspAnalyzeResult
  (match (lsp-validate-forms-result
    (owned_view.compiler-owned-shared-view text))
    [(Invalid line col msg ctx)
      (match (compiler_semantic_index.compiler-check-source-index-with-roots-and-cfg
        (owned_view.compiler-owned-shared-view path)
        (owned_view.compiler-owned-shared-view text)
        stdlib-roots
        (lsp-language-cfgs))
        [(Partial diagnostics semantic-index)
          (lsp-analyze-partial-result
            uri
            path
            text
            version
            (json.list-empty)
            diagnostics
            semantic-index)]
        [(Ok _ unexpected)
          (begin
            (compiler_semantic_index.compiler-semantic-source-index-release!
              (&mut unexpected))
            (lsp-analyze-validation-error uri text version line col msg ctx))]
        [(Err _)
          (lsp-analyze-validation-error uri text version line col msg ctx)])]
    [(Valid)
      (let
        [lint-diags : json.JsonSeq
          (lsp-lint-diagnostics
            (owned_view.compiler-owned-shared-view path)
            (owned_view.compiler-owned-shared-view text)
            version
            (owned_view.compiler-owned-shared-view stdlib-roots))]
        (match (compiler_semantic_index.compiler-check-source-index-with-roots-and-cfg
          (owned_view.compiler-owned-shared-view path)
          (owned_view.compiler-owned-shared-view text)
          stdlib-roots
          (lsp-language-cfgs))
          [(Ok _ semantic-index)
            (begin
              (lsp-publish-diagnostics uri lint-diags)
              (LspAnalyzeResult
                (lsp-diagnostic-uris-empty)
                LspCheckCacheOk
                semantic-index
                true))]
          [(Partial diag semantic-index)
            (lsp-analyze-partial-result
              uri
              path
              text
              version
              lint-diags
              diag
              semantic-index)]
          [(Err diag)
            (let
              [diagnostics : cdiag.CompilerDiagnosticList (deref diag)]
              [first-diag : cdiag.CompilerDiagnostic
                (cdiag.compiler-diagnostic-list-first diagnostics)]
              [check-cache : lsp_vector_families.LspCheckCache
                (LspCheckCacheErr
                  (cdiag.compiler-diagnostic-message first-diag))]
              [uri-diags : json.JsonSeq
                (lsp-compiler-diagnostics-for-uri
                  (owned_view.compiler-owned-shared-view uri)
                  (owned_view.compiler-owned-shared-view path)
                  (owned_view.compiler-owned-shared-view text)
                  version
                  (owned_view.compiler-owned-shared-view diagnostics)
                  0
                  lint-diags)]
              (begin
                (lsp-publish-diagnostics
                  (owned_view.compiler-owned-shared-view uri)
                  uri-diags)
                (LspAnalyzeResult
                  (lsp-publish-external-diagnostic-groups
                    uri
                    path
                    text
                    version
                    (owned_view.compiler-owned-shared-view diagnostics)
                    diagnostics
                    (lsp-diagnostic-uris-empty))
                  check-cache
                  (compiler_semantic_index.compiler-semantic-source-index-empty)
                  false)))]))]))

(define (lsp-first-change-text [params : json.Json]) : LspJsonText
  (let
    [key : String "contentChanges"]
    (match (json.object-get params (& key))
      [(JsonFound value)
        (match value
          [(JsonArray items)
            (match (json.list-get-index (deref items) 0)
              [(JsonFound first) (lsp-json-string-field first "text")]
              [(JsonMissing) Missing])]
          [_ Missing])]
      [(JsonMissing) Missing])))

(define (lsp-did-open
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [stdlib-roots : lsp_svec.Vec]) : LspDocumentHandleResult
  (let
    [key : String "textDocument"]
    (match (json.object-get params (& key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Ok uri)
            (let
              [text : String
                (lsp-json-string-field-default
                  (owned_view.compiler-owned-shared-view document)
                  "text"
                  "")]
              [version : i64 (lsp-json-int-field-default document "version" -1)]
              (match (lsp-file-uri-to-path uri)
                [(Ok path)
                  (let
                    [analysis : LspAnalyzeResult
                      (lsp-analyze-document
                        (owned_view.compiler-owned-shared-view uri)
                        (owned_view.compiler-owned-shared-view path)
                        (owned_view.compiler-owned-shared-view text)
                        version
                        stdlib-roots)]
                    (begin
                      (lsp-clear-stale-diagnostics
                        docs
                        uri
                        (owned_view.compiler-owned-shared-view
                          analysis.diagnostic-uris))
                      (let
                        [updated-docs : lsp_document_vec.Vec
                          (lsp-documents-set-check-cache
                            (lsp-documents-set-versioned
                              docs
                              (owned_view.compiler-owned-shared-view uri)
                              path
                              text
                              version
                              analysis.diagnostic-uris)
                            uri
                            analysis.check-cache)]
                        [semantic-docs : lsp_document_vec.Vec
                          (if analysis.semantic-present
                            (lsp-documents-set-semantic-index
                              updated-docs
                              uri
                              version
                              analysis.semantic-index)
                            updated-docs)]
                        (LspDocumentHandleResult.Continue semantic-docs))))]
                [(Err message)
                  (begin
                    (lsp-publish-uri-diagnostic uri message)
                    (LspDocumentHandleResult.Continue docs))]))]
          [(Missing) (LspDocumentHandleResult.Continue docs)])]
      [(JsonMissing) (LspDocumentHandleResult.Continue docs)])))

(define (lsp-did-change
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [stdlib-roots : lsp_svec.Vec]) : LspDocumentHandleResult
  (let
    [key : String "textDocument"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view params)
      (& key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Ok uri)
            (let
              [version : i64 (lsp-json-int-field-default document "version" -1)]
              (match (lsp-first-change-text params)
                [(Ok text)
                  (match (lsp-file-uri-to-path uri)
                    [(Ok path)
                      (let
                        [analysis : LspAnalyzeResult
                          (lsp-analyze-document
                            (owned_view.compiler-owned-shared-view uri)
                            (owned_view.compiler-owned-shared-view path)
                            (owned_view.compiler-owned-shared-view text)
                            version
                            stdlib-roots)]
                        (begin
                          (lsp-clear-stale-diagnostics
                            docs
                            uri
                            (owned_view.compiler-owned-shared-view
                              analysis.diagnostic-uris))
                          (let
                            [updated-docs : lsp_document_vec.Vec
                              (lsp-documents-set-check-cache
                                (lsp-documents-set-versioned
                                  docs
                                  (owned_view.compiler-owned-shared-view uri)
                                  path
                                  text
                                  version
                                  analysis.diagnostic-uris)
                                uri
                                analysis.check-cache)]
                            [semantic-docs : lsp_document_vec.Vec
                              (if analysis.semantic-present
                                (lsp-documents-set-semantic-index
                                  updated-docs
                                  uri
                                  version
                                  analysis.semantic-index)
                                updated-docs)]
                            (LspDocumentHandleResult.Continue semantic-docs))))]
                    [(Err message)
                      (begin
                        (lsp-publish-uri-diagnostic uri message)
                        (LspDocumentHandleResult.Continue docs))])]
                [(Missing)
                  (let
                    [idx : i64 (lsp-documents-find-index docs uri)]
                    (if (< idx 0)
                      (LspDocumentHandleResult.Continue docs)
                      (let
                        [doc : lsp_vector_families.LspDocument
                          (lsp_document_vec.get
                            (& docs)
                            idx
                            (lsp-document-fallback))]
                        [analysis : LspAnalyzeResult
                          (lsp-analyze-document
                            (owned_view.compiler-owned-shared-view uri)
                            doc.path
                            doc.text
                            doc.version
                            stdlib-roots)]
                        [updated-docs : lsp_document_vec.Vec
                          (lsp-documents-set-check-cache
                            docs
                            uri
                            analysis.check-cache)]
                        [semantic-docs : lsp_document_vec.Vec
                          (if analysis.semantic-present
                            (lsp-documents-set-semantic-index
                              updated-docs
                              uri
                              doc.version
                              analysis.semantic-index)
                            updated-docs)]
                        (LspDocumentHandleResult.Continue semantic-docs))))]))]
          [(Missing) (LspDocumentHandleResult.Continue docs)])]
      [(JsonMissing) (LspDocumentHandleResult.Continue docs)])))

(define (lsp-did-close [params : json.Json] [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (let
    [key : String "textDocument"]
    (match (json.object-get params (& key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Ok uri)
            (begin
              (lsp-clear-close-diagnostics
                docs
                (owned_view.compiler-owned-shared-view uri))
              (LspDocumentHandleResult.Continue (lsp-documents-remove docs uri)))]
          [(Missing) (LspDocumentHandleResult.Continue docs)])]
      [(JsonMissing) (LspDocumentHandleResult.Continue docs)])))

;; --------------------------------------------------------------------------
;; Quick fixes (textDocument/codeAction).
;;
;; Diagnostics carry only an opaque source-version/kind/index token. The
;; provider recomputes the compiler diagnostic and lint findings from the
;; current overlay, then uses that token to associate the client's diagnostic
;; with structured data. It never parses a rendered diagnostic message.
;; --------------------------------------------------------------------------
(define (lsp-code-action-position-key [line : i64] [character : i64]) : i64
  (+ (* line 2147483648) character))

(define (lsp-code-action-range-field
  [range : json.Json]
  [endpoint : String]
  [coordinate : String]) : i64
  (match (json.object-get range (& endpoint))
    [(JsonFound position) (lsp-json-int-field-default position coordinate -1)]
    [(JsonMissing) -1]))

(define (lsp-code-action-ranges-intersect?
  [left : json.Json]
  [right : json.Json]) : bool
  (let
    [left-start-line : i64
      (lsp-code-action-range-field
        (owned_view.compiler-owned-shared-view left)
        "start"
        "line")]
    [left-start-char : i64
      (lsp-code-action-range-field
        (owned_view.compiler-owned-shared-view left)
        "start"
        "character")]
    [left-end-line : i64
      (lsp-code-action-range-field
        (owned_view.compiler-owned-shared-view left)
        "end"
        "line")]
    [left-end-char : i64 (lsp-code-action-range-field left "end" "character")]
    [right-start-line : i64
      (lsp-code-action-range-field
        (owned_view.compiler-owned-shared-view right)
        "start"
        "line")]
    [right-start-char : i64
      (lsp-code-action-range-field
        (owned_view.compiler-owned-shared-view right)
        "start"
        "character")]
    [right-end-line : i64
      (lsp-code-action-range-field
        (owned_view.compiler-owned-shared-view right)
        "end"
        "line")]
    [right-end-char : i64 (lsp-code-action-range-field right "end" "character")]
    (if (or
      (< left-start-line 0)
      (< left-start-char 0)
      (< left-end-line 0)
      (< left-end-char 0)
      (< right-start-line 0)
      (< right-start-char 0)
      (< right-end-line 0)
      (< right-end-char 0)
      (> left-start-line 2147483647)
      (> left-start-char 2147483647)
      (> left-end-line 2147483647)
      (> left-end-char 2147483647)
      (> right-start-line 2147483647)
      (> right-start-char 2147483647)
      (> right-end-line 2147483647)
      (> right-end-char 2147483647))
      false
      (let
        [left-start : i64
          (lsp-code-action-position-key left-start-line left-start-char)]
        [left-end : i64
          (lsp-code-action-position-key left-end-line left-end-char)]
        [right-start : i64
          (lsp-code-action-position-key right-start-line right-start-char)]
        [right-end : i64
          (lsp-code-action-position-key right-end-line right-end-char)]
        (and
          (<= left-start left-end)
          (<= right-start right-end)
          (if (= left-start left-end)
            (if (= right-start right-end)
              (= left-start right-start)
              (and (<= right-start left-start) (< left-start right-end)))
            (if (= right-start right-end)
              (and (<= left-start right-start) (< right-start left-end))
              (and (< left-start right-end) (< right-start left-end)))))))))

(define (lsp-code-action-array-has-quickfix?
  [items : json.JsonSeq]
  [index : i64]) : bool
  (if (>= index (json.list-count (owned_view.compiler-owned-shared-view items)))
    false
    (match (json.list-get-index
      (owned_view.compiler-owned-shared-view items)
      index)
      [(JsonFound item)
        (match item
          [(JsonString kind)
            (if (string.eq kind "quickfix")
              true
              (lsp-code-action-array-has-quickfix? items (+ index 1)))]
          [_ (lsp-code-action-array-has-quickfix? items (+ index 1))])]
      [(JsonMissing) false])))

(define (lsp-code-action-kind-requested? [context : json.Json]) : bool
  (let
    [only-key : String "only"]
    (match (json.object-get context (& only-key))
      [(JsonMissing) true]
      [(JsonFound only)
        (match only
          [(JsonArray items)
            (lsp-code-action-array-has-quickfix? (deref items) 0)]
          [_ false])])))

(define (lsp-code-action-data-matches?
  [diagnostic : json.Json]
  [version : i64]
  [kind : (& kind str)]
  [index : i64]) : bool
  (let
    [data-key : String "data"]
    (match (json.object-get diagnostic (& data-key))
      [(JsonMissing) false]
      [(JsonFound data)
        (and
          (= (lsp-json-int-field-default data "version" -1) version)
          (= (lsp-json-int-field-default data "index" -1) index)
          (string.eq (lsp-json-string-field-default data "kind" "") kind))])))

(define (lsp-code-action-context-has-kind-from?
  [items : json.JsonSeq]
  [request-range : json.Json]
  [version : i64]
  [kind : String]
  [index : i64]) : bool
  (if (>= index (json.list-count (owned_view.compiler-owned-shared-view items)))
    false
    (match (json.list-get-index
      (owned_view.compiler-owned-shared-view items)
      index)
      [(JsonMissing) false]
      [(JsonFound diagnostic)
        (let
          [data-key : String "data"]
          [range-key : String "range"]
          (match (json.object-get
            (owned_view.compiler-owned-shared-view diagnostic)
            (& data-key))
            [(JsonMissing)
              (lsp-code-action-context-has-kind-from?
                items
                request-range
                version
                kind
                (+ index 1))]
            [(JsonFound data)
              (match (json.object-get diagnostic (& range-key))
                [(JsonMissing)
                  (lsp-code-action-context-has-kind-from?
                    items
                    request-range
                    version
                    kind
                    (+ index 1))]
                [(JsonFound diagnostic-range)
                  (if (and
                    (= (lsp-json-int-field-default data "version" -1) version)
                    (>= (lsp-json-int-field-default data "index" -1) 0)
                    (string.eq
                      (lsp-json-string-field-default data "kind" "")
                      kind)
                    (lsp-code-action-ranges-intersect?
                      (owned_view.compiler-owned-shared-view request-range)
                      diagnostic-range))
                    true
                    (lsp-code-action-context-has-kind-from?
                      items
                      request-range
                      version
                      kind
                      (+ index 1)))])]))])))

(define (lsp-code-action-find-diagnostic-from
  [items : json.JsonSeq]
  [request-range : json.Json]
  [version : i64]
  [kind : String]
  [wanted-index : i64]
  [index : i64]) : LspJsonValue
  (if (>= index (json.list-count (owned_view.compiler-owned-shared-view items)))
    Missing
    (match (json.list-get-index
      (owned_view.compiler-owned-shared-view items)
      index)
      [(JsonMissing) Missing]
      [(JsonFound diagnostic)
        (let
          [range-key : String "range"]
          (match (json.object-get
            (owned_view.compiler-owned-shared-view diagnostic)
            (& range-key))
            [(JsonFound diagnostic-range)
              (if (and
                (lsp-code-action-data-matches?
                  (owned_view.compiler-owned-shared-view diagnostic)
                  version
                  kind
                  wanted-index)
                (lsp-code-action-ranges-intersect?
                  (owned_view.compiler-owned-shared-view request-range)
                  diagnostic-range))
                (Found diagnostic)
                (lsp-code-action-find-diagnostic-from
                  items
                  request-range
                  version
                  kind
                  wanted-index
                  (+ index 1)))]
            [(JsonMissing)
              (lsp-code-action-find-diagnostic-from
                items
                request-range
                version
                kind
                wanted-index
                (+ index 1))]))])))

(define (lsp-code-action-context-diagnostics [context : json.Json]) : json.JsonSeq
  (let
    [key : String "diagnostics"]
    (match (json.object-get context (& key))
      [(JsonFound value)
        (match value
          [(JsonArray items) (__tl-box-place items)]
          [_ (json.list-empty)])]
      [(JsonMissing) (json.list-empty)])))

(define (lsp-code-action-request-range [params : json.Json]) : LspJsonValue
  (let
    [key : String "range"]
    (match (json.object-get params (& key))
      [(JsonFound range) (Found range)]
      [(JsonMissing) Missing])))

(define (lsp-code-action-path [path : String] [fallback-path : String]) : String
  (let
    [selected : String
      (if (string.eq path "")
        fallback-path
        path)]
    (fs.path-normalize (& selected))))

(define (lsp-code-action-document-for-path
  [docs : (& docs lsp_document_vec.Vec)]
  [path : String]) : LspCodeActionDocument
  (let
    [wanted : String (fs.path-normalize (& path))]
    [index : i64 0]
    [result : LspCodeActionDocument Missing]
    [done : bool false]
    (begin
      (while (and (not done) (< index (lsp_document_vec.len (& docs))))
        (let
          [doc : lsp_vector_families.LspDocument
            (lsp_document_vec.get (& docs) index (lsp-document-fallback))]
          [candidate : String (fs.path-normalize (& doc.path))]
          (if (string.eq candidate wanted)
            (begin
              (set! result (Found doc.uri doc.text doc.version))
              (set! done true))
            (set! index (+ index 1)))))
      result)))

(define (lsp-code-action-all-edits-open?
  [docs : (& docs lsp_document_vec.Vec)]
  [fallback-path : String]
  [edits : (& edits cdiag.CompilerDiagnosticTextEditSeq)]) : bool
  (let
    [slots : (__tl_dyn-array cdiag.CompilerDiagnosticTextEdit) edits.slots]
    [count : i64 edits.len]
    [index : i64 0]
    [ok : bool (> count 0)]
    (begin
      (while (and ok (< index count))
        (let
          [edit : cdiag.CompilerDiagnosticTextEdit
            (owned_view.compiler-owned-array-element-shared-view slots index)]
          [span : cdiag.CompilerDiagnosticSpan
            (cdiag.compiler-diagnostic-text-edit-span edit)]
          [path : String
            (lsp-code-action-path
              (cdiag.compiler-diagnostic-span-path span)
              (owned_view.compiler-owned-shared-view fallback-path))]
          (match (lsp-code-action-document-for-path docs path)
            [(Found _ _ version)
              (if (>= version 0)
                (set! index (+ index 1))
                (set! ok false))]
            [(Missing) (set! ok false)])))
      ok)))

(define (lsp-code-action-text-edit
  [path : String]
  [text : String]
  [edit : cdiag.CompilerDiagnosticTextEdit]) : json.Json
  (let
    [span : cdiag.CompilerDiagnosticSpan
      (cdiag.compiler-diagnostic-text-edit-span
        (owned_view.compiler-owned-shared-view edit))]
    ;; Force conversion through the open overlay even when the diagnostic used
    ;; a different but equivalent spelling of this path.
    [overlay-span : cdiag.CompilerDiagnosticSpan
      (cdiag.CompilerDiagnosticSpan
        (owned_view.compiler-owned-shared-view path)
        (cdiag.compiler-diagnostic-span-start-line span)
        (cdiag.compiler-diagnostic-span-start-col span)
        (cdiag.compiler-diagnostic-span-end-line span)
        (cdiag.compiler-diagnostic-span-end-col span))]
    (lsp-json-object2
      "range"
      (lsp-range-from-compiler-span path text overlay-span)
      "newText"
      (JsonString (cdiag.compiler-diagnostic-text-edit-replacement edit)))))

(define (lsp-code-action-edits-for-path
  [edits : (& edits cdiag.CompilerDiagnosticTextEditSeq)]
  [fallback-path : String]
  [path : String]
  [text : String]
  [index : i64]
  [acc : json.JsonSeq]) : json.JsonSeq
  (if (>= index edits.len)
    acc
    (let
      [edit : cdiag.CompilerDiagnosticTextEdit
        (owned_view.compiler-owned-array-element-shared-view edits.slots index)]
      [span : cdiag.CompilerDiagnosticSpan
        (cdiag.compiler-diagnostic-text-edit-span
          (owned_view.compiler-owned-shared-view edit))]
      [edit-path : String
        (lsp-code-action-path
          (cdiag.compiler-diagnostic-span-path span)
          (owned_view.compiler-owned-shared-view fallback-path))]
      [next : json.JsonSeq
        (if (string.eq edit-path path)
          (lsp-json-list-cons
            (lsp-code-action-text-edit
              (owned_view.compiler-owned-shared-view path)
              (owned_view.compiler-owned-shared-view text)
              edit)
            acc)
          acc)]
      (lsp-code-action-edits-for-path
        edits
        fallback-path
        path
        text
        (+ index 1)
        next))))

(define (lsp-code-action-document-edit
  [uri : String]
  [version : i64]
  [edits : json.JsonSeq]) : json.Json
  (lsp-json-object2
    "textDocument"
    (lsp-json-object2
      "uri"
      (JsonString uri)
      "version"
      (lsp-json-number version))
    "edits"
    (lsp-json-array edits)))

(define (lsp-code-action-document-changes-from
  [docs : (& docs lsp_document_vec.Vec)]
  [fallback-path : String]
  [edits : (& edits cdiag.CompilerDiagnosticTextEditSeq)]
  [index : i64]
  [acc : json.JsonSeq]) : json.JsonSeq
  (if (>= index (lsp_document_vec.len (& docs)))
    acc
    (let
      [doc : lsp_vector_families.LspDocument
        (lsp_document_vec.get (& docs) index (lsp-document-fallback))]
      [path : String (fs.path-normalize (& doc.path))]
      [document-edits : json.JsonSeq
        (lsp-code-action-edits-for-path
          edits
          (owned_view.compiler-owned-shared-view fallback-path)
          path
          doc.text
          0
          (json.list-empty))]
      [next : json.JsonSeq
        (if (>
          (json.list-count
            (owned_view.compiler-owned-shared-view document-edits))
          0)
          (lsp-json-list-cons
            (lsp-code-action-document-edit doc.uri doc.version document-edits)
            acc)
          acc)]
      (lsp-code-action-document-changes-from
        docs
        fallback-path
        edits
        (+ index 1)
        next))))

(define (lsp-code-action-workspace-edit
  [docs : (& docs lsp_document_vec.Vec)]
  [fallback-path : String]
  [edits : (& edits cdiag.CompilerDiagnosticTextEditSeq)]) : json.Json
  (lsp-json-object1
    "documentChanges"
    (lsp-json-array
      (lsp-code-action-document-changes-from
        docs
        fallback-path
        edits
        0
        (json.list-empty)))))

(define (lsp-code-action
  [title : String]
  [diagnostic : json.Json]
  [edit : json.Json]) : json.Json
  (lsp-json-object
    (lsp-json-member
      "title"
      (JsonString title)
      (lsp-json-member
        "kind"
        (JsonString "quickfix")
        (lsp-json-member
          "diagnostics"
          (lsp-json-array (lsp-json-list-cons diagnostic (json.list-empty)))
          (lsp-json-member
            "isPreferred"
            (JsonBool true)
            (lsp-json-member "edit" edit (json.member-list-empty))))))))

(define (lsp-code-action-compiler-fixes-from
  [docs : (& docs lsp_document_vec.Vec)]
  [fallback-path : String]
  [diagnostic : json.Json]
  [fixes : cdiag.CompilerDiagnosticFixSeq]
  [index : i64]
  [acc : json.JsonSeq]) : json.JsonSeq
  (if (>= index fixes.len)
    acc
    (let
      [fix : cdiag.CompilerDiagnosticFix
        (owned_view.compiler-owned-array-element-shared-view fixes.slots index)]
      [edits : cdiag.CompilerDiagnosticTextEditSeq
        (cdiag.compiler-diagnostic-fix-edits
          (owned_view.compiler-owned-shared-view fix))]
      [machine-applicable : bool
        (match (cdiag.compiler-diagnostic-fix-applicability
          (owned_view.compiler-owned-shared-view fix))
          [CompilerDiagnosticMachineApplicable true]
          [_ false])]
      [next : json.JsonSeq
        (if (and
          machine-applicable
          (lsp-code-action-all-edits-open?
            docs
            (owned_view.compiler-owned-shared-view fallback-path)
            edits))
          (lsp-json-list-cons
            (lsp-code-action
              (cdiag.compiler-diagnostic-fix-title fix)
              (owned_view.compiler-owned-shared-view diagnostic)
              (lsp-code-action-workspace-edit
                docs
                (owned_view.compiler-owned-shared-view fallback-path)
                edits))
            acc)
          acc)]
      (lsp-code-action-compiler-fixes-from
        docs
        fallback-path
        diagnostic
        fixes
        (+ index 1)
        next))))

(define (lsp-code-action-compiler-diagnostics
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : String]
  [path : String]
  [version : i64]
  [request-range : json.Json]
  [context-diagnostics : json.JsonSeq]
  [diagnostics : cdiag.CompilerDiagnosticList]
  [index : i64]
  [acc : json.JsonSeq]) : json.JsonSeq
  (let
    [count : i64 (cdiag.compiler-diagnostic-list-count diagnostics)]
    [cursor : i64 index]
    [out : json.JsonSeq acc]
    (begin
      (while (< cursor count)
        (let
          [diagnostic : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-list-get diagnostics cursor)]
          [diagnostic-uri : String
            (lsp-diagnostic-uri
              (owned_view.compiler-owned-shared-view uri)
              path
              diagnostic)]
          [diagnostic-kind : String (lsp-compiler-diagnostic-kind diagnostic)]
          [diagnostic-fixes : cdiag.CompilerDiagnosticFixSeq
            (cdiag.compiler-diagnostic-fixes (& diagnostic))]
          (begin
            (if (not (string.eq diagnostic-uri uri))
              unit
              (match (lsp-code-action-find-diagnostic-from
                (owned_view.compiler-owned-shared-view context-diagnostics)
                (owned_view.compiler-owned-shared-view request-range)
                version
                diagnostic-kind
                cursor
                0)
                [(Missing) unit]
                [(Found context-diagnostic)
                  (set!
                    out
                    (lsp-code-action-compiler-fixes-from
                      docs
                      (owned_view.compiler-owned-shared-view path)
                      context-diagnostic
                      diagnostic-fixes
                      0
                      out))]))
            (set! cursor (+ cursor 1)))))
      out)))

(define (lsp-code-action-compiler
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : String]
  [path : String]
  [text : String]
  [version : i64]
  [request-range : json.Json]
  [context-diagnostics : json.JsonSeq]
  [stdlib-roots : lsp_svec.Vec]
  [acc : json.JsonSeq]) : json.JsonSeq
  (match (compiler_check_core.compiler-check-source-with-roots-and-cfg
    (owned_view.compiler-owned-shared-view path)
    text
    stdlib-roots
    (lsp-language-cfgs))
    [(Ok _ _) acc]
    [(Err diagnostic-box _)
      (lsp-code-action-compiler-diagnostics
        docs
        uri
        path
        version
        request-range
        context-diagnostics
        (cdiag.compiler-diagnostic-list-box-shared-view diagnostic-box)
        0
        acc)]))

(define (lsp-code-action-leading-indent [text : (& text str)] [line : i64]) : String
  (let
    [start : i64 (lint_driver_core.selfhost-lint-line-start-index text line)]
    [length : i64 (string.string-length text)]
    [end : i64 start]
    (begin
      (while (and
        (< end length)
        (or
          (= (string.string-ref text end) ' ')
          (= (string.string-ref text end) '\t')))
        (set! end (+ end 1)))
      (string.substring text start (- end start)))))

(define (lsp-code-action-newline [text : String]) : String
  (let
    [crlf : String "\r\n"]
    (if (string.contains (& text) (& crlf))
      crlf
      "\n")))

(define (lsp-code-action-lint-duplicate-before?
  [findings : lint.LintFindings]
  [finding : lint.LintFinding]
  [index : i64]) : bool
  (let
    [wanted-span : ast.AstSourceSpan finding.span]
    [wanted-line : i64 (ast.ast-source-span-start-line wanted-span)]
    [wanted-rule : String finding.rule-id]
    [cursor : i64 0]
    [duplicate : bool false]
    (begin
      (while (and (not duplicate) (< cursor index))
        (let
          [earlier : lint.LintFinding (lint.lint-findings-ref findings cursor)]
          [earlier-span : ast.AstSourceSpan earlier.span]
          (if (and
            (= (ast.ast-source-span-start-line earlier-span) wanted-line)
            (string.eq earlier.rule-id wanted-rule))
            (set! duplicate true)
            (set! cursor (+ cursor 1)))))
      duplicate)))

(define (lsp-code-action-lint-edit
  [uri : String]
  [version : i64]
  [text : String]
  [finding : lint.LintFinding]) : json.Json
  (let
    [span : ast.AstSourceSpan finding.span]
    [line : i64 (ast.ast-source-span-start-line span)]
    [indent : String (lsp-code-action-leading-indent text line)]
    [replacement : String
      (lsp-str4
        indent
        ";; lint-allow: "
        finding.rule-id
        (lsp-code-action-newline text))]
    [edit : json.Json
      (lsp-json-object2
        "range"
        (lsp-json-object2
          "start"
          (lsp-position line 1)
          "end"
          (lsp-position line 1))
        "newText"
        (JsonString replacement))]
    (lsp-json-object1
      "documentChanges"
      (lsp-json-array
        (lsp-json-list-cons
          (lsp-code-action-document-edit
            uri
            version
            (lsp-json-list-cons edit (json.list-empty)))
          (json.list-empty))))))

(define (lsp-code-action-lint-from
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : String]
  [path : String]
  [text : String]
  [version : i64]
  [findings : lint.LintFindings]
  [request-range : json.Json]
  [context-diagnostics : json.JsonSeq]
  [index : i64]
  [acc : json.JsonSeq]) : json.JsonSeq
  (if (>=
    index
    (lint.lint-findings-count (owned_view.compiler-owned-shared-view findings)))
    acc
    (let
      [finding : lint.LintFinding (lint.lint-findings-ref findings index)]
      [next : json.JsonSeq
        (if (or
          (lint_driver_core.selfhost-lint-suppressed?
            text
            (owned_view.compiler-owned-shared-view finding))
          (lsp-code-action-lint-duplicate-before?
            (owned_view.compiler-owned-shared-view findings)
            (owned_view.compiler-owned-shared-view finding)
            index))
          acc
          (match (lsp-code-action-find-diagnostic-from
            (owned_view.compiler-owned-shared-view context-diagnostics)
            (owned_view.compiler-owned-shared-view request-range)
            version
            "lint"
            index
            0)
            [(Missing) acc]
            [(Found diagnostic)
              (let
                [lint-diagnostic : cdiag.CompilerDiagnostic
                  (lint_driver_core.selfhost-lint-finding-diagnostic
                    (owned_view.compiler-owned-shared-view path)
                    (owned_view.compiler-owned-shared-view finding))]
                [fixes : cdiag.CompilerDiagnosticFixSeq
                  (cdiag.compiler-diagnostic-fixes (& lint-diagnostic))]
                [with-fixes : json.JsonSeq
                  (lsp-code-action-compiler-fixes-from
                    docs
                    (owned_view.compiler-owned-shared-view path)
                    (owned_view.compiler-owned-shared-view diagnostic)
                    fixes
                    0
                    acc)]
                (lsp-json-list-cons
                  (lsp-code-action
                    (lsp-str3
                      "Suppress "
                      (owned_view.compiler-owned-shared-view finding.rule-id)
                      " for this form")
                    diagnostic
                    (lsp-code-action-lint-edit
                      (owned_view.compiler-owned-shared-view uri)
                      version
                      (owned_view.compiler-owned-shared-view text)
                      finding))
                  with-fixes))]))]
      (lsp-code-action-lint-from
        docs
        uri
        path
        text
        version
        findings
        request-range
        context-diagnostics
        (+ index 1)
        next))))

(define (lsp-code-action-respond
  [id : json.Json]
  [params : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]
  [stdlib-roots : lsp_svec.Vec]) : unit
  (let
    [text-document-key : String "textDocument"]
    [context-key : String "context"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view params)
      (& text-document-key))
      [(JsonMissing) (lsp-write-response id (lsp-json-array (json.list-empty)))]
      [(JsonFound text-document)
        (match (lsp-json-string-field text-document "uri")
          [(Missing) (lsp-write-response id (lsp-json-array (json.list-empty)))]
          [(Ok uri)
            (let
              [document-index : i64 (lsp-documents-find-index docs uri)]
              (if (< document-index 0)
                (lsp-write-response id (lsp-json-array (json.list-empty)))
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view params)
                  (& context-key))
                  [(JsonMissing)
                    (lsp-write-response id (lsp-json-array (json.list-empty)))]
                  [(JsonFound context)
                    (match (lsp-code-action-request-range params)
                      [(Missing)
                        (lsp-write-response
                          id
                          (lsp-json-array (json.list-empty)))]
                      [(Found request-range)
                        (let
                          [doc : lsp_vector_families.LspDocument
                            (lsp_document_vec.get
                              (& docs)
                              document-index
                              (lsp-document-fallback))]
                          [version : i64 doc.version]
                          (if (or
                            (< version 0)
                            (not
                              (lsp-code-action-kind-requested?
                                (owned_view.compiler-owned-shared-view context))))
                            (lsp-write-response
                              id
                              (lsp-json-array (json.list-empty)))
                            (let
                              [context-diagnostics : json.JsonSeq
                                (lsp-code-action-context-diagnostics context)]
                              [has-compiler : bool
                                (or
                                  (lsp-code-action-context-has-kind-from?
                                    (owned_view.compiler-owned-shared-view
                                      context-diagnostics)
                                    (owned_view.compiler-owned-shared-view
                                      request-range)
                                    version
                                    "compiler"
                                    0)
                                  (lsp-code-action-context-has-kind-from?
                                    (owned_view.compiler-owned-shared-view
                                      context-diagnostics)
                                    (owned_view.compiler-owned-shared-view
                                      request-range)
                                    version
                                    "parse"
                                    0))]
                              [has-lint : bool
                                (lsp-code-action-context-has-kind-from?
                                  (owned_view.compiler-owned-shared-view
                                    context-diagnostics)
                                  (owned_view.compiler-owned-shared-view
                                    request-range)
                                  version
                                  "lint"
                                  0)]
                              [compiler-actions : json.JsonSeq
                                (if has-compiler
                                  (lsp-code-action-compiler
                                    docs
                                    (owned_view.compiler-owned-shared-view uri)
                                    (owned_view.compiler-owned-shared-view
                                      doc.path)
                                    (owned_view.compiler-owned-shared-view
                                      doc.text)
                                    version
                                    (owned_view.compiler-owned-shared-view
                                      request-range)
                                    (owned_view.compiler-owned-shared-view
                                      context-diagnostics)
                                    (owned_view.compiler-owned-shared-view
                                      stdlib-roots)
                                    (json.list-empty))
                                  (json.list-empty))]
                              [findings : lint.LintFindings
                                (if has-lint
                                  (lint_driver_core.selfhost-lint-source-with-roots-and-cfg
                                    (owned_view.compiler-owned-shared-view
                                      doc.path)
                                    (owned_view.compiler-owned-shared-view
                                      doc.text)
                                    stdlib-roots
                                    (lsp-language-cfgs))
                                  (lint.lint-findings-empty))]
                              [actions : json.JsonSeq
                                (lsp-code-action-lint-from
                                  docs
                                  uri
                                  doc.path
                                  doc.text
                                  version
                                  findings
                                  request-range
                                  context-diagnostics
                                  0
                                  compiler-actions)]
                              (lsp-write-response id (lsp-json-array actions)))))])])))])])))

(define (lsp-handle-code-action
  [id : json.Json]
  [params : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]
  [stdlib-roots : lsp_svec.Vec]) : unit
  (lsp-code-action-respond id params docs stdlib-roots))

;; --------------------------------------------------------------------------
;; Go-to-definition (textDocument/definition).
;;
;; An import operand resolves to its module file; any other symbol resolves
;; through the current document's semantic snapshot. The lexical scans below
;; skip string literals, character literals, and `;` comments so fixture
;; sources that embed TypeLisp inside literals never produce a false match.
;; --------------------------------------------------------------------------
(define (lsp-ident-char? [c : char]) : bool
  (or
    (and (>= c 'a') (<= c 'z'))
    (and (>= c 'A') (<= c 'Z'))
    (and (>= c '0') (<= c '9'))
    (= c '-')
    (= c '+')
    (= c '*')
    (= c '/')
    (= c '?')
    (= c '!')
    (= c '>')
    (= c '<')
    (= c '=')
    (= c '&')
    (= c ':')
    (= c '_')
    (= c '.')
    (= c '%')))

(define (lsp-scan-ident [text : (& text str)] [i : i64] [n : i64]) : i64
  (let
    [j : i64 i]
    (begin
      (while (and (< j n) (lsp-ident-char? (string.string-ref text j)))
        (set! j (+ j 1)))
      j)))

;; Maximal identifier token covering `off`, or "" when `off` is not on one.
(define (lsp-symbol-at-offset [text : (& text str)] [off : i64]) : String
  (let
    [n : i64 (string.string-length text)]
    (if (or (< off 0) (>= off n))
      ""
      (if (not (lsp-ident-char? (string.string-ref text off)))
        ""
        (let
          [start : i64 off]
          [end : i64 (lsp-scan-ident text off n)]
          (begin
            (while (and
              (> start 0)
              (lsp-ident-char? (string.string-ref text (- start 1))))
              (set! start (- start 1)))
            (string.substring text start (- end start))))))))

(define (lsp-symbol-start-at-offset [text : (& text str)] [off : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [start : i64 off]
    (if (or
      (< off 0)
      (>= off n)
      (not (lsp-ident-char? (string.string-ref text off))))
      off
      (begin
        (while (and
          (> start 0)
          (lsp-ident-char? (string.string-ref text (- start 1))))
          (set! start (- start 1)))
        start))))

;; Base name of a possibly module-qualified symbol (`core/cond` -> `cond`,
;; `core.cond` -> `cond`).
(define (lsp-symbol-base [s : String]) : String
  (let
    [n : i64 (string.string-length s)]
    [i : i64 0]
    [k : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (or
            (= (string.string-ref s i) '/')
            (= (string.string-ref s i) '.'))
            (set! k i)
            unit)
          (set! i (+ i 1))))
      (if (>= k 0)
        (string.substring s (+ k 1) (- n (+ k 1)))
        s))))

;; Negotiated LSP character units contributed by one UTF-8 byte. In UTF-16,
;; a four-byte lead spans a surrogate pair and continuation bytes add nothing.
(define (lsp-position-units-for-byte [c : char]) : i64
  (source_text.source-text-column-units c (not lsp-position-encoding-utf8)))

(define (lsp-string-position-units [text : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (string.string-length text)]
    [units : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            units
            (+ units (lsp-position-units-for-byte (string.string-ref text i))))
          (set! i (+ i 1))))
      units)))

(define (lsp-using-utf16-positions?) : bool
  (not lsp-position-encoding-utf8))

;; Byte offset of a negotiated 0-based LSP position, clamped to the line.
(define (lsp-offset-at-position
  [text : (& text str)]
  [line0 : i64]
  [char0 : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [ln : i64 0]
    [col : i64 0]
    (begin
      (while (and (< i n) (< ln line0))
        (begin
          (if (= (string.string-ref text i) '\n')
            (set! ln (+ ln 1))
            unit)
          (set! i (+ i 1))))
      (while (and
        (< i n)
        (not (= (string.string-ref text i) '\n'))
        (or
          (< col char0)
          (and
            (lsp-using-utf16-positions?)
            (source_text.source-text-utf8-continuation-byte?
              (string.string-ref text i)))))
        (begin
          (set!
            col
            (+ col (lsp-position-units-for-byte (string.string-ref text i))))
          (set! i (+ i 1))))
      i)))

;; Exact position conversion for cursor-sensitive requests. Unlike the clamping
;; `lsp-offset-at-position`, this rejects missing lines, columns beyond the line, and a
;; UTF-16 character position in the middle of a surrogate pair.
(define (lsp-offset-at-position-checked
  [text : String]
  [line0 : i64]
  [char0 : i64]) : LspOffsetLookup
  (if (or (< line0 0) (< char0 0))
    Missing
    (let
      [n : i64 (string.string-length text)]
      [i : i64 0]
      [ln : i64 0]
      [col : i64 0]
      (begin
        (while (and (< i n) (< ln line0))
          (begin
            (if (= (string.string-ref text i) '\n')
              (set! ln (+ ln 1))
              unit)
            (set! i (+ i 1))))
        (if (not (= ln line0))
          Missing
          (begin
            (while (and
              (< i n)
              (< col char0)
              (not (= (string.string-ref text i) '\n'))
              (not
                (and
                  (= (string.string-ref text i) '\r')
                  (< (+ i 1) n)
                  (= (string.string-ref text (+ i 1)) '\n'))))
              (begin
                (set!
                  col
                  (+
                    col
                    (lsp-position-units-for-byte (string.string-ref text i))))
                (set! i (+ i 1))))
            (if (not (= col char0))
              Missing
              (begin
                (if (lsp-using-utf16-positions?)
                  (while (and
                    (< i n)
                    (source_text.source-text-utf8-continuation-byte?
                      (string.string-ref text i)))
                    (set! i (+ i 1)))
                  unit)
                (Found i)))))))))

;; --------------------------------------------------------------------------
;; Shared signature-help and completion cursor context.
;;
;; This scanner intentionally stops at the cursor. It recognizes only enough
;; reader structure to find the innermost open call and count its direct
;; arguments, classify the syntactic completion position, and retain exact
;; token spans. Symbol resolution and candidate selection belong to providers.
;; --------------------------------------------------------------------------
(define (lsp-call-frame-fallback) : lsp_vector_families.LspCallFrame
  (lsp_vector_families.LspCallFrame
    0
    -1
    -1
    -1
    2
    0
    false
    false
    false
    false
    false))

(define (lsp-call-token-delimiter? [c : char]) : bool
  (or
    (source_text.source-text-space? c)
    (= c '(')
    (= c ')')
    (= c '[')
    (= c ']')
    (= c ';')
    (= c '"')
    (= c '\'')
    (= c '`')
    (= c ',')))

(define (lsp-call-scan-token [text : (& text str)] [start : i64] [limit : i64]) : i64
  (let
    [i : i64 start]
    (begin
      (while (and
        (< i limit)
        (not (lsp-call-token-delimiter? (string.string-ref text i))))
        (set! i (+ i 1)))
      i)))

(define (lsp-completion-scan-token
  [text : (& text str)]
  [start : i64]
  [limit : i64]) : LspCompletionTokenScan
  (let
    [i : i64 start]
    [last-dot : i64 -1]
    (begin
      (while (and
        (< i limit)
        (not (lsp-call-token-delimiter? (string.string-ref text i))))
        (begin
          (if (= (string.string-ref text i) '.')
            (set! last-dot i)
            unit)
          (set! i (+ i 1))))
      (LspCompletionTokenScan i last-dot))))

(define (lsp-call-clamp [offset : i64] [limit : i64]) : i64
  (if (> offset limit)
    limit
    offset))

;; Start another direct datum. Adjacent reader forms count separately even
;; without whitespace; a chain of reader prefixes remains one incomplete
;; datum until its payload completes.
(define (lsp-call-frame-start-datum!
  [frame : (&mut frame lsp_vector_families.LspCallFrame)]) : unit
  (if frame.datum-active
    (if frame.datum-complete
      (begin
        (set! frame.argument-index (+ frame.argument-index 1))
        (set! frame.datum-complete false))
      unit)
    (begin
      (set! frame.datum-active true)
      (set! frame.datum-complete false))))

(define (lsp-call-frame-complete-datum!
  [frame : (&mut frame lsp_vector_families.LspCallFrame)]) : unit
  (begin
    (if (not frame.datum-active)
      (lsp-call-frame-start-datum! frame)
      unit)
    (set! frame.datum-complete true)))

;; A separator after a completed argument moves the cursor to the next
;; zero-based argument. Separators after a quote prefix leave that datum open.
(define (lsp-call-frame-separate!
  [frame : (&mut frame lsp_vector_families.LspCallFrame)]) : unit
  (if (and frame.datum-active frame.datum-complete)
    (begin
      (set! frame.argument-index (+ frame.argument-index 1))
      (set! frame.datum-active false)
      (set! frame.datum-complete false))
    unit))

(define (lsp-call-frames-update-top-datum!
  [frames : (&mut frames lsp_vector_families.LspCallFrames)]
  [complete : bool]) : unit
  (let
    [index : i64 (- (lsp_vector_families.lsp-call-frames-len frames) 1)]
    (if (< index 0)
      unit
      (let
        [frame : lsp_vector_families.LspCallFrame
          (lsp_vector_families.lsp-call-frames-get
            frames
            index
            (lsp-call-frame-fallback))]
        (begin
          (if (and (= frame.kind 0) (= frame.head-state 0))
            (set! frame.head-state 2)
            (begin
              (lsp-call-frame-start-datum! (&mut frame))
              (if complete
                (lsp-call-frame-complete-datum! (&mut frame))
                unit)))
          (lsp_vector_families.lsp-call-frames-set! frames index frame))))))

(define (lsp-call-frames-complete-top-datum!
  [frames : (&mut frames lsp_vector_families.LspCallFrames)]) : unit
  (let
    [index : i64 (- (lsp_vector_families.lsp-call-frames-len frames) 1)]
    (if (< index 0)
      unit
      (let
        [frame : lsp_vector_families.LspCallFrame
          (lsp_vector_families.lsp-call-frames-get
            frames
            index
            (lsp-call-frame-fallback))]
        (begin
          (if (not (and (= frame.kind 0) (= frame.head-state 0)))
            (lsp-call-frame-complete-datum! (&mut frame))
            unit)
          (lsp_vector_families.lsp-call-frames-set! frames index frame))))))

(define (lsp-call-frames-separate-top!
  [frames : (&mut frames lsp_vector_families.LspCallFrames)]) : unit
  (let
    [index : i64 (- (lsp_vector_families.lsp-call-frames-len frames) 1)]
    (if (< index 0)
      unit
      (let
        [frame : lsp_vector_families.LspCallFrame
          (lsp_vector_families.lsp-call-frames-get
            frames
            index
            (lsp-call-frame-fallback))]
        (begin
          (lsp-call-frame-separate! (&mut frame))
          (lsp_vector_families.lsp-call-frames-set! frames index frame))))))

(define (lsp-call-context-from-frames
  [frames : (& frames lsp_vector_families.LspCallFrames)]) : LspCallContextLookup
  (let
    [index : i64 (- (lsp_vector_families.lsp-call-frames-len frames) 1)]
    [result : LspCallContextLookup Missing]
    [found : bool false]
    (begin
      (while (and (>= index 0) (not found))
        (let
          [frame : lsp_vector_families.LspCallFrame
            (lsp_vector_families.lsp-call-frames-get
              frames
              index
              (lsp-call-frame-fallback))]
          (begin
            (if (and (= frame.kind 0) (= frame.head-state 1))
              (begin
                (set!
                  result
                  (Found
                    (LspCallContext
                      frame.form-start
                      frame.head-start
                      frame.head-end
                      frame.argument-index)))
                (set! found true))
              unit)
            (set! index (- index 1)))))
      result)))

(define (lsp-completion-field-head? [head : (& head str)]) : bool
  (or
    (string.eq head "struct-get")
    (string.eq head "struct-set")
    (string.eq head "struct-set!")
    (string.eq head "__tl_struct-get")
    (string.eq head "__tl_struct-set")))

(define (lsp-completion-context-from-scan
  [text : (& text str)]
  [limit : i64]
  [frames : (& frames lsp_vector_families.LspCallFrames)]
  [has-token : bool]
  [scan-token-start : i64]
  [scan-token-end : i64]
  [scan-last-dot : i64]
  [token-suppressed : bool]
  [cursor-suppressed : bool]
  [token-type : bool]
  [quote-pending : bool]) : LspCompletionContextLookup
  (let
    [frame-count : i64 (lsp_vector_families.lsp-call-frames-len frames)]
    [top-index : i64 (- frame-count 1)]
    [top-frame : lsp_vector_families.LspCallFrame
      (lsp_vector_families.lsp-call-frames-get
        frames
        top-index
        (lsp-call-frame-fallback))]
    [call-index : i64 top-index]
    [call-frame : lsp_vector_families.LspCallFrame (lsp-call-frame-fallback)]
    [call-found : bool false]
    [token-start : i64 scan-token-start]
    [written-token-start : i64 scan-token-start]
    [token-end : i64 scan-token-end]
    [last-dot : i64 scan-last-dot]
    [token : String ""]
    [prefix : String ""]
    [receiver : String ""]
    [head : String ""]
    [form-start : i64 -1]
    [head-start : i64 -1]
    [head-end : i64 -1]
    [active-argument : i64 -1]
    [call-head-position : bool false]
    [type-position : bool token-type]
    [suppressed : bool
      (or
        cursor-suppressed
        token-suppressed
        quote-pending
        (and (>= top-index 0) top-frame.literal))]
    (begin
      (while (and (>= call-index 0) (not call-found))
        (begin
          (set!
            call-frame
            (lsp_vector_families.lsp-call-frames-get
              frames
              call-index
              (lsp-call-frame-fallback)))
          (if (= call-frame.kind 0)
            (set! call-found true)
            (set! call-index (- call-index 1)))))
      (if has-token
        (set!
          token
          (string.substring text token-start (- token-end token-start)))
        (begin
          (set! token-start limit)
          (set! written-token-start limit)
          (set! token-end limit)
          (set! last-dot -1)))
      (if call-found
        (begin
          (set! form-start call-frame.form-start)
          (set! active-argument call-frame.argument-index)
          (if (= call-frame.head-state 1)
            (begin
              (set! head-start call-frame.head-start)
              (set! head-end call-frame.head-end)
              (set!
                head
                (string.substring text head-start (- head-end head-start)))
              (if (and
                (= call-index top-index)
                has-token
                (= scan-token-start head-start)
                (= scan-token-end head-end))
                (set! call-head-position true)
                unit))
            (if (and (= call-frame.head-state 0) (= call-index top-index))
              (begin
                (set! call-head-position true)
                (set! head-start token-start)
                (set! head-end token-end)
                (set! head (string.copy (& token))))
              unit)))
        unit)
      (if (and
        (>= top-index 0)
        (or top-frame.type-context top-frame.expect-type))
        (set! type-position true)
        unit)
      ;; `:` introduces a type but is not itself part of the replaceable token.
      (if (and type-position (string.eq token ":"))
        (begin
          (set! type-position true)
          (set! token "")
          (set! token-start limit)
          (set! written-token-start limit)
          (set! token-end limit)
          (set! last-dot -1))
        unit)
      (if (>= last-dot token-start)
        (begin
          (set!
            receiver
            (string.substring text token-start (- last-dot token-start)))
          (set!
            prefix
            (string.substring text (+ last-dot 1) (- token-end (+ last-dot 1))))
          (set! token-start (+ last-dot 1)))
        (set! prefix (string.copy (& token))))
      (Found
        (LspCompletionContext
          (cond
            [suppressed Suppressed]
            [(string.eq head "import")
              (if (>= active-argument 2)
                ImportAlias
                ImportPathOrItem)]
            [(and (= active-argument 1) (lsp-completion-field-head? head))
              Field]
            [type-position Type]
            [(>= last-dot 0) DottedMember]
            [call-head-position CallHead]
            [else Value])
          limit
          token-start
          limit
          written-token-start
          token
          prefix
          receiver
          head
          form-start
          head-start
          head-end
          active-argument)))))

;; Scan bytes [0, limit). A cursor immediately before a closer therefore still
;; belongs to that call, while one immediately after it does not.
(define (lsp-cursor-context-at-offset
  [text : (& text str)]
  [limit : i64]
  [include-completion : bool]) : LspCursorContextScan
  (let
    [n : i64 (string.string-length text)]
    (if (or (< limit 0) (> limit n))
      (LspCursorContextScan Missing Missing)
      (let
        [frames : lsp_vector_families.LspCallFrames
          (lsp_vector_families.lsp-call-frames-new)]
        [i : i64 0]
        [has-token : bool false]
        [token-start : i64 limit]
        [token-end : i64 limit]
        [last-dot : i64 -1]
        [token-suppressed : bool false]
        [cursor-suppressed : bool false]
        [token-type : bool false]
        [quote-pending : bool false]
        (begin
          (while (< i limit)
            (let
              [c : char (string.string-ref text i)]
              (cond
                [(source_text.source-text-space? c)
                  (begin
                    (lsp-call-frames-separate-top! (&mut frames))
                    (set! i (source_text.source-text-skip-space text i limit)))]
                [(= c ';')
                  (let
                    [past : i64
                      (lsp-call-clamp
                        (source_text.source-text-skip-line text i limit)
                        limit)]
                    (begin
                      (lsp-call-frames-separate-top! (&mut frames))
                      (if (and
                        (= past limit)
                        (> past i)
                        (not (= (string.string-ref text (- past 1)) '\n')))
                        (set! cursor-suppressed true)
                        unit)
                      (set! i past)))]
                [(= c '"')
                  (let
                    [raw-past : i64
                      (source_text.source-text-skip-string text i limit)]
                    [past : i64 (lsp-call-clamp raw-past limit)]
                    [complete : bool
                      (and
                        (<= raw-past limit)
                        (> raw-past (+ i 1))
                        (= (string.string-ref text (- raw-past 1)) '"'))]
                    (begin
                      (lsp-call-frames-update-top-datum! (&mut frames) complete)
                      (if complete
                        (set! quote-pending false)
                        (set! cursor-suppressed true))
                      (set! i past)))]
                [(= c '\'')
                  (let
                    [past : i64
                      (lsp-call-clamp
                        (source_text.source-text-skip-char-literal text i limit)
                        limit)]
                    (if (> past (+ i 1))
                      (begin
                        (lsp-call-frames-update-top-datum! (&mut frames) true)
                        (set! quote-pending false)
                        (set! i past))
                      (begin
                        (lsp-call-frames-update-top-datum! (&mut frames) false)
                        (set! quote-pending true)
                        (set! i (+ i 1)))))]
                [(or (= c '`') (= c ','))
                  (begin
                    (lsp-call-frames-update-top-datum! (&mut frames) false)
                    (set! quote-pending true)
                    (if (and
                      (= c ',')
                      (< (+ i 1) limit)
                      (= (string.string-ref text (+ i 1)) '@'))
                      (set! i (+ i 2))
                      (set! i (+ i 1))))]
                [(or (= c '(') (= c '['))
                  (let
                    [top-index : i64
                      (- (lsp_vector_families.lsp-call-frames-len (& frames)) 1)]
                    [parent : lsp_vector_families.LspCallFrame
                      (lsp_vector_families.lsp-call-frames-get
                        (& frames)
                        top-index
                        (lsp-call-frame-fallback))]
                    [child-literal : bool
                      (or quote-pending (and (>= top-index 0) parent.literal))]
                    [child-type : bool
                      (and
                        (>= top-index 0)
                        (or parent.type-context parent.expect-type))]
                    (begin
                      (if (and (>= top-index 0) parent.expect-type)
                        (begin
                          (set! parent.expect-type false)
                          (lsp_vector_families.lsp-call-frames-set!
                            (&mut frames)
                            top-index
                            parent))
                        unit)
                      (lsp-call-frames-update-top-datum! (&mut frames) false)
                      (lsp_vector_families.lsp-call-frames-push!
                        (&mut frames)
                        (lsp_vector_families.LspCallFrame
                          (if (= c '(')
                            0
                            1)
                          i
                          -1
                          -1
                          (if (= c '(')
                            0
                            2)
                          0
                          false
                          false
                          child-literal
                          child-type
                          false))
                      (set! quote-pending false)
                      (set! i (+ i 1))))]
                [(or (= c ')') (= c ']'))
                  (let
                    [top-index : i64
                      (- (lsp_vector_families.lsp-call-frames-len (& frames)) 1)]
                    (if (< top-index 0)
                      (set! i (+ i 1))
                      (let
                        [frame : lsp_vector_families.LspCallFrame
                          (lsp_vector_families.lsp-call-frames-get
                            (& frames)
                            top-index
                            (lsp-call-frame-fallback))]
                        [close-kind : i64
                          (if (= c ')')
                            0
                            1)]
                        (begin
                          (if (= frame.kind close-kind)
                            (begin
                              (lsp_vector_families.lsp-call-frames-pop!
                                (&mut frames))
                              (lsp-call-frames-complete-top-datum!
                                (&mut frames)))
                            (lsp_vector_families.lsp-call-frames-clear!
                              (&mut frames)))
                          (set! quote-pending false)
                          (set! i (+ i 1))))))]
                [else
                  (let
                    [start : i64 i]
                    [token-scan : LspCompletionTokenScan
                      (lsp-completion-scan-token text i limit)]
                    [past : i64 token-scan.end]
                    [exact : bool
                      (or
                        (< past limit)
                        (= limit n)
                        (and
                          (< limit n)
                          (lsp-call-token-delimiter?
                            (string.string-ref text limit))))]
                    [top-index : i64
                      (- (lsp_vector_families.lsp-call-frames-len (& frames)) 1)]
                    [frame : lsp_vector_families.LspCallFrame
                      (lsp_vector_families.lsp-call-frames-get
                        (& frames)
                        top-index
                        (lsp-call-frame-fallback))]
                    [head-token : bool
                      (and
                        (>= top-index 0)
                        (= frame.kind 0)
                        (= frame.head-state 0))]
                    [in-literal : bool
                      (or quote-pending (and (>= top-index 0) frame.literal))]
                    [in-type : bool
                      (and
                        (>= top-index 0)
                        (or frame.type-context frame.expect-type))]
                    [colon-token : bool
                      (and
                        (not head-token)
                        (= (- past start) 1)
                        (= (string.string-ref text start) ':'))]
                    (begin
                      (if (= past limit)
                        (begin
                          (set! has-token true)
                          (set! token-start start)
                          (set! token-end past)
                          (set! last-dot token-scan.last-dot)
                          (set! token-suppressed in-literal)
                          (set! token-type (or in-type colon-token)))
                        unit)
                      (if (>= top-index 0)
                        (begin
                          (if head-token
                            (if exact
                              (begin
                                (set! frame.head-start start)
                                (set! frame.head-end past)
                                (set! frame.head-state 1))
                              unit)
                            (begin
                              (lsp-call-frame-start-datum! (&mut frame))
                              (if exact
                                (lsp-call-frame-complete-datum! (&mut frame))
                                unit)
                              (if colon-token
                                (set! frame.expect-type true)
                                (if frame.expect-type
                                  (set! frame.expect-type false)
                                  unit))))
                          (lsp_vector_families.lsp-call-frames-set!
                            (&mut frames)
                            top-index
                            frame))
                        unit)
                      (set! quote-pending false)
                      (set! i past)))])))
          (LspCursorContextScan
            (lsp-call-context-from-frames (& frames))
            (if include-completion
              (lsp-completion-context-from-scan
                text
                limit
                (& frames)
                has-token
                token-start
                token-end
                last-dot
                token-suppressed
                cursor-suppressed
                token-type
                quote-pending)
              Missing)))))))

(define (lsp-call-context-at-offset [text : String] [limit : i64]) : LspCallContextLookup
  (let
    [scan : LspCursorContextScan
      (lsp-cursor-context-at-offset text limit false)]
    scan.call))

(define (lsp-completion-context-at-offset [text : String] [limit : i64]) : LspCompletionContextLookup
  (let
    [scan : LspCursorContextScan (lsp-cursor-context-at-offset text limit true)]
    scan.completion))

(define (lsp-completion-context-at-position
  [text : String]
  [line0 : i64]
  [char0 : i64]) : LspCompletionContextLookup
  (match (lsp-offset-at-position-checked
    (owned_view.compiler-owned-shared-view text)
    line0
    char0)
    [(Found offset) (lsp-completion-context-at-offset text offset)]
    [(Missing) Missing]))

;; 1-based negotiated LSP line/column of a byte offset.
(define (lsp-line-col-at-offset [text : (& text str)] [off : i64]) : LspLineCol
  (let
    [position : source_text.SourceTextLineCol
      (source_text.source-text-line-col-at-offset
        text
        off
        (lsp-using-utf16-positions?))]
    (LspLineCol position.line position.col)))

;; 1-based byte-counted line/column of a byte offset.
(define (lsp-byte-line-col-at-offset [text : (& text str)] [off : i64]) : LspLineCol
  (let
    [position : source_text.SourceTextLineCol
      (source_text.source-text-line-col-at-offset text off false)]
    (LspLineCol position.line position.col)))

(define (lsp-line-col-cache-at-offset!
  [cache : (&mut cache LspLineColCache)]
  [text : (& text str)]
  [off : i64]) : LspLineCol
  (if (= off cache.offset)
    (LspLineCol cache.line cache.col)
    (let
      [n : i64 (string.string-length text)]
      [resume : bool (and (>= cache.offset 0) (< cache.offset off))]
      [start : i64
        (if resume
          cache.offset
          0)]
      [line : i64
        (if resume
          cache.line
          1)]
      [col : i64
        (if resume
          cache.col
          1)]
      [i : i64 start]
      (begin
        (while (and (< i n) (< i off))
          (begin
            (if (= (string.string-ref text i) '\n')
              (begin
                (set! line (+ line 1))
                (set! col 1))
              (set!
                col
                (+ col (lsp-position-units-for-byte (string.string-ref text i)))))
            (set! i (+ i 1))))
        (set! cache.offset off)
        (set! cache.line line)
        (set! cache.col col)
        (LspLineCol line col)))))

(define (lsp-def-keyword? [kw : String]) : bool
  (or
    (string.eq kw "define")
    (string.eq kw "defmacro")
    (string.eq kw "defstruct")
    (string.eq kw "defenum")
    (string.eq kw "defdispatch")
    (string.eq kw "extern")))

;; When `text[i]` opens a top-level definition form, return the byte offset of
;; the defined name (skipping an optional `(` for function/extern forms);
;; otherwise -1.
(define (lsp-def-name-offset-at [text : (& text str)] [i : i64] [n : i64]) : i64
  (let
    [after-open : i64 (source_text.source-text-skip-space text (+ i 1) n)]
    [kw-end : i64 (lsp-scan-ident text after-open n)]
    (if (<= kw-end after-open)
      -1
      (let
        [kw : String (string.substring text after-open (- kw-end after-open))]
        (if (lsp-def-keyword? kw)
          (let
            [after-kw : i64 (source_text.source-text-skip-space text kw-end n)]
            [name-start : i64
              (if (and (< after-kw n) (= (string.string-ref text after-kw) '('))
                (source_text.source-text-skip-space text (+ after-kw 1) n)
                after-kw)]
            (if (< name-start n)
              (if (lsp-ident-char? (string.string-ref text name-start))
                name-start
                -1)
              -1))
          -1)))))

(define (lsp-dotted-import-name-kind
  [name : (& name str)]
  [token-complete : bool]) : LspDottedImportNameKind
  (cond
    [(module_name.compiler-module-name-valid? name) Complete]
    [(not token-complete)
      (let
        [continued : String (str_cat.str-cat (string.copy name) "x" "")]
        (if (module_name.compiler-module-name-valid? (& continued))
          Prefix
          Invalid))]
    [else Invalid]))

;; An identifier scanner stop at an unsupported byte is not a token boundary.
(define (lsp-dotted-import-token-boundary? [text : (& text str)] [end : i64]) : bool
  (if (= end (string.string-length text))
    true
    (let
      [c : char (string.string-ref text end)]
      (or
        (source_text.source-text-space? c)
        (= c '(')
        (= c ')')
        (= c '[')
        (= c ']')
        (= c '"')
        (= c '\'')
        (= c ';')))))

(define (lsp-resolve-module-import-target
  [path : String]
  [module-name : String]
  [stdlib-roots : lsp_svec.Vec]) : String
  (match (compiler_load.compiler-load-resolve-module-import-with-roots
    (owned_view.compiler-owned-shared-view path)
    (compiler_load.compiler-load-dirname path)
    (owned_view.compiler-owned-shared-view module-name)
    stdlib-roots)
    [(Ok resolved) (compiler_load.compiler-load-normalize-path resolved)]
    [(Err _) module-name]))

(define (lsp-resolve-import-target-at
  [text : (& text str)]
  [path : String]
  [stdlib-roots : lsp_svec.Vec]
  [operand-start : i64]) : LspImportTarget
  (let
    [n : i64 (string.string-length text)]
    (if (>= operand-start n)
      Missing
      (let
        [c : char (string.string-ref text operand-start)]
        (cond
          [(= c '"')
            (let
              [str-end : i64
                (source_text.source-text-skip-string text operand-start n)]
              [content-start : i64 (+ operand-start 1)]
              [content-end : i64 (- str-end 1)]
              [spec : String
                (string.substring
                  text
                  content-start
                  (- content-end content-start))]
              [resolved : String
                (compiler_load.compiler-load-normalize-path
                  (compiler_load.compiler-load-resolve-import-with-roots
                    path
                    spec
                    stdlib-roots))]
              (Found resolved content-start content-end))]
          [(lsp-ident-char? c)
            (let
              [module-end : i64 (lsp-scan-ident text operand-start n)]
              [module-name : String
                (string.substring
                  text
                  operand-start
                  (- module-end operand-start))]
              (match (if (lsp-dotted-import-token-boundary? text module-end)
                (lsp-dotted-import-name-kind (& module-name) (< module-end n))
                LspDottedImportNameKind.Invalid)
                [(Complete)
                  (Found
                    (lsp-resolve-module-import-target
                      path
                      module-name
                      stdlib-roots)
                    operand-start
                    module-end)]
                [_ Missing]))]
          [else Missing])))))

;; Collect every import target from the document, skipping strings and comments
;; so embedded source never yields a false import.
(define (lsp-import-target-at-offset
  [text : (& text str)]
  [path : String]
  [stdlib-roots : lsp_svec.Vec]
  [off : i64]) : LspImportTarget
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [target : LspImportTarget Missing]
    (begin
      (while (and
        (< i n)
        (match (owned_view.compiler-owned-shared-view target)
          [(Found _ _ _) false]
          [(Missing) true]))
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c ';') (set! i (source_text.source-text-skip-line text i n))]
            [(= c '\'')
              (set! i (source_text.source-text-skip-char-literal text i n))]
            [(= c '"') (set! i (source_text.source-text-skip-string text i n))]
            [(= c '(')
              (let
                [kw-start : i64
                  (source_text.source-text-skip-space text (+ i 1) n)]
                [kw-end : i64 (lsp-scan-ident text kw-start n)]
                (if (and
                  (> kw-end kw-start)
                  (string.eq
                    (string.substring text kw-start (- kw-end kw-start))
                    "import"))
                  (let
                    [operand-start : i64
                      (source_text.source-text-skip-space text kw-end n)]
                    (match (lsp-resolve-import-target-at
                      text
                      (owned_view.compiler-owned-shared-view path)
                      (owned_view.compiler-owned-shared-view stdlib-roots)
                      operand-start)
                      [(Found resolved start end)
                        (begin
                          (if (and (>= off start) (< off end))
                            (set! target (Found resolved start end))
                            unit)
                          (set! i end))]
                      [(Missing) (set! i (+ i 1))]))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      target)))

(define (lsp-json-int-field-default
  [value : (& value json.Json)]
  [key : String]
  [fallback : i64]) : i64
  (let
    [value : json.Json (owned_view.compiler-owned-reference-shared-view value)]
    (match (json.object-get value (& key))
      [(JsonFound field)
        (match field
          [(JsonNumber text)
            (match (json.number->i64 (& text))
              [(OkJsonNumberI64 number) number]
              [(ErrJsonNumberI64 _) fallback])]
          [_ fallback])]
      [(JsonMissing) fallback])))

(define (lsp-definition-location
  [uri : String]
  [line : i64]
  [col : i64]
  [len : i64]) : json.Json
  (lsp-json-object2
    "uri"
    (JsonString uri)
    "range"
    (lsp-json-object2
      "start"
      (lsp-position line col)
      "end"
      (lsp-position line (+ col len)))))

(define (lsp-semantic-span-position
  [span : compiler_semantic_index.CompilerSemanticSpan]
  [start : bool]) : json.Json
  (let
    [source : ast.AstSourceSpan span.source]
    [line : i64
      (if start
        (ast.ast-source-span-start-line source)
        (ast.ast-source-span-end-line source))]
    [byte-col : i64
      (if start
        (ast.ast-source-span-start-col source)
        (ast.ast-source-span-end-col source))]
    [utf16-col : i64
      (if start
        span.utf16-start-col
        span.utf16-end-col)]
    (lsp-position
      line
      (if lsp-position-encoding-utf8
        byte-col
        utf16-col))))

(define (lsp-semantic-definition-location
  [record : compiler_semantic_index.CompilerSemanticRecord]) : json.Json
  (let
    [span : compiler_semantic_index.CompilerSemanticSpan record.span]
    (lsp-json-object2
      "uri"
      (JsonString (lsp-resolved-path-to-file-uri span.path))
      "range"
      (lsp-json-object2
        "start"
        (lsp-semantic-span-position
          (owned_view.compiler-owned-shared-view span)
          true)
        "end"
        (lsp-semantic-span-position span false)))))

(define (lsp-definition-respond
  [id : json.Json]
  [uri : String]
  [position : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]
  [stdlib-roots : lsp_svec.Vec]) : unit
  (let
    [doc-index : i64 (lsp-documents-find-index docs uri)]
    (if (< doc-index 0)
      (lsp-write-response id JsonNull)
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp_document_vec.get (& docs) doc-index (lsp-document-fallback))]
        [path : String doc.path]
        [text : String doc.text]
        [line0 : i64 (lsp-json-int-field-default position "line" 0)]
        [char0 : i64 (lsp-json-int-field-default position "character" 0)]
        [off : i64 (lsp-offset-at-position text line0 char0)]
        [import-target : LspImportTarget
          (lsp-import-target-at-offset text path stdlib-roots off)]
        (match import-target
          [(Found resolved _ _)
            (lsp-write-response
              id
              (lsp-definition-location
                (lsp-resolved-path-to-file-uri resolved)
                1
                1
                1))]
          [(Missing)
            (match (lsp-document-semantic-symbol-query (& doc) off)
              [(Found _ definition)
                (lsp-write-response
                  id
                  (lsp-semantic-definition-location definition))]
              [(Missing) (lsp-write-response id JsonNull)])])))))

(define (lsp-handle-definition
  [id : json.Json]
  [params : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]
  [stdlib-roots : lsp_svec.Vec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view params)
      (& td-key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Ok uri)
            (let
              [pos-key : String "position"]
              (match (json.object-get params (& pos-key))
                [(JsonFound position)
                  (lsp-definition-respond id uri position docs stdlib-roots)]
                [(JsonMissing) (lsp-write-response id JsonNull)]))]
          [(Missing) (lsp-write-response id JsonNull)])]
      [(JsonMissing) (lsp-write-response id JsonNull)])))

;; --------------------------------------------------------------------------
;; Signature help (textDocument/signatureHelp).
;;
;; The lexical scanner identifies the innermost call and its direct argument.
;; Resolution remains identity-first: the exact call-head span must be a use in
;; the current document-owned semantic snapshot, and its definition must carry
;; a callable rendered type. No spelling-based fallback is permitted.
;; --------------------------------------------------------------------------
(define (lsp-signature-space? [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

;; Split `(-> parameter ... result)` at balanced top-level boundaries. A valid
;; zero-parameter signature has one component (the result); an empty vector is
;; therefore an unambiguous malformed/non-callable result.
(define (lsp-signature-type-components [type-text : String]) : lsp_svec.Vec
  (let
    [parts : lsp_svec.Vec (lsp_svec.new)]
    [n : i64 (string.string-length type-text)]
    [limit : i64 (- n 1)]
    [i : i64 3]
    [valid : bool
      (and
        (>= n 6)
        (= (string.string-ref type-text 0) '(')
        (= (string.string-ref type-text 1) '-')
        (= (string.string-ref type-text 2) '>')
        (lsp-signature-space? (string.string-ref type-text 3))
        (= (string.string-ref type-text limit) ')'))]
    (begin
      (while (and valid (< i limit))
        (begin
          (while (and
            (< i limit)
            (lsp-signature-space? (string.string-ref type-text i)))
            (set! i (+ i 1)))
          (if (< i limit)
            (let
              [start : i64 i]
              [depth : i64 0]
              [done : bool false]
              (begin
                (while (and valid (< i limit) (not done))
                  (let
                    [c : char (string.string-ref type-text i)]
                    (cond
                      [(= c '(')
                        (begin
                          (set! depth (+ depth 1))
                          (set! i (+ i 1)))]
                      [(= c ')')
                        (if (= depth 0)
                          (set! valid false)
                          (begin
                            (set! depth (- depth 1))
                            (set! i (+ i 1))))]
                      [(and (= depth 0) (lsp-signature-space? c))
                        (set! done true)]
                      [else (set! i (+ i 1))])))
                (if (or (not valid) (not (= depth 0)) (= i start))
                  (set! valid false)
                  (lsp_svec.push-ref!
                    (&mut parts)
                    (string.substring type-text start (- i start))))))
            unit)))
      (if (and valid (> (lsp_svec.len (& parts)) 0))
        parts
        (lsp_svec.new)))))

(define (lsp-signature-record-use?
  [record : compiler_semantic_index.CompilerSemanticRecord]) : bool
  (match record.role
    [(Use) true]
    [_ false]))

(define (lsp-signature-callable-kind?
  [kind : compiler_semantic_index.CompilerSemanticSymbolKind]) : bool
  (match kind
    [(Value) true]
    [(Function) true]
    [(Macro) true]
    [(ExternValue) true]
    [(ExternFunction) true]
    [(Parameter) true]
    [(Local) true]
    [_ false]))

(define (lsp-signature-named-parameter-owner?
  [record : (& record compiler_semantic_index.CompilerSemanticRecord)]) : bool
  (and
    (= record.symbol.local-ordinal -1)
    (match record.kind
      [(Function) true]
      [(Macro) true]
      [(ExternFunction) true]
      [_ false])))

;; Return names only when the semantic index proves a complete ordered
;; association: same owning declaration identity/path, dense parameter ordinal,
;; and the same rendered type as the callable signature. Otherwise the caller
;; uses type-only labels for every parameter rather than mixing confidence.
(define (lsp-signature-parameter-names
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [definition : (& definition compiler_semantic_index.CompilerSemanticRecord)]
  [components : (& components lsp_svec.Vec)]) : lsp_svec.Vec
  (let
    [names : lsp_svec.Vec (lsp_svec.new)]
    [parameter-count : i64 (- (lsp_svec.len components) 1)]
    [record-index : i64 0]
    [found : i64 0]
    [valid : bool (lsp-signature-named-parameter-owner? definition)]
    [owner : compiler_semantic_index.CompilerSemanticSymbolId definition.symbol]
    [definition-span : compiler_semantic_index.CompilerSemanticSpan
      definition.span]
    (begin
      (while (and
        valid
        (< found parameter-count)
        (<
          record-index
          (compiler_semantic_index.compiler-semantic-source-index-len index)))
        (let
          [record : compiler_semantic_index.CompilerSemanticRecord
            (compiler_semantic_index.compiler-semantic-source-index-get
              index
              record-index)]
          [symbol : compiler_semantic_index.CompilerSemanticSymbolId
            record.symbol]
          [span : compiler_semantic_index.CompilerSemanticSpan record.span]
          (begin
            (if (and
              (match record.role
                [(Definition) true]
                [_ false])
              (match record.kind
                [(Parameter) true]
                [_ false])
              record.editable
              (= symbol.module-id owner.module-id)
              (= symbol.declaration-ordinal owner.declaration-ordinal)
              (= symbol.local-ordinal found)
              (string.eq span.path definition-span.path)
              (> span.start-byte definition-span.end-byte))
              (if (string.eq
                record.resolved-type
                (lsp_svec.get components found ""))
                (begin
                  (lsp_svec.push-ref! (&mut names) record.display-name)
                  (set! found (+ found 1)))
                (set! valid false))
              unit)
            (set! record-index (+ record-index 1)))))
      (if (and valid (= found parameter-count))
        names
        (lsp_svec.new)))))

(define (lsp-signature-parameter-labels
  [components : (& components lsp_svec.Vec)]
  [names : (& names lsp_svec.Vec)]) : lsp_svec.Vec
  (let
    [labels : lsp_svec.Vec (lsp_svec.new)]
    [parameter-count : i64 (- (lsp_svec.len components) 1)]
    [named : bool (= (lsp_svec.len names) parameter-count)]
    [index : i64 0]
    (begin
      (while (< index parameter-count)
        (let
          [type-label : String (lsp_svec.get components index "")]
          (begin
            (lsp_svec.push-ref!
              (&mut labels)
              (if named
                (lsp-str5
                  "["
                  (lsp_svec.get names index "")
                  " : "
                  type-label
                  "]")
                type-label))
            (set! index (+ index 1)))))
      labels)))

(define (lsp-signature-label
  [call-name : String]
  [parameter-labels : (& parameter-labels lsp_svec.Vec)]
  [result-label : String]) : String
  (let
    [label : String (lsp-str2 "(" call-name)]
    [index : i64 0]
    (begin
      (while (< index (lsp_svec.len parameter-labels))
        (begin
          (set!
            label
            (lsp-str3 label " " (lsp_svec.get parameter-labels index "")))
          (set! index (+ index 1))))
      (lsp-str3 label ") : " result-label))))

;; Parameter label offsets are always UTF-16 code units by the LSP 3.17
;; SignatureInformation contract, regardless of negotiated document positions.
(define (lsp-signature-utf16-length [text : String]) : i64
  (-
    (compiler_semantic_index.compiler-semantic-source-utf16-col-at-offset
      (lsp-global-shared-view text)
      (string.string-length text))
    1))

(define (lsp-signature-parameter-information-list
  [labels : (& labels lsp_svec.Vec)]
  [index : i64]
  [prior-end : i64]) : json.JsonSeq
  (if (>= index (lsp_svec.len labels))
    (json.list-empty)
    (let
      [label : String (lsp_svec.get labels index "")]
      [start : i64 (+ prior-end 1)]
      [end : i64 (+ start (lsp-signature-utf16-length label))]
      (lsp-json-list-cons
        (lsp-json-object1
          "label"
          (lsp-json-array
            (lsp-json-list-cons
              (lsp-json-number start)
              (lsp-json-list-cons (lsp-json-number end) (json.list-empty)))))
        (lsp-signature-parameter-information-list labels (+ index 1) end)))))

(define (lsp-signature-information
  [call-name : String]
  [definition : compiler_semantic_index.CompilerSemanticRecord]
  [parameter-labels : (& parameter-labels lsp_svec.Vec)]
  [result-label : String]) : json.Json
  (let
    [label : String
      (lsp-signature-label
        (lsp-global-shared-view call-name)
        parameter-labels
        result-label)]
    [parameters : json.Json
      (lsp-json-array
        (lsp-signature-parameter-information-list
          parameter-labels
          0
          (lsp-signature-utf16-length (lsp-str2 "(" call-name))))]
    (lsp-json-object
      (lsp-json-member
        "label"
        (JsonString label)
        (if (string.eq definition.documentation "")
          (lsp-json-member "parameters" parameters (json.member-list-empty))
          (lsp-json-member
            "documentation"
            (JsonString definition.documentation)
            (lsp-json-member "parameters" parameters (json.member-list-empty))))))))

(define (lsp-signature-help-result
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [text : String]
  [context : LspCallContext]
  [definition : compiler_semantic_index.CompilerSemanticRecord]
  [components : (& components lsp_svec.Vec)]) : json.Json
  (let
    [parameter-count : i64 (- (lsp_svec.len components) 1)]
    [call-name : String
      (string.substring
        text
        context.head-start
        (- context.head-end context.head-start))]
    [names : lsp_svec.Vec
      (lsp-signature-parameter-names index definition components)]
    [labels : lsp_svec.Vec
      (lsp-signature-parameter-labels components (& names))]
    [result-label : String (lsp_svec.get components parameter-count "")]
    [signature : json.Json
      (lsp-signature-information call-name definition (& labels) result-label)]
    [active-valid : bool
      (and
        (> parameter-count 0)
        (>= context.active-argument 0)
        (< context.active-argument parameter-count))]
    (lsp-json-object
      (lsp-json-member
        "signatures"
        (lsp-json-array (lsp-json-list-cons signature (json.list-empty)))
        (lsp-json-member
          "activeSignature"
          (lsp-json-number 0)
          (if active-valid
            (lsp-json-member
              "activeParameter"
              (lsp-json-number context.active-argument)
              (json.member-list-empty))
            (json.member-list-empty)))))))

(define (lsp-signature-help-at
  [doc : lsp_vector_families.LspDocument]
  [line0 : i64]
  [char0 : i64]) : json.Json
  (match (lsp-offset-at-position-checked
    (lsp-global-shared-view doc.text)
    line0
    char0)
    [(Missing) JsonNull]
    [(Found offset)
      (match (lsp-call-context-at-offset
        (lsp-global-shared-view doc.text)
        offset)
        [(Missing) JsonNull]
        [(Found context)
          (match (lsp-document-semantic-symbol-query (& doc) context.head-start)
            [(Missing) JsonNull]
            [(Found cursor definition)
              (let
                [cursor-span : compiler_semantic_index.CompilerSemanticSpan
                  (lsp-global-shared-view cursor.span)]
                [components : lsp_svec.Vec
                  (lsp-signature-type-components
                    (lsp-global-shared-view definition.resolved-type))]
                (if (and
                  (lsp-signature-record-use? cursor)
                  (lsp-signature-callable-kind? definition.kind)
                  (= cursor-span.start-byte context.head-start)
                  (= cursor-span.end-byte context.head-end)
                  (> (lsp_svec.len (& components)) 0))
                  (lsp-signature-help-result
                    (& doc.semantic.index)
                    doc.text
                    context
                    definition
                    (& components))
                  JsonNull))])])]))

(define (lsp-signature-help-uri-result
  [params : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : String]) : json.Json
  (let
    [doc-index : i64 (lsp-documents-find-index docs uri)]
    [position-key : String "position"]
    (if (< doc-index 0)
      JsonNull
      (match (json.object-get params (& position-key))
        [(JsonMissing) JsonNull]
        [(JsonFound position)
          (let
            [doc : lsp_vector_families.LspDocument
              (lsp_document_vec.get (& docs) doc-index (lsp-document-fallback))]
            [line0 : i64 (lsp-json-int-field-default position "line" -1)]
            [char0 : i64 (lsp-json-int-field-default position "character" -1)]
            (lsp-signature-help-at doc line0 char0))]))))

(define (lsp-signature-help-document-result
  [params : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]) : json.Json
  (let
    [text-document-key : String "textDocument"]
    (match (json.object-get
      (lsp-global-shared-view params)
      (& text-document-key))
      [(JsonMissing) JsonNull]
      [(JsonFound text-document)
        (match (lsp-json-string-field text-document "uri")
          [(Missing) JsonNull]
          [(Ok uri) (lsp-signature-help-uri-result params docs uri)])])))

(define (lsp-signature-help-respond
  [id : json.Json]
  [params : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]) : unit
  (lsp-write-response id (lsp-signature-help-document-result params docs)))

;; --------------------------------------------------------------------------
;; Completion (textDocument/completion).
;;
;; Offers the language's special forms, builtins, and primitive types, plus
;; semantic and workspace declarations. Candidates must match the typed prefix
;; and only the best-ranked rows are returned (`lsp-completion-results-insert!`).
;; --------------------------------------------------------------------------
(define (lsp-completion-keywords) : String
  "define lambda let if begin while set! return match foreach cond when unless and or with-arena with-escape with-scratch try unsafe quote quasiquote unquote ann init cast type defstruct defenum defmacro defdispatch import export extern module comptime include-str include-bin test spmd-reduce spmd-scan spmd-broadcast spmd-shuffle program-index program-count")

(define (lsp-completion-builtins) : String
  "c-fn-check ptr-null ptr-read ptr-write! ptr-offset ptr-cast ptr->int int->ptr ptr-null? ptr-addr-of array-ref tuple-ref deref string-data string-from-bytes program-argc program-argv program-envp cpuid-eax cpuid-ebx cpuid-ecx cpuid-edx xgetbv syscall box array tuple slice")

(define (lsp-completion-types) : String
  "i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char String str unit never Array Tuple CFunc Box Ptr MutPtr")

(define (lsp-split-spaces [s : String]) : lsp_svec.Vec
  (let
    [n : i64 (string.string-length s)]
    [i : i64 0]
    [start : i64 0]
    [acc : lsp_svec.Vec (lsp_svec.new)]
    (begin
      (while (< i n)
        (begin
          (if (= (string.string-ref s i) ' ')
            (begin
              (if (> i start)
                (lsp_svec.push-ref!
                  (&mut acc)
                  (string.substring s start (- i start)))
                unit)
              (set! start (+ i 1)))
            unit)
          (set! i (+ i 1))))
      (if (> n start)
        (lsp_svec.push-ref! (&mut acc) (string.substring s start (- n start)))
        unit)
      acc)))

(define lsp-completion-result-limit : i64
  256)

(define (lsp-completion-candidate-fallback) : LspCompletionCandidate
  (LspCompletionCandidate 2 9 9 1 "" "" "" "" "" 0 0 "" ""))

(define (lsp-completion-results-new) : LspCompletionResults
  (LspCompletionResults
    (__tl_make-array LspCompletionCandidate lsp-completion-result-limit)
    0
    false))

(define (lsp-completion-results-get
  [results : (& results LspCompletionResults)]
  [index : i64]) : LspCompletionCandidate
  (if (and (>= index 0) (< index results.len))
    (array-ref results.slots index)
    (lsp-completion-candidate-fallback)))

(define (lsp-completion-match-rank [label : (& label str)] [prefix : String]) : i64
  (cond
    [(string.eq label prefix) 0]
    [(or
        (= (string.string-length prefix) 0)
        (string.is-string-prefix-at label (& prefix) 0))
      1]
    [else -1]))

(define (lsp-completion-candidate-less?
  [left : LspCompletionCandidate]
  [right : LspCompletionCandidate]) : bool
  (cond
    [(< left.match-rank right.match-rank) true]
    [(> left.match-rank right.match-rank) false]
    [(< left.source-rank right.source-rank) true]
    [(> left.source-rank right.source-rank) false]
    [(not (string.eq left.label right.label))
      (package_source_core.package-source-string-less? left.label right.label)]
    [(< left.namespace-rank right.namespace-rank) true]
    [(> left.namespace-rank right.namespace-rank) false]
    [(< left.kind right.kind) true]
    [(> left.kind right.kind) false]
    [(not (string.eq left.module right.module))
      (package_source_core.package-source-string-less? left.module right.module)]
    [(not (string.eq left.path right.path))
      (package_source_core.package-source-string-less? left.path right.path)]
    [(< left.line right.line) true]
    [(> left.line right.line) false]
    [(< left.col right.col) true]
    [(> left.col right.col) false]
    [else
      (package_source_core.package-source-string-less?
        left.stable-key
        right.stable-key)]))

(define (lsp-completion-results-contain-key?
  [results : (& results LspCompletionResults)]
  [stable-key : String]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (< index results.len) (not found))
        (begin
          (if (string.eq
            (lsp-completion-results-get results index).stable-key
            stable-key)
            (set! found true)
            unit)
          (set! index (+ index 1))))
      found)))

;; Insert into the sorted live prefix, retaining the best 256 unique semantic
;; identities.  Seeing any further match marks the CompletionList incomplete,
;; even when that match ranks below every retained row.
(define (lsp-completion-results-insert!
  [results : (&mut results LspCompletionResults)]
  [candidate : LspCompletionCandidate]) : unit
  (if (lsp-completion-results-contain-key?
    results
    (owned_view.compiler-owned-shared-view candidate.stable-key))
    unit
    (let
      [len : i64 results.len]
      [position : i64 0]
      (begin
        (while (and
          (< position len)
          (not
            (lsp-completion-candidate-less?
              (owned_view.compiler-owned-shared-view candidate)
              (lsp-completion-results-get results position))))
          (set! position (+ position 1)))
        (if (>= position lsp-completion-result-limit)
          (set! results.incomplete true)
          (let
            [write : i64
              (if (< len lsp-completion-result-limit)
                len
                (- lsp-completion-result-limit 1))]
            (begin
              (while (> write position)
                (begin
                  (set!
                    (array-ref results.slots write)
                    (array-ref results.slots (- write 1)))
                  (set! write (- write 1))))
              (set! (array-ref results.slots position) candidate)
              (if (< len lsp-completion-result-limit)
                (set! results.len (+ len 1))
                (set! results.incomplete true)))))))))

(define (lsp-completion-symbol-kind
  [kind : (& kind compiler_semantic_index.CompilerSemanticSymbolKind)]) : i64
  (match (deref kind)
    [(Function) 3]
    [(ExternFunction) 3]
    [(Macro) 3]
    [(Field) 5]
    [(Value) 6]
    [(ExternValue) 6]
    [(Parameter) 6]
    [(Local) 6]
    [(Module) 9]
    [(Enum) 13]
    [(EnumMember) 20]
    [(Struct) 22]))

(define (lsp-completion-namespace-rank
  [namespace
    : (& namespace compiler_semantic_index.CompilerSemanticBindingNamespace)]) : i64
  (match (deref namespace)
    [(Value) 0]
    [(Type) 1]
    [(Macro) 2]))

(define (lsp-completion-kind-name
  [kind : (& kind compiler_semantic_index.CompilerSemanticSymbolKind)]) : String
  (match (deref kind)
    [(Value) "value"]
    [(Function) "function"]
    [(Macro) "macro"]
    [(ExternValue) "extern value"]
    [(ExternFunction) "extern function"]
    [(Struct) "struct"]
    [(Enum) "enum"]
    [(Module) "module"]
    [(Field) "field"]
    [(EnumMember) "enum member"]
    [(Parameter) "parameter"]
    [_ "local"]))

(define (lsp-completion-semantic-stable-key
  [binding : (& binding compiler_semantic_index.CompilerSemanticVisibleBinding)]) : String
  (lsp-str3
    (lsp-str3 "semantic:" (string.int->string binding.symbol.module-id) ":")
    (lsp-str3
      (string.int->string binding.symbol.declaration-ordinal)
      ":"
      (string.int->string binding.symbol.local-ordinal))
    (lsp-str3
      ":"
      (string.int->string (lsp-completion-namespace-rank (& binding.namespace)))
      "")))

(define (lsp-completion-source-rank
  [kind : compiler_semantic_index.CompilerSemanticSymbolKind]
  [definition-path : (& definition-path str)]
  [current-path : String]) : i64
  (match kind
    [(Parameter) 0]
    [(Local) 0]
    [_
      (if (string.eq definition-path current-path)
        1
        2)]))

(define (lsp-completion-add-visible!
  [results : (&mut results LspCompletionResults)]
  [binding : compiler_semantic_index.CompilerSemanticVisibleBinding]
  [prefix : String]
  [current-path : String]) : unit
  (let
    [rank : i64 (lsp-completion-match-rank binding.display-name prefix)]
    (if (or (< rank 0) (not binding.editable))
      unit
      (let
        [detail : String
          (if (= (string.string-length binding.resolved-type) 0)
            (lsp-completion-kind-name (& binding.kind))
            (string.copy (& binding.resolved-type)))]
        (lsp-completion-results-insert!
          results
          (LspCompletionCandidate
            rank
            (lsp-completion-source-rank
              binding.kind
              binding.definition-span.path
              current-path)
            (lsp-completion-namespace-rank (& binding.namespace))
            (lsp-completion-symbol-kind (& binding.kind))
            (string.copy (& binding.display-name))
            (string.copy (& detail))
            (string.copy (& binding.documentation))
            ""
            (string.copy (& binding.definition-span.path))
            (cast binding.definition-span.source.start-line : i64)
            (cast binding.definition-span.source.start-col : i64)
            (lsp-completion-semantic-stable-key (& binding))
            (string.copy (& binding.display-name))))))))

(define (lsp-completion-collect-visible!
  [results : (&mut results LspCompletionResults)]
  [doc : (& doc lsp_vector_families.LspDocument)]
  [context : (& context LspCompletionContext)]
  [namespace-mask : i64]) : unit
  (match (compiler_semantic_index.compiler-semantic-source-index-query
    (& doc.semantic.index)
    (string.copy (& doc.path))
    context.cursor-byte)
    [(None) unit]
    [(Some query)
      (let
        [cursor : compiler_semantic_index.CompilerSemanticVisibleBindingCursor
          (compiler_semantic_index.compiler-semantic-visible-binding-cursor
            (& doc.semantic.index)
            query
            namespace-mask)]
        [done : bool false]
        (while (not done)
          (match (compiler_semantic_index.compiler-semantic-visible-binding-cursor-step
            (& doc.semantic.index)
            cursor)
            [(Some binding next)
              (begin
                (lsp-completion-add-visible!
                  results
                  binding
                  (string.copy (& context.prefix))
                  (string.copy (& doc.path)))
                (set! cursor next))]
            [(Done) (set! done true)])))]))

(define (lsp-completion-add-language-labels!
  [results : (&mut results LspCompletionResults)]
  [labels : String]
  [prefix : String]
  [kind : i64]
  [source-rank : i64]
  [identity-prefix : String]
  [detail : String]) : unit
  (let
    [split : lsp_svec.Vec (lsp-split-spaces labels)]
    [index : i64 0]
    (while (< index (lsp_svec.len (& split)))
      (let
        [label : String (lsp_svec.get (& split) index "")]
        [rank : i64
          (lsp-completion-match-rank
            label
            (owned_view.compiler-owned-shared-view prefix))]
        (begin
          (if (>= rank 0)
            (lsp-completion-results-insert!
              results
              (LspCompletionCandidate
                rank
                source-rank
                8
                kind
                (string.copy (& label))
                (string.copy (& detail))
                ""
                ""
                ""
                0
                0
                (lsp-str3
                  (owned_view.compiler-owned-shared-view identity-prefix)
                  ":"
                  (owned_view.compiler-owned-shared-view label))
                (string.copy (& label))))
            unit)
          (set! index (+ index 1)))))))

(define (lsp-completion-record-definition?
  [record : (& record compiler_semantic_index.CompilerSemanticRecord)]) : bool
  (match record.role
    [(Definition) true]
    [_ false]))

(define (lsp-completion-record-kind-allowed?
  [kind : compiler_semantic_index.CompilerSemanticSymbolKind]
  [type-context : bool]
  [member-context : bool]) : bool
  (if member-context
    (if type-context
      false
      (or
        (match kind
          [(Field) true]
          [_ false])
        (match kind
          [(EnumMember) true]
          [_ false])))
    (if type-context
      (or
        (match kind
          [(Struct) true]
          [_ false])
        (match kind
          [(Enum) true]
          [_ false]))
      (or
        (match kind
          [(Value) true]
          [_ false])
        (match kind
          [(Function) true]
          [_ false])
        (match kind
          [(ExternValue) true]
          [_ false])
        (match kind
          [(ExternFunction) true]
          [_ false])
        (match kind
          [(Macro) true]
          [_ false])
        (match kind
          [(Struct) true]
          [_ false])
        (match kind
          [(EnumMember) true]
          [_ false])))))

(define (lsp-completion-record-stable-key
  [record : (& record compiler_semantic_index.CompilerSemanticRecord)]) : String
  (lsp-str3
    (lsp-str3 "record:" (string.int->string record.symbol.module-id) ":")
    (lsp-str3
      (string.int->string record.symbol.declaration-ordinal)
      ":"
      (string.int->string record.symbol.local-ordinal))
    (lsp-str3
      ":"
      (string.int->string (lsp-completion-symbol-kind (& record.kind)))
      "")))

(define (lsp-completion-add-record!
  [results : (&mut results LspCompletionResults)]
  [record : compiler_semantic_index.CompilerSemanticRecord]
  [prefix : String]
  [source-rank : i64]
  [module : (& module str)]) : unit
  (let
    [rank : i64 (lsp-completion-match-rank record.display-name prefix)]
    (if (or (< rank 0) (not record.editable))
      unit
      (lsp-completion-results-insert!
        results
        (LspCompletionCandidate
          rank
          source-rank
          3
          (lsp-completion-symbol-kind (& record.kind))
          (string.copy (& record.display-name))
          (if (= (string.string-length record.resolved-type) 0)
            (lsp-completion-kind-name (& record.kind))
            (string.copy (& record.resolved-type)))
          (string.copy (& record.documentation))
          (string.copy module)
          (string.copy (& record.span.path))
          (cast record.span.source.start-line : i64)
          (cast record.span.source.start-col : i64)
          (lsp-completion-record-stable-key (& record))
          (string.copy (& record.display-name)))))))

(define (lsp-completion-workspace-item-kind [symbol-kind : i64]) : i64
  (cond
    [(= symbol-kind 12) 3]
    [(= symbol-kind 23) 22]
    [(= symbol-kind 10) 13]
    [else 6]))

(define (lsp-completion-add-workspace-decl!
  [results : (&mut results LspCompletionResults)]
  [source : (& source lsp_vector_families.LspWorkspaceSource)]
  [decl : lsp_vector_families.LspDeclEntry]
  [prefix : String]
  [source-rank : i64]) : unit
  (let
    [rank : i64 (lsp-completion-match-rank decl.name prefix)]
    (if (< rank 0)
      unit
      (lsp-completion-results-insert!
        results
        (LspCompletionCandidate
          rank
          source-rank
          4
          (lsp-completion-workspace-item-kind decl.symbol-kind)
          (string.copy (& decl.name))
          (lsp-str3
            (owned_view.compiler-owned-shared-view decl.kind)
            " from "
            (string.copy (& source.module)))
          ""
          (string.copy (& source.module))
          (string.copy (& source.path))
          decl.name-line
          decl.name-col
          (lsp-str7
            "workspace:"
            (string.copy (& source.path))
            ":"
            (string.int->string decl.name-line)
            ":"
            (string.int->string decl.name-col)
            (lsp-str3 ":" decl.kind ""))
          (string.copy (& decl.name)))))))

(define (lsp-completion-first-module-segment [text : String]) : String
  (let
    [index : i64 0]
    [n : i64 (string.string-length text)]
    (begin
      (while (and (< index n) (not (= (string.string-ref text index) '.')))
        (set! index (+ index 1)))
      (string.substring text 0 index))))

;; Return the next bare module component after `receiver`, or empty when the
;; indexed module is outside that subtree.
(define (lsp-completion-module-next-segment
  [module : String]
  [receiver : String]) : String
  (if (= (string.string-length receiver) 0)
    (lsp-completion-first-module-segment module)
    (let
      [prefix : String (lsp-str3 receiver "." "")]
      (if (not (string.is-string-prefix-at (& module) (& prefix) 0))
        ""
        (lsp-completion-first-module-segment
          (string.substring
            module
            (string.string-length prefix)
            (- (string.string-length module) (string.string-length prefix))))))))

(define (lsp-completion-collect-import!
  [results : (&mut results LspCompletionResults)]
  [workspace : (& workspace lsp_vector_families.LspWorkspaceIndex)]
  [context : (& context LspCompletionContext)]) : unit
  (let
    [sources : lsp_vector_families.LspWorkspaceSources workspace.sources]
    [source-index : i64 0]
    (while (< source-index (lsp-workspace-sources-len (& sources)))
      (let
        [source : lsp_vector_families.LspWorkspaceSource
          (lsp-workspace-sources-get (& sources) source-index)]
        [segment : String
          (lsp-completion-module-next-segment
            (string.copy (& source.module))
            (string.copy (& context.receiver)))]
        (begin
          (if (> (string.string-length segment) 0)
            (let
              [rank : i64
                (lsp-completion-match-rank
                  segment
                  (string.copy (& context.prefix)))]
              (if (>= rank 0)
                (lsp-completion-results-insert!
                  results
                  (LspCompletionCandidate
                    rank
                    4
                    4
                    9
                    (string.copy (& segment))
                    (lsp-str3
                      "module "
                      (owned_view.compiler-owned-shared-view source.module)
                      "")
                    ""
                    (string.copy (& source.module))
                    (string.copy (& source.path))
                    0
                    0
                    (lsp-str5
                      "module-segment:"
                      (string.copy (& context.receiver))
                      ":"
                      (owned_view.compiler-owned-shared-view segment)
                      "")
                    (string.copy (& segment))))
                unit))
            unit)
          (if (string.eq source.module (string.copy (& context.receiver)))
            (let
              [decls : lsp_decl_vec.Vec source.decls]
              [decl-index : i64 0]
              (while (< decl-index (lsp_decl_vec.len (& decls)))
                (begin
                  (lsp-completion-add-workspace-decl!
                    results
                    (& source)
                    (lsp_decl_vec.get
                      (& decls)
                      decl-index
                      (lsp-decl-entry-fallback))
                    (string.copy (& context.prefix))
                    4)
                  (set! decl-index (+ decl-index 1)))))
            unit)
          (set! source-index (+ source-index 1)))))))

(define (lsp-completion-record-is-value-receiver?
  [record : (& record compiler_semantic_index.CompilerSemanticRecord)]) : bool
  (or
    (match record.kind
      [(Value) true]
      [_ false])
    (match record.kind
      [(Local) true]
      [_ false])
    (match record.kind
      [(Parameter) true]
      [_ false])
    (match record.kind
      [(Field) true]
      [_ false])))

(define (lsp-completion-rendered-type-tail [type-text : String]) : String
  ;; `tc-type-render` emits wrapper types as S-expressions. Find their final
  ;; top-level component so reference and region wrappers can be peeled without
  ;; confusing a lifetime argument with the nominal referent.
  (let
    [end : i64 (- (string.string-length type-text) 1)]
    [start : i64 -1]
    [depth : i64 0]
    (begin
      (while (and
        (> end 0)
        (source_text.source-text-space? (string.string-ref type-text (- end 1))))
        (set! end (- end 1)))
      (if (and (> end 0) (= (string.string-ref type-text (- end 1)) ')'))
        (let
          [cursor : i64 (- end 1)]
          (begin
            (set! depth 1)
            (set! cursor (- cursor 1))
            (while (and (>= cursor 0) (> depth 0))
              (begin
                (cond
                  [(= (string.string-ref type-text cursor) ')')
                    (set! depth (+ depth 1))]
                  [(= (string.string-ref type-text cursor) '(')
                    (set! depth (- depth 1))]
                  [else unit])
                (if (= depth 0)
                  (set! start cursor)
                  unit)
                (set! cursor (- cursor 1))))))
        (let
          [cursor : i64 (- end 1)]
          (begin
            (while (and
              (> cursor 0)
              (not
                (source_text.source-text-space?
                  (string.string-ref type-text (- cursor 1))))
              (not (= (string.string-ref type-text (- cursor 1)) '(')))
              (set! cursor (- cursor 1)))
            (set! start cursor))))
      (if (and (>= start 0) (> end start))
        (string.substring type-text start (- end start))
        ""))))

(define (lsp-completion-rendered-type-owner-name [type-text : String]) : String
  ;; A field receiver can be a nominal value, a lifetime-instantiated nominal,
  ;; or a shared/mutable reference (possibly carrying an outer Region tag).
  ;; Extract only that nominal head. A raw substring match is not semantic:
  ;; e.g. type `app.main/AB` must not resolve to an earlier struct named `A`.
  (let
    [n : i64 (string.string-length type-text)]
    (if (= n 0)
      ""
      (if (not (= (string.string-ref type-text 0) '('))
        (string.copy (& type-text))
        (let
          [head-end : i64 1]
          (begin
            (while (and
              (< head-end n)
              (not
                (source_text.source-text-space?
                  (string.string-ref type-text head-end)))
              (not (= (string.string-ref type-text head-end) ')')))
              (set! head-end (+ head-end 1)))
            (let
              [head : String (string.substring type-text 1 (- head-end 1))]
              (if (or
                (string.eq head "&")
                (string.eq head "&mut")
                (string.eq head "Region"))
                (lsp-completion-rendered-type-owner-name
                  (lsp-completion-rendered-type-tail type-text))
                head))))))))

(define (lsp-completion-record-owns-rendered-type?
  [record : (& record compiler_semantic_index.CompilerSemanticRecord)]
  [owner-name : (& owner-name str)]) : bool
  (let
    [module : String (tc.macro-decl-module-display record.symbol.module-id)]
    [module-len : i64 (string.string-length module)]
    [display-len : i64 (string.string-length record.display-name)]
    (or
      (string.eq owner-name record.display-name)
      (and
        (> module-len 0)
        (= (string.string-length owner-name) (+ module-len (+ display-len 1)))
        (string.is-string-prefix-at owner-name (& module) 0)
        (or
          (= (string.string-ref owner-name module-len) '/')
          (= (string.string-ref owner-name module-len) '.'))
        (string.is-string-prefix-at
          owner-name
          (& record.display-name)
          (+ module-len 1))))))

(define (lsp-completion-find-type-owner
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [type-text : String]) : i64
  (let
    [record-index : i64 0]
    [found : i64 -1]
    [owner-name : String (lsp-completion-rendered-type-owner-name type-text)]
    (begin
      (while (and
        (< found 0)
        (<
          record-index
          (compiler_semantic_index.compiler-semantic-source-index-len index)))
        (let
          [record : compiler_semantic_index.CompilerSemanticRecord
            (compiler_semantic_index.compiler-semantic-source-index-get
              index
              record-index)]
          (begin
            (if (and
              (lsp-completion-record-definition? (& record))
              (or
                (match record.kind
                  [(Struct) true]
                  [_ false])
                (match record.kind
                  [(Enum) true]
                  [_ false]))
              (lsp-completion-record-owns-rendered-type? (& record) owner-name))
              (set! found record-index)
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (lsp-completion-find-module-record
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [path : String]
  [start : i64]
  [end : i64]) : i64
  (let
    [record-index : i64 0]
    [found : i64 -1]
    [best-start : i64 -1]
    (begin
      (while (<
        record-index
        (compiler_semantic_index.compiler-semantic-source-index-len index))
        (let
          [record : compiler_semantic_index.CompilerSemanticRecord
            (compiler_semantic_index.compiler-semantic-source-index-get
              index
              record-index)]
          (begin
            (if (and
              (match record.kind
                [(Module) true]
                [_ false])
              record.editable
              (string.eq record.span.path path)
              (>= record.span.start-byte start)
              (<= record.span.end-byte end)
              (> record.span.start-byte best-start))
              (begin
                (set! found record-index)
                (set! best-start record.span.start-byte))
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (lsp-completion-find-member-owner
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [member-index : i64]) : i64
  (if (< member-index 0)
    -1
    (let
      [member : compiler_semantic_index.CompilerSemanticRecord
        (compiler_semantic_index.compiler-semantic-source-index-get
          index
          member-index)]
      [record-index : i64 0]
      [found : i64 -1]
      (begin
        (when
          (not
            (or
              (match member.kind
                [(Field) true]
                [_ false])
              (match member.kind
                [(EnumMember) true]
                [_ false])))
          (return -1))
        (while (and
          (< found 0)
          (<
            record-index
            (compiler_semantic_index.compiler-semantic-source-index-len index)))
          (let
            [record : compiler_semantic_index.CompilerSemanticRecord
              (compiler_semantic_index.compiler-semantic-source-index-get
                index
                record-index)]
            (begin
              (if (and
                (lsp-completion-record-definition? (& record))
                (or
                  (match record.kind
                    [(Struct) true]
                    [_ false])
                  (match record.kind
                    [(Enum) true]
                    [_ false]))
                (compiler_semantic_index.compiler-semantic-member-symbol-owned-by?
                  (& record.symbol)
                  (& member.symbol)))
                (set! found record-index)
                unit)
              (set! record-index (+ record-index 1)))))
        found))))

(define (lsp-completion-find-visible-receiver-owner
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [path : String]
  [cursor-byte : i64]
  [receiver : String]) : i64
  (match (compiler_semantic_index.compiler-semantic-source-index-query
    index
    path
    cursor-byte)
    [(None) -1]
    [(Some query)
      (let
        [cursor : compiler_semantic_index.CompilerSemanticVisibleBindingCursor
          (compiler_semantic_index.compiler-semantic-visible-binding-cursor
            index
            query
            (compiler_semantic_index.compiler-semantic-binding-namespace-value-mask))]
        [found : i64 -1]
        [done : bool false]
        (begin
          (while (and (< found 0) (not done))
            (match (compiler_semantic_index.compiler-semantic-visible-binding-cursor-step
              index
              cursor)
              [(Some binding next)
                (begin
                  (if (string.eq binding.display-name receiver)
                    (set!
                      found
                      (lsp-completion-find-type-owner
                        index
                        binding.resolved-type))
                    unit)
                  (set! cursor next))]
              [(Done) (set! done true)]))
          found))]))

(define (lsp-completion-find-field-receiver
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [path : String]
  [context : (& context LspCompletionContext)]) : i64
  (let
    [record-index : i64 0]
    [found : i64 -1]
    [best-end : i64 -1]
    (begin
      (while (<
        record-index
        (compiler_semantic_index.compiler-semantic-source-index-len index))
        (let
          [record : compiler_semantic_index.CompilerSemanticRecord
            (compiler_semantic_index.compiler-semantic-source-index-get
              index
              record-index)]
          (begin
            (if (and
              (lsp-completion-record-is-value-receiver? (& record))
              (string.eq record.span.path path)
              (>= record.span.start-byte context.form-start)
              (<= record.span.end-byte context.token-start)
              (> record.span.end-byte best-end))
              (begin
                (set! found record-index)
                (set! best-end record.span.end-byte))
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (lsp-completion-workspace-module-exists?
  [workspace : (& workspace lsp_vector_families.LspWorkspaceIndex)]
  [module : String]) : bool
  (let
    [sources : lsp_vector_families.LspWorkspaceSources workspace.sources]
    [source-index : i64 0]
    [found : bool false]
    (begin
      (while (and
        (< source-index (lsp-workspace-sources-len (& sources)))
        (not found))
        (begin
          (if (string.eq
            (lsp-workspace-sources-get (& sources) source-index).module
            module)
            (set! found true)
            unit)
          (set! source-index (+ source-index 1))))
      found)))

(define (lsp-completion-collect-workspace-module-decls!
  [results : (&mut results LspCompletionResults)]
  [workspace : (& workspace lsp_vector_families.LspWorkspaceIndex)]
  [module : String]
  [prefix : String]
  [type-context : bool]) : unit
  (let
    [sources : lsp_vector_families.LspWorkspaceSources workspace.sources]
    [source-index : i64 0]
    (while (< source-index (lsp-workspace-sources-len (& sources)))
      (let
        [source : lsp_vector_families.LspWorkspaceSource
          (lsp-workspace-sources-get (& sources) source-index)]
        (begin
          (if (string.eq source.module module)
            (let
              [decls : lsp_decl_vec.Vec source.decls]
              [decl-index : i64 0]
              (while (< decl-index (lsp_decl_vec.len (& decls)))
                (let
                  [decl : lsp_vector_families.LspDeclEntry
                    (lsp_decl_vec.get
                      (& decls)
                      decl-index
                      (lsp-decl-entry-fallback))]
                  [allowed : bool
                    (if type-context
                      (or (= decl.symbol-kind 23) (= decl.symbol-kind 10))
                      (not (= decl.symbol-kind 10)))]
                  (begin
                    (if allowed
                      (lsp-completion-add-workspace-decl!
                        results
                        (& source)
                        decl
                        (owned_view.compiler-owned-shared-view prefix)
                        3)
                      unit)
                    (set! decl-index (+ decl-index 1))))))
            unit)
          (set! source-index (+ source-index 1)))))))

(define (lsp-completion-collect-owned-members!
  [results : (&mut results LspCompletionResults)]
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [owner-index : i64]
  [prefix : String]) : unit
  (if (< owner-index 0)
    unit
    (let
      [owner : compiler_semantic_index.CompilerSemanticRecord
        (compiler_semantic_index.compiler-semantic-source-index-get
          index
          owner-index)]
      [record-index : i64 0]
      (while (<
        record-index
        (compiler_semantic_index.compiler-semantic-source-index-len index))
        (let
          [record : compiler_semantic_index.CompilerSemanticRecord
            (compiler_semantic_index.compiler-semantic-source-index-get
              index
              record-index)]
          (begin
            (if (and
              (lsp-completion-record-definition? (& record))
              (lsp-completion-record-kind-allowed? record.kind false true)
              (compiler_semantic_index.compiler-semantic-member-symbol-owned-by?
                (& owner.symbol)
                (& record.symbol)))
              (lsp-completion-add-record!
                results
                record
                (owned_view.compiler-owned-shared-view prefix)
                3
                owner.display-name)
              unit)
            (set! record-index (+ record-index 1))))))))

(define (lsp-completion-collect-module-records!
  [results : (&mut results LspCompletionResults)]
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [module-id : i64]
  [module : (& module str)]
  [prefix : String]
  [type-context : bool]) : unit
  (let
    [record-index : i64 0]
    (while (<
      record-index
      (compiler_semantic_index.compiler-semantic-source-index-len index))
      (let
        [record : compiler_semantic_index.CompilerSemanticRecord
          (compiler_semantic_index.compiler-semantic-source-index-get
            index
            record-index)]
        (begin
          (if (and
            (= record.module-id module-id)
            (lsp-completion-record-definition? (& record))
            (lsp-completion-record-kind-allowed? record.kind type-context false))
            (lsp-completion-add-record!
              results
              record
              (owned_view.compiler-owned-shared-view prefix)
              3
              module)
            unit)
          (set! record-index (+ record-index 1)))))))

(define (lsp-completion-collect-qualified!
  [results : (&mut results LspCompletionResults)]
  [doc : (& doc lsp_vector_families.LspDocument)]
  [workspace : (& workspace lsp_vector_families.LspWorkspaceIndex)]
  [context : (& context LspCompletionContext)]
  [type-context : bool]) : unit
  (let
    [index : compiler_semantic_index.CompilerSemanticSourceIndex
      doc.semantic.index]
    [receiver-end : i64 (- context.replace-start 1)]
    [point-index : i64
      (if (> receiver-end context.token-start)
        (compiler_semantic_index.compiler-semantic-source-index-find-editable-record-at
          (& index)
          (& doc.path)
          (- receiver-end 1))
        -1)]
    [point : compiler_semantic_index.CompilerSemanticRecord
      (compiler_semantic_index.compiler-semantic-source-index-get
        (& index)
        point-index)]
    [suffix-index : i64
      (if (> context.cursor-byte context.replace-start)
        (compiler_semantic_index.compiler-semantic-source-index-find-editable-record-at
          (& index)
          (& doc.path)
          (- context.cursor-byte 1))
        -1)]
    [member-owner-index : i64
      (lsp-completion-find-member-owner (& index) suffix-index)]
    [visible-owner-index : i64
      (lsp-completion-find-visible-receiver-owner
        (& index)
        (string.copy (& doc.path))
        context.cursor-byte
        (string.copy (& context.receiver)))]
    [local-receiver : bool
      (and
        (>= point-index 0)
        (lsp-completion-record-is-value-receiver? (& point))
        ;; A whole qualified-use record may overlap its leading module
        ;; component.  Only a value fact whose own spelling is the receiver
        ;; wins the SPEC §4.4.3 local-field precedence rule.
        (string.eq point.display-name context.receiver))]
    (if (>= member-owner-index 0)
      (lsp-completion-collect-owned-members!
        results
        (& index)
        member-owner-index
        (string.copy (& context.prefix)))
      (if (or local-receiver (>= visible-owner-index 0))
        (lsp-completion-collect-owned-members!
          results
          (& index)
          (if local-receiver
            (lsp-completion-find-type-owner (& index) point.resolved-type)
            visible-owner-index)
          (string.copy (& context.prefix)))
        (let
          [module-index : i64
            (lsp-completion-find-module-record
              (& index)
              (string.copy (& doc.path))
              context.token-start
              receiver-end)]
          (if (>= module-index 0)
            (let
              [module-record : compiler_semantic_index.CompilerSemanticRecord
                (compiler_semantic_index.compiler-semantic-source-index-get
                  (& index)
                  module-index)]
              [module : String module-record.resolved-type]
              [workspace-backed : bool
                (lsp-completion-workspace-module-exists?
                  workspace
                  (owned_view.compiler-owned-shared-view module))]
              (if workspace-backed
                (lsp-completion-collect-workspace-module-decls!
                  results
                  workspace
                  module
                  (string.copy (& context.prefix))
                  type-context)
                (lsp-completion-collect-module-records!
                  results
                  (& index)
                  module-record.module-id
                  module
                  (string.copy (& context.prefix))
                  type-context)))
            (if (and
              (>= point-index 0)
              (or
                (match point.kind
                  [(Struct) true]
                  [_ false])
                (match point.kind
                  [(Enum) true]
                  [_ false])))
              (lsp-completion-collect-owned-members!
                results
                (& index)
                point-index
                (string.copy (& context.prefix)))
              unit)))))))

(define (lsp-completion-collect-field!
  [results : (&mut results LspCompletionResults)]
  [doc : (& doc lsp_vector_families.LspDocument)]
  [context : (& context LspCompletionContext)]) : unit
  (let
    [index : compiler_semantic_index.CompilerSemanticSourceIndex
      doc.semantic.index]
    [receiver-index : i64
      (lsp-completion-find-field-receiver
        (& index)
        (string.copy (& doc.path))
        context)]
    [receiver : compiler_semantic_index.CompilerSemanticRecord
      (compiler_semantic_index.compiler-semantic-source-index-get
        (& index)
        receiver-index)]
    (if (>= receiver-index 0)
      (lsp-completion-collect-owned-members!
        results
        (& index)
        (lsp-completion-find-type-owner (& index) receiver.resolved-type)
        (string.copy (& context.prefix)))
      unit)))

(define (lsp-completion-collect
  [doc : (& doc lsp_vector_families.LspDocument)]
  [workspace : (& workspace lsp_vector_families.LspWorkspaceIndex)]
  [context : (& context LspCompletionContext)]) : LspCompletionResults
  (let
    [results : LspCompletionResults (lsp-completion-results-new)]
    (begin
      (match context.kind
        [(Suppressed) unit]
        [(ImportAlias) unit]
        [(ImportPathOrItem)
          (lsp-completion-collect-import! (&mut results) workspace context)]
        [(DottedMember)
          (lsp-completion-collect-qualified!
            (&mut results)
            doc
            workspace
            context
            false)]
        [(Field) (lsp-completion-collect-field! (&mut results) doc context)]
        [(Type)
          (if (> (string.string-length context.receiver) 0)
            (lsp-completion-collect-qualified!
              (&mut results)
              doc
              workspace
              context
              true)
            (begin
              (lsp-completion-collect-visible!
                (&mut results)
                doc
                context
                (compiler_semantic_index.compiler-semantic-binding-namespace-type-mask))
              (lsp-completion-add-language-labels!
                (&mut results)
                (lsp-completion-types)
                (string.copy (& context.prefix))
                7
                5
                "type"
                "primitive type")))]
        [(CallHead)
          (begin
            (lsp-completion-collect-visible!
              (&mut results)
              doc
              context
              (bit-or
                (compiler_semantic_index.compiler-semantic-binding-namespace-value-mask)
                (compiler_semantic_index.compiler-semantic-binding-namespace-macro-mask)))
            (lsp-completion-add-language-labels!
              (&mut results)
              (lsp-completion-builtins)
              (string.copy (& context.prefix))
              3
              5
              "builtin"
              "builtin form")
            (lsp-completion-add-language-labels!
              (&mut results)
              (lsp-completion-keywords)
              (string.copy (& context.prefix))
              14
              6
              "keyword"
              "language form"))]
        [(Value)
          (lsp-completion-collect-visible!
            (&mut results)
            doc
            context
            (compiler_semantic_index.compiler-semantic-binding-namespace-value-mask))])
      results)))

(define (lsp-completion-text-edit
  [candidate : (& candidate LspCompletionCandidate)]
  [text : (& text str)]
  [context : (& context LspCompletionContext)]) : json.Json
  (let
    [start : LspLineCol (lsp-line-col-at-offset text context.replace-start)]
    [end : LspLineCol (lsp-line-col-at-offset text context.replace-end)]
    (lsp-json-object2
      "range"
      (lsp-json-object2
        "start"
        (lsp-position start.line start.col)
        "end"
        (lsp-position end.line end.col))
      "newText"
      (JsonString (string.copy (& candidate.new-text))))))

(define (lsp-completion-item-json
  [candidate : (& candidate LspCompletionCandidate)]
  [text : (& text str)]
  [context : (& context LspCompletionContext)]) : json.Json
  (lsp-json-object
    (lsp-json-member
      "label"
      (JsonString (string.copy (& candidate.label)))
      (lsp-json-member
        "kind"
        (lsp-json-number candidate.kind)
        (if (> (string.string-length candidate.detail) 0)
          (lsp-json-member
            "detail"
            (JsonString (string.copy (& candidate.detail)))
            (if (> (string.string-length candidate.documentation) 0)
              (lsp-json-member
                "documentation"
                (JsonString (string.copy (& candidate.documentation)))
                (lsp-json-member
                  "textEdit"
                  (lsp-completion-text-edit candidate text context)
                  (json.member-list-empty)))
              (lsp-json-member
                "textEdit"
                (lsp-completion-text-edit candidate text context)
                (json.member-list-empty))))
          (if (> (string.string-length candidate.documentation) 0)
            (lsp-json-member
              "documentation"
              (JsonString (string.copy (& candidate.documentation)))
              (lsp-json-member
                "textEdit"
                (lsp-completion-text-edit candidate text context)
                (json.member-list-empty)))
            (lsp-json-member
              "textEdit"
              (lsp-completion-text-edit candidate text context)
              (json.member-list-empty))))))))

(define (lsp-completion-items-json
  [results : (& results LspCompletionResults)]
  [text : String]
  [context : (& context LspCompletionContext)]
  [index : i64]) : json.JsonSeq
  (if (>= index results.len)
    (json.list-empty)
    (lsp-json-list-cons
      (lsp-completion-item-json
        (& (array-ref results.slots index))
        text
        context)
      (lsp-completion-items-json results text context (+ index 1)))))

(define (lsp-completion-empty-result) : json.Json
  (lsp-json-object2
    "isIncomplete"
    (JsonBool false)
    "items"
    (lsp-json-array (json.list-empty))))

(define (lsp-completion-result-json
  [doc : (& doc lsp_vector_families.LspDocument)]
  [workspace : (& workspace lsp_vector_families.LspWorkspaceIndex)]
  [context : (& context LspCompletionContext)]) : json.Json
  (let
    [results : LspCompletionResults
      (lsp-completion-collect doc workspace context)]
    (lsp-json-object2
      "isIncomplete"
      (JsonBool results.incomplete)
      "items"
      (lsp-json-array
        (lsp-completion-items-json
          (& results)
          (string.copy (& doc.text))
          context
          0)))))

(define (lsp-completion-result-for-params
  [params : json.Json]
  [state : lsp_vector_families.LspServerState]) : json.Json
  (match (lsp-get-semantic-document
    (owned_view.compiler-owned-shared-view params)
    state.documents)
    [(Missing) (lsp-completion-empty-result)]
    [(Found doc)
      (let
        [position-key : String "position"]
        (match (json.object-get params (& position-key))
          [(JsonMissing) (lsp-completion-empty-result)]
          [(JsonFound position)
            (if (not
              (and
                (lsp-json-int-field-usable?
                  (owned_view.compiler-owned-shared-view position)
                  "line")
                (lsp-json-int-field-usable?
                  (owned_view.compiler-owned-shared-view position)
                  "character")))
              (lsp-completion-empty-result)
              (match (lsp-completion-context-at-position
                doc.text
                (lsp-json-int-field-default position "line" -1)
                (lsp-json-int-field-default position "character" -1))
                [(Missing) (lsp-completion-empty-result)]
                [(Found context)
                  (match (lsp-document-semantic-snapshot-status (& doc))
                    [(Current _ _)
                      (lsp-completion-result-json
                        (& doc)
                        (& state.workspace)
                        (& context))]
                    [_ (lsp-completion-empty-result)])]))]))]))

(define (lsp-handle-completion-message
  [message : json.Json]
  [state : lsp_vector_families.LspServerState]) : LspHandleResult
  (let
    [id-key : String "id"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view message)
      (& id-key))
      [(JsonMissing) (Continue state)]
      [(JsonFound id)
        (let
          [previous : i64 (arena.tl_arena_current)]
          [scratch : i64 (arena.tl_arena_make)]
          [_install : unit
            (unsafe
              (arena.tl_arena_set scratch))]
          [params-key : String "params"]
          (begin
            (match (json.object-get message (& params-key))
              [(JsonMissing)
                (lsp-write-response id (lsp-completion-empty-result))]
              [(JsonFound params)
                (lsp-write-response
                  id
                  (lsp-completion-result-for-params
                    params
                    (owned_view.compiler-owned-shared-view state)))])
            (unsafe
              (begin
                (arena.tl_arena_set previous)
                (arena.tl_arena_destroy scratch)))
            (Continue state)))])))

;; --------------------------------------------------------------------------
;; Inlay hints (textDocument/inlayHint) for inferred types.
;;
;; The typechecker records the inferred type + position of each un-annotated
;; `let` binding value (see tc-inlay-hint-* in compiler_typecheck_core). Here we
;; re-check the document with collection enabled, then emit a `: <type>` hint at
;; each recorded position that the open document confirms is a real un-annotated
;; binding within the requested range.
;; --------------------------------------------------------------------------
;; True when `off` is the start of the value in an un-annotated `[name value]`
;; binding: the char before (past whitespace) is the name, preceded by `[`.
(define (lsp-inlay-valid-binding? [text : (& text str)] [off : i64]) : bool
  (let
    [p : i64 (- off 1)]
    (begin
      (while (and
        (>= p 0)
        (source_text.source-text-space? (string.string-ref text p)))
        (set! p (- p 1)))
      (if (< p 0)
        false
        (if (not (lsp-ident-char? (string.string-ref text p)))
          false
          (begin
            (while (and (>= p 0) (lsp-ident-char? (string.string-ref text p)))
              (set! p (- p 1)))
            (while (and
              (>= p 0)
              (source_text.source-text-space? (string.string-ref text p)))
              (set! p (- p 1)))
            (and (>= p 0) (= (string.string-ref text p) '['))))))))

(define (lsp-inlay-valid-expr? [text : (& text str)] [off : i64]) : bool
  (let
    [p : i64 (- off 1)]
    (begin
      (while (and
        (>= p 0)
        (source_text.source-text-space? (string.string-ref text p)))
        (set! p (- p 1)))
      (if (< p 0)
        false
        (= (string.string-ref text p) '(')))))

(define (lsp-inlay-range-line
  [range : json.Json]
  [which : String]
  [fallback : i64]) : i64
  (match (json.object-get range (& which))
    [(JsonFound endpoint) (lsp-json-int-field-default endpoint "line" fallback)]
    [(JsonMissing) fallback]))

(define (lsp-inlay-hint-json
  [text : (& text str)]
  [line : i64]
  [col : i64]
  [ty : String]) : json.Json
  (let
    [offset : i64
      (source_text.source-text-offset-at-byte-position
        text
        (lsp-zero-based line)
        (lsp-zero-based col))]
    [lc : LspLineCol (lsp-line-col-at-offset text offset)]
    (lsp-json-object4
      "position"
      (lsp-position lc.line lc.col)
      "label"
      (JsonString (str_cat.str-cat ": " ty))
      "kind"
      (lsp-json-number 1)
      "paddingRight"
      (JsonBool true))))

(define (lsp-inlay-build
  [inlay-state : tc.TcInlayHintState]
  [text : (& text str)]
  [start-line : i64]
  [end-line : i64]) : json.JsonSeq
  (let
    [size : i64 (tc.tc-inlay-hints-size-for-state inlay-state)]
    [i : i64 0]
    [acc : json.JsonSeq (json.list-empty)]
    (begin
      (while (< i size)
        (let
          [line1 : i64 (tc.tc-inlay-hint-line-at-for-state inlay-state i)]
          [col1 : i64 (tc.tc-inlay-hint-col-at-for-state inlay-state i)]
          [line0 : i64 (- line1 1)]
          [off : i64
            (source_text.source-text-offset-at-byte-position
              text
              line0
              (- col1 1))]
          (begin
            (if (and
              (>= line0 start-line)
              (<= line0 end-line)
              (or
                (lsp-inlay-valid-binding? text off)
                (lsp-inlay-valid-expr? text off)))
              (set!
                acc
                (lsp-json-list-cons
                  (lsp-inlay-hint-json
                    text
                    line1
                    col1
                    (tc.tc-inlay-hint-type-at-for-state inlay-state i))
                  acc))
              unit)
            (set! i (+ i 1)))))
      acc)))

(define (lsp-inlay-respond
  [id : json.Json]
  [uri : String]
  [range : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]
  [stdlib-roots : lsp_svec.Vec]
  [job-state : tc.TcJobState]) : unit
  (match (lsp-documents-lookup docs uri)
    [(Found path text _)
      (let
        [start-line : i64
          (lsp-inlay-range-line
            (owned_view.compiler-owned-shared-view range)
            "start"
            0)]
        [end-line : i64 (lsp-inlay-range-line range "end" 1000000000)]
        [inlay-state : tc.TcInlayHintState
          (tc.tc-job-state-inlay-hints job-state)]
        [load-state : compiler_load.CompilerLoadSessionState
          (compiler_load.compiler-load-serial-test-session-state)]
        [program-cache-enabled : bool
          (compiler_load.compiler-load-session-state-program-cache-enabled?
            load-state)]
        (begin
          ;; Cached imported programs were typechecked before collection was
          ;; enabled and can leave the entry document ahead of the only bodies
          ;; visited by this pass. Bypass (but retain) the program cache for the
          ;; collector pass so the requested document's spans are recorded.
          (lsp-typecheck-tool-session-before!)
          (compiler_load.compiler-load-session-state-program-cache-set-enabled-cell!
            (compiler_load.compiler-load-session-state-shared-view
              (& load-state))
            false)
          (tc.tc-inlay-hints-enable-for-state! inlay-state)
          (match (compiler_check_core.compiler-check-source-with-roots-and-cfg-and-job-state
            path
            (owned_view.compiler-owned-shared-view text)
            stdlib-roots
            (lsp-language-cfgs)
            job-state)
            [(Ok _ _) unit]
            [(Err _ _) unit])
          (let
            [hints : json.JsonSeq
              (lsp-inlay-build inlay-state text start-line end-line)]
            (begin
              (tc.tc-inlay-hints-disable-for-state! inlay-state)
              (lsp-write-response id (lsp-json-array hints))
              (compiler_load.compiler-load-session-state-program-cache-set-enabled-cell!
                (compiler_load.compiler-load-session-state-shared-view
                  (& load-state))
                program-cache-enabled)
              (lsp-typecheck-tool-session-after!)))))]
    [(Missing) (lsp-write-response id (lsp-json-array (json.list-empty)))]))

(define (lsp-handle-inlay
  [id : json.Json]
  [params : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]
  [stdlib-roots : lsp_svec.Vec]
  [job-state : tc.TcJobState]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view params)
      (& td-key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Ok uri)
            (let
              [range-key : String "range"]
              (match (json.object-get params (& range-key))
                [(JsonFound range)
                  (lsp-inlay-respond id uri range docs stdlib-roots job-state)]
                [(JsonMissing)
                  (lsp-write-response id (lsp-json-array (json.list-empty)))]))]
          [(Missing) (lsp-write-response id (lsp-json-array (json.list-empty)))])]
      [(JsonMissing) (lsp-write-response id (lsp-json-array (json.list-empty)))])))

;; --------------------------------------------------------------------------
;; Document formatting (textDocument/formatting), enabling format-on-save.
;;
;; Reuses the `typelisp fmt` formatter (format-rules, width 80). On a parse
;; error the document is left untouched (empty edit list) so saving never
;; mangles in-progress code.
;; --------------------------------------------------------------------------
(define (lsp-formatting-edit [text : (& text str)] [formatted : String]) : json.Json
  (let
    [end : LspLineCol (lsp-line-col-at-offset text (string.string-length text))]
    (lsp-json-object2
      "range"
      (lsp-json-object2
        "start"
        (lsp-position 1 1)
        "end"
        (lsp-position end.line end.col))
      "newText"
      (JsonString formatted))))

(define (lsp-formatting-respond
  [id : json.Json]
  [uri : String]
  [docs : (& docs lsp_document_vec.Vec)]) : unit
  (match (lsp-documents-lookup docs uri)
    [(Found _ text _)
      (match (format_rules.format-rules-render-source-width-result
        (owned_view.compiler-owned-shared-view text)
        80)
        [(Ok formatted)
          (lsp-write-response
            id
            (lsp-json-array
              (lsp-json-list-cons
                (lsp-formatting-edit text formatted)
                (json.list-empty))))]
        [(Err _) (lsp-write-response id (lsp-json-array (json.list-empty)))])]
    [(Missing) (lsp-write-response id (lsp-json-array (json.list-empty)))]))

(define (lsp-format-edit-text [text : String]) : String
  (match (format_rules.format-rules-render-source-width-result
    (owned_view.compiler-owned-shared-view text)
    80)
    [(Ok formatted) formatted]
    [(Err _) text]))

(define (lsp-handle-formatting
  [id : json.Json]
  [params : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json.object-get params (& td-key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Ok uri) (lsp-formatting-respond id uri docs)]
          [(Missing) (lsp-write-response id (lsp-json-array (json.list-empty)))])]
      [(JsonMissing) (lsp-write-response id (lsp-json-array (json.list-empty)))])))

;; --------------------------------------------------------------------------
;; Hover (textDocument/hover).
;;
;; Resolved through the current document's semantic snapshot: the definition's
;; name and resolved type, plus its recorded documentation. Builtins, operators
;; and special forms have no semantic identity and use the curated table below.
;; --------------------------------------------------------------------------
;; Offset just past a balanced ( ... ) group starting at `i`.
(define (lsp-skip-paren-group [text : (& text str)] [i : i64] [n : i64]) : i64
  (let
    [j : i64 i]
    [depth : i64 0]
    [done : bool false]
    (begin
      (while (and (< j n) (not done))
        (let
          [c : char (string.string-ref text j)]
          (cond
            [(= c ';') (set! j (source_text.source-text-skip-line text j n))]
            [(= c '\'')
              (set! j (source_text.source-text-skip-char-literal text j n))]
            [(= c '"') (set! j (source_text.source-text-skip-string text j n))]
            [(= c '(')
              (begin
                (set! depth (+ depth 1))
                (set! j (+ j 1)))]
            [(= c ')')
              (begin
                (set! depth (- depth 1))
                (set! j (+ j 1))
                (if (<= depth 0)
                  (set! done true)
                  unit))]
            [else (set! j (+ j 1))])))
      j)))

;; End offset of one type expression (a ( ... ) group or a single token).
(define (lsp-scan-type [text : (& text str)] [i : i64] [n : i64]) : i64
  (if (and (< i n) (= (string.string-ref text i) '('))
    (lsp-skip-paren-group text i n)
    (lsp-scan-ident text i n)))

(define (lsp-text-has-form-content? [text : (& text str)]) : bool
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (begin
          (set! i (source_text.source-text-skip-space text i n))
          (if (and (< i n) (= (string.string-ref text i) ';'))
            (set! i (source_text.source-text-skip-line text i n))
            (set! done true))))
      (< i n))))

;; Validate that text contains one or more complete parenthesized forms.
;; Returns true if all non-comment content consists of valid forms, using the
;; real compiler parser.
(define (lsp-text-is-valid-forms [text : String]) : bool
  (if (not (lsp-text-has-form-content? text))
    false
    (match (lsp-validate-forms-result text)
      [(Valid) true]
      [(Invalid _ _ _ _) false])))

(define (lsp-validation-error-message
  [line : i64]
  [col : i64]
  [msg : String]
  [ctx : String]) : String
  (lsp-str7
    msg
    " at line "
    (string.int->string line)
    ", col "
    (string.int->string col)
    " | "
    ctx))

(define (lsp-replace-body-validation-message [new-body : String]) : String
  (let
    [detail : String
      (if (lsp-text-has-form-content? new-body)
        (match (lsp-validate-forms-result new-body)
          [(Valid) ""]
          [(Invalid line col msg ctx)
            (lsp-validation-error-message line col msg ctx)])
        (lsp-validation-error-message
          1
          1
          "expected one or more complete TypeLisp expressions"
          "<empty body>"))]
    (if (= (string.string-length detail) 0)
      ""
      (lsp-str3
        "replaceBody rejected before writing: newBody is not a complete TypeLisp body. "
        detail
        " No changes were written."))))

(define (lsp-replace-body-validation-data-at
  [line : i64]
  [col : i64]
  [msg : String]
  [ctx : String]) : json.Json
  (lsp-json-object
    (lsp-json-member
      "operation"
      (JsonString "replaceBody")
      (lsp-json-member
        "parameter"
        (JsonString "newBody")
        (lsp-json-member
          "expected"
          (JsonString
            "one or more complete TypeLisp expression(s), without the define/defmacro header")
          (lsp-json-member
            "errorCode"
            (JsonString "invalidBody")
            (lsp-json-member
              "location"
              (lsp-json-object2
                "line"
                (lsp-json-number line)
                "column"
                (lsp-json-number col))
              (lsp-json-member
                "parserMessage"
                (JsonString msg)
                (lsp-json-member
                  "context"
                  (JsonString ctx)
                  (lsp-json-member
                    "written"
                    (JsonBool false)
                    (json.member-list-empty)))))))))))

(define (lsp-replace-body-validation-data [new-body : String]) : json.Json
  (if (lsp-text-has-form-content? new-body)
    (match (lsp-validate-forms-result new-body)
      [(Valid) JsonNull]
      [(Invalid line col msg ctx)
        (lsp-replace-body-validation-data-at line col msg ctx)])
    (lsp-replace-body-validation-data-at
      1
      1
      "expected one or more complete TypeLisp expressions"
      "<empty body>")))

;; Return a formatted error message, or empty string if valid.
(define (lsp-validate-forms-error [text : String]) : String
  (match (lsp-validate-forms-result text)
    [(Valid) ""]
    [(Invalid line col msg ctx) (lsp-validation-error-message line col msg ctx)]))

(define (lsp-validate-edited-document [text : String]) : LspEditResult
  (match (lsp-validate-forms-result
    (owned_view.compiler-owned-shared-view text))
    [(Valid) (Ok text)]
    [(Invalid line col msg ctx)
      (Err
        (lsp-str2
          "Edited document is not valid TypeLisp source: "
          (lsp-validation-error-message line col msg ctx)))]))

;; Extract the line at position (1-based line)
(define (lsp-line-at [text : (& text str)] [line1 : i64]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [current-line : i64 1]
    [start : i64 0]
    [done : bool false]
    (begin
      (while (and (< i n) (not done))
        (if (= current-line line1)
          (if (or (= i n) (= (string.string-ref text i) '\n'))
            (set! done true)
            (set! i (+ i 1)))
          (begin
            (if (= (string.string-ref text i) '\n')
              (set! current-line (+ current-line 1))
              unit)
            (set! i (+ i 1))
            (set! start i))))
      (if (= current-line line1)
        (string.substring text start (- i start))
        ""))))

;; Validate forms using real parser. Returns `LspValidationResult.Valid` on
;; success, or `Invalid` with line, col, message, and context on failure.
(define (lsp-validate-forms-result [text : String]) : LspValidationResult
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (match (lexer.spanned-result (owned_view.compiler-owned-shared-view text))
      [(Err err)
        (let
          [span : token.SourceSpan
            (token.source-error-span
              (owned_view.compiler-owned-shared-view err))]
          [line : i64 (token.span-start-line span)]
          [col : i64 (token.span-start-col span)]
          [msg : String (token.source-error-message err)]
          (Invalid line col msg (lsp-line-at text line)))]
      [(Ok toks)
        (let
          [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
          [dispatch : sym_i64_env.SymI64Env
            (parser.compiler-parse-dispatch-env)]
          [done : bool false]
          [result : LspValidationResult Valid]
          (begin
            (set! (array-ref cur 0) 0)
            (while (and
              (not done)
              (not
                (= (reader.peek-spanned-tag (& toks) (& cur)) (token.tag-end))))
              (match (reader.form-spanned-result (& toks) (&mut cur))
                [(Err err)
                  (let
                    [span : token.SourceSpan
                      (token.source-error-span
                        (owned_view.compiler-owned-shared-view err))]
                    [line : i64 (token.span-start-line span)]
                    [col : i64 (token.span-start-col span)]
                    [msg : String (token.source-error-message err)]
                    (begin
                      (set!
                        result
                        (Invalid line col msg (lsp-line-at text line)))
                      (set! done true)))]
                [(Ok sexpr)
                  (match (parser.parse-ast-decl-maybe
                    dispatch
                    (owned_view.compiler-owned-shared-view sexpr))
                    [(Err msg)
                      (match (parser.parse-ast-expr
                        dispatch
                        (owned_view.compiler-owned-shared-view sexpr))
                        [(Err _)
                          (let
                            [span : token.SourceSpan
                              (reader.spanned-sexpr-span sexpr)]
                            [line : i64 (token.span-start-line span)]
                            [col : i64 (token.span-start-col span)]
                            (begin
                              (set!
                                result
                                (Invalid line col msg (lsp-line-at text line)))
                              (set! done true)))]
                        [(Ok _) unit])]
                    [(NoDecl)
                      (match (parser.parse-ast-expr
                        dispatch
                        (owned_view.compiler-owned-shared-view sexpr))
                        [(Err msg)
                          (let
                            [span : token.SourceSpan
                              (reader.spanned-sexpr-span sexpr)]
                            [line : i64 (token.span-start-line span)]
                            [col : i64 (token.span-start-col span)]
                            (begin
                              (set!
                                result
                                (Invalid line col msg (lsp-line-at text line)))
                              (set! done true)))]
                        [(Ok _) unit])]
                    [(SomeDecl _) unit]
                    [(Decls _) unit])]))
            result))])))

;; Find the byte offset where the body of a define/defmacro begins,
;; given the offset of the opening '(' of the form.
(define (lsp-find-body-start-offset [text : (& text str)] [form-start : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 form-start]
    (begin
      ; skip '('
      (set! i (+ i 1))
      ; skip keyword (define / defmacro)
      (set! i (lsp-scan-ident text i n))
      ; skip whitespace
      (set! i (source_text.source-text-skip-space text i n))
      ; skip param list '(...)'
      (set! i (lsp-skip-paren-group text i n))
      ; skip whitespace
      (set! i (source_text.source-text-skip-space text i n))
      ; if type annotation ': type', skip it
      (if (and (< i n) (= (string.string-ref text i) ':'))
        (begin
          (set! i (+ i 1))
          ; skip ':'
          (set! i (source_text.source-text-skip-space text i n))
          (set! i (lsp-scan-type text i n))
          (set! i (source_text.source-text-skip-space text i n)))
        unit)
      i)))

;; Declared type of the nearest [sym : TYPE] binding whose name starts at or
;; before `limit`, or "" if none (function params and let bindings).
(define (lsp-binding-type [text : (& text str)] [sym : String] [limit : i64]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [result : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c ';') (set! i (source_text.source-text-skip-line text i n))]
            [(= c '\'')
              (set! i (source_text.source-text-skip-char-literal text i n))]
            [(= c '"') (set! i (source_text.source-text-skip-string text i n))]
            [(= c '[')
              (let
                [name-start : i64
                  (source_text.source-text-skip-space text (+ i 1) n)]
                [name-end : i64 (lsp-scan-ident text name-start n)]
                (begin
                  (if (and
                    (> name-end name-start)
                    (<= name-start limit)
                    (string.eq
                      (string.substring text name-start (- name-end name-start))
                      sym))
                    (let
                      [after : i64
                        (source_text.source-text-skip-space text name-end n)]
                      (if (and
                        (< after n)
                        (= (string.string-ref text after) ':'))
                        (let
                          [ty-start : i64
                            (source_text.source-text-skip-space
                              text
                              (+ after 1)
                              n)]
                          [ty-end : i64 (lsp-scan-type text ty-start n)]
                          (set!
                            result
                            (string.substring text ty-start (- ty-end ty-start))))
                        unit))
                    unit)
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      result)))

(define (lsp-hover-markdown [body : String] [docs : String]) : String
  (if (string.eq docs "")
    (str_cat.str-cat "```typelisp\n" body "\n```")
    (str_cat.str-cat "```typelisp\n" body "\n```\n\n" docs)))

(define (lsp-hover-result
  [markdown : String]
  [text : String]
  [start : i64]
  [end : i64]) : json.Json
  (lsp-json-object2
    "contents"
    (lsp-json-object2
      "kind"
      (JsonString "markdown")
      "value"
      (JsonString markdown))
    "range"
    (lsp-offset-range-json text start end)))

(define (lsp-semantic-hover-body
  [record : compiler_semantic_index.CompilerSemanticRecord]) : String
  (let
    [name : String record.display-name]
    [resolved-type : String record.resolved-type]
    (match record.kind
      [(Struct)
        (if (string.eq resolved-type "")
          (str_cat.str-cat "struct " name)
          resolved-type)]
      [(Enum)
        (if (string.eq resolved-type "")
          (str_cat.str-cat "enum " name)
          resolved-type)]
      [_
        (if (string.eq resolved-type "")
          name
          (str_cat.str-cat name " : " resolved-type))])))

;; Curated hover for builtins, operators, and special forms (no source
;; (define ...) exists for these). Returns markdown, or "" when unknown.
(define (lsp-builtin-hover [name : String]) : String
  (cond
    [(or
        (string.eq name "i64")
        (string.eq name "i32")
        (string.eq name "i16")
        (string.eq name "i8"))
      (lsp-hover-markdown
        (string.copy name)
        "Signed integer (two's complement) of the named bit width.")]
    [(or
        (string.eq name "u64")
        (string.eq name "u32")
        (string.eq name "u16")
        (string.eq name "u8"))
      (lsp-hover-markdown
        (string.copy name)
        "Unsigned integer of the named bit width.")]
    [(or (string.eq name "f64") (string.eq name "f32"))
      (lsp-hover-markdown
        (string.copy name)
        "IEEE-754 floating-point number (64- or 32-bit).")]
    [(string.eq name "bool")
      (lsp-hover-markdown "bool" "Boolean: `true` or `false`.")]
    [(string.eq name "char")
      (lsp-hover-markdown "char" "A character value (written like `'a'`).")]
    [(string.eq name "String")
      (lsp-hover-markdown "String" "Owned, heap-allocated UTF-8 string.")]
    [(string.eq name "str")
      (lsp-hover-markdown "str" "Borrowed string slice (used as `(& str)`).")]
    [(string.eq name "unit")
      (lsp-hover-markdown "unit" "The unit type; its only value is `unit`.")]
    [(string.eq name "never")
      (lsp-hover-markdown
        "never"
        "The empty type, for expressions that never return (e.g. `panic`).")]
    [(string.eq name "Array")
      (lsp-hover-markdown
        "(Array T N)"
        "Fixed-size inline array of `N` elements of `T`.")]
    [(string.eq name "Tuple")
      (lsp-hover-markdown
        "(Tuple A B ...)"
        "Fixed-size tuple of the given element types.")]
    [(string.eq name "CFunc")
      (lsp-hover-markdown
        "(CFunc mode (-> Arg ... Result))"
        "Raw C function pointer retaining its signature and call effect. Modes: nullable, non-null, unsafe-nullable, unsafe-non-null. Use c-fn-check before calling a nullable value; unsafe modes require an unsafe context.")]
    [(string.eq name "Box")
      (lsp-hover-markdown
        "(Box T)"
        "Heap-allocated `T`; used for recursive data structures.")]
    [(string.eq name "Ptr")
      (lsp-hover-markdown
        "(Ptr T)"
        "Raw immutable pointer to `T` (unsafe to dereference).")]
    [(string.eq name "MutPtr")
      (lsp-hover-markdown
        "(MutPtr T)"
        "Raw mutable pointer to `T` (unsafe to dereference).")]
    [(or
        (string.eq name "+")
        (string.eq name "-")
        (string.eq name "*")
        (string.eq name "/"))
      (lsp-hover-markdown
        (str_cat.str-cat name " : (-> num num num)")
        "Arithmetic on two integers or floats of the same numeric type.")]
    [(string.eq name "%")
      (lsp-hover-markdown "% : (-> int int int)" "Integer remainder (modulo).")]
    [(or (string.eq name "=") (string.eq name "!="))
      (lsp-hover-markdown
        (str_cat.str-cat name " : (-> a a bool)")
        "Equality / inequality comparison.")]
    [(or
        (string.eq name "<")
        (string.eq name "<=")
        (string.eq name ">")
        (string.eq name ">="))
      (lsp-hover-markdown
        (str_cat.str-cat name " : (-> a a bool)")
        "Ordering comparison.")]
    [(or (string.eq name "shl") (string.eq name "shr"))
      (lsp-hover-markdown
        (str_cat.str-cat name " : (-> int int int)")
        "Bit shift left / right.")]
    [(or
        (string.eq name "bit-and")
        (string.eq name "bit-or")
        (string.eq name "bit-xor"))
      (lsp-hover-markdown
        (str_cat.str-cat name " : (-> int int int)")
        "Bitwise and / or / xor.")]
    [(string.eq name "bit-not")
      (lsp-hover-markdown "bit-not : (-> int int)" "Bitwise complement.")]
    [(string.eq name "not")
      (lsp-hover-markdown "not : (-> bool bool)" "Logical negation.")]
    [(string.eq name "neg")
      (lsp-hover-markdown "neg : (-> num num)" "Numeric negation.")]
    [(string.eq name "string-length")
      (lsp-hover-markdown
        "string-length : (-> String i64)"
        "Number of bytes in a string.")]
    [(string.eq name "string-ref")
      (lsp-hover-markdown
        "string-ref : (-> String i64 char)"
        "Byte at the given index.")]
    [(string.eq name "string-data")
      (lsp-hover-markdown
        "string-data : (-> String (Ptr u8))"
        "Pointer to a string's bytes.")]
    [(string.eq name "array-ref")
      (lsp-hover-markdown
        "array-ref : (-> (Array T N) i64 T)"
        "Read an array element (bounds-checked).")]
    [(string.eq name "tuple-ref")
      (lsp-hover-markdown
        "tuple-ref : (-> Tuple i64 T)"
        "Read a tuple element by constant index.")]
    [(string.eq name "deref")
      (lsp-hover-markdown
        "deref : (-> (Box T | &T | &mut T) T)"
        "Project through a Box or safe reference place.")]
    [(string.eq name "c-fn-check")
      (lsp-hover-markdown
        "c-fn-check : CFunc -> non-null CFunc"
        "Checks once for null, exiting with status 134 on failure. Preserves the C signature and unsafe-call effect.")]
    [(string.eq name "ptr-null")
      (lsp-hover-markdown
        "ptr-null : (-> (Ptr T))"
        "Null pointer of the given type. CFunc requires nullable or unsafe-nullable mode.")]
    [(string.eq name "ptr-null?")
      (lsp-hover-markdown
        "ptr-null? : (-> (Ptr T) bool)"
        "Whether a raw pointer or CFunc is null. Does not call it or refine its type.")]
    [(string.eq name "ptr-read")
      (lsp-hover-markdown
        "ptr-read : (-> (Ptr T) i64 T)"
        "Read the element at an offset from a pointer (unsafe).")]
    [(string.eq name "ptr-write!")
      (lsp-hover-markdown
        "ptr-write! : (-> (MutPtr T) i64 T unit)"
        "Write the element at an offset through a pointer (unsafe).")]
    [(string.eq name "ptr-offset")
      (lsp-hover-markdown
        "ptr-offset : (-> (Ptr T) i64 (Ptr T))"
        "Offset a pointer by N elements (unsafe).")]
    [(string.eq name "ptr-cast")
      (lsp-hover-markdown
        "ptr-cast : (-> (Ptr A) Type (Ptr B))"
        "Reinterpret a pointer's element type (unsafe).")]
    [(string.eq name "ptr->int")
      (lsp-hover-markdown
        "ptr->int : (-> (Ptr T) u64)"
        "Pointer to integer address (unsafe).")]
    [(string.eq name "int->ptr")
      (lsp-hover-markdown
        "int->ptr : (-> u64 Type (Ptr T))"
        "Integer address to pointer (unsafe).")]
    [(string.eq name "if")
      (lsp-hover-markdown
        "(if cond then else)"
        "Conditional expression; both branches must have the same type.")]
    [(string.eq name "let")
      (lsp-hover-markdown
        "(let [name : T value] ... body...)"
        "Introduce local bindings, then evaluate the body expressions.")]
    [(string.eq name "begin")
      (lsp-hover-markdown
        "(begin expr ...)"
        "Evaluate expressions in sequence; the result is the last.")]
    [(string.eq name "while")
      (lsp-hover-markdown
        "(while cond body...)"
        "Loop while the condition is true.")]
    [(string.eq name "set!")
      (lsp-hover-markdown "(set! name value)" "Mutate an existing binding.")]
    [(string.eq name "match")
      (lsp-hover-markdown
        "(match value [pattern body] ...)"
        "Pattern match on an enum value.")]
    [(string.eq name "return")
      (lsp-hover-markdown
        "(return value)"
        "Return early from the enclosing function.")]
    [(string.eq name "lambda")
      (lsp-hover-markdown "(lambda [p : T] ... body...)" "Anonymous function.")]
    [(string.eq name "cast")
      (lsp-hover-markdown
        "(cast value : Type)"
        "Convert a value to another numeric or pointer type.")]
    [(string.eq name "unsafe")
      (lsp-hover-markdown
        "(unsafe body)"
        "Permit unsafe operations (raw pointers, syscalls) within the body.")]
    [else ""]))

(define (lsp-semantic-hover-respond
  [id : json.Json]
  [uri : String]
  [position : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]) : unit
  (let
    [doc-index : i64 (lsp-documents-find-index docs uri)]
    (if (< doc-index 0)
      (lsp-write-response id JsonNull)
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp_document_vec.get (& docs) doc-index (lsp-document-fallback))]
        [text : String doc.text]
        [line0 : i64 (lsp-json-int-field-default position "line" 0)]
        [char0 : i64 (lsp-json-int-field-default position "character" 0)]
        [off : i64 (lsp-offset-at-position text line0 char0)]
        (match (lsp-document-semantic-symbol-query (& doc) off)
          [(Found cursor definition)
            (let
              [cursor-span : compiler_semantic_index.CompilerSemanticSpan
                cursor.span]
              (lsp-write-response
                id
                (lsp-hover-result
                  (lsp-hover-markdown
                    (lsp-semantic-hover-body
                      (owned_view.compiler-owned-shared-view definition))
                    definition.documentation)
                  text
                  cursor-span.start-byte
                  cursor-span.end-byte)))]
          [(Missing)
            ;; Builtins intentionally have no semantic identity. Keep curated
            ;; hover only for a current snapshot and a real, unquoted code
            ;; token; stale text never falls back to a lexical answer.
            (match (lsp-document-semantic-snapshot-status (& doc))
              [(Current _ _)
                (let
                  [symbol : String (lsp-code-symbol-at-offset text off)]
                  [symbol-start : i64 (lsp-symbol-start-at-offset text off)]
                  [builtin : String
                    (if (or
                      (string.eq symbol "")
                      (lsp-symbol-in-quoted-data?
                        (owned_view.compiler-owned-shared-view text)
                        symbol-start))
                      ""
                      (lsp-builtin-hover
                        (lsp-symbol-base
                          (owned_view.compiler-owned-shared-view symbol))))]
                  (if (string.eq builtin "")
                    (lsp-write-response id JsonNull)
                    (lsp-write-response
                      id
                      (lsp-hover-result
                        builtin
                        text
                        symbol-start
                        (+ symbol-start (string.string-length symbol))))))]
              [_ (lsp-write-response id JsonNull)])])))))

(define (lsp-handle-hover
  [id : json.Json]
  [params : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view params)
      (& td-key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Ok uri)
            (let
              [pos-key : String "position"]
              (match (json.object-get params (& pos-key))
                [(JsonFound position)
                  (lsp-semantic-hover-respond id uri position docs)]
                [(JsonMissing) (lsp-write-response id JsonNull)]))]
          [(Missing) (lsp-write-response id JsonNull)])]
      [(JsonMissing) (lsp-write-response id JsonNull)])))

;; --------------------------------------------------------------------------
;; Document links (textDocument/documentLink): make import operands clickable,
;; navigating to the resolved module file.
;; --------------------------------------------------------------------------
(define (lsp-document-link-json
  [text : (& text str)]
  [resolved : String]
  [content-start : i64]
  [content-end : i64]) : json.Json
  (let
    [start-lc : LspLineCol (lsp-line-col-at-offset text content-start)]
    [end-lc : LspLineCol (lsp-line-col-at-offset text content-end)]
    (lsp-json-object2
      "range"
      (lsp-json-object2
        "start"
        (lsp-position start-lc.line start-lc.col)
        "end"
        (lsp-position end-lc.line end-lc.col))
      "target"
      (JsonString (lsp-resolved-path-to-file-uri resolved)))))

(define (lsp-document-links
  [text : (& text str)]
  [path : String]
  [stdlib-roots : lsp_svec.Vec]) : json.JsonSeq
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [acc : json.JsonSeq (json.list-empty)]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c ';') (set! i (source_text.source-text-skip-line text i n))]
            [(= c '\'')
              (set! i (source_text.source-text-skip-char-literal text i n))]
            [(= c '"') (set! i (source_text.source-text-skip-string text i n))]
            [(= c '(')
              (let
                [kw-start : i64
                  (source_text.source-text-skip-space text (+ i 1) n)]
                [kw-end : i64 (lsp-scan-ident text kw-start n)]
                (if (and
                  (> kw-end kw-start)
                  (string.eq
                    (string.substring text kw-start (- kw-end kw-start))
                    "import"))
                  (let
                    [operand-start : i64
                      (source_text.source-text-skip-space text kw-end n)]
                    (match (lsp-resolve-import-target-at
                      text
                      (owned_view.compiler-owned-shared-view path)
                      (owned_view.compiler-owned-shared-view stdlib-roots)
                      operand-start)
                      [(Found resolved start end)
                        (begin
                          (set!
                            acc
                            (lsp-json-list-cons
                              (lsp-document-link-json text resolved start end)
                              acc))
                          (set! i end))]
                      [(Missing) (set! i (+ i 1))]))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      acc)))

(define (lsp-document-link-respond
  [id : json.Json]
  [uri : String]
  [docs : (& docs lsp_document_vec.Vec)]
  [stdlib-roots : lsp_svec.Vec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(Found path text _)
      (lsp-write-response
        id
        (lsp-json-array (lsp-document-links text path stdlib-roots)))]
    [(Missing) (lsp-write-response id (lsp-json-array (json.list-empty)))]))

(define (lsp-handle-document-link
  [id : json.Json]
  [params : json.Json]
  [docs : (& docs lsp_document_vec.Vec)]
  [stdlib-roots : lsp_svec.Vec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json.object-get params (& td-key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Ok uri) (lsp-document-link-respond id uri docs stdlib-roots)]
          [(Missing) (lsp-write-response id (lsp-json-array (json.list-empty)))])]
      [(JsonMissing) (lsp-write-response id (lsp-json-array (json.list-empty)))])))

(define (lsp-maybe-write-method-not-found [message : json.Json]) : unit
  (let
    [key : String "id"]
    (match (json.object-get message (& key))
      [(JsonFound id) (lsp-write-error id -32601 "Method not found")]
      [(JsonMissing) unit])))

(define (lsp-decl-entry-fallback) : lsp_vector_families.LspDeclEntry
  (lsp_vector_families.LspDeclEntry "" "" 0 0 0 0 0 0 0 13))

(define (lsp-decl-kind-at [text : (& text str)] [i : i64] [n : i64]) : String
  (let
    [after-open : i64 (source_text.source-text-skip-space text (+ i 1) n)]
    [kw-end : i64 (lsp-scan-ident text after-open n)]
    (if (<= kw-end after-open)
      "unknown"
      (let
        [kw : String (string.substring text after-open (- kw-end after-open))]
        (cond
          [(string.eq kw "define") "function"]
          [(string.eq kw "defmacro") "macro"]
          [(string.eq kw "defstruct") "struct"]
          [(string.eq kw "defenum") "enum"]
          [(string.eq kw "defdispatch") "dispatch"]
          [(string.eq kw "extern") "extern"]
          [else "unknown"])))))

;; LSP SymbolKind values are protocol-facing and intentionally separate from
;; the custom declaration kind strings consumed by the tl/* tools (for example
;; the tl/findPosition kind filter). In particular, those tools continue to
;; classify every define as "function", while the standard outline
;; distinguishes function-head and value declarations.
(define (lsp-decl-symbol-kind-at [text : (& text str)] [i : i64] [n : i64]) : i64
  (let
    [after-open : i64 (source_text.source-text-skip-space text (+ i 1) n)]
    [kw-end : i64 (lsp-scan-ident text after-open n)]
    (if (<= kw-end after-open)
      13
      (let
        [kw : String (string.substring text after-open (- kw-end after-open))]
        [after-kw : i64 (source_text.source-text-skip-space text kw-end n)]
        [function-head : bool
          (and (< after-kw n) (= (string.string-ref text after-kw) '('))]
        (cond
          [(string.eq kw "defstruct") 23]
          [(string.eq kw "defenum") 10]
          [(or (string.eq kw "defmacro") (string.eq kw "defdispatch")) 12]
          [(or (string.eq kw "define") (string.eq kw "extern"))
            (if function-head
              12
              13)]
          [else 13])))))

(define (lsp-scan-decls [text : String]) : lsp_decl_vec.Vec
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [depth : i64 0]
    [result : lsp_decl_vec.Vec (lsp_decl_vec.with-capacity 16)]
    [lc-cache : LspLineColCache (LspLineColCache -1 1 1)]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c ';') (set! i (source_text.source-text-skip-line text i n))]
            [(= c '\'')
              (set! i (source_text.source-text-skip-char-literal text i n))]
            [(= c '"') (set! i (source_text.source-text-skip-string text i n))]
            [(= c '(')
              (begin
                (set! depth (+ depth 1))
                (if (= depth 1)
                  (let
                    [name-off : i64 (lsp-def-name-offset-at text i n)]
                    (if (>= name-off 0)
                      (let
                        [name : String (lsp-symbol-at-offset text name-off)]
                        [kind : String (lsp-decl-kind-at text i n)]
                        [symbol-kind : i64 (lsp-decl-symbol-kind-at text i n)]
                        [form-end : i64 (lsp-skip-paren-group text i n)]
                        [form-start-lc : LspLineCol
                          (lsp-line-col-cache-at-offset! (&mut lc-cache) text i)]
                        [name-lc : LspLineCol
                          (lsp-line-col-cache-at-offset!
                            (&mut lc-cache)
                            text
                            name-off)]
                        [form-end-lc : LspLineCol
                          (lsp-line-col-cache-at-offset!
                            (&mut lc-cache)
                            text
                            form-end)]
                        (lsp_decl_vec.push-ref!
                          (&mut result)
                          (lsp_vector_families.LspDeclEntry
                            kind
                            (owned_view.compiler-owned-shared-view name)
                            name-lc.line
                            name-lc.col
                            (lsp-string-position-units name)
                            form-start-lc.line
                            form-start-lc.col
                            form-end-lc.line
                            form-end-lc.col
                            symbol-kind)))
                      unit))
                  unit)
                (set! i (+ i 1)))]
            [(= c ')')
              (begin
                (set! depth (- depth 1))
                (set! i (+ i 1)))]
            [else (set! i (+ i 1))])))
      result)))

(define (lsp-explicit-module-name [text : (& text str)]) : String
  (let
    [n : i64 (string.string-length text)]
    [index : i64 0]
    [depth : i64 0]
    [module-name : String ""]
    [found : bool false]
    (begin
      (while (and (< index n) (not found))
        (let
          [c : char (string.string-ref text index)]
          (cond
            [(= c ';')
              (set! index (source_text.source-text-skip-line text index n))]
            [(= c '\'')
              (set!
                index
                (source_text.source-text-skip-char-literal text index n))]
            [(= c '"')
              (set! index (source_text.source-text-skip-string text index n))]
            [(= c '(')
              (let
                [after-open : i64
                  (source_text.source-text-skip-space text (+ index 1) n)]
                [keyword-end : i64 (lsp-scan-ident text after-open n)]
                [keyword : String
                  (if (> keyword-end after-open)
                    (string.substring
                      text
                      after-open
                      (- keyword-end after-open))
                    "")]
                (begin
                  (if (and (= depth 0) (string.eq keyword "module"))
                    (let
                      [name-start : i64
                        (source_text.source-text-skip-space text keyword-end n)]
                      [name-end : i64 (lsp-scan-ident text name-start n)]
                      (if (> name-end name-start)
                        (begin
                          (set!
                            module-name
                            (string.substring
                              text
                              name-start
                              (- name-end name-start)))
                          (set! found true))
                        unit))
                    unit)
                  (set! depth (+ depth 1))
                  (set! index (+ index 1))))]
            [(= c ')')
              (begin
                (if (> depth 0)
                  (set! depth (- depth 1))
                  unit)
                (set! index (+ index 1)))]
            [else (set! index (+ index 1))])))
      module-name)))

(define (lsp-decl-entry-copy [entry : lsp_vector_families.LspDeclEntry]) : lsp_vector_families.LspDeclEntry
  (lsp_vector_families.LspDeclEntry
    (string.copy (& entry.kind))
    (string.copy (& entry.name))
    entry.name-line
    entry.name-col
    entry.name-len
    entry.form-start-line
    entry.form-start-col
    entry.form-end-line
    entry.form-end-col
    entry.symbol-kind))

(define (lsp-decls-copy [decls : lsp_decl_vec.Vec]) : lsp_decl_vec.Vec
  (let
    [count : i64 (lsp_decl_vec.len (& decls))]
    [copy : lsp_decl_vec.Vec (lsp_decl_vec.with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (lsp_decl_vec.push-ref!
            (&mut copy)
            (lsp-decl-entry-copy
              (lsp_decl_vec.get (& decls) index (lsp-decl-entry-fallback))))
          (set! index (+ index 1))))
      copy)))

(define (lsp-check-cache-copy [cache : lsp_vector_families.LspCheckCache]) : lsp_vector_families.LspCheckCache
  (match cache
    [(LspCheckCacheInvalid) LspCheckCacheInvalid]
    [(LspCheckCacheOk) LspCheckCacheOk]
    [(LspCheckCacheErr message) (LspCheckCacheErr (string.copy (& message)))]))

(define (lsp-document-copy [doc : lsp_vector_families.LspDocument]) : lsp_vector_families.LspDocument
  (lsp_vector_families.LspDocument
    (string.copy (& doc.uri))
    (string.copy (& doc.path))
    (string.copy (& doc.text))
    doc.version
    (lsp-diagnostic-uris-copy doc.diagnostic-uris)
    (lsp-decls-copy doc.decls)
    doc.decls-valid
    (lsp-check-cache-copy doc.check-cache)
    ;; The semantic snapshot owns its index and source identity in the index
    ;; arena, so server-state arena swaps transfer this value without copying.
    doc.semantic))

(define (lsp-documents-copy [docs : (& docs lsp_document_vec.Vec)]) : lsp_document_vec.Vec
  (let
    [count : i64 (lsp_document_vec.len (& docs))]
    [copy : lsp_document_vec.Vec (lsp_document_vec.with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (lsp_document_vec.push-ref!
            (&mut copy)
            (lsp-document-copy
              (lsp_document_vec.get (& docs) index (lsp-document-fallback))))
          (set! index (+ index 1))))
      copy)))

(define (lsp-workspace-root-copy [root : lsp_vector_families.LspWorkspaceRoot]) : lsp_vector_families.LspWorkspaceRoot
  (lsp_vector_families.LspWorkspaceRoot
    (string.copy (& root.uri))
    (string.copy (& root.path))))

(define (lsp-workspace-roots-copy
  [roots : (& roots lsp_vector_families.LspWorkspaceRoots)]) : lsp_vector_families.LspWorkspaceRoots
  (let
    [copy : lsp_vector_families.LspWorkspaceRoots (lsp-workspace-roots-new)]
    [index : i64 0]
    (begin
      (while (< index (lsp-workspace-roots-len (& roots)))
        (begin
          (lsp-workspace-roots-push!
            (&mut copy)
            (lsp-workspace-root-copy (lsp-workspace-roots-get (& roots) index)))
          (set! index (+ index 1))))
      copy)))

(define (lsp-workspace-source-copy
  [source : lsp_vector_families.LspWorkspaceSource]) : lsp_vector_families.LspWorkspaceSource
  (lsp_vector_families.LspWorkspaceSource
    (string.copy (& source.root-uri))
    (string.copy (& source.root-path))
    (string.copy (& source.uri))
    (string.copy (& source.path))
    (string.copy (& source.module))
    source.explicit-module
    source.overlay
    (lsp-decls-copy source.decls)))

(define (lsp-workspace-sources-copy
  [sources : (& sources lsp_vector_families.LspWorkspaceSources)]) : lsp_vector_families.LspWorkspaceSources
  (let
    [copy : lsp_vector_families.LspWorkspaceSources (lsp-workspace-sources-new)]
    [index : i64 0]
    (begin
      (while (< index (lsp-workspace-sources-len (& sources)))
        (begin
          (lsp-workspace-sources-push!
            (&mut copy)
            (lsp-workspace-source-copy
              (lsp-workspace-sources-get (& sources) index)))
          (set! index (+ index 1))))
      copy)))

(define (lsp-workspace-index-copy
  [index : (& index lsp_vector_families.LspWorkspaceIndex)]) : lsp_vector_families.LspWorkspaceIndex
  (lsp_vector_families.LspWorkspaceIndex
    (lsp-workspace-roots-copy index.roots)
    (lsp-workspace-sources-copy index.sources)))

(define (lsp-workspace-semantic-cache-new) : lsp_vector_families.LspWorkspaceSemanticCache
  (lsp_vector_families.LspWorkspaceSemanticCache
    ""
    (__tl_make-array lsp_vector_families.LspWorkspaceSemanticCacheEntry 0)
    0
    0))

(define (lsp-workspace-semantic-cache-find-uri
  [cache : (& cache lsp_vector_families.LspWorkspaceSemanticCache)]
  [uri : String]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< index cache.len) (< found 0))
        (if (string.eq
          (owned_view.compiler-owned-array-element-shared-view
            cache.slots
            index).uri
          uri)
          (set! found index)
          (set! index (+ index 1))))
      found)))

(define (lsp-workspace-semantic-cache-remove-index!
  [cache : (&mut cache lsp_vector_families.LspWorkspaceSemanticCache)]
  [index : i64]) : unit
  (if (or (< index 0) (>= index cache.len))
    unit
    (let
      [cursor : i64 index]
      [last : i64 (- cache.len 1)]
      (begin
        (if (> (array-ref cache.slots index).index.owner-arena 0)
          (compiler_semantic_index.compiler-semantic-source-index-release!
            (&mut (array-ref cache.slots index).index))
          unit)
        (while (< cursor last)
          (begin
            (unsafe
              (ptr-write!
                (ptr-offset (__tl_array-data cache.slots) cursor)
                (array-ref cache.slots (+ cursor 1))))
            (set! cursor (+ cursor 1))))
        (set! cache.len last)))))

(define (lsp-workspace-semantic-cache-release-all!
  [cache : (&mut cache lsp_vector_families.LspWorkspaceSemanticCache)]) : unit
  (let
    [index : i64 0]
    (begin
      (while (< index cache.len)
        (begin
          (if (> (array-ref cache.slots index).index.owner-arena 0)
            (compiler_semantic_index.compiler-semantic-source-index-release!
              (&mut (array-ref cache.slots index).index))
            unit)
          (set! index (+ index 1))))
      (set! cache.len 0)
      (set! cache.context-key "")
      (set! cache.source-checks 0))))

(define (lsp-workspace-semantic-cache-copy
  [cache : (& cache lsp_vector_families.LspWorkspaceSemanticCache)]) : lsp_vector_families.LspWorkspaceSemanticCache
  (let
    [copy : lsp_vector_families.LspWorkspaceSemanticCache
      (lsp-workspace-semantic-cache-new)]
    [index : i64 0]
    (begin
      (set!
        copy.slots
        (__tl_make-array
          lsp_vector_families.LspWorkspaceSemanticCacheEntry
          cache.len))
      (set! copy.len cache.len)
      (set! copy.context-key (string.copy (& cache.context-key)))
      (set! copy.source-checks cache.source-checks)
      (while (< index cache.len)
        (let
          [entry : lsp_vector_families.LspWorkspaceSemanticCacheEntry
            (owned_view.compiler-owned-array-element-shared-view
              cache.slots
              index)]
          (begin
            ;; Move the independent owner; old state destruction never walks
            ;; stale cache rows.
            (unsafe
              (ptr-write!
                (ptr-offset (__tl_array-data copy.slots) index)
                (lsp_vector_families.LspWorkspaceSemanticCacheEntry
                  (string.copy (& entry.uri))
                  (string.copy (& entry.path))
                  entry.source-fingerprint
                  entry.source-len
                  entry.index)))
            (set! index (+ index 1)))))
      copy)))

;; Invalidate the changed entry and every retained entry whose compiler import
;; closure contains it. Negative cache entries have no dependency table, so a
;; protocol source change conservatively drops them; they are bounded and will
;; be recomputed once rather than risking a stale negative result.
(define (lsp-workspace-semantic-cache-invalidate-path!
  [cache : (&mut cache lsp_vector_families.LspWorkspaceSemanticCache)]
  [path : String]) : unit
  (let
    [normalized : String (lsp-normalized-absolute-path path)]
    [index : i64 0]
    (while (< index cache.len)
      (let
        [entry : lsp_vector_families.LspWorkspaceSemanticCacheEntry
          (owned_view.compiler-owned-array-element-shared-view
            cache.slots
            index)]
        [affected : bool
          (or
            (string.eq entry.path normalized)
            (<= entry.index.owner-arena 0)
            (compiler_semantic_index.compiler-semantic-source-index-contains-path?
              (& entry.index)
              (owned_view.compiler-owned-shared-view normalized)))]
        (if affected
          (lsp-workspace-semantic-cache-remove-index! cache index)
          (set! index (+ index 1)))))))

(define (lsp-workspace-root-for-path
  [roots : (& roots lsp_vector_families.LspWorkspaceRoots)]
  [path : (& path str)]
  [require-file : bool]) : lsp_vector_families.LspWorkspaceRootLookup
  (let
    [index : i64 0]
    [found : lsp_vector_families.LspWorkspaceRootLookup Missing]
    [done : bool false]
    (begin
      (while (and (< index (lsp-workspace-roots-len roots)) (not done))
        (let
          [root : lsp_vector_families.LspWorkspaceRoot
            (lsp-workspace-roots-get roots index)]
          [eligible : bool
            (if require-file
              (package_source_core.package-source-path-eligible-for-root?
                root.path
                path)
              (package_source_core.package-source-path-location-eligible-for-root?
                root.path
                path))]
          (if eligible
            (begin
              (set! found (Found (owned_view.compiler-owned-shared-view root)))
              (set! done true))
            (set! index (+ index 1)))))
      found)))

(define (lsp-workspace-source-module
  [root-path : (& root-path str)]
  [path : (& path str)]
  [text : (& text str)]) : String
  (let
    [explicit : String (lsp-explicit-module-name text)]
    (if (> (string.string-length explicit) 0)
      explicit
      (compiler_load.compiler-load-canonical-module-id-from-path
        (if (> (string.string-length root-path) 0)
          (compiler_load.compiler-load-root-relative-path root-path path)
          (fs.basename path))))))

(define (lsp-workspace-source-from-text
  [root : lsp_vector_families.LspWorkspaceRootLookup]
  [path : String]
  [text : String]
  [overlay : bool]) : lsp_vector_families.LspWorkspaceSource
  (let
    [normalized-path : String (lsp-normalized-absolute-path path)]
    [uri : String
      (lsp-path-to-file-uri
        (owned_view.compiler-owned-shared-view normalized-path))]
    [explicit : String (lsp-explicit-module-name text)]
    [root-uri : String
      (match (owned_view.compiler-owned-shared-view root)
        [(Found found) found.uri]
        [(Missing) ""])]
    [root-path : String
      (match root
        [(Found found) found.path]
        [(Missing) ""])]
    [module : String
      (if (> (string.string-length explicit) 0)
        (owned_view.compiler-owned-shared-view explicit)
        (lsp-workspace-source-module root-path normalized-path text))]
    (lsp_vector_families.LspWorkspaceSource
      (string.copy (& root-uri))
      (string.copy (& root-path))
      (string.copy (& uri))
      (string.copy (& normalized-path))
      (string.copy (& module))
      (> (string.string-length explicit) 0)
      overlay
      (lsp-scan-decls text))))

(define (lsp-workspace-index-add-text-source!
  [index : (&mut index lsp_vector_families.LspWorkspaceIndex)]
  [root : lsp_vector_families.LspWorkspaceRootLookup]
  [path : String]
  [text : String]
  [overlay : bool]) : unit
  (let
    [source : lsp_vector_families.LspWorkspaceSource
      (lsp-workspace-source-from-text root path text overlay)]
    [uri : String (owned_view.compiler-owned-shared-view source.uri)]
    (if (>= (lsp-workspace-sources-find-uri (& index.sources) uri) 0)
      unit
      (lsp-workspace-sources-push! (&mut index.sources) source))))

(define (lsp-workspace-index-set-text-source!
  [index : (&mut index lsp_vector_families.LspWorkspaceIndex)]
  [root : lsp_vector_families.LspWorkspaceRootLookup]
  [path : String]
  [text : String]
  [overlay : bool]) : unit
  (let
    [source : lsp_vector_families.LspWorkspaceSource
      (lsp-workspace-source-from-text root path text overlay)]
    [existing : i64
      (lsp-workspace-sources-find-uri
        (& index.sources)
        (owned_view.compiler-owned-shared-view source.uri))]
    (if (>= existing 0)
      (lsp-workspace-sources-set! (&mut index.sources) existing source)
      (lsp-workspace-sources-push! (&mut index.sources) source))))

(define (lsp-workspace-index-add-path!
  [index : (&mut index lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [root : lsp_vector_families.LspWorkspaceRootLookup]
  [path : String]) : unit
  (let
    [doc-index : i64 (lsp-documents-find-path-index (& docs) path)]
    (if (>= doc-index 0)
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp_document_vec.get (& docs) doc-index (lsp-document-fallback))]
        (lsp-workspace-index-add-text-source! index root path doc.text true))
      (match (io.try-read-file (& path))
        [(OkIoBytes contents)
          (let
            [text : String (byte_buf.to-string contents)]
            (lsp-workspace-index-add-text-source! index root path text false))]
        [(ErrIoBytes _) unit]))))

(define (lsp-workspace-index-build-root!
  [index : (&mut index lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [root : lsp_vector_families.LspWorkspaceRoot]) : unit
  (match (package_source_core.package-source-discover-root-for "lsp" root.path)
    [(Err _) unit]
    [(Ok paths)
      (let
        [path-index : i64 0]
        (while (< path-index (lsp_svec.len (& paths)))
          (begin
            (lsp-workspace-index-add-path!
              index
              docs
              (Found (owned_view.compiler-owned-shared-view root))
              (lsp_svec.get (& paths) path-index ""))
            (set! path-index (+ path-index 1)))))]))

(define (lsp-workspace-index-add-rootless-overlays!
  [index : (&mut index lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]) : unit
  (let
    [doc-index : i64 0]
    (while (< doc-index (lsp_document_vec.len (& docs)))
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp_document_vec.get (& docs) doc-index (lsp-document-fallback))]
        [path : String doc.path]
        [uri : String
          (if (> (string.string-length path) 0)
            (lsp-resolved-path-to-file-uri path)
            "")]
        (begin
          (if (and
            (> (string.string-length path) 0)
            (< (lsp-workspace-sources-find-uri (& index.sources) uri) 0))
            (lsp-workspace-index-add-text-source!
              index
              Missing
              path
              doc.text
              true)
            unit)
          (set! doc-index (+ doc-index 1)))))))

(define (lsp-workspace-index-build-sources!
  [index : (&mut index lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]) : unit
  (let
    [root-index : i64 0]
    (begin
      (while (< root-index (lsp-workspace-roots-len (& index.roots)))
        (begin
          (lsp-workspace-index-build-root!
            index
            docs
            (lsp-workspace-roots-get (& index.roots) root-index))
          (set! root-index (+ root-index 1))))
      (lsp-workspace-index-add-rootless-overlays! index docs))))

(define (lsp-server-state-copy-in-current
  [state : (& state lsp_vector_families.LspServerState)]) : lsp_vector_families.LspServerState
  (lsp_vector_families.LspServerState
    0
    (lsp-documents-copy state.documents)
    (lsp-workspace-index-copy state.workspace)
    (lsp-workspace-semantic-cache-copy state.semantic-cache)))

(define (lsp-server-state-finish-swap
  [old-state : (& old-state lsp_vector_families.LspServerState)]
  [draft : lsp_vector_families.LspServerState]
  [owner : i64]
  [previous-arena : i64]) : lsp_vector_families.LspServerState
  (let
    [next : lsp_vector_families.LspServerState
      (lsp_vector_families.LspServerState
        owner
        draft.documents
        draft.workspace
        draft.semantic-cache)]
    (begin
      (unsafe
        (arena.tl_arena_set previous-arena))
      (if (> old-state.owner-arena 0)
        (unsafe
          (arena.tl_arena_destroy old-state.owner-arena))
        unit)
      (set! lsp-document-cache-arena owner)
      next)))

(define (lsp-server-state-new) : lsp_vector_families.LspServerState
  (let
    [previous : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make)]
    [_install : unit
      (unsafe
        (arena.tl_arena_set owner))]
    [docs : lsp_document_vec.Vec (lsp_document_vec.new)]
    [workspace : lsp_vector_families.LspWorkspaceIndex
      (lsp_vector_families.LspWorkspaceIndex
        (lsp-workspace-roots-new)
        (lsp-workspace-sources-new))]
    [semantic-cache : lsp_vector_families.LspWorkspaceSemanticCache
      (lsp-workspace-semantic-cache-new)]
    [_restore : unit
      (unsafe
        (arena.tl_arena_set previous))]
    (begin
      (set! lsp-document-cache-arena owner)
      (lsp_vector_families.LspServerState owner docs workspace semantic-cache))))

(define (lsp-server-state-destroy! [state : lsp_vector_families.LspServerState]) : unit
  (let
    [state : lsp_vector_families.LspServerState state]
    [owner : i64 state.owner-arena]
    (begin
      (lsp-documents-release-all! (&mut state.documents))
      (lsp-workspace-semantic-cache-release-all! (&mut state.semantic-cache))
      (set! lsp-document-cache-arena 0)
      (if (> owner 0)
        (unsafe
          (arena.tl_arena_destroy owner))
        unit))))

(define (lsp-workspace-semantic-key-field [value : String]) : String
  (str_cat.str-cat (string.int->string (string.string-length value)) ":" value))

;; Exact framing avoids accidental cache reuse when roots/cfgs are reordered or
;; contain punctuation. Position encoding is intentionally absent: semantic
;; indexes retain both UTF-8 bytes and UTF-16 columns and do not depend on the
;; negotiated rendering choice.
(define (lsp-workspace-semantic-context-key
  [workspace : (& workspace lsp_vector_families.LspWorkspaceIndex)]
  [stdlib-roots : (& stdlib-roots lsp_svec.Vec)]) : String
  (let
    [cfg-names : lsp_svec.Vec (lsp-global-shared-view lsp-language-cfg-names)]
    [key : String
      (match lsp-language-target
        [(Linux) "lsp-semantic-v1|linux|"]
        [(Windows) "lsp-semantic-v1|windows|"])]
    [index : i64 0]
    (begin
      (set!
        key
        (str_cat.str-cat
          key
          (string.int->string (lsp_svec.len (& cfg-names)))
          "|cfg|"))
      (while (< index (lsp_svec.len (& cfg-names)))
        (begin
          (set!
            key
            (str_cat.str-cat
              key
              (lsp-workspace-semantic-key-field
                (lsp_svec.get (& cfg-names) index ""))
              ""))
          (set! index (+ index 1))))
      (set! index 0)
      (set!
        key
        (str_cat.str-cat
          key
          (string.int->string (lsp_svec.len (& stdlib-roots)))
          "|stdlib|"))
      (while (< index (lsp_svec.len (& stdlib-roots)))
        (begin
          (set!
            key
            (str_cat.str-cat
              key
              (lsp-workspace-semantic-key-field
                (lsp-normalized-absolute-path
                  (lsp_svec.get (& stdlib-roots) index "")))
              ""))
          (set! index (+ index 1))))
      (set! index 0)
      (set!
        key
        (str_cat.str-cat
          key
          (string.int->string (lsp-workspace-roots-len (& workspace.roots)))
          "|workspace|"))
      (while (< index (lsp-workspace-roots-len (& workspace.roots)))
        (let
          [root : lsp_vector_families.LspWorkspaceRoot
            (lsp-workspace-roots-get (& workspace.roots) index)]
          (begin
            (set!
              key
              (str_cat.str-cat
                key
                (lsp-workspace-semantic-key-field root.uri)
                (lsp-workspace-semantic-key-field root.path)))
            (set! index (+ index 1)))))
      key)))

(define (lsp-workspace-semantic-source-fingerprint [text : (& text str)]) : i64
  (let
    ;; Two independent 31-bit polynomial hashes fit losslessly in one i64.
    ;; Keeping the byte length beside this value makes accidental reuse far
    ;; less plausible than the declaration-index hash used for internal maps,
    ;; without retaining unopened disk text in long-lived workspace state.
    [modulus-a : i64 2147483647]
    [modulus-b : i64 2147483629]
    [hash-a : i64 17]
    [hash-b : i64 29]
    [index : i64 0]
    (begin
      (while (< index (string.string-length text))
        (let
          [value : i64 (cast (string.string-ref text index) : i64)]
          (begin
            (set! hash-a (% (+ (* hash-a 131) value) modulus-a))
            (set! hash-b (% (+ (* hash-b 137) value) modulus-b))
            (set! index (+ index 1)))))
      (+ (* hash-a modulus-b) hash-b))))

(define (lsp-workspace-semantic-index-overlay-mismatch?
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]) : bool
  (let
    [doc-index : i64 0]
    [mismatch : bool false]
    (begin
      (while (and (< doc-index (lsp_document_vec.len (& docs))) (not mismatch))
        (let
          [doc : lsp_vector_families.LspDocument
            (lsp_document_vec.get (& docs) doc-index (lsp-document-fallback))]
          (begin
            (if (and
              (>= doc.version 0)
              (compiler_semantic_index.compiler-semantic-source-index-contains-path?
                index
                (owned_view.compiler-owned-shared-view doc.path)))
              (match (io.try-read-file (& doc.path))
                [(OkIoBytes contents)
                  (let
                    [text : String (byte_buf.to-string contents)]
                    (if (and
                      (=
                        (lsp-workspace-semantic-source-fingerprint text)
                        (lsp-workspace-semantic-source-fingerprint doc.text))
                      (=
                        (string.string-length text)
                        (string.string-length doc.text)))
                      unit
                      (set! mismatch true)))]
                [(ErrIoBytes _) (set! mismatch true)])
              unit)
            (set! doc-index (+ doc-index 1)))))
      mismatch)))

(define (lsp-workspace-semantic-cache-install!
  [cache : (&mut cache lsp_vector_families.LspWorkspaceSemanticCache)]
  [source : lsp_vector_families.LspWorkspaceSource]
  [fingerprint : i64]
  [source-len : i64]
  [semantic-index : compiler_semantic_index.CompilerSemanticSourceIndex]) : unit
  (begin
    (unsafe
      (ptr-write!
        (ptr-offset (__tl_array-data cache.slots) cache.len)
        (lsp_vector_families.LspWorkspaceSemanticCacheEntry
          (string.copy (& source.uri))
          (string.copy (& source.path))
          fingerprint
          source-len
          semantic-index)))
    (set! cache.len (+ cache.len 1))))

(define (lsp-workspace-semantic-cache-refresh-source!
  [cache : (&mut cache lsp_vector_families.LspWorkspaceSemanticCache)]
  [source : lsp_vector_families.LspWorkspaceSource]
  [docs : (& docs lsp_document_vec.Vec)]
  [stdlib-roots : lsp_svec.Vec]) : i64
  (match (io.try-read-file (& source.path))
    [(ErrIoBytes _)
      (let
        [existing : i64
          (lsp-workspace-semantic-cache-find-uri cache source.uri)]
        (begin
          (if (>= existing 0)
            (lsp-workspace-semantic-cache-remove-index! cache existing)
            unit)
          0))]
    [(OkIoBytes contents)
      (let
        [text : String (byte_buf.to-string contents)]
        [fingerprint : i64 (lsp-workspace-semantic-source-fingerprint text)]
        [source-len : i64 (string.string-length text)]
        [existing : i64
          (lsp-workspace-semantic-cache-find-uri
            cache
            (lsp-global-shared-view source.uri))]
        [fresh : bool
          (if (< existing 0)
            false
            (let
              [entry : lsp_vector_families.LspWorkspaceSemanticCacheEntry
                (owned_view.compiler-owned-array-element-shared-view
                  cache.slots
                  existing)]
              (and
                (= entry.source-fingerprint fingerprint)
                (= entry.source-len source-len))))]
        (if fresh
          (let
            [entry : lsp_vector_families.LspWorkspaceSemanticCacheEntry
              (owned_view.compiler-owned-array-element-shared-view
                cache.slots
                existing)]
            (if (and
              (> entry.index.owner-arena 0)
              (lsp-workspace-semantic-index-overlay-mismatch?
                (& entry.index)
                docs))
              (begin
                (lsp-workspace-semantic-cache-remove-index! cache existing)
                (lsp-workspace-semantic-cache-install!
                  cache
                  source
                  fingerprint
                  source-len
                  (compiler_semantic_index.compiler-semantic-source-index-empty))
                0)
              0))
          (begin
            (if (>= existing 0)
              (lsp-workspace-semantic-cache-remove-index! cache existing)
              unit)
            (let
              [semantic-index : compiler_semantic_index.CompilerSemanticSourceIndex
                (match (compiler_semantic_index.compiler-check-source-index-with-roots-and-cfg
                  (lsp-global-shared-view source.path)
                  text
                  stdlib-roots
                  (lsp-language-cfgs))
                  [(Ok _ index) index]
                  [(Partial _ index) index]
                  [(Err _)
                    (compiler_semantic_index.compiler-semantic-source-index-empty)])]
              (begin
                (if (and
                  (> semantic-index.owner-arena 0)
                  (lsp-workspace-semantic-index-overlay-mismatch?
                    (& semantic-index)
                    docs))
                  (begin
                    (compiler_semantic_index.compiler-semantic-source-index-release!
                      (&mut semantic-index))
                    (set!
                      semantic-index
                      (compiler_semantic_index.compiler-semantic-source-index-empty)))
                  unit)
                (lsp-workspace-semantic-cache-install!
                  cache
                  source
                  fingerprint
                  source-len
                  semantic-index)))
            1)))]))

(define (lsp-workspace-semantic-cache-refresh!
  [cache : (&mut cache lsp_vector_families.LspWorkspaceSemanticCache)]
  [workspace : (& workspace lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [stdlib-roots : lsp_svec.Vec]) : i64
  (let
    [context-key : String
      (lsp-workspace-semantic-context-key workspace stdlib-roots)]
    [source-index : i64 0]
    [source-checks : i64 0]
    (begin
      (if (string.eq cache.context-key context-key)
        unit
        (begin
          (lsp-workspace-semantic-cache-release-all! cache)
          (set! cache.context-key (string.copy (& context-key)))))
      (let
        [prune-index : i64 0]
        (while (< prune-index cache.len)
          (let
            [entry : lsp_vector_families.LspWorkspaceSemanticCacheEntry
              (owned_view.compiler-owned-array-element-shared-view
                cache.slots
                prune-index)]
            [uri : String (string.copy (& entry.uri))]
            [live-index : i64
              (lsp-workspace-sources-find-uri (& workspace.sources) uri)]
            (if (and
              (>= live-index 0)
              (not
                (__tl-project-field
                  (lsp-workspace-sources-get (& workspace.sources) live-index)
                  overlay)))
              (set! prune-index (+ prune-index 1))
              (lsp-workspace-semantic-cache-remove-index! cache prune-index)))))
      (if (<
        (array-length cache.slots)
        (lsp-workspace-sources-len (& workspace.sources)))
        (let
          [bigger : (__tl_dyn-array
            lsp_vector_families.LspWorkspaceSemanticCacheEntry)
            (__tl_make-array
              lsp_vector_families.LspWorkspaceSemanticCacheEntry
              (lsp-workspace-sources-len (& workspace.sources)))]
          [copy-index : i64 0]
          (begin
            (while (< copy-index cache.len)
              (begin
                (unsafe
                  (ptr-write!
                    (ptr-offset (__tl_array-data bigger) copy-index)
                    (owned_view.compiler-owned-array-element-shared-view
                      cache.slots
                      copy-index)))
                (set! copy-index (+ copy-index 1))))
            (set! cache.slots bigger)))
        unit)
      (while (< source-index (lsp-workspace-sources-len (& workspace.sources)))
        (let
          [source : lsp_vector_families.LspWorkspaceSource
            (lsp-workspace-source-copy
              (lsp-workspace-sources-get (& workspace.sources) source-index))]
          (begin
            (if source.overlay
              unit
              (set!
                source-checks
                (+
                  source-checks
                  (lsp-workspace-semantic-cache-refresh-source!
                    cache
                    source
                    docs
                    (lsp-global-shared-view stdlib-roots)))))
            (set! source-index (+ source-index 1)))))
      source-checks)))

;; Refresh returns a new arena-swapped state. A cold call checks each missing or
;; stale unopened entry once; a warm call performs fingerprint validation but
;; reports zero source checks and retains the same bounded owners.
(define (lsp-server-state-refresh-semantic-cache
  [state : (& state lsp_vector_families.LspServerState)]
  [stdlib-roots : lsp_svec.Vec]) : lsp_vector_families.LspServerState
  (let
    [previous : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make)]
    [_install : unit
      (unsafe
        (arena.tl_arena_set owner))]
    [draft : lsp_vector_families.LspServerState
      (lsp-server-state-copy-in-current state)]
    [source-checks : i64
      (lsp-workspace-semantic-cache-refresh!
        (&mut draft.semantic-cache)
        (& draft.workspace)
        draft.documents
        stdlib-roots)]
    [next : lsp_vector_families.LspServerState
      (lsp-server-state-finish-swap state draft owner previous)]
    (begin
      (set! next.semantic-cache.source-checks source-checks)
      next)))

(define (lsp-workspace-semantic-fact-fallback) : lsp_vector_families.LspWorkspaceSemanticFact
  (lsp_vector_families.LspWorkspaceSemanticFact
    ""
    false
    -1
    Definition
    ""
    Value
    (compiler_semantic_index.CompilerSemanticSpan
      ""
      -1
      -1
      (ast.ast-source-span 1 1 1 1)
      -1
      -1)
    false))

(define (lsp-workspace-semantic-facts-get
  [facts : (& facts LspWorkspaceSemanticQuery)]
  [index : i64]) : lsp_vector_families.LspWorkspaceSemanticFact
  (if (and (>= index 0) (< index facts.len))
    (owned_view.compiler-owned-array-element-shared-view facts.slots index)
    (lsp-workspace-semantic-fact-fallback)))

(define (lsp-workspace-semantic-facts-contain?
  [facts : (& facts LspWorkspaceSemanticQuery)]
  [candidate : (& candidate lsp_vector_families.LspWorkspaceSemanticFact)]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (< index facts.len) (not found))
        (let
          [existing : lsp_vector_families.LspWorkspaceSemanticFact
            (owned_view.compiler-owned-array-element-shared-view
              facts.slots
              index)]
          (begin
            (if (and
              (string.eq candidate.span.path existing.span.path)
              (= candidate.span.start-byte existing.span.start-byte)
              (= candidate.span.end-byte existing.span.end-byte)
              (match candidate.role
                [(Definition)
                  (match existing.role
                    [(Definition) true]
                    [_ false])]
                [(Use)
                  (match existing.role
                    [(Use) true]
                    [_ false])]))
              (set! found true)
              unit)
            (set! index (+ index 1)))))
      found)))

(define (lsp-workspace-semantic-role-order
  [role : (& role compiler_semantic_index.CompilerSemanticRecordRole)]) : i64
  (match (deref role)
    [(Definition) 0]
    [(Use) 1]))

(define (lsp-workspace-semantic-fact-less?
  [left : (& left lsp_vector_families.LspWorkspaceSemanticFact)]
  [right : (& right lsp_vector_families.LspWorkspaceSemanticFact)]) : bool
  (cond
    [(not (string.eq left.uri right.uri))
      (stdlib.sort.string-less-borrowed? (& left.uri) (& right.uri))]
    [(< left.span.start-byte right.span.start-byte) true]
    [(> left.span.start-byte right.span.start-byte) false]
    [(< left.span.end-byte right.span.end-byte) true]
    [(> left.span.end-byte right.span.end-byte) false]
    [else
      (<
        (lsp-workspace-semantic-role-order (& left.role))
        (lsp-workspace-semantic-role-order (& right.role)))]))

;; Insert new facts directly into deterministic provider order. The candidate
;; is independent of the result storage, so shifting the live prefix cannot
;; alias or overwrite it.
(define (lsp-workspace-semantic-facts-insert!
  [facts : (&mut facts LspWorkspaceSemanticQuery)]
  [candidate : lsp_vector_families.LspWorkspaceSemanticFact]) : unit
  (if (lsp-workspace-semantic-facts-contain? facts candidate)
    unit
    (begin
      (if (>= facts.len (array-length facts.slots))
        (let
          [old-cap : i64 (array-length facts.slots)]
          [new-cap : i64
            (if (< old-cap 16)
              16
              (* old-cap 2))]
          [bigger : (__tl_dyn-array
            lsp_vector_families.LspWorkspaceSemanticFact)
            (__tl_make-array
              lsp_vector_families.LspWorkspaceSemanticFact
              new-cap)]
          [copy-index : i64 0]
          (begin
            (while (< copy-index facts.len)
              (begin
                (unsafe
                  (ptr-write!
                    (ptr-offset (__tl_array-data bigger) copy-index)
                    (array-ref facts.slots copy-index)))
                (set! copy-index (+ copy-index 1))))
            (set! facts.slots bigger)))
        unit)
      (let
        [position : i64 0]
        [write : i64 facts.len]
        (begin
          (while (and
            (< position facts.len)
            (not
              (lsp-workspace-semantic-fact-less?
                (& candidate)
                (& (array-ref facts.slots position)))))
            (set! position (+ position 1)))
          (while (> write position)
            (begin
              (set!
                (array-ref facts.slots write)
                (array-ref facts.slots (- write 1)))
              (set! write (- write 1))))
          (set! (array-ref facts.slots position) candidate)
          (set! facts.len (+ facts.len 1)))))))

(define (lsp-workspace-semantic-facts-add-index!
  [facts : (&mut facts LspWorkspaceSemanticQuery)]
  [semantic-index
    : (& semantic-index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [canonical-key : (& canonical-key str)]) : unit
  (let
    [record-index : i64 0]
    (while (<
      record-index
      (compiler_semantic_index.compiler-semantic-source-index-len
        semantic-index))
      (let
        [record : compiler_semantic_index.CompilerSemanticRecord
          (compiler_semantic_index.compiler-semantic-source-index-get
            semantic-index
            record-index)]
        [record-key : String
          (compiler_semantic_index.compiler-semantic-source-index-record-canonical-key
            semantic-index
            (& record))]
        (begin
          (if (and
            (> (string.string-length canonical-key) 0)
            (string.eq canonical-key record-key))
            (let
              [path : String
                (if (> (string.string-length record.span.path) 0)
                  (lsp-normalized-absolute-path record.span.path)
                  "")]
              [doc-index : i64
                (if (> (string.string-length path) 0)
                  (lsp-documents-find-path-index docs path)
                  -1)]
              [open : bool (>= doc-index 0)]
              [version : i64
                (if open
                  (__tl-project-field
                    (lsp_document_vec.get
                      docs
                      doc-index
                      (lsp-document-fallback))
                    version)
                  -1)]
              [candidate : lsp_vector_families.LspWorkspaceSemanticFact
                (lsp_vector_families.LspWorkspaceSemanticFact
                  (if (> (string.string-length path) 0)
                    (lsp-path-to-file-uri
                      (owned_view.compiler-owned-shared-view path))
                    "")
                  open
                  version
                  (match record.role
                    [(Definition) Definition]
                    [(Use) Use])
                  (string.copy (& record.display-name))
                  (match record.kind
                    [(Value) Value]
                    [(Function) Function]
                    [(Macro) Macro]
                    [(ExternValue) ExternValue]
                    [(ExternFunction) ExternFunction]
                    [(Struct) Struct]
                    [(Enum) Enum]
                    [(Module) Module]
                    [(Field) Field]
                    [(EnumMember) EnumMember]
                    [(Parameter) Parameter]
                    [(Local) Local])
                  (compiler_semantic_index.CompilerSemanticSpan
                    (string.copy (& path))
                    record.span.start-byte
                    record.span.end-byte
                    (ast.ast-source-span
                      (cast record.span.source.start-line : i64)
                      (cast record.span.source.start-col : i64)
                      (cast record.span.source.end-line : i64)
                      (cast record.span.source.end-col : i64))
                    record.span.utf16-start-col
                    record.span.utf16-end-col)
                  record.editable)]
              (lsp-workspace-semantic-facts-insert! facts candidate))
            unit)
          (set! record-index (+ record-index 1)))))))

(define (lsp-document-semantic-canonical-key-at
  [doc : (& doc lsp_vector_families.LspDocument)]
  [byte-position : i64]) : String
  (let
    [record-index : i64 (lsp-document-semantic-record-at doc byte-position)]
    (if (< record-index 0)
      ""
      (let
        [record : compiler_semantic_index.CompilerSemanticRecord
          (compiler_semantic_index.compiler-semantic-source-index-get
            (& doc.semantic.index)
            record-index)]
        (compiler_semantic_index.compiler-semantic-source-index-record-canonical-key
          (& doc.semantic.index)
          (& record))))))

;; Read-only provider boundary. It never checks source: missing or stale disk
;; entries are omitted and reported as refreshable, while current partial or
;; unavailable open/negative entries are reported as currently incomplete.
(define (lsp-workspace-semantic-query
  [state : (& state lsp_vector_families.LspServerState)]
  [stdlib-roots : (& stdlib-roots lsp_svec.Vec)]
  [canonical-key : (& canonical-key str)]) : LspWorkspaceSemanticQuery
  (let
    [facts : LspWorkspaceSemanticQuery
      (LspWorkspaceSemanticQuery
        (__tl_make-array lsp_vector_families.LspWorkspaceSemanticFact 0)
        0
        0)]
    ;; 0 complete, 1 refreshable, 2 currently incomplete.
    [completeness : i64 0]
    [doc-index : i64 0]
    [source-index : i64 0]
    [context-current : bool
      (string.eq
        state.semantic-cache.context-key
        (lsp-workspace-semantic-context-key (& state.workspace) stdlib-roots))]
    (begin
      ;; Open buffers are authoritative and scanned first, so exact duplicate
      ;; dependency records from unopened entry closures collapse onto them.
      (while (< doc-index (lsp_document_vec.len (& state.documents)))
        (let
          [doc : lsp_vector_families.LspDocument
            (lsp_document_vec.get
              (& state.documents)
              doc-index
              (lsp-document-fallback))]
          (begin
            (match (lsp-document-semantic-snapshot-status (& doc))
              [(Current _ complete)
                (begin
                  (lsp-workspace-semantic-facts-add-index!
                    (&mut facts)
                    (& doc.semantic.index)
                    (& state.documents)
                    canonical-key)
                  (if complete
                    unit
                    (set! completeness 2)))]
              [_ (set! completeness 2)])
            (set! doc-index (+ doc-index 1)))))
      (while (<
        source-index
        (lsp-workspace-sources-len (& state.workspace.sources)))
        (let
          [source : lsp_vector_families.LspWorkspaceSource
            (lsp-workspace-sources-get (& state.workspace.sources) source-index)]
          (begin
            (if source.overlay
              unit
              (let
                [cache-index : i64
                  (if context-current
                    (lsp-workspace-semantic-cache-find-uri
                      (& state.semantic-cache)
                      source.uri)
                    -1)]
                (if (< cache-index 0)
                  (if (= completeness 0)
                    (set! completeness 1)
                    unit)
                  (let
                    [entry : lsp_vector_families.LspWorkspaceSemanticCacheEntry
                      (owned_view.compiler-owned-array-element-shared-view
                        state.semantic-cache.slots
                        cache-index)]
                    (match (io.try-read-file (& source.path))
                      [(ErrIoBytes _)
                        (if (= completeness 0)
                          (set! completeness 1)
                          unit)]
                      [(OkIoBytes contents)
                        (let
                          [text : String (byte_buf.to-string contents)]
                          [fingerprint : i64
                            (lsp-workspace-semantic-source-fingerprint text)]
                          [source-len : i64 (string.string-length text)]
                          (if (or
                            (not (= fingerprint entry.source-fingerprint))
                            (not (= source-len entry.source-len)))
                            (if (= completeness 0)
                              (set! completeness 1)
                              unit)
                            (if (> entry.index.owner-arena 0)
                              (begin
                                (lsp-workspace-semantic-facts-add-index!
                                  (&mut facts)
                                  (& entry.index)
                                  (& state.documents)
                                  canonical-key)
                                (if (compiler_semantic_index.compiler-semantic-source-index-complete?
                                  (& entry.index))
                                  unit
                                  (set! completeness 2)))
                              (set! completeness 2))))])))))
            (set! source-index (+ source-index 1)))))
      (set! facts.completeness completeness)
      facts)))

(define (lsp-workspace-semantic-fact-real-location?
  [fact : lsp_vector_families.LspWorkspaceSemanticFact]) : bool
  (let
    [span : compiler_semantic_index.CompilerSemanticSpan fact.span]
    [source : ast.AstSourceSpan span.source]
    (and
      (> (string.string-length fact.uri) 0)
      (> (string.string-length span.path) 0)
      (>= span.start-byte 0)
      (> span.end-byte span.start-byte)
      (> (ast.ast-source-span-start-line source) 0)
      (> (ast.ast-source-span-start-col source) 0)
      (> (ast.ast-source-span-end-line source) 0)
      (> (ast.ast-source-span-end-col source) 0)
      (> span.utf16-start-col 0)
      (> span.utf16-end-col 0))))

(define (lsp-workspace-semantic-fact-definition?
  [fact : (& fact lsp_vector_families.LspWorkspaceSemanticFact)]) : bool
  (match fact.role
    [(Definition) true]
    [(Use) false]))

(define (lsp-reference-location
  [fact : lsp_vector_families.LspWorkspaceSemanticFact]) : json.Json
  (lsp-json-object2
    "uri"
    (JsonString fact.uri)
    "range"
    (lsp-json-object2
      "start"
      (lsp-semantic-span-position (lsp-global-shared-view fact.span) true)
      "end"
      (lsp-semantic-span-position fact.span false))))

(define (lsp-reference-result-json
  [query : (& query LspWorkspaceSemanticQuery)]
  [include-declaration : bool]) : json.Json
  (let
    [index : i64 (- query.len 1)]
    [locations : json.JsonSeq (json.list-empty)]
    (begin
      (while (>= index 0)
        (let
          [fact : lsp_vector_families.LspWorkspaceSemanticFact
            (lsp-workspace-semantic-facts-get query index)]
          (begin
            (if (and
              (lsp-workspace-semantic-fact-real-location?
                (lsp-global-shared-view fact))
              (or
                include-declaration
                (not (lsp-workspace-semantic-fact-definition? fact))))
              (set!
                locations
                (lsp-json-list-cons (lsp-reference-location fact) locations))
              unit)
            (set! index (- index 1)))))
      (lsp-json-array locations))))

(define (lsp-rename-span-real?
  [span : compiler_semantic_index.CompilerSemanticSpan]
  [text : (& text str)]) : bool
  (and
    (>= span.start-byte 0)
    (> span.end-byte span.start-byte)
    (<= span.end-byte (string.string-length text))))

;; Value/function facts preserve a whole qualified token for navigation. A
;; rename edits only its final identifier component; aliases have a different
;; source spelling and therefore keep their exact alias span.
(define (lsp-rename-effective-span
  [span : compiler_semantic_index.CompilerSemanticSpan]
  [display-name : (& display-name str)]
  [text : (& text str)]) : compiler_semantic_index.CompilerSemanticSpan
  (if (not (lsp-rename-span-real? (lsp-global-shared-view span) text))
    span
    (let
      [name-len : i64 (string.string-length display-name)]
      [candidate-start : i64 (- span.end-byte name-len)]
      [suffix : bool
        (and
          (> name-len 0)
          (>= candidate-start span.start-byte)
          (string.eq
            (string.substring text candidate-start name-len)
            display-name))]
      [component : bool
        (and
          suffix
          (or
            (= candidate-start span.start-byte)
            (= (string.string-ref text (- candidate-start 1)) '.')
            (= (string.string-ref text (- candidate-start 1)) '/')))]
      (if (not component)
        span
        (let
          [source : ast.AstSourceSpan span.source]
          [end-line : i64 (ast.ast-source-span-end-line source)]
          [end-col : i64 (ast.ast-source-span-end-col source)]
          (compiler_semantic_index.CompilerSemanticSpan
            (string.copy (& span.path))
            candidate-start
            span.end-byte
            (ast.ast-source-span end-line (- end-col name-len) end-line end-col)
            (- span.utf16-end-col name-len)
            span.utf16-end-col))))))

(define (lsp-rename-span-text
  [span : compiler_semantic_index.CompilerSemanticSpan]
  [text : (& text str)]) : String
  (if (lsp-rename-span-real? (lsp-global-shared-view span) text)
    (string.substring text span.start-byte (- span.end-byte span.start-byte))
    ""))

(define (lsp-rename-target-at
  [doc : (& doc lsp_vector_families.LspDocument)]
  [byte-position : i64]) : LspRenameTargetLookup
  (match (lsp-document-semantic-snapshot-status doc)
    [(Current _ complete)
      (if (not complete)
        Missing
        (let
          [index : compiler_semantic_index.CompilerSemanticSourceIndex
            doc.semantic.index]
          [record-index : i64 0]
          [best-width : i64 999999999]
          [result : LspRenameTargetLookup Missing]
          [source-text : String (string.copy (& doc.text))]
          (begin
            (while (<
              record-index
              (compiler_semantic_index.compiler-semantic-source-index-len
                (& index)))
              (let
                [record : compiler_semantic_index.CompilerSemanticRecord
                  (compiler_semantic_index.compiler-semantic-source-index-get
                    (& index)
                    record-index)]
                [record-span : compiler_semantic_index.CompilerSemanticSpan
                  record.span]
                [edit-span : compiler_semantic_index.CompilerSemanticSpan
                  (lsp-rename-effective-span
                    (lsp-global-shared-view record-span)
                    record.display-name
                    source-text)]
                [width : i64 (- edit-span.end-byte edit-span.start-byte)]
                (begin
                  (if (and
                    (lsp-semantic-record-exact-editable? record)
                    (string.eq
                      (lsp-normalized-absolute-path
                        (string.copy (& record-span.path)))
                      (lsp-normalized-absolute-path (string.copy (& doc.path))))
                    (lsp-rename-span-real?
                      (lsp-global-shared-view edit-span)
                      source-text)
                    (>= byte-position edit-span.start-byte)
                    (< byte-position edit-span.end-byte)
                    (< width best-width))
                    (let
                      [canonical-key : String
                        (compiler_semantic_index.compiler-semantic-source-index-record-canonical-key
                          (& index)
                          (& record))]
                      [surface-name : String
                        (lsp-rename-span-text
                          (lsp-global-shared-view edit-span)
                          source-text)]
                      (if (and
                        (> (string.string-length canonical-key) 0)
                        (> (string.string-length surface-name) 0))
                        (begin
                          (set! best-width width)
                          (set!
                            result
                            (Found
                              (LspRenameTarget
                                canonical-key
                                surface-name
                                record.kind
                                record-span
                                edit-span))))
                        unit))
                    unit)
                  (set! record-index (+ record-index 1)))))
            result)))]
    [_ Missing]))

(define (lsp-rename-source-for-fact
  [state : (& state lsp_vector_families.LspServerState)]
  [fact : (& fact lsp_vector_families.LspWorkspaceSemanticFact)]) : LspRenameSourceLookup
  (let
    [doc-index : i64
      (lsp-documents-find-path-index (& state.documents) fact.span.path)]
    (if (>= doc-index 0)
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp_document_vec.get
            (& state.documents)
            doc-index
            (lsp-document-fallback))]
        (Found (string.copy (& doc.text))))
      (match (io.try-read-file (& fact.span.path))
        [(OkIoBytes contents) (Found (byte_buf.to-string contents))]
        [(ErrIoBytes _) Missing]))))

(define (lsp-rename-fact-surface-span
  [fact : lsp_vector_families.LspWorkspaceSemanticFact]
  [text : (& text str)]) : compiler_semantic_index.CompilerSemanticSpan
  (lsp-rename-effective-span fact.span fact.display-name text))

(define (lsp-rename-fact-selected?
  [fact : lsp_vector_families.LspWorkspaceSemanticFact]
  [text : (& text str)]
  [surface-name : (& surface-name str)]) : bool
  (string.eq
    (lsp-rename-span-text (lsp-rename-fact-surface-span fact text) text)
    surface-name))

(define (lsp-rename-module-kind?
  [kind : (& kind compiler_semantic_index.CompilerSemanticSymbolKind)]) : bool
  (match (deref kind)
    [(Module) true]
    [_ false]))

(define (lsp-rename-path-leaf-start [path : (& path str)] [name : String]) : i64
  (let
    [path-len : i64 (string.string-length path)]
    [leaf-len : i64 (+ (string.string-length name) 3)]
    [start : i64 (- path-len leaf-len)]
    (if (and
      (>= start 0)
      (string.eq (string.substring path start leaf-len) (lsp-str2 name ".tl"))
      (or
        (= start 0)
        (= (string.string-ref path (- start 1)) '/')
        (= (string.string-ref path (- start 1)) '\\')))
      start
      -1)))

(define (lsp-rename-module-new-path
  [path : (& path str)]
  [old-name : String]
  [new-name : String]) : String
  (let
    [start : i64 (lsp-rename-path-leaf-start path old-name)]
    (if (< start 0)
      ""
      (lsp-str3 (string.substring path 0 start) new-name ".tl"))))

;; Keep workspace-boundary and filesystem-probe decisions deterministic and
;; directly testable. Callers pass a dummy successful probe for an outside
;; path; the value is ignored, so no filesystem access occurs in that branch.
(define (lsp-rename-module-move-from-probe
  [old-path : String]
  [new-path : String]
  [inside-workspace : bool]
  [probe : io.ResultIoBool]) : LspRenameModuleMoveLookup
  (if (not inside-workspace)
    (Err "Renamed module path would leave the editable workspace")
    (match probe
      [(ErrIoBool _) (Err "Cannot validate the renamed module destination")]
      [(OkIoBool exists)
        (if exists
          (Err "Renamed module source path already exists")
          (Ok (Found old-path new-path)))])))

;; A real module declaration is source-addressed by its final component. Its
;; file must move after all TextDocumentEdits have applied to the old URI;
;; selected import aliases have no matching source leaf and therefore need no
;; resource operation.
(define (lsp-rename-module-move
  [state : (& state lsp_vector_families.LspServerState)]
  [query : (& query LspWorkspaceSemanticQuery)]
  [target : LspRenameTarget]
  [new-name : String]) : LspRenameModuleMoveLookup
  (if (not (lsp-rename-module-kind? (& target.kind)))
    (Ok Missing)
    (let
      [index : i64 0]
      [old-path : String ""]
      [new-path : String ""]
      (begin
        (while (< index query.len)
          (let
            [fact : lsp_vector_families.LspWorkspaceSemanticFact
              (lsp-workspace-semantic-facts-get query index)]
            (begin
              (if (and
                (lsp-workspace-semantic-fact-definition? fact)
                (lsp-rename-module-kind? (& fact.kind))
                (>=
                  (lsp-rename-path-leaf-start
                    fact.span.path
                    (lsp-global-shared-view target.surface-name))
                  0))
                (match (lsp-rename-source-for-fact state fact)
                  [(Found text)
                    (if (lsp-rename-fact-selected?
                      (lsp-global-shared-view fact)
                      text
                      target.surface-name)
                      (let
                        [candidate : String
                          (lsp-rename-module-new-path
                            fact.span.path
                            target.surface-name
                            (lsp-global-shared-view new-name))]
                        (cond
                          [(= (string.string-length old-path) 0)
                            (begin
                              (set! old-path (string.copy (& fact.span.path)))
                              (set! new-path candidate))]
                          [(not (string.eq old-path fact.span.path))
                            (return
                              (Err
                                "Rename resolves to multiple module source files"))]
                          [else unit]))
                      unit)]
                  [(Missing) unit])
                unit)
              (set! index (+ index 1)))))
        (if (= (string.string-length old-path) 0)
          (Ok Missing)
          (match (lsp-workspace-root-for-path
            (& state.workspace.roots)
            new-path
            false)
            [(Missing)
              (lsp-rename-module-move-from-probe
                old-path
                new-path
                false
                (OkIoBool false))]
            [(Found _)
              (let
                [probe : io.ResultIoBool (io.try-file-exists? (& new-path))]
                (lsp-rename-module-move-from-probe old-path new-path true probe))]))))))

(define (lsp-rename-space-list-contains? [items : String] [name : (& name str)]) : bool
  (let
    [len : i64 (string.string-length items)]
    [name-len : i64 (string.string-length name)]
    [index : i64 0]
    (begin
      (while (<= (+ index name-len) len)
        (if (and
          (or (= index 0) (= (string.string-ref items (- index 1)) ' '))
          (or
            (= (+ index name-len) len)
            (= (string.string-ref items (+ index name-len)) ' '))
          (string.is-string-prefix-at (& items) name index))
          (return true)
          (set! index (+ index 1))))
      false)))

(define (lsp-rename-valid-new-name? [name : (& name str)]) : bool
  (let
    [len : i64 (string.string-length name)]
    [index : i64 0]
    [valid : bool (> len 0)]
    [dot : String "."]
    [colon : String ":"]
    (begin
      (if (and
        valid
        (or
          (and
            (>= (string.string-ref name 0) '0')
            (<= (string.string-ref name 0) '9'))
          (string.eq name "_")
          (string.contains name (& dot))
          (string.contains name (& colon))))
        (set! valid false)
        unit)
      (while (and valid (< index len))
        (if (lsp-ident-char? (string.string-ref name index))
          (set! index (+ index 1))
          (set! valid false)))
      (and
        valid
        (not
          (lsp-rename-space-list-contains?
            (lsp-str3
              (lsp-completion-keywords)
              " "
              (lsp-str3 (lsp-completion-types) " " "true false unit"))
            name))))))

(define (lsp-rename-valid-new-name-for-target?
  [target : (& target LspRenameTarget)]
  [name : (& name str)]) : bool
  (and
    (lsp-rename-valid-new-name? name)
    (if (lsp-rename-module-kind? (& target.kind))
      (let
        [slash : String "/"]
        (not (string.contains name (& slash))))
      true)))

(define (lsp-rename-fact-workspace-editable?
  [state : (& state lsp_vector_families.LspServerState)]
  [fact : lsp_vector_families.LspWorkspaceSemanticFact]) : bool
  (and
    fact.editable
    (lsp-workspace-semantic-fact-real-location? (lsp-global-shared-view fact))
    (if fact.open
      (>= fact.version 0)
      (match (lsp-workspace-root-for-path
        (& state.workspace.roots)
        fact.span.path
        true)
        [(Found _) true]
        [(Missing) false]))))

(define (lsp-rename-fact-collision-in-index?
  [index : (& index compiler_semantic_index.CompilerSemanticSourceIndex)]
  [fact : lsp_vector_families.LspWorkspaceSemanticFact]
  [canonical-key : (& canonical-key str)]
  [new-name : (& new-name str)]) : bool
  (compiler_semantic_index.compiler-semantic-source-index-rename-collision?
    index
    canonical-key
    fact.span.path
    fact.span.start-byte
    fact.span.end-byte
    new-name))

(define (lsp-rename-fact-collision?
  [state : (& state lsp_vector_families.LspServerState)]
  [fact : lsp_vector_families.LspWorkspaceSemanticFact]
  [canonical-key : (& canonical-key str)]
  [new-name : (& new-name str)]) : bool
  (let
    [doc-index : i64 0]
    [cache-index : i64 0]
    (begin
      (while (< doc-index (lsp_document_vec.len (& state.documents)))
        (let
          [doc : lsp_vector_families.LspDocument
            (lsp_document_vec.get
              (& state.documents)
              doc-index
              (lsp-document-fallback))]
          (begin
            (when
              (lsp-rename-fact-collision-in-index?
                (& doc.semantic.index)
                (lsp-global-shared-view fact)
                canonical-key
                new-name)
              (return true))
            (set! doc-index (+ doc-index 1)))))
      (while (< cache-index state.semantic-cache.len)
        (begin
          (when
            (lsp-rename-fact-collision-in-index?
              (& (array-ref state.semantic-cache.slots cache-index).index)
              (lsp-global-shared-view fact)
              canonical-key
              new-name)
            (return true))
          (set! cache-index (+ cache-index 1))))
      false)))

(define (lsp-rename-validate-query
  [state : (& state lsp_vector_families.LspServerState)]
  [query : (& query LspWorkspaceSemanticQuery)]
  [target : (& target LspRenameTarget)]
  [new-name : String]
  [check-collisions : bool]) : LspRenameValidation
  (if (not (= query.completeness 0))
    (Err "Workspace semantic rename information is currently incomplete")
    (let
      [index : i64 0]
      [selected : i64 0]
      [definitions : i64 0]
      [error : String ""]
      (begin
        (while (and (< index query.len) (= (string.string-length error) 0))
          (let
            [fact : lsp_vector_families.LspWorkspaceSemanticFact
              (lsp-workspace-semantic-facts-get query index)]
            (begin
              (match (lsp-rename-source-for-fact state fact)
                [(Missing)
                  (if (string.eq fact.display-name target.surface-name)
                    (set!
                      error
                      "A rename occurrence has no current source text")
                    unit)]
                [(Found text)
                  (if (lsp-rename-fact-selected?
                    (lsp-global-shared-view fact)
                    text
                    target.surface-name)
                    (begin
                      (set! selected (+ selected 1))
                      (if (lsp-workspace-semantic-fact-definition? fact)
                        (set! definitions (+ definitions 1))
                        unit)
                      (cond
                        [(not
                            (lsp-rename-fact-workspace-editable?
                              state
                              (lsp-global-shared-view fact)))
                          (set!
                            error
                            "Rename would modify generated, stale, or non-workspace source")]
                        [(not
                            (lsp-rename-span-real?
                              (lsp-rename-fact-surface-span
                                (lsp-global-shared-view fact)
                                text)
                              text))
                          (set!
                            error
                            "Rename occurrence has an invalid source range")]
                        [(and
                            check-collisions
                            (lsp-rename-fact-collision?
                              state
                              fact
                              target.canonical-key
                              new-name))
                          (set!
                            error
                            "New name collides with a visible binding")]
                        [else unit]))
                    unit)])
              (set! index (+ index 1)))))
        (cond
          [(> (string.string-length error) 0) (Err error)]
          [(= selected 0) (Err "No editable rename occurrences were found")]
          [(= definitions 0) (Err "Rename target has no editable definition")]
          [else (Ok selected)])))))

(define (lsp-rename-text-edit
  [span : compiler_semantic_index.CompilerSemanticSpan]
  [new-name : String]) : json.Json
  (lsp-json-object2
    "range"
    (lsp-json-object2
      "start"
      (lsp-semantic-span-position (lsp-global-shared-view span) true)
      "end"
      (lsp-semantic-span-position span false))
    "newText"
    (JsonString new-name)))

(define (lsp-rename-document-edit
  [uri : String]
  [open : bool]
  [version : i64]
  [edits : json.JsonSeq]) : json.Json
  (lsp-json-object2
    "textDocument"
    (lsp-json-object2
      "uri"
      (JsonString uri)
      "version"
      (if open
        (lsp-json-number version)
        JsonNull))
    "edits"
    (lsp-json-array edits)))

(define (lsp-rename-file-operation [old-path : String] [new-path : String]) : json.Json
  (lsp-json-object3
    "kind"
    (JsonString "rename")
    "oldUri"
    (JsonString (lsp-path-to-file-uri old-path))
    "newUri"
    (JsonString (lsp-path-to-file-uri new-path))))

(define (lsp-rename-append-module-move
  [changes : json.JsonSeq]
  [module-move : LspRenameModuleMove]) : json.JsonSeq
  (match module-move
    [(Found old-path new-path)
      (json.list-concat
        changes
        (lsp-json-list-cons
          (lsp-rename-file-operation old-path new-path)
          (json.list-empty)))]
    [(Missing) changes]))

(define (lsp-rename-workspace-edit
  [state : (& state lsp_vector_families.LspServerState)]
  [query : (& query LspWorkspaceSemanticQuery)]
  [target : LspRenameTarget]
  [new-name : String]
  [module-move : LspRenameModuleMove]) : json.Json
  (let
    [index : i64 (- query.len 1)]
    [changes : json.JsonSeq (json.list-empty)]
    (begin
      (while (>= index 0)
        (let
          [last : lsp_vector_families.LspWorkspaceSemanticFact
            (lsp-workspace-semantic-facts-get query index)]
          [uri : String last.uri]
          [open : bool last.open]
          [version : i64 last.version]
          [edits : json.JsonSeq (json.list-empty)]
          [previous-start : i64 -1]
          [previous-end : i64 -1]
          (begin
            (while (and
              (>= index 0)
              (string.eq (lsp-workspace-semantic-facts-get query index).uri uri))
              (let
                [fact : lsp_vector_families.LspWorkspaceSemanticFact
                  (lsp-workspace-semantic-facts-get query index)]
                (begin
                  (match (lsp-rename-source-for-fact state fact)
                    [(Missing) unit]
                    [(Found text)
                      (if (lsp-rename-fact-selected?
                        (lsp-global-shared-view fact)
                        text
                        target.surface-name)
                        (let
                          [span : compiler_semantic_index.CompilerSemanticSpan
                            (lsp-rename-fact-surface-span fact text)]
                          (if (and
                            (= span.start-byte previous-start)
                            (= span.end-byte previous-end))
                            unit
                            (begin
                              (set! previous-start span.start-byte)
                              (set! previous-end span.end-byte)
                              (set!
                                edits
                                (lsp-json-list-cons
                                  (lsp-rename-text-edit
                                    span
                                    (lsp-global-shared-view new-name))
                                  edits)))))
                        unit)])
                  (set! index (- index 1)))))
            (if (> (json.list-count (lsp-global-shared-view edits)) 0)
              (set!
                changes
                (lsp-json-list-cons
                  (lsp-rename-document-edit uri open version edits)
                  changes))
              unit))))
      (set! changes (lsp-rename-append-module-move changes module-move))
      (lsp-json-object1 "documentChanges" (lsp-json-array changes)))))

(define (lsp-prepare-rename-result [target : LspRenameTarget]) : json.Json
  (lsp-json-object2
    "range"
    (lsp-json-object2
      "start"
      (lsp-semantic-span-position
        (lsp-global-shared-view target.edit-span)
        true)
      "end"
      (lsp-semantic-span-position target.edit-span false))
    "placeholder"
    (JsonString target.surface-name)))

(define (lsp-server-state-initialize-workspaces
  [state : lsp_vector_families.LspServerState]
  [message : json.Json]) : lsp_vector_families.LspServerState
  (let
    [previous : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make)]
    [_install : unit
      (unsafe
        (arena.tl_arena_set owner))]
    [docs : lsp_document_vec.Vec (lsp-documents-copy state.documents)]
    [workspace : lsp_vector_families.LspWorkspaceIndex
      (lsp_vector_families.LspWorkspaceIndex
        (lsp-initialize-workspace-roots message)
        (lsp-workspace-sources-new))]
    [_build : unit (lsp-workspace-index-build-sources! (&mut workspace) docs)]
    [semantic-cache : lsp_vector_families.LspWorkspaceSemanticCache
      (lsp-workspace-semantic-cache-copy state.semantic-cache)]
    [_invalidate : unit
      (lsp-workspace-semantic-cache-release-all! (&mut semantic-cache))]
    [draft : lsp_vector_families.LspServerState
      (lsp_vector_families.LspServerState 0 docs workspace semantic-cache)]
    (lsp-server-state-finish-swap state draft owner previous)))

(define lsp-workspace-symbol-result-limit : i64
  256)

(define (lsp-workspace-decl-row-fallback) : lsp_vector_families.LspWorkspaceDeclRow
  (lsp_vector_families.LspWorkspaceDeclRow
    ""
    ""
    ""
    ""
    ""
    false
    false
    (lsp-decl-entry-fallback)))

(define (lsp-workspace-symbol-candidate-fallback) : LspWorkspaceSymbolCandidate
  (LspWorkspaceSymbolCandidate 3 (lsp-workspace-decl-row-fallback)))

(define (lsp-workspace-symbol-results-new) : LspWorkspaceSymbolResults
  (LspWorkspaceSymbolResults
    (__tl_make-array
      LspWorkspaceSymbolCandidate
      lsp-workspace-symbol-result-limit)
    0))

(define (lsp-workspace-symbol-results-len
  [results : (& results LspWorkspaceSymbolResults)]) : i64
  results.len)

(define (lsp-workspace-symbol-results-get
  [results : (& results LspWorkspaceSymbolResults)]
  [index : i64]) : LspWorkspaceSymbolCandidate
  (if (and (>= index 0) (< index results.len))
    (array-ref results.slots index)
    (lsp-workspace-symbol-candidate-fallback)))

(define (lsp-workspace-symbol-match-rank
  [name : (& name str)]
  [query : (& query str)]) : i64
  (cond
    [(= (string.string-length query) 0) 0]
    [(string.eq name query) 0]
    [(string.is-string-prefix-at name query 0) 1]
    [(string.contains name query) 2]
    [else -1]))

(define (lsp-workspace-symbol-candidate-less?
  [left : LspWorkspaceSymbolCandidate]
  [right : LspWorkspaceSymbolCandidate]) : bool
  (let
    [left-row : lsp_vector_families.LspWorkspaceDeclRow left.row]
    [right-row : lsp_vector_families.LspWorkspaceDeclRow right.row]
    [left-decl : lsp_vector_families.LspDeclEntry left-row.decl]
    [right-decl : lsp_vector_families.LspDeclEntry right-row.decl]
    [left-name : String left-decl.name]
    [right-name : String right-decl.name]
    [left-container : String left-row.module]
    [right-container : String right-row.module]
    [left-uri : String left-row.uri]
    [right-uri : String right-row.uri]
    (cond
      [(< left.rank right.rank) true]
      [(> left.rank right.rank) false]
      [(not (string.eq left-name right-name))
        (package_source_core.package-source-string-less? left-name right-name)]
      [(not (string.eq left-container right-container))
        (package_source_core.package-source-string-less?
          left-container
          right-container)]
      [(not (string.eq left-uri right-uri))
        (package_source_core.package-source-string-less? left-uri right-uri)]
      [(< left-decl.name-line right-decl.name-line) true]
      [(> left-decl.name-line right-decl.name-line) false]
      [else (< left-decl.name-col right-decl.name-col)])))

;; A source range is the stable editable identity. Overlapping workspace roots
;; are already URI-deduplicated by the index, and this final guard also keeps a
;; malformed duplicate summary from producing two protocol results.
(define (lsp-workspace-symbol-candidate-same?
  [left : (& left LspWorkspaceSymbolCandidate)]
  [right : LspWorkspaceSymbolCandidate]) : bool
  (let
    [left-row : lsp_vector_families.LspWorkspaceDeclRow left.row]
    [right-row : lsp_vector_families.LspWorkspaceDeclRow right.row]
    [left-decl : lsp_vector_families.LspDeclEntry left-row.decl]
    [right-decl : lsp_vector_families.LspDeclEntry right-row.decl]
    (and
      (string.eq left-row.uri right-row.uri)
      (string.eq left-decl.name right-decl.name)
      (= left-decl.name-line right-decl.name-line)
      (= left-decl.name-col right-decl.name-col))))

(define (lsp-workspace-symbol-results-contain?
  [results : (& results LspWorkspaceSymbolResults)]
  [candidate : (& candidate LspWorkspaceSymbolCandidate)]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (< index results.len) (not found))
        (begin
          (if (lsp-workspace-symbol-candidate-same?
            candidate
            (lsp-workspace-symbol-results-get results index))
            (set! found true)
            unit)
          (set! index (+ index 1))))
      found)))

;; Insert into the sorted live prefix and retain only the best 256 candidates.
;; Since the cap is fixed by the protocol contract, this remains linear in the
;; number of indexed declarations and uses constant request-local storage.
(define (lsp-workspace-symbol-results-insert!
  [results : (&mut results LspWorkspaceSymbolResults)]
  [candidate : LspWorkspaceSymbolCandidate]) : unit
  (if (lsp-workspace-symbol-results-contain? results candidate)
    unit
    (let
      [len : i64 results.len]
      [position : i64 0]
      (begin
        (while (and
          (< position len)
          (not
            (lsp-workspace-symbol-candidate-less?
              (owned_view.compiler-owned-shared-view candidate)
              (lsp-workspace-symbol-results-get results position))))
          (set! position (+ position 1)))
        (if (>= position lsp-workspace-symbol-result-limit)
          unit
          (let
            [write : i64
              (if (< len lsp-workspace-symbol-result-limit)
                len
                (- lsp-workspace-symbol-result-limit 1))]
            (begin
              (while (> write position)
                (begin
                  (set!
                    (array-ref results.slots write)
                    (array-ref results.slots (- write 1)))
                  (set! write (- write 1))))
              (set! (array-ref results.slots position) candidate)
              (if (< len lsp-workspace-symbol-result-limit)
                (set! results.len (+ len 1))
                unit))))))))

(define (lsp-workspace-symbol-query
  [index : (& index lsp_vector_families.LspWorkspaceIndex)]
  [query : String]) : LspWorkspaceSymbolResults
  (let
    [results : LspWorkspaceSymbolResults (lsp-workspace-symbol-results-new)]
    [source-index : i64 0]
    [sources : lsp_vector_families.LspWorkspaceSources index.sources]
    (begin
      (while (< source-index (lsp-workspace-sources-len (& sources)))
        (let
          [source : lsp_vector_families.LspWorkspaceSource
            (lsp-workspace-sources-get (& sources) source-index)]
          [decls : lsp_decl_vec.Vec source.decls]
          [decl-index : i64 0]
          (begin
            (while (< decl-index (lsp_decl_vec.len (& decls)))
              (let
                [decl : lsp_vector_families.LspDeclEntry
                  (lsp_decl_vec.get
                    (& decls)
                    decl-index
                    (lsp-decl-entry-fallback))]
                [rank : i64 (lsp-workspace-symbol-match-rank decl.name query)]
                (begin
                  (if (>= rank 0)
                    (lsp-workspace-symbol-results-insert!
                      (&mut results)
                      (LspWorkspaceSymbolCandidate
                        rank
                        (lsp_vector_families.LspWorkspaceDeclRow
                          source.root-uri
                          source.root-path
                          source.uri
                          source.path
                          source.module
                          source.explicit-module
                          source.overlay
                          decl)))
                    unit)
                  (set! decl-index (+ decl-index 1)))))
            (set! source-index (+ source-index 1)))))
      results)))

(define (lsp-workspace-index-refresh-path!
  [index : (&mut index lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [path : String]
  [deleted : bool]) : unit
  (let
    [normalized : String (lsp-normalized-absolute-path path)]
    [uri : String
      (lsp-path-to-file-uri (owned_view.compiler-owned-shared-view normalized))]
    [existing : i64 (lsp-workspace-sources-find-uri (& index.sources) uri)]
    [doc-index : i64 (lsp-documents-find-path-index (& docs) normalized)]
    (if (>= doc-index 0)
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp_document_vec.get (& docs) doc-index (lsp-document-fallback))]
        [root : lsp_vector_families.LspWorkspaceRootLookup
          (lsp-workspace-root-for-path (& index.roots) normalized false)]
        (lsp-workspace-index-set-text-source!
          index
          root
          normalized
          doc.text
          true))
      (if deleted
        (if (>= existing 0)
          (lsp-workspace-sources-remove-index! (&mut index.sources) existing)
          unit)
        (match (lsp-workspace-root-for-path (& index.roots) normalized true)
          [(Missing)
            (if (>= existing 0)
              (lsp-workspace-sources-remove-index!
                (&mut index.sources)
                existing)
              unit)]
          [(Found root)
            (match (io.try-read-file (& normalized))
              [(OkIoBytes contents)
                (let
                  [text : String (byte_buf.to-string contents)]
                  (lsp-workspace-index-set-text-source!
                    index
                    (Found root)
                    normalized
                    text
                    false))]
              [(ErrIoBytes _)
                (if (>= existing 0)
                  (lsp-workspace-sources-remove-index!
                    (&mut index.sources)
                    existing)
                  unit)])])))))

(define (lsp-workspace-index-refresh-documents!
  [index : (&mut index lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]) : unit
  (let
    [doc-index : i64 0]
    (while (< doc-index (lsp_document_vec.len (& docs)))
      (let
        [doc : lsp_vector_families.LspDocument
          (lsp_document_vec.get (& docs) doc-index (lsp-document-fallback))]
        (begin
          (if (> (string.string-length doc.path) 0)
            (lsp-workspace-index-refresh-path! index docs doc.path false)
            unit)
          (set! doc-index (+ doc-index 1)))))))

(define (lsp-server-state-refresh-document-result
  [state : lsp_vector_families.LspServerState]
  [result : LspDocumentHandleResult]
  [uri : String]
  [deleted : bool]) : LspHandleResult
  (match result
    [(Continue next-documents)
      (match (lsp-file-uri-to-path uri)
        [(Err _) (Continue state)]
        [(Ok path)
          (let
            [previous : i64 (arena.tl_arena_current)]
            [owner : i64 (arena.tl_arena_make)]
            [_install : unit
              (unsafe
                (arena.tl_arena_set owner))]
            [docs : lsp_document_vec.Vec (lsp-documents-copy next-documents)]
            [workspace : lsp_vector_families.LspWorkspaceIndex
              (lsp-workspace-index-copy state.workspace)]
            [semantic-cache : lsp_vector_families.LspWorkspaceSemanticCache
              (lsp-workspace-semantic-cache-copy state.semantic-cache)]
            [_refresh : unit
              (lsp-workspace-index-refresh-path!
                (&mut workspace)
                docs
                (owned_view.compiler-owned-shared-view path)
                deleted)]
            [_invalidate : unit
              (lsp-workspace-semantic-cache-invalidate-path!
                (&mut semantic-cache)
                path)]
            [draft : lsp_vector_families.LspServerState
              (lsp_vector_families.LspServerState
                0
                docs
                workspace
                semantic-cache)]
            (Continue (lsp-server-state-finish-swap state draft owner previous)))])]
    [(Exit next-documents)
      (match (lsp-server-state-refresh-document-result
        state
        (LspDocumentHandleResult.Continue next-documents)
        uri
        deleted)
        [(Continue next) (Exit next)]
        [(Exit next) (Exit next)])]))

(define (lsp-server-state-copy-document-result
  [state : lsp_vector_families.LspServerState]
  [result : LspDocumentHandleResult]
  [refresh-documents : bool]) : LspHandleResult
  (match result
    [(Continue next-documents)
      (let
        [previous : i64 (arena.tl_arena_current)]
        [owner : i64 (arena.tl_arena_make)]
        [_install : unit
          (unsafe
            (arena.tl_arena_set owner))]
        [docs : lsp_document_vec.Vec (lsp-documents-copy next-documents)]
        [workspace : lsp_vector_families.LspWorkspaceIndex
          (lsp-workspace-index-copy state.workspace)]
        [semantic-cache : lsp_vector_families.LspWorkspaceSemanticCache
          (lsp-workspace-semantic-cache-copy state.semantic-cache)]
        [_refresh : unit
          (if refresh-documents
            (lsp-workspace-index-refresh-documents! (&mut workspace) docs)
            unit)]
        [_invalidate : unit
          (if refresh-documents
            (lsp-workspace-semantic-cache-release-all! (&mut semantic-cache))
            unit)]
        [draft : lsp_vector_families.LspServerState
          (lsp_vector_families.LspServerState 0 docs workspace semantic-cache)]
        (Continue (lsp-server-state-finish-swap state draft owner previous)))]
    [(Exit next-documents)
      (match (lsp-server-state-copy-document-result
        state
        (LspDocumentHandleResult.Continue next-documents)
        refresh-documents)
        [(Continue next) (Exit next)]
        [(Exit next) (Exit next)])]))

(define (lsp-watched-files-refresh-items!
  [workspace : (&mut workspace lsp_vector_families.LspWorkspaceIndex)]
  [semantic-cache
    : (&mut semantic-cache lsp_vector_families.LspWorkspaceSemanticCache)]
  [docs : (& docs lsp_document_vec.Vec)]
  [items : json.JsonSeq]) : unit
  (let
    [index : i64 0]
    [count : i64
      (json.list-count (owned_view.compiler-owned-shared-view items))]
    (while (< index count)
      (begin
        (match (json.list-get-index
          (owned_view.compiler-owned-shared-view items)
          index)
          [(JsonMissing) unit]
          [(JsonFound change)
            (match (lsp-json-string-field change "uri")
              [(Missing) unit]
              [(Ok uri)
                (match (lsp-file-uri-to-path uri)
                  [(Err _) unit]
                  [(Ok path)
                    (if (string.eq (fs.extension (& path)) "tl")
                      (begin
                        (lsp-workspace-semantic-cache-invalidate-path!
                          semantic-cache
                          (owned_view.compiler-owned-shared-view path))
                        (lsp-workspace-index-refresh-path!
                          workspace
                          docs
                          path
                          (= (lsp-json-int-field-default change "type" 2) 3)))
                      unit)])])])
        (set! index (+ index 1))))))

(define (lsp-server-state-did-change-watched-files
  [state : (& state lsp_vector_families.LspServerState)]
  [params : json.Json]) : lsp_vector_families.LspServerState
  (let
    [previous : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make)]
    [_install : unit
      (unsafe
        (arena.tl_arena_set owner))]
    [draft : lsp_vector_families.LspServerState
      (lsp-server-state-copy-in-current state)]
    [changes-key : String "changes"]
    [_refresh : unit
      (match (json.object-get params (& changes-key))
        [(JsonMissing) unit]
        [(JsonFound changes)
          (match changes
            [(JsonArray items)
              (lsp-watched-files-refresh-items!
                (&mut draft.workspace)
                (&mut draft.semantic-cache)
                draft.documents
                (deref items))]
            [_ unit])])]
    (lsp-server-state-finish-swap state draft owner previous)))

(define (lsp-workspace-index-remove-root-uri!
  [workspace : (&mut workspace lsp_vector_families.LspWorkspaceIndex)]
  [uri : String]) : unit
  (let
    [root-index : i64
      (lsp-workspace-roots-find-uri
        (& workspace.roots)
        (owned_view.compiler-owned-shared-view uri))]
    (if (< root-index 0)
      unit
      (begin
        (lsp-workspace-roots-remove-index! (&mut workspace.roots) root-index)
        (let
          [source-index : i64 0]
          (while (<
            source-index
            (lsp-workspace-sources-len (& workspace.sources)))
            (let
              [source : lsp_vector_families.LspWorkspaceSource
                (lsp-workspace-sources-get (& workspace.sources) source-index)]
              (if (string.eq source.root-uri uri)
                (lsp-workspace-sources-remove-index!
                  (&mut workspace.sources)
                  source-index)
                (set! source-index (+ source-index 1))))))))))

(define (lsp-workspace-index-recover-live-paths!
  [workspace : (&mut workspace lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [paths : lsp_svec.Vec]) : unit
  (let
    [index : i64 0]
    (while (< index (lsp_svec.len (& paths)))
      (begin
        (lsp-workspace-index-refresh-path!
          workspace
          docs
          (lsp_svec.get (& paths) index "")
          false)
        (set! index (+ index 1))))))

(define (lsp-workspace-index-remove-root!
  [workspace : (&mut workspace lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [root : lsp_vector_families.LspWorkspaceRoot]) : unit
  (let
    [paths : lsp_svec.Vec (lsp_svec.new)]
    [source-index : i64 0]
    (begin
      (while (< source-index (lsp-workspace-sources-len (& workspace.sources)))
        (let
          [source : lsp_vector_families.LspWorkspaceSource
            (lsp-workspace-sources-get (& workspace.sources) source-index)]
          (begin
            (if (string.eq source.root-uri root.uri)
              (lsp_svec.push-ref! (&mut paths) (string.copy (& source.path)))
              unit)
            (set! source-index (+ source-index 1)))))
      (lsp-workspace-index-remove-root-uri! workspace root.uri)
      ;; Only paths whose owning root disappeared are reconsidered. They may
      ;; transfer to an overlapping remaining root, remain as open rootless
      ;; overlays, or disappear.
      (lsp-workspace-index-recover-live-paths! workspace docs paths))))

(define (lsp-workspace-index-adopt-rootless-overlays!
  [workspace : (&mut workspace lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [root : (& root lsp_vector_families.LspWorkspaceRoot)]) : unit
  (let
    [paths : lsp_svec.Vec (lsp_svec.new)]
    [source-index : i64 0]
    (begin
      (while (< source-index (lsp-workspace-sources-len (& workspace.sources)))
        (let
          [source : lsp_vector_families.LspWorkspaceSource
            (lsp-workspace-sources-get (& workspace.sources) source-index)]
          (begin
            (if (and
              (string.eq source.root-uri "")
              (package_source_core.package-source-path-location-eligible-for-root?
                root.path
                source.path))
              (lsp_svec.push-ref! (&mut paths) (string.copy (& source.path)))
              unit)
            (set! source-index (+ source-index 1)))))
      (lsp-workspace-index-recover-live-paths! workspace docs paths))))

(define (lsp-workspace-index-add-root!
  [workspace : (&mut workspace lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [root : lsp_vector_families.LspWorkspaceRoot]) : unit
  (if (>=
    (lsp-workspace-roots-find-uri
      (& workspace.roots)
      (owned_view.compiler-owned-shared-view root.uri))
    0)
    unit
    (begin
      (lsp-workspace-roots-push!
        (&mut workspace.roots)
        (owned_view.compiler-owned-shared-view root))
      (lsp-workspace-index-adopt-rootless-overlays! workspace docs root)
      ;; Discover only the added root. URI de-duplication preserves the first
      ;; root in client order when roots overlap.
      (lsp-workspace-index-build-root! workspace docs root))))

(define (lsp-workspace-folders-remove-items!
  [workspace : (&mut workspace lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [items : json.JsonSeq]) : unit
  (let
    [index : i64 0]
    [count : i64
      (json.list-count (owned_view.compiler-owned-shared-view items))]
    (while (< index count)
      (begin
        (match (json.list-get-index
          (owned_view.compiler-owned-shared-view items)
          index)
          [(JsonMissing) unit]
          [(JsonFound folder)
            (match (lsp-json-string-field folder "uri")
              [(Missing) unit]
              [(Ok uri)
                (match (lsp-workspace-root-from-uri uri)
                  [(Missing) unit]
                  [(Found root)
                    (lsp-workspace-index-remove-root! workspace docs root)])])])
        (set! index (+ index 1))))))

(define (lsp-workspace-folders-add-items!
  [workspace : (&mut workspace lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [items : json.JsonSeq]) : unit
  (let
    [index : i64 0]
    [count : i64
      (json.list-count (owned_view.compiler-owned-shared-view items))]
    (while (< index count)
      (begin
        (match (json.list-get-index
          (owned_view.compiler-owned-shared-view items)
          index)
          [(JsonMissing) unit]
          [(JsonFound folder)
            (match (lsp-json-string-field folder "uri")
              [(Missing) unit]
              [(Ok uri)
                (match (lsp-workspace-root-from-uri uri)
                  [(Missing) unit]
                  [(Found root)
                    (lsp-workspace-index-add-root! workspace docs root)])])])
        (set! index (+ index 1))))))

(define (lsp-workspace-folders-apply-event!
  [workspace : (&mut workspace lsp_vector_families.LspWorkspaceIndex)]
  [docs : (& docs lsp_document_vec.Vec)]
  [event : json.Json]) : unit
  (let
    [removed-key : String "removed"]
    [added-key : String "added"]
    (begin
      (match (json.object-get
        (owned_view.compiler-owned-shared-view event)
        (& removed-key))
        [(JsonMissing) unit]
        [(JsonFound removed)
          (match removed
            [(JsonArray items)
              (lsp-workspace-folders-remove-items! workspace docs (deref items))]
            [_ unit])])
      (match (json.object-get event (& added-key))
        [(JsonMissing) unit]
        [(JsonFound added)
          (match added
            [(JsonArray items)
              (lsp-workspace-folders-add-items! workspace docs (deref items))]
            [_ unit])]))))

(define (lsp-server-state-did-change-workspace-folders
  [state : (& state lsp_vector_families.LspServerState)]
  [params : json.Json]) : lsp_vector_families.LspServerState
  (let
    [previous : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make)]
    [_install : unit
      (unsafe
        (arena.tl_arena_set owner))]
    [draft : lsp_vector_families.LspServerState
      (lsp-server-state-copy-in-current state)]
    [event-key : String "event"]
    [_update : unit
      (match (json.object-get params (& event-key))
        [(JsonMissing) unit]
        [(JsonFound event)
          (lsp-workspace-folders-apply-event!
            (&mut draft.workspace)
            draft.documents
            event)])]
    [_invalidate : unit
      (lsp-workspace-semantic-cache-release-all! (&mut draft.semantic-cache))]
    (lsp-server-state-finish-swap state draft owner previous)))

;; Helper: extract document from params
(define (lsp-get-document [params : json.Json] [docs : lsp_document_vec.Vec]) : LspDocumentLookup
  (let
    [key : String "textDocument"]
    (match (json.object-get params (& key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Ok uri) (lsp-documents-lookup-resynced docs uri)]
          [(Missing) Missing])]
      [(JsonMissing) Missing])))

(define (lsp-get-semantic-document
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspSemanticDocumentLookup
  (let
    [key : String "textDocument"]
    (match (json.object-get params (& key))
      [(JsonMissing) Missing]
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Missing) Missing]
          [(Ok uri)
            (let
              [index : i64 (lsp-documents-find-index docs uri)]
              (if (>= index 0)
                (Found (lsp-document-refresh-from-disk docs index))
                Missing))])])))

;; --------------------------------------------------------------------------
;; Full semantic tokens (textDocument/semanticTokens/full).
;;
;; Lexical candidates come from the formatter's recovering, comment-preserving
;; lexer over the authoritative current text. Exact records are overlaid only
;; from a current document-owned semantic snapshot. A fixed-pass radix sort
;; keeps construction linear in source tokens plus semantic records without a
;; generated collection family or per-token source rescans.
;; --------------------------------------------------------------------------
(define lsp-semantic-token-type-namespace : i64
  0)
(define lsp-semantic-token-type-type : i64
  1)
(define lsp-semantic-token-type-enum-member : i64
  2)
(define lsp-semantic-token-type-function : i64
  3)
(define lsp-semantic-token-type-macro : i64
  4)
(define lsp-semantic-token-type-parameter : i64
  5)
(define lsp-semantic-token-type-variable : i64
  6)
(define lsp-semantic-token-type-property : i64
  7)
(define lsp-semantic-token-type-keyword : i64
  8)
(define lsp-semantic-token-type-comment : i64
  9)
(define lsp-semantic-token-type-string : i64
  10)
(define lsp-semantic-token-type-number : i64
  11)
(define lsp-semantic-token-type-operator : i64
  12)
(define lsp-semantic-token-modifier-declaration : i64
  1)
(define lsp-semantic-token-modifier-definition : i64
  2)

(define (lsp-semantic-token-candidates-new) : LspSemanticTokenCandidates
  (LspSemanticTokenCandidates (__tl_make-array LspSemanticTokenCandidate 32) 0))

(define (lsp-semantic-token-candidate-copy-one!
  [dst : (&mut dst (__tl_dyn-array LspSemanticTokenCandidate))]
  [dst-index : i64]
  [src : (& src (__tl_dyn-array LspSemanticTokenCandidate))]
  [src-index : i64]) : unit
  (set! (array-ref dst dst-index) (array-ref src src-index)))

(define (lsp-semantic-token-candidate-copy-range!
  [dst : (&mut dst (__tl_dyn-array LspSemanticTokenCandidate))]
  [src : (& src (__tl_dyn-array LspSemanticTokenCandidate))]
  [index : i64]
  [count : i64]) : unit
  (if (< index count)
    (begin
      (lsp-semantic-token-candidate-copy-one! dst index src index)
      (lsp-semantic-token-candidate-copy-range! dst src (+ index 1) count))
    unit))

(define (lsp-semantic-token-candidates-grow!
  [tokens : (&mut tokens LspSemanticTokenCandidates)]) : unit
  (let
    [old-cap : i64 (array-length tokens.slots)]
    [new-cap : i64
      (if (< old-cap 32)
        32
        (* old-cap 2))]
    [bigger : (__tl_dyn-array LspSemanticTokenCandidate)
      (__tl_make-array LspSemanticTokenCandidate new-cap)]
    (begin
      (lsp-semantic-token-candidate-copy-range!
        (&mut bigger)
        (& tokens.slots)
        0
        tokens.len)
      (set! tokens.slots bigger))))

(define (lsp-semantic-token-candidates-push!
  [tokens : (&mut tokens LspSemanticTokenCandidates)]
  [candidate : LspSemanticTokenCandidate]) : unit
  (begin
    (if (>= tokens.len (array-length tokens.slots))
      (lsp-semantic-token-candidates-grow! tokens)
      unit)
    (set! (array-ref tokens.slots tokens.len) candidate)
    (set! tokens.len (+ tokens.len 1))))

;; LSP semantic tokens cannot cross a line. CR is excluded from a CRLF line
;; segment even though byte offsets continue through both terminator bytes.
(define (lsp-semantic-token-add-split-span!
  [tokens : (&mut tokens LspSemanticTokenCandidates)]
  [text : (& text str)]
  [start : i64]
  [end : i64]
  [token-type : i64]
  [modifiers : i64]
  [priority : i64]) : unit
  (let
    [n : i64 (string.string-length text)]
    [safe-start : i64
      (if (< start 0)
        0
        start)]
    [safe-end : i64
      (if (> end n)
        n
        end)]
    [segment-start : i64 safe-start]
    [index : i64 safe-start]
    (begin
      (while (< index safe-end)
        (if (= (string.string-ref text index) '\n')
          (let
            [segment-end : i64
              (if (and
                (> index segment-start)
                (= (string.string-ref text (- index 1)) '\r'))
                (- index 1)
                index)]
            (begin
              (if (> segment-end segment-start)
                (lsp-semantic-token-candidates-push!
                  tokens
                  (LspSemanticTokenCandidate
                    segment-start
                    segment-end
                    token-type
                    modifiers
                    priority))
                unit)
              (set! segment-start (+ index 1))
              (set! index (+ index 1))))
          (set! index (+ index 1))))
      (let
        [final-end : i64
          (if (and
            (> safe-end segment-start)
            (< safe-end n)
            (= (string.string-ref text safe-end) '\n')
            (= (string.string-ref text (- safe-end 1)) '\r'))
            (- safe-end 1)
            safe-end)]
        (if (> final-end segment-start)
          (lsp-semantic-token-candidates-push!
            tokens
            (LspSemanticTokenCandidate
              segment-start
              final-end
              token-type
              modifiers
              priority))
          unit)))))

(define (lsp-semantic-token-keyword? [name : (& name str)]) : bool
  (lsp-rename-space-list-contains?
    "define lambda let if begin while break continue set! return match foreach cond when unless and or with-arena with-escape with-scratch in-arena try unsafe quote quasiquote unquote ann init cast type defstruct defenum defmacro defdispatch import export extern module comptime include-str include-bin test cfg spmd-reduce spmd-scan spmd-broadcast spmd-shuffle program-index program-count else"
    name))

(define (lsp-semantic-token-operator? [name : (& name str)]) : bool
  (lsp-rename-space-list-contains?
    "+ - * / % = != < <= > >= neg bit-and bit-or bit-xor bit-not shl shr"
    name))

(define (lsp-semantic-token-add-lexical!
  [tokens : (&mut tokens LspSemanticTokenCandidates)]
  [text : String]) : unit
  (let
    [stream : format_tokens.FormatTokenStream
      (format_tokens.format-lex-recover
        (owned_view.compiler-owned-shared-view text))]
    [index : i64 0]
    ;; 0 is an ordinary datum, 1 is a parenthesized form head, and 2 is the
    ;; first datum in a bracket arm. Brackets also introduce parameters and let
    ;; bindings, so only `else` is a keyword in their head position.
    [head-position : i64 0]
    (begin
      (while (< index (format_tokens.format-token-count stream))
        (let
          [start : i64 (format_tokens.format-token-start stream index)]
          [tok : format_tokens.FormatToken
            (format_tokens.format-token-at stream index)]
          (begin
            (match tok
              [(LParen) (set! head-position 1)]
              [(LBracket) (set! head-position 2)]
              [(Comment spelling)
                (lsp-semantic-token-add-split-span!
                  tokens
                  text
                  start
                  (+ start (string.string-length spelling))
                  lsp-semantic-token-type-comment
                  0
                  1)]
              [(String spelling)
                (begin
                  (lsp-semantic-token-add-split-span!
                    tokens
                    text
                    start
                    (+ start (string.string-length spelling))
                    lsp-semantic-token-type-string
                    0
                    1)
                  (set! head-position 0))]
              [(Char spelling)
                (begin
                  (lsp-semantic-token-add-split-span!
                    tokens
                    text
                    start
                    (+ start (string.string-length spelling))
                    lsp-semantic-token-type-string
                    0
                    1)
                  (set! head-position 0))]
              [(Int spelling)
                (begin
                  (lsp-semantic-token-add-split-span!
                    tokens
                    text
                    start
                    (+ start (string.string-length spelling))
                    lsp-semantic-token-type-number
                    0
                    1)
                  (set! head-position 0))]
              [(Symbol spelling)
                (begin
                  (if (= head-position 1)
                    (cond
                      [(lsp-semantic-token-keyword? spelling)
                        (lsp-semantic-token-add-split-span!
                          tokens
                          text
                          start
                          (+ start (string.string-length spelling))
                          lsp-semantic-token-type-keyword
                          0
                          0)]
                      [(lsp-semantic-token-operator? spelling)
                        (lsp-semantic-token-add-split-span!
                          tokens
                          text
                          start
                          (+ start (string.string-length spelling))
                          lsp-semantic-token-type-operator
                          0
                          0)]
                      [else unit])
                    (if (and (= head-position 2) (string.eq spelling "else"))
                      (lsp-semantic-token-add-split-span!
                        tokens
                        text
                        start
                        (+ start (string.string-length spelling))
                        lsp-semantic-token-type-keyword
                        0
                        0)
                      unit))
                  (set! head-position 0))]
              [(End) unit]
              [_ (set! head-position 0)])
            (set! index (+ index 1)))))
      unit)))

(define (lsp-semantic-token-type-for-kind
  [kind : compiler_semantic_index.CompilerSemanticSymbolKind]) : i64
  (match kind
    [(Module) lsp-semantic-token-type-namespace]
    [(Struct) lsp-semantic-token-type-type]
    [(Enum) lsp-semantic-token-type-type]
    [(EnumMember) lsp-semantic-token-type-enum-member]
    [(Function) lsp-semantic-token-type-function]
    [(ExternFunction) lsp-semantic-token-type-function]
    [(Macro) lsp-semantic-token-type-macro]
    [(Parameter) lsp-semantic-token-type-parameter]
    [(Field) lsp-semantic-token-type-property]
    [_ lsp-semantic-token-type-variable]))

(define (lsp-semantic-token-modifiers-for-record
  [record : compiler_semantic_index.CompilerSemanticRecord]) : i64
  (match record.role
    [(Use) 0]
    [(Definition)
      (match record.kind
        [(ExternValue) lsp-semantic-token-modifier-declaration]
        [(ExternFunction) lsp-semantic-token-modifier-declaration]
        [_ lsp-semantic-token-modifier-definition])]))

(define (lsp-semantic-token-add-records!
  [tokens : (&mut tokens LspSemanticTokenCandidates)]
  [doc : (& doc lsp_vector_families.LspDocument)]) : unit
  (match (lsp-document-semantic-snapshot-status doc)
    [(Current _ _)
      (let
        [index : compiler_semantic_index.CompilerSemanticSourceIndex
          doc.semantic.index]
        [source-text : String (string.copy (& doc.text))]
        [record-index : i64 0]
        (while (<
          record-index
          (compiler_semantic_index.compiler-semantic-source-index-len (& index)))
          (let
            [record : compiler_semantic_index.CompilerSemanticRecord
              (compiler_semantic_index.compiler-semantic-source-index-get
                (& index)
                record-index)]
            [span : compiler_semantic_index.CompilerSemanticSpan
              (lsp-rename-effective-span
                (owned_view.compiler-owned-shared-view record.span)
                record.display-name
                source-text)]
            [source : ast.AstSourceSpan span.source]
            [exact-editable? : bool
              (lsp-semantic-record-exact-editable? (& record))]
            [path-match? : bool (string.eq span.path doc.path)]
            [single-line? : bool
              (=
                (ast.ast-source-span-start-line source)
                (ast.ast-source-span-end-line source))]
            (begin
              (if (and
                exact-editable?
                path-match?
                (>= span.start-byte 0)
                (> span.end-byte span.start-byte)
                (<= span.end-byte (string.string-length source-text))
                single-line?)
                (lsp-semantic-token-candidates-push!
                  tokens
                  (LspSemanticTokenCandidate
                    span.start-byte
                    span.end-byte
                    (lsp-semantic-token-type-for-kind record.kind)
                    (lsp-semantic-token-modifiers-for-record record)
                    3))
                unit)
              (set! record-index (+ record-index 1))))))]
    [_ unit]))

(define (lsp-semantic-token-radix-copy-back!
  [tokens : (&mut tokens LspSemanticTokenCandidates)]
  [scratch : (& scratch (__tl_dyn-array LspSemanticTokenCandidate))]) : unit
  (lsp-semantic-token-candidate-copy-range!
    (&mut tokens.slots)
    scratch
    0
    tokens.len))

(define (lsp-semantic-token-sort!
  [tokens : (&mut tokens LspSemanticTokenCandidates)]) : unit
  (let
    [scratch : (__tl_dyn-array LspSemanticTokenCandidate)
      (__tl_make-array LspSemanticTokenCandidate tokens.len)]
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 256)]
    [index : i64 0]
    [sum : i64 0]
    [pass : i64 0]
    (begin
      ;; Stable secondary key: larger priority comes first at an equal start.
      (while (< index tokens.len)
        (let
          [key : i64 (- 3 (array-ref tokens.slots index).priority)]
          (begin
            (set! (array-ref counts key) (+ (array-ref counts key) 1))
            (set! index (+ index 1)))))
      (set! index 0)
      (set! sum 0)
      (while (< index 4)
        (let
          [count : i64 (array-ref counts index)]
          (begin
            (set! (array-ref counts index) sum)
            (set! sum (+ sum count))
            (set! index (+ index 1)))))
      (set! index 0)
      (while (< index tokens.len)
        (let
          [candidate : LspSemanticTokenCandidate (array-ref tokens.slots index)]
          [key : i64 (- 3 candidate.priority)]
          [out : i64 (array-ref counts key)]
          (begin
            (lsp-semantic-token-candidate-copy-one!
              (&mut scratch)
              out
              (& tokens.slots)
              index)
            (set! (array-ref counts key) (+ out 1))
            (set! index (+ index 1)))))
      (lsp-semantic-token-radix-copy-back! tokens (& scratch))
      ;; Stable primary key: non-negative byte start, least-significant byte
      ;; first. Eight fixed passes preserve linear complexity on i64 targets.
      (while (< pass 8)
        (begin
          (set! index 0)
          (while (< index 256)
            (begin
              (set! (array-ref counts index) 0)
              (set! index (+ index 1))))
          (set! index 0)
          (while (< index tokens.len)
            (let
              [candidate : LspSemanticTokenCandidate
                (array-ref tokens.slots index)]
              [key : i64 (bit-and (shr candidate.start-byte (* pass 8)) 255)]
              (begin
                (set! (array-ref counts key) (+ (array-ref counts key) 1))
                (set! index (+ index 1)))))
          (set! index 0)
          (set! sum 0)
          (while (< index 256)
            (let
              [count : i64 (array-ref counts index)]
              (begin
                (set! (array-ref counts index) sum)
                (set! sum (+ sum count))
                (set! index (+ index 1)))))
          (set! index 0)
          (while (< index tokens.len)
            (let
              [candidate : LspSemanticTokenCandidate
                (array-ref tokens.slots index)]
              [key : i64 (bit-and (shr candidate.start-byte (* pass 8)) 255)]
              [out : i64 (array-ref counts key)]
              (begin
                (lsp-semantic-token-candidate-copy-one!
                  (&mut scratch)
                  out
                  (& tokens.slots)
                  index)
                (set! (array-ref counts key) (+ out 1))
                (set! index (+ index 1)))))
          (lsp-semantic-token-radix-copy-back! tokens (& scratch))
          (set! pass (+ pass 1)))))))

(define (lsp-semantic-tokens-for-document
  [doc : (& doc lsp_vector_families.LspDocument)]) : json.Json
  (let
    [source-text : String (string.copy (& doc.text))]
    [tokens : LspSemanticTokenCandidates (lsp-semantic-token-candidates-new)]
    [_lexical : unit
      (lsp-semantic-token-add-lexical!
        (&mut tokens)
        (owned_view.compiler-owned-shared-view source-text))]
    [_semantic : unit (lsp-semantic-token-add-records! (&mut tokens) doc)]
    [_sort : unit (lsp-semantic-token-sort! (&mut tokens))]
    [encoded : (__tl_dyn-array json.Json)
      (__tl_make-array json.Json (* tokens.len 5))]
    [cache : LspLineColCache (LspLineColCache -1 1 1)]
    [candidate-index : i64 0]
    [encoded-len : i64 0]
    [last-end : i64 -1]
    [previous-line : i64 0]
    [previous-start : i64 0]
    (begin
      (while (< candidate-index tokens.len)
        (let
          [candidate : LspSemanticTokenCandidate
            (array-ref tokens.slots candidate-index)]
          (begin
            (if (>= candidate.start-byte last-end)
              (let
                [start : LspLineCol
                  (lsp-line-col-cache-at-offset!
                    (&mut cache)
                    source-text
                    candidate.start-byte)]
                [end : LspLineCol
                  (lsp-line-col-cache-at-offset!
                    (&mut cache)
                    source-text
                    candidate.end-byte)]
                [line : i64 (- start.line 1)]
                [start-character : i64 (- start.col 1)]
                [length : i64 (- end.col start.col)]
                [delta-line : i64 (- line previous-line)]
                [delta-start : i64
                  (if (= delta-line 0)
                    (- start-character previous-start)
                    start-character)]
                (if (and (= start.line end.line) (> length 0))
                  (begin
                    (set!
                      (array-ref encoded encoded-len)
                      (lsp-json-number delta-line))
                    (set!
                      (array-ref encoded (+ encoded-len 1))
                      (lsp-json-number delta-start))
                    (set!
                      (array-ref encoded (+ encoded-len 2))
                      (lsp-json-number length))
                    (set!
                      (array-ref encoded (+ encoded-len 3))
                      (lsp-json-number candidate.token-type))
                    (set!
                      (array-ref encoded (+ encoded-len 4))
                      (lsp-json-number candidate.modifiers))
                    (set! encoded-len (+ encoded-len 5))
                    (set! previous-line line)
                    (set! previous-start start-character)
                    (set! last-end candidate.end-byte))
                  unit))
              unit)
            (set! candidate-index (+ candidate-index 1)))))
      (lsp-json-object1
        "data"
        (lsp-json-array (json.JsonSeq encoded encoded-len))))))

(define (lsp-handle-semantic-tokens-with-params!
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : unit
  (match (lsp-get-semantic-document params docs)
    [(Found doc)
      (lsp-write-response id (lsp-semantic-tokens-for-document (& doc)))]
    [(Missing) (lsp-write-response id JsonNull)]))

(define (lsp-get-document-decls
  [params : (& params json.Json)]
  [docs : (& docs lsp_document_vec.Vec)]) : LspDocumentDeclsLookup
  (let
    [params : json.Json
      (owned_view.compiler-owned-reference-shared-view params)]
    [docs : lsp_document_vec.Vec
      (owned_view.compiler-owned-reference-shared-view docs)]
    [key : String "textDocument"]
    (match (json.object-get params (& key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(Ok uri)
            (let
              [idx : i64 (lsp-documents-find-index docs uri)]
              (if (>= idx 0)
                (let
                  [doc : lsp_vector_families.LspDocument
                    (lsp-document-refresh-from-disk
                      (owned_view.compiler-owned-shared-view docs)
                      idx)]
                  (LspDocumentDeclsLookup.Found
                    doc.path
                    doc.text
                    (owned_view.compiler-owned-shared-view doc.diagnostic-uris)
                    (lsp-document-decls
                      (owned_view.compiler-owned-shared-view doc)
                      docs)))
                Missing))]
          [(Missing) Missing])]
      [(JsonMissing) Missing])))

;; Helper: get cached decls or scan and cache them
(define (lsp-document-decls-cache-on-current-arena
  [doc : lsp_vector_families.LspDocument]
  [docs : lsp_document_vec.Vec]) : lsp_decl_vec.Vec
  (let
    [text : String doc.text]
    [uri : String doc.uri]
    [scanned : lsp_decl_vec.Vec
      (lsp-scan-decls (owned_view.compiler-owned-shared-view text))]
    [slots : (__tl_dyn-array lsp_vector_families.LspDocument) docs.slots]
    [idx : i64 (lsp-documents-find-index docs uri)]
    (begin
      (if (>= idx 0)
        (begin
          (set!
            (array-ref slots idx)
            (lsp_vector_families.LspDocument
              uri
              doc.path
              text
              doc.version
              doc.diagnostic-uris
              (owned_view.compiler-owned-shared-view scanned)
              true
              doc.check-cache
              doc.semantic))
          unit)
        unit)
      scanned)))

(define (lsp-document-decls
  [doc : lsp_vector_families.LspDocument]
  [docs : lsp_document_vec.Vec]) : lsp_decl_vec.Vec
  (let
    [cached : lsp_decl_vec.Vec
      (owned_view.compiler-owned-shared-view doc.decls)]
    (if doc.decls-valid
      cached
      (if (> lsp-document-cache-arena 0)
        (in-arena
          (arena.Arena lsp-document-cache-arena)
          (lsp-document-decls-cache-on-current-arena doc docs))
        (lsp-document-decls-cache-on-current-arena doc docs)))))

;; Helper: build a json.Json array of names from the canonical declaration vector.
(define (lsp-decls-to-name-list [decls : lsp_decl_vec.Vec] [idx : i64]) : json.JsonSeq
  (if (>= idx (lsp_decl_vec.len (& decls)))
    (json.list-empty)
    (let
      [entry : lsp_vector_families.LspDeclEntry
        (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))]
      [name : String entry.name]
      (lsp-json-list-cons
        (JsonString name)
        (lsp-decls-to-name-list decls (+ idx 1))))))

(define (lsp-decl-selection-range-json
  [entry : (& entry lsp_vector_families.LspDeclEntry)]) : json.Json
  (lsp-json-object2
    "start"
    (lsp-position entry.name-line entry.name-col)
    "end"
    (lsp-position entry.name-line (+ entry.name-col entry.name-len))))

(define (lsp-workspace-symbol-information-json
  [candidate : LspWorkspaceSymbolCandidate]) : json.Json
  (let
    [row : lsp_vector_families.LspWorkspaceDeclRow candidate.row]
    [decl : lsp_vector_families.LspDeclEntry row.decl]
    (lsp-json-object4
      "name"
      (JsonString decl.name)
      "kind"
      (lsp-json-number decl.symbol-kind)
      "location"
      (lsp-json-object2
        "uri"
        (JsonString row.uri)
        "range"
        (lsp-decl-selection-range-json decl))
      "containerName"
      (JsonString row.module))))

(define (lsp-workspace-symbol-information-list
  [results : (& results LspWorkspaceSymbolResults)]
  [index : i64]) : json.JsonSeq
  (if (>= index (lsp-workspace-symbol-results-len results))
    (json.list-empty)
    (lsp-json-list-cons
      (lsp-workspace-symbol-information-json
        (lsp-workspace-symbol-results-get results index))
      (lsp-workspace-symbol-information-list results (+ index 1)))))

(define (lsp-workspace-symbol-result-json
  [index : (& index lsp_vector_families.LspWorkspaceIndex)]
  [query : String]) : json.Json
  (let
    [results : LspWorkspaceSymbolResults
      (lsp-workspace-symbol-query index query)]
    (lsp-json-array (lsp-workspace-symbol-information-list (& results) 0))))

(define (lsp-project-search-result-list
  [results : (& results LspWorkspaceSymbolResults)]
  [index : i64]) : json.JsonSeq
  (if (>= index (lsp-workspace-symbol-results-len results))
    (json.list-empty)
    (let
      [candidate : LspWorkspaceSymbolCandidate
        (lsp-workspace-symbol-results-get results index)]
      (if (not (= candidate.rank 0))
        (json.list-empty)
        (let
          [row : lsp_vector_families.LspWorkspaceDeclRow candidate.row]
          [decl : lsp_vector_families.LspDeclEntry row.decl]
          (lsp-json-list-cons
            (lsp-json-object2
              "uri"
              (JsonString row.uri)
              "name"
              (JsonString decl.name))
            (lsp-project-search-result-list results (+ index 1))))))))

(define (lsp-project-search-result-json
  [index : (& index lsp_vector_families.LspWorkspaceIndex)]
  [name : String]) : json.Json
  (let
    [results : LspWorkspaceSymbolResults
      (lsp-workspace-symbol-query index name)]
    (lsp-json-object2
      "success"
      (JsonBool true)
      "results"
      (lsp-json-array (lsp-project-search-result-list (& results) 0)))))

(define (lsp-decl-document-symbol-json
  [entry : lsp_vector_families.LspDeclEntry]) : json.Json
  (lsp-json-object4
    "name"
    (JsonString (owned_view.compiler-owned-shared-view entry.name))
    "kind"
    (lsp-json-number entry.symbol-kind)
    "range"
    (lsp-decl-entry-form-range-json entry)
    "selectionRange"
    (lsp-decl-selection-range-json entry)))

(define (lsp-decls-to-document-symbol-list
  [decls : lsp_decl_vec.Vec]
  [idx : i64]) : json.JsonSeq
  (if (>= idx (lsp_decl_vec.len (& decls)))
    (json.list-empty)
    (let
      [entry : lsp_vector_families.LspDeclEntry
        (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))]
      (lsp-json-list-cons
        (lsp-decl-document-symbol-json entry)
        (lsp-decls-to-document-symbol-list decls (+ idx 1))))))

(define (lsp-document-symbols-json [decls : lsp_decl_vec.Vec]) : json.Json
  (lsp-json-array (lsp-decls-to-document-symbol-list decls 0)))

(define (lsp-handle-document-symbol
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : unit
  (match (lsp-get-document-decls params docs)
    [(Found _ _ _ decls)
      (lsp-write-response id (lsp-document-symbols-json decls))]
    [(Missing) (lsp-write-response id (lsp-json-array (json.list-empty)))]))

(define (lsp-decls-to-position-map-members
  [decls : lsp_decl_vec.Vec]
  [idx : i64]) : json.JsonMemberSeq
  (if (>= idx (lsp_decl_vec.len (& decls)))
    (json.member-list-empty)
    (let
      [entry : lsp_vector_families.LspDeclEntry
        (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))]
      (lsp-json-member
        entry.name
        (lsp-position entry.name-line entry.name-col)
        (lsp-decls-to-position-map-members decls (+ idx 1))))))

(define (lsp-position-map-for-text [text : String]) : json.Json
  (lsp-json-object (lsp-decls-to-position-map-members (lsp-scan-decls text) 0)))

;; Helper: replace text from (sl,sc) to (el,ec) with new-text
;; Positions are 1-based (from scanner), convert to 0-based for offset-at-position
(define (lsp-edit-range-at-offset
  [text : String]
  [start-off : i64]
  [end-off : i64]
  [new-text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    [new-len : i64 (string.string-length new-text)]
    [removed-len : i64 (- end-off start-off)]
    [capacity : i64 (+ (- n removed-len) new-len)]
    [buf : byte_buf.ByteBuf (byte_buf.with-capacity capacity)]
    (begin
      (set!
        buf
        (byte_buf.append-string-range
          buf
          (owned_view.compiler-owned-shared-view text)
          0
          start-off))
      (set! buf (byte_buf.append-string buf new-text))
      (set! buf (byte_buf.append-string-range buf text end-off (- n end-off)))
      (byte_buf.to-string buf))))

(define (lsp-edit-at-pos
  [text : String]
  [sl : i64]
  [sc : i64]
  [el : i64]
  [ec : i64]
  [new-text : String]) : String
  (let
    [start-off : i64 (lsp-offset-at-position text (- sl 1) (- sc 1))]
    [end-off : i64 (lsp-offset-at-position text (- el 1) (- ec 1))]
    (lsp-edit-range-at-offset text start-off end-off new-text)))

;; tl/listFunctions - List all top-level function names in a document
(define (lsp-handle-tl-list-functions
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (let
        [items : json.JsonSeq (lsp-decls-to-name-list decls 0)]
        (begin
          (lsp-write-response id (lsp-json-array items))
          (LspDocumentHandleResult.Continue docs)))]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; tl/findPosition - Find the name position {line, character} of a top-level form
(define (lsp-handle-tl-find-position
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (match (lsp-json-string-field params "name")
        [(Ok name)
          (let
            [kind-param : String
              (lsp-json-string-field-default params "kind" "")]
            [i : i64 0]
            [n : i64 (lsp_decl_vec.len (& decls))]
            [found : bool false]
            [result-line : i64 0]
            [result-col : i64 0]
            (begin
              (while (and (< i n) (not found))
                (let
                  [entry : lsp_vector_families.LspDeclEntry
                    (lsp_decl_vec.get (& decls) i (lsp-decl-entry-fallback))]
                  (if (and
                    (string.eq entry.name name)
                    (or
                      (= (string.string-length kind-param) 0)
                      (string.eq entry.kind kind-param)))
                    (begin
                      (set! result-line entry.name-line)
                      (set! result-col entry.name-col)
                      (set! found true)
                      unit)
                    (begin
                      (set! i (+ i 1))
                      unit))))
              (if found
                (begin
                  (lsp-write-response
                    id
                    (lsp-json-object2
                      "line"
                      (lsp-json-number (- result-line 1))
                      "character"
                      (lsp-json-number (- result-col 1))))
                  (LspDocumentHandleResult.Continue docs))
                (begin
                  (lsp-write-declaration-not-found-error id decls name)
                  (LspDocumentHandleResult.Continue docs)))))]
        [(Missing)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspDocumentHandleResult.Continue docs))])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; tl/replace - Replace a top-level declaration by name, with position fallback
;; Helper: get offset from LspDeclEntry start position
(define (lsp-offset-from-entry-start
  [text : (& text str)]
  [entry : (& entry lsp_vector_families.LspDeclEntry)]) : i64
  (lsp-offset-at-position
    text
    (- entry.form-start-line 1)
    (- entry.form-start-col 1)))

;; Helper: move a form after another form
(define (lsp-move-form-after
  [text : (& text str)]
  [source : lsp_vector_families.LspDeclEntry]
  [dest : lsp_vector_families.LspDeclEntry]) : String
  (let
    [source-start : i64 (lsp-offset-from-entry-start text source)]
    [source-end : i64 (lsp-offset-from-entry-end text source)]
    [dest-start : i64 (lsp-offset-from-entry-start text dest)]
    [dest-end : i64 (lsp-offset-from-entry-end text dest)]
    [source-text : String
      (string.substring text source-start (- source-end source-start))]
    [text-without-source : String
      (str_cat.str-cat
        (string.substring text 0 source-start)
        (string.substring
          text
          source-end
          (- (string.string-length text) source-end)))]
    [dest-end-new : i64
      (if (< source-start dest-start)
        (- dest-end (- source-end source-start))
        dest-end)]
    [before : String (string.substring text-without-source 0 dest-end-new)]
    [after : String
      (string.substring
        text-without-source
        dest-end-new
        (- (string.string-length text-without-source) dest-end-new))]
    (lsp-str4 before "
" source-text after)))

;; Helper: get offset from LspDeclEntry end position
(define (lsp-offset-from-entry-end
  [text : (& text str)]
  [entry : lsp_vector_families.LspDeclEntry]) : i64
  (lsp-offset-at-position
    text
    (- entry.form-end-line 1)
    (- entry.form-end-col 1)))

(define (lsp-decl-entry-contains-offset?
  [text : (& text str)]
  [entry : lsp_vector_families.LspDeclEntry]
  [offset : i64]) : bool
  (let
    [start : i64 (lsp-offset-from-entry-start text entry)]
    [end : i64 (lsp-offset-from-entry-end text entry)]
    (and (>= offset start) (< offset end))))

(define (lsp-decl-index-at-position
  [text : (& text str)]
  [decls : (& decls lsp_decl_vec.Vec)]
  [line : i64]
  [col : i64]) : i64
  (if (or (< line 0) (< col 0))
    -1
    (let
      [offset : i64 (lsp-offset-at-position text line col)]
      (if (>= offset (string.string-length text))
        -1
        (let
          [i : i64 0]
          [n : i64 (lsp_decl_vec.len (& decls))]
          [found : i64 -1]
          (begin
            (while (and (< i n) (= found -1))
              (let
                [entry : lsp_vector_families.LspDeclEntry
                  (lsp_decl_vec.get (& decls) i (lsp-decl-entry-fallback))]
                (if (lsp-decl-entry-contains-offset? text entry offset)
                  (set! found i)
                  (set! i (+ i 1)))))
            found))))))

;; Helper: resolve a structural edit target from a position parameter.
(define (lsp-structural-name-from-position-with-decls
  [params : json.Json]
  [text : String]
  [decls : lsp_decl_vec.Vec]) : String
  (let
    [pos-key : String "position"]
    (match (json.object-get params (& pos-key))
      [(JsonFound position)
        (let
          [line : i64 (lsp-json-int-field-default position "line" 0)]
          [col : i64 (lsp-json-int-field-default position "character" 0)]
          [idx : i64 (lsp-decl-index-at-position text decls line col)]
          (if (= idx -1)
            ""
            (__tl-project-field
              (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))
              name)))]
      [(JsonMissing) ""])))

;; Helper: resolve a structural edit target by name first, then position.
(define (lsp-structural-move-name-with-decls
  [params : json.Json]
  [text : String]
  [decls : (& decls lsp_decl_vec.Vec)]) : String
  (let
    [decls : lsp_decl_vec.Vec
      (owned_view.compiler-owned-reference-shared-view decls)]
    (match (lsp-json-string-field params "name")
      [(Ok name)
        (if (= (string.string-length name) 0)
          (lsp-structural-name-from-position-with-decls params text decls)
          name)]
      [(Missing)
        (lsp-structural-name-from-position-with-decls params text decls)])))

(define (lsp-structural-move-name [params : json.Json] [text : String]) : String
  (let
    [decls (lsp-scan-decls (owned_view.compiler-owned-shared-view text))]
    (lsp-structural-move-name-with-decls params text decls)))

(define (lsp-decl-list-find-name
  [decls : (& decls lsp_decl_vec.Vec)]
  [name : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (lsp_decl_vec.len decls)]
    [found : i64 -1]
    (begin
      (while (and (< i n) (= found -1))
        (let
          [entry : lsp_vector_families.LspDeclEntry
            (lsp_decl_vec.get decls i (lsp-decl-entry-fallback))]
          (if (string.eq entry.name name)
            (set! found i)
            (set! i (+ i 1)))))
      found)))

(define (lsp-line-text-at [text : String] [line0 : i64]) : String
  (if (< line0 0)
    ""
    (let
      [n : i64 (string.string-length text)]
      [i : i64 0]
      [line : i64 0]
      [start : i64 0]
      (begin
        (while (and (< i n) (< line line0))
          (begin
            (if (= (string.string-ref text i) '\n')
              (set! line (+ line 1))
              unit)
            (set! i (+ i 1))))
        (if (< line line0)
          ""
          (begin
            (set! start i)
            (while (and (< i n) (not (= (string.string-ref text i) '\n')))
              (set! i (+ i 1)))
            (if (and (> i start) (= (string.string-ref text (- i 1)) '\r'))
              (string.substring text start (- (- i 1) start))
              (string.substring text start (- i start)))))))))

(define (lsp-decl-range-distance [offset : i64] [start : i64] [end : i64]) : i64
  (if (< offset start)
    (- start offset)
    (if (> offset end)
      (- offset end)
      0)))

(define (lsp-nearest-decl-index
  [text : (& text str)]
  [decls : (& decls lsp_decl_vec.Vec)]
  [offset : i64]) : i64
  (let
    [i : i64 0]
    [n : i64 (lsp_decl_vec.len (& decls))]
    [best : i64 -1]
    [best-distance : i64 (+ (string.string-length text) 1)]
    (begin
      (while (< i n)
        (let
          [entry : lsp_vector_families.LspDeclEntry
            (lsp_decl_vec.get (& decls) i (lsp-decl-entry-fallback))]
          [start : i64 (lsp-offset-from-entry-start text entry)]
          [end : i64 (lsp-offset-from-entry-end text entry)]
          [distance : i64 (lsp-decl-range-distance offset start end)]
          (begin
            (if (< distance best-distance)
              (begin
                (set! best i)
                (set! best-distance distance))
              unit)
            (set! i (+ i 1)))))
      best)))

(define (lsp-decl-entry-form-range-json
  [entry : (& entry lsp_vector_families.LspDeclEntry)]) : json.Json
  (lsp-json-object2
    "start"
    (lsp-position entry.form-start-line entry.form-start-col)
    "end"
    (lsp-position entry.form-end-line entry.form-end-col)))

(define (lsp-position-context-json [text : String] [line : i64] [col : i64]) : json.Json
  (let
    [decls : lsp_decl_vec.Vec
      (lsp-scan-decls (owned_view.compiler-owned-shared-view text))]
    [offset : i64
      (if (or (< line 0) (< col 0))
        -1
        (lsp-offset-at-position text line col))]
    [nearest-index : i64 (lsp-nearest-decl-index text decls offset)]
    [nearest-line : i64 -1]
    [nearest-col : i64 -1]
    [nearest-name : String ""]
    [nearest-kind : String ""]
    [nearest-range : json.Json JsonNull]
    (begin
      (if (>= nearest-index 0)
        (let
          [entry : lsp_vector_families.LspDeclEntry
            (lsp_decl_vec.get (& decls) nearest-index (lsp-decl-entry-fallback))]
          (begin
            (set! nearest-line (- entry.form-start-line 1))
            (set! nearest-col (- entry.form-start-col 1))
            (set! nearest-name entry.name)
            (set!
              nearest-kind
              (owned_view.compiler-owned-shared-view entry.kind))
            (set! nearest-range (lsp-decl-entry-form-range-json entry))))
        unit)
      (lsp-json-object
        (lsp-json-member
          "requestedLine"
          (lsp-json-number line)
          (lsp-json-member
            "requestedCol"
            (lsp-json-number col)
            (lsp-json-member
              "lineText"
              (JsonString (lsp-line-text-at text line))
              (lsp-json-member
                "nearestFormLine"
                (lsp-json-number nearest-line)
                (lsp-json-member
                  "nearestFormCol"
                  (lsp-json-number nearest-col)
                  (lsp-json-member
                    "nearestFormName"
                    (JsonString nearest-name)
                    (lsp-json-member
                      "nearestFormKind"
                      (JsonString nearest-kind)
                      (lsp-json-member
                        "nearestFormRange"
                        nearest-range
                        (json.member-list-empty)))))))))))))

(define (lsp-position-error-message [base : String] [line : i64] [col : i64]) : String
  (lsp-str7
    base
    " (line "
    (string.int->string line)
    ", col "
    (string.int->string col)
    ")"
    ""))

(define (lsp-write-position-context-error
  [id : json.Json]
  [text : String]
  [line : i64]
  [col : i64]
  [base-message : String]) : unit
  (let
    [message : String (lsp-position-error-message base-message line col)]
    (lsp-write-error-with-context
      id
      -32600
      message
      (lsp-position-context-json text line col))))

(define lsp-declaration-context-name-cap : i64
  32)

(define (lsp-decls-to-name-list-capped
  [decls : lsp_decl_vec.Vec]
  [idx : i64]
  [remaining : i64]) : json.JsonSeq
  (if (or (>= idx (lsp_decl_vec.len (& decls))) (<= remaining 0))
    (json.list-empty)
    (let
      [entry : lsp_vector_families.LspDeclEntry
        (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))]
      [name : String entry.name]
      (lsp-json-list-cons
        (JsonString name)
        (lsp-decls-to-name-list-capped decls (+ idx 1) (- remaining 1))))))

(define (lsp-common-prefix-len [left : String] [right : String]) : i64
  (let
    [left-len : i64 (string.string-length left)]
    [right-len : i64 (string.string-length right)]
    [limit : i64
      (if (< left-len right-len)
        left-len
        right-len)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (and (< i limit) (not done))
        (if (= (string.string-ref left i) (string.string-ref right i))
          (set! i (+ i 1))
          (set! done true)))
      i)))

(define (lsp-decl-name-similar? [needle : String] [name : String]) : bool
  (if (or (= (string.string-length needle) 0) (= (string.string-length name) 0))
    false
    (or
      (string.contains (& name) (& needle))
      (string.contains (& needle) (& name))
      (>= (lsp-common-prefix-len needle name) 2))))

(define (lsp-decls-to-similar-name-list
  [decls : (& decls lsp_decl_vec.Vec)]
  [idx : i64]
  [needle : String]) : json.JsonSeq
  (if (>= idx (lsp_decl_vec.len (& decls)))
    (json.list-empty)
    (let
      [entry : lsp_vector_families.LspDeclEntry
        (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))]
      [name : String entry.name]
      [rest : json.JsonSeq
        (lsp-decls-to-similar-name-list
          decls
          (+ idx 1)
          (owned_view.compiler-owned-shared-view needle))]
      (if (lsp-decl-name-similar?
        needle
        (owned_view.compiler-owned-shared-view name))
        (lsp-json-list-cons (JsonString name) rest)
        rest))))

(define (lsp-declaration-context-json
  [decls : lsp_decl_vec.Vec]
  [name : String]) : json.Json
  (let
    [all-name-count : i64 (lsp_decl_vec.len (& decls))]
    (lsp-json-object
      (lsp-json-member
        "requestedName"
        (JsonString (owned_view.compiler-owned-shared-view name))
        (lsp-json-member
          "similarNames"
          (lsp-json-array (lsp-decls-to-similar-name-list decls 0 name))
          (lsp-json-member
            "allNames"
            (lsp-json-array
              (lsp-decls-to-name-list-capped
                decls
                0
                lsp-declaration-context-name-cap))
            (lsp-json-member
              "allNameCount"
              (lsp-json-number all-name-count)
              (lsp-json-member
                "allNamesTruncated"
                (JsonBool (> all-name-count lsp-declaration-context-name-cap))
                (lsp-json-member
                  "allNameLimit"
                  (lsp-json-number lsp-declaration-context-name-cap)
                  (lsp-json-member
                    "declarationCount"
                    (lsp-json-number all-name-count)
                    (json.member-list-empty)))))))))))

(define (lsp-declaration-not-found-message [name : String]) : String
  (if (= (string.string-length name) 0)
    "Declaration not found"
    (lsp-str3 "Declaration '" name "' not found")))

(define (lsp-write-declaration-context-error
  [id : json.Json]
  [decls : lsp_decl_vec.Vec]
  [name : String]
  [message : String]) : unit
  (lsp-write-error-with-context
    id
    -32600
    message
    (lsp-declaration-context-json decls name)))

(define (lsp-write-declaration-not-found-error
  [id : json.Json]
  [decls : lsp_decl_vec.Vec]
  [name : String]) : unit
  (lsp-write-declaration-context-error
    id
    decls
    (owned_view.compiler-owned-shared-view name)
    (lsp-declaration-not-found-message name)))

(define (lsp-tl-request-uri [params : json.Json]) : LspJsonText
  (let
    [key : String "textDocument"]
    (match (json.object-get params (& key))
      [(JsonFound document) (lsp-json-string-field document "uri")]
      [(JsonMissing) Missing])))

(define (lsp-cache-string-copy [text : String]) : String
  (if (> lsp-document-cache-arena 0)
    (in-arena (arena.Arena lsp-document-cache-arena) (string.copy (& text)))
    (string.copy (& text))))

(define (lsp-diagnostic-uris-copy
  [uris : lsp_vector_families.LspDiagnosticUris]) : lsp_vector_families.LspDiagnosticUris
  (let
    [n : i64 (lsp-diagnostic-uris-len uris)]
    [slots : (__tl_dyn-array String) (__tl_make-array String n)]
    [index : i64 0]
    (begin
      (while (< index n)
        (let
          [uri : String
            (lsp-diagnostic-uris-get
              (owned_view.compiler-owned-shared-view uris)
              index)]
          (begin
            (set! (array-ref slots index) (string.copy (& uri)))
            (set! index (+ index 1)))))
      (lsp_vector_families.LspDiagnosticUris slots n))))

(define (lsp-cache-diagnostic-uris-copy
  [uris : lsp_vector_families.LspDiagnosticUris]) : lsp_vector_families.LspDiagnosticUris
  (if (> lsp-document-cache-arena 0)
    (in-arena
      (arena.Arena lsp-document-cache-arena)
      (lsp-diagnostic-uris-copy uris))
    (lsp-diagnostic-uris-copy uris)))

(define (lsp-tl-save-doc
  [docs : lsp_document_vec.Vec]
  [uri : String]
  [path : String]
  [diagnostic-uris : lsp_vector_families.LspDiagnosticUris]
  [formatted : String]) : LspSaveResult
  (match (lsp-validate-edited-document
    (owned_view.compiler-owned-shared-view formatted))
    [(Ok _)
      (match (io.try-write-file (& path) (byte_buf.str-as-bytes (& formatted)))
        [(OkIoUnit)
          (let
            [cached-uri : String (lsp-cache-string-copy uri)]
            [cached-path : String (lsp-cache-string-copy path)]
            [cached-text : String (lsp-cache-string-copy formatted)]
            (LspSaveResult.Ok
              (lsp-documents-set
                docs
                cached-uri
                cached-path
                cached-text
                diagnostic-uris)))]
        [(ErrIoUnit message)
          (Err
            (lsp-str2 "Failed to write document: " (io.error-message message)))])]
    [(Err message) (Err message)]))

(define (lsp-tl-save-known-and-continue
  [id : json.Json]
  [docs : lsp_document_vec.Vec]
  [uri : String]
  [path : String]
  [diagnostic-uris : lsp_vector_families.LspDiagnosticUris]
  [formatted : String]) : LspDocumentHandleResult
  (match (lsp-tl-save-doc
    (owned_view.compiler-owned-shared-view docs)
    uri
    path
    diagnostic-uris
    (owned_view.compiler-owned-shared-view formatted))
    [(Ok next-docs)
      (begin
        (lsp-write-response
          id
          (lsp-json-object3
            "success"
            (JsonBool true)
            "text"
            (JsonString (owned_view.compiler-owned-shared-view formatted))
            "positionMap"
            (lsp-position-map-for-text formatted)))
        (LspDocumentHandleResult.Continue next-docs))]
    [(Err message)
      (begin
        (lsp-write-error id -32600 message)
        (LspDocumentHandleResult.Continue docs))]))

(define (lsp-tl-save-and-continue
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [formatted : String]) : LspDocumentHandleResult
  (match (lsp-tl-request-uri params)
    [(Ok uri)
      (match (lsp-documents-lookup docs uri)
        [(Found path _ diagnostic-uris)
          (lsp-tl-save-known-and-continue
            id
            docs
            uri
            path
            diagnostic-uris
            formatted)]
        [(Missing)
          (match (lsp-file-uri-to-path uri)
            [(Ok path)
              (lsp-tl-save-known-and-continue
                id
                docs
                uri
                path
                (lsp-diagnostic-uris-empty)
                formatted)]
            [(Err message)
              (begin
                (lsp-write-error id -32600 message)
                (LspDocumentHandleResult.Continue docs))])])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Missing uri in textDocument parameter")
        (LspDocumentHandleResult.Continue docs))]))

(define (lsp-write-structural-edit-success
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [result : String]) : LspDocumentHandleResult
  (let
    [formatted : String (lsp-format-edit-text result)]
    (lsp-tl-save-and-continue id params docs formatted)))

(define (lsp-write-position-context-error-from-params
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [base-message : String]) : LspDocumentHandleResult
  (match (lsp-get-document
    (owned_view.compiler-owned-shared-view params)
    (owned_view.compiler-owned-shared-view docs))
    [(Found _ text _)
      (let
        [pos-key : String "position"]
        (match (json.object-get params (& pos-key))
          [(JsonFound position)
            (let
              [line : i64 (lsp-json-int-field-default position "line" 0)]
              [col : i64 (lsp-json-int-field-default position "character" 0)]
              (begin
                (lsp-write-position-context-error id text line col base-message)
                (LspDocumentHandleResult.Continue docs)))]
          [(JsonMissing)
            (begin
              (lsp-write-error id -32600 base-message)
              (LspDocumentHandleResult.Continue docs))]))]
    [(Missing)
      (begin
        (lsp-write-error id -32600 base-message)
        (LspDocumentHandleResult.Continue docs))]))

(define (lsp-write-declaration-context-error-from-params
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found _ text _ decls)
      (let
        [name : String (lsp-structural-move-name-with-decls params text decls)]
        (begin
          (lsp-write-declaration-not-found-error id decls name)
          (LspDocumentHandleResult.Continue docs)))]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Declaration not found")
        (LspDocumentHandleResult.Continue docs))]))

(define (lsp-write-contextual-edit-error
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [message : String]) : LspDocumentHandleResult
  (cond
    [(string.eq message "No form found at position")
      (lsp-write-position-context-error-from-params id params docs message)]
    [(string.eq message "Declaration not found")
      (lsp-write-declaration-context-error-from-params id params docs)]
    [else
      (begin
        (lsp-write-error id -32600 message)
        (LspDocumentHandleResult.Continue docs))]))

(define (lsp-write-structural-edit-result
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [result : LspEditResult]) : LspDocumentHandleResult
  (match result
    [(Ok replaced) (lsp-write-structural-edit-success id params docs replaced)]
    [(Err message) (lsp-write-contextual-edit-error id params docs message)]))

(define (lsp-write-replace-body-validation-error
  [id : json.Json]
  [docs : lsp_document_vec.Vec]
  [new-body : String]) : LspDocumentHandleResult
  (begin
    (lsp-write-error-with-data
      id
      -32600
      (lsp-replace-body-validation-message
        (owned_view.compiler-owned-shared-view new-body))
      (lsp-replace-body-validation-data new-body))
    (LspDocumentHandleResult.Continue docs)))

(define (lsp-write-read-form-success
  [id : json.Json]
  [form-text : String]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (begin
    (lsp-write-response
      id
      (lsp-json-object2 "success" (JsonBool true) "form" (JsonString form-text)))
    (LspDocumentHandleResult.Continue docs)))

(define (lsp-write-read-form-result
  [id : json.Json]
  [params : json.Json]
  [result : LspStringResult]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match result
    [(Ok form-text) (lsp-write-read-form-success id form-text docs)]
    [(Err message) (lsp-write-contextual-edit-error id params docs message)]))

(define (lsp-write-missing-structural-name-error
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (let
    [pos-key : String "position"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view params)
      (& pos-key))
      [(JsonFound _)
        (lsp-write-position-context-error-from-params
          id
          params
          docs
          "Could not extract function name at position")]
      [(JsonMissing)
        (begin
          (lsp-write-error id -32600 "Missing name or position parameter")
          (LspDocumentHandleResult.Continue docs))])))

(define (lsp-structural-move-after-destination
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [text : String]
  [decls : lsp_decl_vec.Vec]
  [name : String]
  [destination : String]) : LspDocumentHandleResult
  (match (lsp-structural-move-after-destination-text
    text
    decls
    (owned_view.compiler-owned-shared-view name)
    (owned_view.compiler-owned-shared-view destination))
    [(Ok result) (lsp-write-structural-edit-success id params docs result)]
    [(Err message)
      (cond
        [(string.eq message "Declaration not found")
          (begin
            (lsp-write-declaration-not-found-error id decls name)
            (LspDocumentHandleResult.Continue docs))]
        [(string.eq message "Destination declaration not found")
          (begin
            (lsp-write-declaration-context-error
              id
              decls
              (owned_view.compiler-owned-shared-view destination)
              (lsp-str3 "Destination declaration '" destination "' not found"))
            (LspDocumentHandleResult.Continue docs))]
        [else
          (begin
            (lsp-write-error id -32600 message)
            (LspDocumentHandleResult.Continue docs))])]))

(define (lsp-structural-move-direction
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [text : String]
  [decls : lsp_decl_vec.Vec]
  [name : String]
  [direction : String]) : LspDocumentHandleResult
  (match (lsp-structural-move-direction-text
    text
    decls
    (owned_view.compiler-owned-shared-view name)
    direction)
    [(Ok result) (lsp-write-structural-edit-success id params docs result)]
    [(Err message)
      (if (string.eq message "Declaration not found")
        (begin
          (lsp-write-declaration-not-found-error id decls name)
          (LspDocumentHandleResult.Continue docs))
        (begin
          (lsp-write-error id -32600 message)
          (LspDocumentHandleResult.Continue docs)))]))

;; tl/move - Move a form by name or position.
(define (lsp-handle-tl-structural-move
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (let
        [name : String
          (lsp-structural-move-name-with-decls
            (owned_view.compiler-owned-shared-view params)
            (owned_view.compiler-owned-shared-view text)
            decls)]
        (if (= (string.string-length name) 0)
          (lsp-write-missing-structural-name-error id params docs)
          (match (lsp-json-string-field params "destination")
            [(Ok destination)
              (lsp-structural-move-after-destination
                id
                params
                docs
                text
                decls
                name
                destination)]
            [(Missing)
              (match (lsp-json-string-field params "direction")
                [(Ok direction)
                  (lsp-structural-move-direction
                    id
                    params
                    docs
                    text
                    decls
                    name
                    direction)]
                [(Missing)
                  (begin
                    (lsp-write-error
                      id
                      -32600
                      "Missing direction or destination parameter")
                    (LspDocumentHandleResult.Continue docs))])])))]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; tl/expandMacro - Find the form at cursor position and return its text
;; Returns the top-level form by name.
;; Full macro expansion would require compiler macro expansion integration.
(define (lsp-handle-tl-expand-macro
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (match (lsp-json-string-field params "name")
        [(Ok name)
          (let
            [i : i64 0]
            [n : i64 (lsp_decl_vec.len (& decls))]
            [found-idx : i64 -1]
            (begin
              (while (and (< i n) (= found-idx -1))
                (let
                  [entry : lsp_vector_families.LspDeclEntry
                    (lsp_decl_vec.get (& decls) i (lsp-decl-entry-fallback))]
                  (if (string.eq entry.name name)
                    (set! found-idx i)
                    (set! i (+ i 1)))))
              (if (= found-idx -1)
                (begin
                  (lsp-write-error id -32600 "Form not found")
                  (LspDocumentHandleResult.Continue docs))
                (let
                  [entry : lsp_vector_families.LspDeclEntry
                    (lsp_decl_vec.get
                      (& decls)
                      found-idx
                      (lsp-decl-entry-fallback))]
                  [start-off : i64
                    (lsp-offset-at-position
                      text
                      (- entry.form-start-line 1)
                      (- entry.form-start-col 1))]
                  [end-off : i64
                    (lsp-offset-at-position
                      text
                      (- entry.form-end-line 1)
                      (- entry.form-end-col 1))]
                  [result : String
                    (string.substring text start-off (- end-off start-off))]
                  (begin
                    (lsp-write-response
                      id
                      (lsp-json-object2
                        "success"
                        (JsonBool true)
                        "text"
                        (JsonString result)))
                    (LspDocumentHandleResult.Continue docs))))))]
        [(Missing)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspDocumentHandleResult.Continue docs))])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; tl/check - Typecheck a document and return success/error JSON response
(define (lsp-check-cache-valid?
  [check-cache : lsp_vector_families.LspCheckCache]) : bool
  (match check-cache
    [(LspCheckCacheInvalid) false]
    [_ true]))

(define (lsp-check-cache-json [check-cache : lsp_vector_families.LspCheckCache]) : json.Json
  (match check-cache
    [(LspCheckCacheOk) (lsp-json-object1 "success" (JsonBool true))]
    [(LspCheckCacheErr message)
      (lsp-json-object2 "success" (JsonBool false) "error" (JsonString message))]
    [(LspCheckCacheInvalid)
      (lsp-json-object2
        "success"
        (JsonBool false)
        "error"
        (JsonString "Check cache invalid"))]))

(define (lsp-typecheck-tool-session-before!) : unit
  ;; Preserve the loader program cache across interactive checks. The loader
  ;; only caches imported files and embedded stdlib programs here; unsaved
  ;; document text still goes through compiler-load-source and is reparsed.
  (begin
    (compiler_check_core.compiler-check-reset-pools!)
    (compiler_check_core.compiler-check-reset-interns!)))

(define (lsp-typecheck-tool-session-after!) : unit
  (begin
    (compiler_check_core.compiler-check-reset-pools!)
    (compiler_check_core.compiler-check-reset-interns!)))

(define (lsp-write-check-cache-response
  [id : json.Json]
  [check-cache : lsp_vector_families.LspCheckCache]) : unit
  (lsp-write-response id (lsp-check-cache-json check-cache)))

(define (lsp-check-source-cache
  [path : String]
  [text : String]
  [stdlib-roots : lsp_svec.Vec]) : lsp_vector_families.LspCheckCache
  (match (lsp-validate-forms-result
    (owned_view.compiler-owned-shared-view text))
    [(Valid)
      (match (compiler_check_core.compiler-check-source-with-roots-and-cfg
        path
        text
        stdlib-roots
        (lsp-language-cfgs))
        [(Ok _ _) LspCheckCacheOk]
        [(Err diag _)
          (let
            [diagnostics : cdiag.CompilerDiagnosticList
              (cdiag.compiler-diagnostic-list-box-shared-view diag)]
            [first : cdiag.CompilerDiagnostic
              (cdiag.compiler-diagnostic-list-first diagnostics)]
            (LspCheckCacheErr (cdiag.compiler-diagnostic-message first)))])]
    [(Invalid line col msg ctx)
      (LspCheckCacheErr (lsp-validation-error-message line col msg ctx))]))

(define (lsp-run-check-and-respond
  [id : json.Json]
  [uri : String]
  [path : String]
  [text : String]
  [docs : lsp_document_vec.Vec]
  [stdlib-roots : lsp_svec.Vec]) : LspDocumentHandleResult
  (let
    [check-cache : lsp_vector_families.LspCheckCache LspCheckCacheInvalid]
    (begin
      (lsp-typecheck-tool-session-before!)
      (set! check-cache (lsp-check-source-cache path text stdlib-roots))
      (lsp-typecheck-tool-session-after!)
      (lsp-write-check-cache-response
        id
        (owned_view.compiler-owned-shared-view check-cache))
      (LspDocumentHandleResult.Continue
        (lsp-documents-set-check-cache docs uri check-cache)))))

(define (lsp-handle-tl-check
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [stdlib-roots : lsp_svec.Vec]) : LspDocumentHandleResult
  (let
    [uri : String
      (match (lsp-json-string-field params "uri")
        [(Ok u) u]
        [(Missing)
          (let
            [td-key : String "textDocument"]
            (match (json.object-get params (& td-key))
              [(JsonFound document)
                (match (lsp-json-string-field document "uri")
                  [(Ok u) u]
                  [(Missing) ""])]
              [(JsonMissing) ""]))])]
    (if (string.eq uri "")
      (begin
        (lsp-write-error id -32600 "Missing uri parameter")
        (LspDocumentHandleResult.Continue docs))
      (let
        [doc-index : i64 (lsp-documents-find-index docs uri)]
        (if (>= doc-index 0)
          (let
            [doc : lsp_vector_families.LspDocument
              (lsp_document_vec.get (& docs) doc-index (lsp-document-fallback))]
            [check-cache : lsp_vector_families.LspCheckCache doc.check-cache]
            (if (lsp-check-cache-valid?
              (owned_view.compiler-owned-shared-view check-cache))
              (begin
                (lsp-write-check-cache-response id check-cache)
                (LspDocumentHandleResult.Continue docs))
              (lsp-run-check-and-respond
                id
                uri
                doc.path
                doc.text
                docs
                stdlib-roots)))
          (match (lsp-file-uri-to-path uri)
            [(Ok path)
              (let
                [text : String (lsp-read-file-text-or (& path) "")]
                (if (string.eq text "")
                  (begin
                    (lsp-write-response
                      id
                      (lsp-json-object2
                        "success"
                        (JsonBool false)
                        "error"
                        (JsonString "Could not read document")))
                    (LspDocumentHandleResult.Continue docs))
                  (lsp-run-check-and-respond id uri path text docs stdlib-roots)))]
            [(Err message)
              (begin
                (lsp-write-response
                  id
                  (lsp-json-object2
                    "success"
                    (JsonBool false)
                    "error"
                    (JsonString message)))
                (LspDocumentHandleResult.Continue docs))]))))))

(define (lsp-nearest-inlay-hint-index
  [inlay-state : tc.TcInlayHintState]
  [text : (& text str)]
  [line1 : i64]
  [col1 : i64]) : i64
  (let
    [size : i64 (tc.tc-inlay-hints-size-for-state inlay-state)]
    [i : i64 0]
    [best-idx : i64 -1]
    [best-dist : i64 999999999]
    (begin
      (while (< i size)
        (let
          [hint-line : i64 (tc.tc-inlay-hint-line-at-for-state inlay-state i)]
          [hint-col : i64 (tc.tc-inlay-hint-col-at-for-state inlay-state i)]
          [d-line : i64
            (if (< hint-line line1)
              (- line1 hint-line)
              (- hint-line line1))]
          [d-col : i64
            (if (< hint-col col1)
              (- col1 hint-col)
              (- hint-col col1))]
          [dist : i64 (+ (* d-line 1000) d-col)]
          [off : i64
            (source_text.source-text-offset-at-byte-position
              text
              (- hint-line 1)
              (- hint-col 1))]
          [belongs-to-document : bool
            (or
              (lsp-inlay-valid-binding? text off)
              (lsp-inlay-valid-expr? text off))]
          (begin
            ;; Typecheck traverses imports before the entry source and the
            ;; shared hint buffer is not file-attributed. Never select an
            ;; imported hint merely because its line/column is numerically
            ;; close to the requested document position.
            (if (and belongs-to-document (< dist best-dist))
              (begin
                (set! best-dist dist)
                (set! best-idx i))
              unit)
            (set! i (+ i 1)))))
      best-idx)))

;; tl/getType - Type of expression at cursor
(define (lsp-handle-tl-get-type-at
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [stdlib-roots : lsp_svec.Vec]
  [job-state : tc.TcJobState]) : LspDocumentHandleResult
  (match (lsp-get-document
    (owned_view.compiler-owned-shared-view params)
    (owned_view.compiler-owned-shared-view docs))
    [(Found path text _)
      (let
        [pos-key : String "position"]
        (match (json.object-get params (& pos-key))
          [(JsonFound position)
            (let
              [line0 : i64 (lsp-json-int-field-default position "line" 0)]
              [char0 : i64 (lsp-json-int-field-default position "character" 0)]
              [position-off : i64 (lsp-offset-at-position text line0 char0)]
              [byte-lc : LspLineCol
                (lsp-byte-line-col-at-offset text position-off)]
              [line1 : i64 byte-lc.line]
              [col1 : i64 byte-lc.col]
              [inlay-state : tc.TcInlayHintState
                (tc.tc-job-state-inlay-hints job-state)]
              (begin
                (tc.tc-inlay-hints-enable-for-state! inlay-state)
                (match (compiler_check_core.compiler-check-source-with-roots-and-cfg-and-job-state
                  path
                  (owned_view.compiler-owned-shared-view text)
                  stdlib-roots
                  (lsp-language-cfgs)
                  job-state)
                  [(Ok _ _) unit]
                  [(Err _ _) unit])
                (let
                  [found-idx : i64
                    (lsp-nearest-inlay-hint-index inlay-state text line1 col1)]
                  (begin
                    (tc.tc-inlay-hints-disable-for-state! inlay-state)
                    (if (= found-idx -1)
                      ;; Fallback: try to find explicit type annotation
                      (let
                        [off : i64 (lsp-offset-at-position text line0 char0)]
                        [sym : String (lsp-symbol-at-offset text off)]
                        [bind-type : String
                          (if (string.eq sym "")
                            ""
                            (lsp-binding-type text (lsp-symbol-base sym) off))]
                        (if (string.eq bind-type "")
                          (begin
                            (lsp-write-response
                              id
                              (lsp-json-object2
                                "success"
                                (JsonBool false)
                                "error"
                                (JsonString
                                  "No type information at this position")))
                            (LspDocumentHandleResult.Continue docs))
                          (begin
                            (lsp-write-response
                              id
                              (lsp-json-object2
                                "success"
                                (JsonBool true)
                                "type"
                                (JsonString bind-type)))
                            (LspDocumentHandleResult.Continue docs))))
                      (let
                        [found-type : String
                          (tc.tc-inlay-hint-type-at-for-state
                            inlay-state
                            found-idx)]
                        (begin
                          (lsp-write-response
                            id
                            (lsp-json-object2
                              "success"
                              (JsonBool true)
                              "type"
                              (JsonString found-type)))
                          (LspDocumentHandleResult.Continue docs))))))))]
          [(JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspDocumentHandleResult.Continue docs))]))]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

(define (lsp-quoted-datum-end [text : (& text str)] [start : i64] [limit : i64]) : i64
  (let
    [datum-start : i64 (source_text.source-text-skip-space text start limit)]
    (if (>= datum-start limit)
      limit
      (let
        [first : char (string.string-ref text datum-start)]
        (cond
          [(= first '(') (lsp-skip-paren-group text datum-start limit)]
          [(= first '"')
            (source_text.source-text-skip-string text datum-start limit)]
          [(= first '\'')
            (let
              [past : i64
                (source_text.source-text-skip-char-literal
                  text
                  datum-start
                  limit)]
              (if (> past (+ datum-start 1))
                past
                (lsp-quoted-datum-end text (+ datum-start 1) limit)))]
          [(or (= first '`') (= first ','))
            (lsp-quoted-datum-end
              text
              (+
                datum-start
                (if (and
                  (= first ',')
                  (< (+ datum-start 1) limit)
                  (= (string.string-ref text (+ datum-start 1)) '@'))
                  2
                  1))
              limit)]
          [else (lsp-call-scan-token text datum-start limit)])))))

(define (lsp-symbol-in-quoted-data-range?
  [text : (& text str)]
  [start : i64]
  [limit : i64]
  [target : i64]
  [quoted : bool]) : bool
  (let
    [cursor : i64 start]
    (begin
      (while (and (< cursor limit) (<= cursor target))
        (let
          [current : char (string.string-ref text cursor)]
          (cond
            [(source_text.source-text-space? current)
              (set!
                cursor
                (source_text.source-text-skip-space text cursor limit))]
            [(= current ';')
              (set!
                cursor
                (source_text.source-text-skip-line text cursor limit))]
            [(= current '"')
              (set!
                cursor
                (source_text.source-text-skip-string text cursor limit))]
            [(= current '\'')
              (let
                [past : i64
                  (source_text.source-text-skip-char-literal text cursor limit)]
                (if (> past (+ cursor 1))
                  (set! cursor past)
                  (let
                    [datum-start : i64
                      (source_text.source-text-skip-space
                        text
                        (+ cursor 1)
                        limit)]
                    [datum-end : i64
                      (lsp-quoted-datum-end text (+ cursor 1) limit)]
                    (if (and (>= target datum-start) (< target datum-end))
                      (return true)
                      (set! cursor datum-end)))))]
            [(= current '`')
              (let
                [datum-start : i64
                  (source_text.source-text-skip-space text (+ cursor 1) limit)]
                [datum-end : i64 (lsp-quoted-datum-end text (+ cursor 1) limit)]
                (if (and (>= target datum-start) (< target datum-end))
                  (return true)
                  (set! cursor datum-end)))]
            [(= current ',')
              (let
                [prefix-end : i64
                  (+
                    cursor
                    (if (and
                      (< (+ cursor 1) limit)
                      (= (string.string-ref text (+ cursor 1)) '@'))
                      2
                      1))]
                [datum-start : i64
                  (source_text.source-text-skip-space text prefix-end limit)]
                [datum-end : i64 (lsp-quoted-datum-end text prefix-end limit)]
                (if (and (>= target datum-start) (< target datum-end))
                  (return
                    (lsp-symbol-in-quoted-data-range?
                      text
                      datum-start
                      datum-end
                      target
                      false))
                  (set! cursor datum-end)))]
            [(= current '(')
              (let
                [form-end : i64 (lsp-skip-paren-group text cursor limit)]
                [head-start : i64
                  (source_text.source-text-skip-space
                    text
                    (+ cursor 1)
                    form-end)]
                [head-end : i64 (lsp-scan-ident text head-start form-end)]
                (if (and (>= target cursor) (< target form-end))
                  (if (and (>= target head-start) (< target head-end))
                    (return quoted)
                    (let
                      [head : String
                        (string.substring
                          text
                          head-start
                          (- head-end head-start))]
                      [child-quoted : bool
                        (cond
                          [(or
                              (string.eq head "quote")
                              (string.eq head "quasiquote"))
                            true]
                          [(or
                              (string.eq head "unquote")
                              (string.eq head "unquote-splicing"))
                            false]
                          [else quoted])]
                      (return
                        (lsp-symbol-in-quoted-data-range?
                          text
                          head-end
                          form-end
                          target
                          child-quoted))))
                  (set! cursor form-end)))]
            [else
              (let
                [token-end : i64 (lsp-call-scan-token text cursor limit)]
                (if (and (>= target cursor) (< target token-end))
                  (return quoted)
                  (set!
                    cursor
                    (if (> token-end cursor)
                      token-end
                      (+ cursor 1)))))])))
      false)))

(define (lsp-symbol-in-quoted-data? [text : String] [target : i64]) : bool
  (lsp-symbol-in-quoted-data-range?
    text
    0
    (string.string-length text)
    target
    false))

;; Maximal identifier token covering `off`, limited to source code. Comments,
;; strings, character literals, and quoted data deliberately produce no
;; semantic fallback symbol.
(define (lsp-code-symbol-at-offset [text : (& text str)] [off : i64]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    (if (or (< off 0) (>= off n))
      ""
      (begin
        (while (and (< i n) (<= i off))
          (let
            [c : char (string.string-ref text i)]
            (cond
              [(= c ';') (set! i (source_text.source-text-skip-line text i n))]
              [(= c '"')
                (set! i (source_text.source-text-skip-string text i n))]
              [(= c '\'')
                (set! i (source_text.source-text-skip-char-literal text i n))]
              [(lsp-ident-char? c)
                (let
                  [end : i64 (lsp-scan-ident text i n)]
                  (begin
                    (when
                      (< off end)
                      (return (string.substring text i (- end i))))
                    (set! i end)))]
              [else (set! i (+ i 1))])))
        ""))))

(define (lsp-document-highlight-range
  [candidate : (& candidate LspDocumentHighlightCandidate)]) : json.Json
  (lsp-json-object2
    "start"
    (lsp-position
      candidate.start-line
      (if lsp-position-encoding-utf8
        candidate.start-col
        candidate.utf16-start-col))
    "end"
    (lsp-position
      candidate.end-line
      (if lsp-position-encoding-utf8
        candidate.end-col
        candidate.utf16-end-col))))

(define (lsp-document-highlight
  [candidate : (& candidate LspDocumentHighlightCandidate)]) : json.Json
  (lsp-json-object2
    "range"
    (lsp-document-highlight-range candidate)
    "kind"
    (lsp-json-number candidate.kind)))

(define (lsp-document-highlight-kind
  [access : compiler_semantic_index.CompilerSemanticAccess]) : i64
  (match access
    [(None) 1]
    [(Read) 2]
    [(Write) 3]
    ;; LSP has no combined read/write highlight. Prefer the stronger write
    ;; classification when a future semantic producer proves both.
    [(ReadWrite) 3]))

(define (lsp-document-highlight-candidate-less?
  [left : (& left LspDocumentHighlightCandidate)]
  [right : (& right LspDocumentHighlightCandidate)]) : bool
  (cond
    [(< left.start-byte right.start-byte) true]
    [(> left.start-byte right.start-byte) false]
    [else (< left.end-byte right.end-byte)]))

(define (lsp-document-highlight-results-insert!
  [results : (&mut results LspDocumentHighlightResults)]
  [candidate : LspDocumentHighlightCandidate]) : unit
  (let
    [index : i64 0]
    [duplicate : i64 -1]
    (begin
      (while (and (< index results.len) (< duplicate 0))
        (let
          [existing : LspDocumentHighlightCandidate
            (array-ref results.slots index)]
          (begin
            (if (and
              (= candidate.start-byte existing.start-byte)
              (= candidate.end-byte existing.end-byte))
              (set! duplicate index)
              unit)
            (set! index (+ index 1)))))
      (if (>= duplicate 0)
        (if (> candidate.kind (array-ref results.slots duplicate).kind)
          (set! (array-ref results.slots duplicate).kind candidate.kind)
          unit)
        (begin
          (if (>= results.len (array-length results.slots))
            (let
              [old-capacity : i64 (array-length results.slots)]
              [new-capacity : i64
                (if (< old-capacity 8)
                  8
                  (* old-capacity 2))]
              [bigger : (__tl_dyn-array LspDocumentHighlightCandidate)
                (__tl_make-array LspDocumentHighlightCandidate new-capacity)]
              [copy-index : i64 0]
              (begin
                (while (< copy-index results.len)
                  (begin
                    (unsafe
                      (ptr-write!
                        (ptr-offset (__tl_array-data bigger) copy-index)
                        (array-ref results.slots copy-index)))
                    (set! copy-index (+ copy-index 1))))
                (set! results.slots bigger)))
            unit)
          (let
            [position : i64 0]
            [write : i64 results.len]
            (begin
              (while (and
                (< position results.len)
                (not
                  (lsp-document-highlight-candidate-less?
                    (& candidate)
                    (& (array-ref results.slots position)))))
                (set! position (+ position 1)))
              (while (> write position)
                (begin
                  (set!
                    (array-ref results.slots write)
                    (array-ref results.slots (- write 1)))
                  (set! write (- write 1))))
              (set! (array-ref results.slots position) candidate)
              (set! results.len (+ results.len 1)))))))))

(define (lsp-document-highlights-at
  [doc : (& doc lsp_vector_families.LspDocument)]
  [byte-position : i64]) : LspDocumentHighlightResults
  (let
    [results : LspDocumentHighlightResults
      (LspDocumentHighlightResults
        (__tl_make-array LspDocumentHighlightCandidate 0)
        0
        0)]
    [cursor-index : i64 (lsp-document-semantic-record-at doc byte-position)]
    (if (< cursor-index 0)
      results
      (let
        [semantic-index : compiler_semantic_index.CompilerSemanticSourceIndex
          doc.semantic.index]
        [cursor : compiler_semantic_index.CompilerSemanticRecord
          (compiler_semantic_index.compiler-semantic-source-index-get
            (& semantic-index)
            cursor-index)]
        [document-path : String
          (lsp-normalized-absolute-path (string.copy (& doc.path)))]
        [record-index : i64 0]
        (if (not (lsp-semantic-record-exact-editable? cursor))
          results
          (begin
            (while (<
              record-index
              (compiler_semantic_index.compiler-semantic-source-index-len
                (& semantic-index)))
              (let
                [record : compiler_semantic_index.CompilerSemanticRecord
                  (compiler_semantic_index.compiler-semantic-source-index-get
                    (& semantic-index)
                    record-index)]
                (begin
                  (set! results.record-visits (+ results.record-visits 1))
                  (if (and
                    (compiler_semantic_index.compiler-semantic-symbol-id-eq?
                      cursor.symbol
                      record.symbol)
                    (lsp-semantic-record-exact-editable? record)
                    (string.eq
                      (lsp-normalized-absolute-path
                        (string.copy (& record.span.path)))
                      document-path))
                    (lsp-document-highlight-results-insert!
                      (&mut results)
                      (let
                        [source : ast.AstSourceSpan record.span.source]
                        (LspDocumentHighlightCandidate
                          record.span.start-byte
                          record.span.end-byte
                          (ast.ast-source-span-start-line source)
                          (ast.ast-source-span-start-col source)
                          (ast.ast-source-span-end-line source)
                          (ast.ast-source-span-end-col source)
                          record.span.utf16-start-col
                          record.span.utf16-end-col
                          (lsp-document-highlight-kind record.access))))
                    unit)
                  (set! record-index (+ record-index 1)))))
            results))))))

(define (lsp-document-highlight-results-json
  [results : (& results LspDocumentHighlightResults)]) : json.Json
  (let
    [index : i64 (- results.len 1)]
    [items : json.JsonSeq (json.list-empty)]
    (begin
      (while (>= index 0)
        (begin
          (set!
            items
            (lsp-json-list-cons
              (lsp-document-highlight (& (array-ref results.slots index)))
              items))
          (set! index (- index 1))))
      (lsp-json-array items))))

(define (lsp-json-int-field-usable? [value : json.Json] [key : String]) : bool
  (match (json.object-get value (& key))
    [(JsonFound field)
      (match field
        [(JsonNumber text)
          (match (json.number->i64 (& text))
            [(OkJsonNumberI64 number) (>= number 0)]
            [(ErrJsonNumberI64 _) false])]
        [_ false])]
    [(JsonMissing) false]))

(define (lsp-handle-document-highlight
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : unit
  (match (lsp-get-semantic-document
    (owned_view.compiler-owned-shared-view params)
    docs)
    [(Found doc)
      (let
        [position-key : String "position"]
        (match (json.object-get params (& position-key))
          [(JsonFound position)
            (if (and
              (lsp-json-int-field-usable?
                (owned_view.compiler-owned-shared-view position)
                "line")
              (lsp-json-int-field-usable?
                (owned_view.compiler-owned-shared-view position)
                "character"))
              (let
                [line : i64 (lsp-json-int-field-default position "line" 0)]
                [col : i64 (lsp-json-int-field-default position "character" 0)]
                (match (lsp-offset-at-position-checked doc.text line col)
                  [(Missing)
                    (lsp-write-response id (lsp-json-array (json.list-empty)))]
                  [(Found off)
                    (let
                      [results : LspDocumentHighlightResults
                        (lsp-document-highlights-at (& doc) off)]
                      (lsp-write-response
                        id
                        (lsp-document-highlight-results-json (& results))))]))
              (lsp-write-response id (lsp-json-array (json.list-empty))))]
          [(JsonMissing)
            (lsp-write-response id (lsp-json-array (json.list-empty)))]))]
    [(Missing) (lsp-write-response id (lsp-json-array (json.list-empty)))]))

;; --------------------------------------------------------------------------
;; Folding ranges (textDocument/foldingRange).
;;
;; One linear lexical pass over the document, sharing the skip rules used by
;; definition/document-symbol discovery, so delimiters inside
;; strings, character literals, and comments never open or close a fold.
;;
;; A multiline `(`/`[` form folds from just after its opening delimiter to just
;; before its matching closer, which keeps the closer visible in clients that
;; honour range characters (Lisp stacks closers on the last content line, so a
;; whole-line range would hide it). Single-line forms are dropped, and a form
;; that is never closed simply never produces a range.
;;
;; A run of two or more adjacent comment-only lines folds as a `comment`
;; region from the end of its first line to the end of its last. Trailing
;; comments after code do not start a run.
;;
;; Ranges come out sorted by start position because every range reserves its
;; slot in the result vector at the moment its start is scanned, and the scan
;; only moves forward. Nesting is expressed through `parent`, so no separate
;; delimiter stack is needed and deep nesting costs no host recursion.
;;
;; Character columns use the position encoding negotiated at initialization.
;; --------------------------------------------------------------------------
(define lsp-fold-kind-region : i64
  0)
(define lsp-fold-kind-comment : i64
  1)

(define (lsp-fold-range-fallback) : lsp_vector_families.LspFoldRange
  (lsp_vector_families.LspFoldRange 0 0 0 0 lsp-fold-kind-region -1 false))

;; Advance the cursor across `[from, to)`. Used for spans the lexical skips
;; consume in one step (comments, strings, character literals), which may cross
;; line boundaries.
(define (lsp-fold-cursor-advance!
  [cursor : (&mut LspFoldCursor)]
  [text : (& text str)]
  [from : i64]
  [to : i64]) : unit
  (let
    [i : i64 from]
    (while (< i to)
      (let
        [c : char (string.string-ref text i)]
        (begin
          (if (= c '\n')
            (begin
              (set! cursor.line (+ cursor.line 1))
              (set! cursor.col 1)
              (set! cursor.code false))
            (begin
              (set! cursor.col (+ cursor.col (lsp-position-units-for-byte c)))
              (if (source_text.source-text-space? c)
                unit
                (set! cursor.code true))))
          (set! i (+ i 1)))))))

(define (lsp-fold-clamp [value : i64] [limit : i64]) : i64
  (if (> value limit)
    limit
    value))

;; Extend the running comment block, or open a new one when the previous
;; comment-only line was not the immediately preceding line.
(define (lsp-fold-comment-line!
  [folds : (&mut lsp_vector_families.LspFoldRanges)]
  [slot : i64]
  [previous-line : i64]
  [line : i64]
  [end-col : i64]) : i64
  (if (and (>= slot 0) (= line (+ previous-line 1)))
    (let
      [open : lsp_vector_families.LspFoldRange
        (lsp_vector_families.lsp-fold-ranges-get
          folds
          slot
          (lsp-fold-range-fallback))]
      (begin
        (lsp_vector_families.lsp-fold-ranges-set!
          folds
          slot
          (lsp_vector_families.LspFoldRange
            open.start-line
            open.start-char
            line
            end-col
            lsp-fold-kind-comment
            -1
            true))
        slot))
    (let
      [fresh : i64 (lsp_vector_families.lsp-fold-ranges-len folds)]
      (begin
        (lsp_vector_families.lsp-fold-ranges-push!
          folds
          (lsp_vector_families.LspFoldRange
            line
            end-col
            line
            end-col
            lsp-fold-kind-comment
            -1
            false))
        fresh))))

(define (lsp-fold-ranges-scan [text : (& text str)]) : lsp_vector_families.LspFoldRanges
  (let
    [n : i64 (string.string-length text)]
    [folds : lsp_vector_families.LspFoldRanges
      (lsp_vector_families.lsp-fold-ranges-new)]
    [cursor : LspFoldCursor (LspFoldCursor 1 1 false)]
    [i : i64 0]
    [top : i64 -1]
    [comment-slot : i64 -1]
    [comment-line : i64 -2]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c '\n')
              (begin
                (set! cursor.line (+ cursor.line 1))
                (set! cursor.col 1)
                (set! cursor.code false)
                (set! i (+ i 1)))]
            [(= c ';')
              (let
                [own-line? : bool (not cursor.code)]
                [line : i64 cursor.line]
                [past : i64
                  (lsp-fold-clamp
                    (source_text.source-text-skip-line text i n)
                    n)]
                [eol : i64
                  (if (and
                    (> past i)
                    (= (string.string-ref text (- past 1)) '\n'))
                    (- past 1)
                    past)]
                (begin
                  (lsp-fold-cursor-advance! (&mut cursor) text i eol)
                  (if own-line?
                    (begin
                      (set!
                        comment-slot
                        (lsp-fold-comment-line!
                          (&mut folds)
                          comment-slot
                          comment-line
                          line
                          cursor.col))
                      (set! comment-line line))
                    unit)
                  (lsp-fold-cursor-advance! (&mut cursor) text eol past)
                  (set! i past)))]
            [(= c '"')
              (let
                [past : i64
                  (lsp-fold-clamp
                    (source_text.source-text-skip-string text i n)
                    n)]
                (begin
                  (lsp-fold-cursor-advance! (&mut cursor) text i past)
                  (set! cursor.code true)
                  (set! i past)))]
            [(= c '\'')
              (let
                [past : i64
                  (lsp-fold-clamp
                    (source_text.source-text-skip-char-literal text i n)
                    n)]
                (begin
                  (lsp-fold-cursor-advance! (&mut cursor) text i past)
                  (set! cursor.code true)
                  (set! i past)))]
            [(or (= c '(') (= c '['))
              (begin
                (lsp_vector_families.lsp-fold-ranges-push!
                  (&mut folds)
                  (lsp_vector_families.LspFoldRange
                    cursor.line
                    (+ cursor.col 1)
                    0
                    0
                    lsp-fold-kind-region
                    top
                    false))
                (set!
                  top
                  (- (lsp_vector_families.lsp-fold-ranges-len (& folds)) 1))
                (set! cursor.col (+ cursor.col 1))
                (set! cursor.code true)
                (set! i (+ i 1)))]
            [(or (= c ')') (= c ']'))
              (begin
                (if (>= top 0)
                  (let
                    [open : lsp_vector_families.LspFoldRange
                      (lsp_vector_families.lsp-fold-ranges-get
                        (& folds)
                        top
                        (lsp-fold-range-fallback))]
                    [parent : i64 open.parent]
                    (begin
                      (if (> cursor.line open.start-line)
                        (lsp_vector_families.lsp-fold-ranges-set!
                          (&mut folds)
                          top
                          (lsp_vector_families.LspFoldRange
                            open.start-line
                            open.start-char
                            cursor.line
                            cursor.col
                            lsp-fold-kind-region
                            -1
                            true))
                        unit)
                      (set! top parent)))
                  unit)
                (set! cursor.col (+ cursor.col 1))
                (set! cursor.code true)
                (set! i (+ i 1)))]
            [else
              (begin
                (set! cursor.col (+ cursor.col (lsp-position-units-for-byte c)))
                (if (source_text.source-text-space? c)
                  unit
                  (set! cursor.code true))
                (set! i (+ i 1)))])))
      folds)))

(define (lsp-fold-range-json [fold : lsp_vector_families.LspFoldRange]) : json.Json
  (lsp-json-object
    (lsp-json-member
      "startLine"
      (lsp-json-number (lsp-zero-based fold.start-line))
      (lsp-json-member
        "startCharacter"
        (lsp-json-number (lsp-zero-based fold.start-char))
        (lsp-json-member
          "endLine"
          (lsp-json-number (lsp-zero-based fold.end-line))
          (lsp-json-member
            "endCharacter"
            (lsp-json-number (lsp-zero-based fold.end-char))
            (if (= fold.kind lsp-fold-kind-comment)
              (lsp-json-member
                "kind"
                (JsonString "comment")
                (json.member-list-empty))
              (json.member-list-empty))))))))

;; Start-ordered folding ranges. The result vector is already in start order,
;; so a reverse walk cons'd onto an accumulator emits forward order without
;; recursion over the document.
(define (lsp-folding-ranges-in-text [text : String]) : json.JsonSeq
  (let
    [folds : lsp_vector_families.LspFoldRanges (lsp-fold-ranges-scan text)]
    [i : i64 (- (lsp_vector_families.lsp-fold-ranges-len (& folds)) 1)]
    [acc : json.JsonSeq (json.list-empty)]
    (begin
      (while (>= i 0)
        (let
          [fold : lsp_vector_families.LspFoldRange
            (lsp_vector_families.lsp-fold-ranges-get
              (& folds)
              i
              (lsp-fold-range-fallback))]
          (begin
            (if fold.emit
              (set! acc (lsp-json-list-cons (lsp-fold-range-json fold) acc))
              unit)
            (set! i (- i 1)))))
      acc)))

(define (lsp-handle-folding-range
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : unit
  (match (lsp-get-document params docs)
    [(Found _ text _)
      (lsp-write-response id (lsp-json-array (lsp-folding-ranges-in-text text)))]
    [(Missing) (lsp-write-response id (lsp-json-array (json.list-empty)))]))

;; tl/appendFunction - Append a form at the end of the file
(define (lsp-handle-tl-append-function
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (match (lsp-json-string-field params "newText")
        [(Ok new-text)
          (if (not
            (lsp-text-is-valid-forms
              (owned_view.compiler-owned-shared-view new-text)))
            (begin
              (lsp-write-error
                id
                -32600
                (lsp-str2
                  "newText is not valid form(s): "
                  (lsp-validate-forms-error new-text)))
              (LspDocumentHandleResult.Continue docs))
            (let
              [n : i64 (lsp_decl_vec.len (& decls))]
              [result : String ""]
              (begin
                (if (= n 0)
                  (set! result (lsp-str3 text "\n\n" new-text))
                  (let
                    [last-entry : lsp_vector_families.LspDeclEntry
                      (lsp_decl_vec.get
                        (& decls)
                        (- n 1)
                        (lsp-decl-entry-fallback))]
                    (set!
                      result
                      (lsp-edit-at-pos
                        text
                        last-entry.form-end-line
                        last-entry.form-end-col
                        last-entry.form-end-line
                        last-entry.form-end-col
                        (lsp-str2 "\n\n" new-text)))))
                (lsp-write-structural-edit-success id params docs result))))]
        [(Missing)
          (begin
            (lsp-write-error id -32600 "Missing newText parameter")
            (LspDocumentHandleResult.Continue docs))])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; Document/provider dispatch. The production wrapper below owns workspace
;; state and adapts these existing document-only handlers.
(define (lsp-handle-document-message
  [message : json.Json]
  [docs : lsp_document_vec.Vec]
  [stdlib-roots : lsp_svec.Vec]
  [job-state : tc.TcJobState]) : LspDocumentHandleResult
  (match (lsp-json-string-field message "method")
    [(Ok method)
      (let
        [handled : bool false]
        [result : LspDocumentHandleResult
          (LspDocumentHandleResult.Continue
            (owned_view.compiler-owned-shared-view docs))]
        (begin
          (if (and (not handled) (string.eq method "initialize"))
            (begin
              (set! handled true)
              (let
                [key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& key))
                  [(JsonFound id)
                    (match (lsp-initialize-language-config
                      (owned_view.compiler-owned-shared-view message))
                      [(Ok target cfg-names)
                        (begin
                          (lsp-language-config-install! target cfg-names)
                          (set!
                            lsp-position-encoding-utf8
                            (lsp-initialize-position-encoding-utf8?
                              (owned_view.compiler-owned-shared-view message)))
                          (lsp-write-response id (lsp-initialize-result)))]
                      [(Err config-error)
                        (lsp-write-error id -32602 config-error)])]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and (not handled) (string.eq method "initialized"))
            (begin
              (set! handled true)
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and (not handled) (string.eq method "shutdown"))
            (begin
              (set! handled true)
              (let
                [key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& key))
                  [(JsonFound id) (lsp-write-response id JsonNull)]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and (not handled) (string.eq method "exit"))
            (begin
              (set! handled true)
              (set! result (Exit (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and (not handled) (string.eq method "textDocument/didOpen"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& key))
                  [(JsonFound params)
                    (set!
                      result
                      (lsp-did-open
                        params
                        (owned_view.compiler-owned-shared-view docs)
                        (owned_view.compiler-owned-shared-view stdlib-roots)))]
                  [(JsonMissing)
                    (set!
                      result
                      (LspDocumentHandleResult.Continue
                        (owned_view.compiler-owned-shared-view docs)))])))
            unit)
          (if (and (not handled) (string.eq method "textDocument/didChange"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& key))
                  [(JsonFound params)
                    (set!
                      result
                      (lsp-did-change
                        params
                        (owned_view.compiler-owned-shared-view docs)
                        (owned_view.compiler-owned-shared-view stdlib-roots)))]
                  [(JsonMissing)
                    (set!
                      result
                      (LspDocumentHandleResult.Continue
                        (owned_view.compiler-owned-shared-view docs)))])))
            unit)
          (if (and (not handled) (string.eq method "textDocument/didClose"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& key))
                  [(JsonFound params)
                    (set!
                      result
                      (lsp-did-close
                        params
                        (owned_view.compiler-owned-shared-view docs)))]
                  [(JsonMissing)
                    (set!
                      result
                      (LspDocumentHandleResult.Continue
                        (owned_view.compiler-owned-shared-view docs)))])))
            unit)
          (if (and (not handled) (string.eq method "textDocument/codeAction"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.object-get
                        (owned_view.compiler-owned-shared-view message)
                        (& params-key))
                        [(JsonFound params)
                          (lsp-handle-code-action
                            id
                            params
                            docs
                            (owned_view.compiler-owned-shared-view stdlib-roots))]
                        [(JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array (json.list-empty)))]))]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and (not handled) (string.eq method "textDocument/definition"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.object-get
                        (owned_view.compiler-owned-shared-view message)
                        (& params-key))
                        [(JsonFound params)
                          (lsp-handle-definition
                            id
                            params
                            docs
                            (owned_view.compiler-owned-shared-view stdlib-roots))]
                        [(JsonMissing) (lsp-write-response id JsonNull)]))]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and
            (not handled)
            (string.eq method "textDocument/documentSymbol"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.object-get
                        (owned_view.compiler-owned-shared-view message)
                        (& params-key))
                        [(JsonFound params)
                          (lsp-handle-document-symbol
                            id
                            params
                            (owned_view.compiler-owned-shared-view docs))]
                        [(JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array (json.list-empty)))]))]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and
            (not handled)
            (string.eq method "textDocument/documentHighlight"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.object-get
                        (owned_view.compiler-owned-shared-view message)
                        (& params-key))
                        [(JsonFound params)
                          (lsp-handle-document-highlight
                            id
                            params
                            (owned_view.compiler-owned-shared-view docs))]
                        [(JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array (json.list-empty)))]))]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and
            (not handled)
            (string.eq method "textDocument/signatureHelp"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.object-get
                        (owned_view.compiler-owned-shared-view message)
                        (& params-key))
                        [(JsonFound params)
                          (lsp-signature-help-respond id params docs)]
                        [(JsonMissing) (lsp-write-response id JsonNull)]))]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and (not handled) (string.eq method "textDocument/inlayHint"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.object-get
                        (owned_view.compiler-owned-shared-view message)
                        (& params-key))
                        [(JsonFound params)
                          (lsp-handle-inlay
                            id
                            params
                            docs
                            (owned_view.compiler-owned-shared-view stdlib-roots)
                            job-state)]
                        [(JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array (json.list-empty)))]))]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and (not handled) (string.eq method "textDocument/formatting"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.object-get
                        (owned_view.compiler-owned-shared-view message)
                        (& params-key))
                        [(JsonFound params)
                          (lsp-handle-formatting id params docs)]
                        [(JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array (json.list-empty)))]))]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and (not handled) (string.eq method "textDocument/hover"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.object-get
                        (owned_view.compiler-owned-shared-view message)
                        (& params-key))
                        [(JsonFound params) (lsp-handle-hover id params docs)]
                        [(JsonMissing) (lsp-write-response id JsonNull)]))]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and (not handled) (string.eq method "textDocument/documentLink"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.object-get
                        (owned_view.compiler-owned-shared-view message)
                        (& params-key))
                        [(JsonFound params)
                          (lsp-handle-document-link
                            id
                            params
                            docs
                            (owned_view.compiler-owned-shared-view stdlib-roots))]
                        [(JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array (json.list-empty)))]))]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (and (not handled) (string.eq method "textDocument/foldingRange"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.object-get
                  (owned_view.compiler-owned-shared-view message)
                  (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.object-get
                        (owned_view.compiler-owned-shared-view message)
                        (& params-key))
                        [(JsonFound params)
                          (lsp-handle-folding-range
                            id
                            params
                            (owned_view.compiler-owned-shared-view docs))]
                        [(JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array (json.list-empty)))]))]
                  [(JsonMissing) unit]))
              (set!
                result
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))))
            unit)
          (if (not handled)
            (let
              [enclosing : i64 (arena.tl_arena_current)]
              [scratch : i64 (arena.tl_arena_make)]
              [old-cache-arena : i64 lsp-document-cache-arena]
              [tool-result : LspDocumentHandleResult
                (LspDocumentHandleResult.Continue
                  (owned_view.compiler-owned-shared-view docs))]
              (begin
                (set!
                  lsp-document-cache-arena
                  (if (> old-cache-arena 0)
                    old-cache-arena
                    enclosing))
                (unsafe
                  (arena.tl_arena_set scratch))
                (set!
                  tool-result
                  (lsp-handle-tool-message!
                    method
                    message
                    docs
                    stdlib-roots
                    job-state))
                (begin
                  (unsafe
                    (arena.tl_arena_set enclosing))
                  (set! lsp-document-cache-arena old-cache-arena)
                  (unsafe
                    (arena.tl_arena_destroy scratch))
                  (set! result tool-result))))
            unit)
          result))]
    [(Missing) (LspDocumentHandleResult.Continue docs)]))

(define (lsp-tool-method-mutates-document? [method : (& method str)]) : bool
  (or
    (string.eq method "tl/replace")
    (string.eq method "tl/move")
    (string.eq method "tl/appendFunction")
    (string.eq method "tl/replaceBody")
    (string.eq method "tl/replacePattern")
    (string.eq method "tl/patch")
    (string.eq method "tl/delete")
    (string.eq method "tl/insertAfter")
    (string.eq method "tl/batch")))

(define (lsp-handle-initialize-state
  [message : json.Json]
  [state : lsp_vector_families.LspServerState]) : LspHandleResult
  (let
    [id-key : String "id"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view message)
      (& id-key))
      [(JsonMissing) (Continue state)]
      [(JsonFound id)
        (match (lsp-initialize-language-config
          (owned_view.compiler-owned-shared-view message))
          [(Err config-error)
            (begin
              (lsp-write-error id -32602 config-error)
              (Continue state))]
          [(Ok target cfg-names)
            (begin
              (lsp-language-config-install! target cfg-names)
              (set!
                lsp-position-encoding-utf8
                (lsp-initialize-position-encoding-utf8?
                  (owned_view.compiler-owned-shared-view message)))
              ;; Declaration ranges are scanned only after the negotiated
              ;; encoding has been installed.
              (let
                [next : lsp_vector_families.LspServerState
                  (lsp-server-state-initialize-workspaces state message)]
                (begin
                  (lsp-write-response id (lsp-initialize-result))
                  (Continue next))))])])))

(define (lsp-handle-document-event
  [method : String]
  [params : json.Json]
  [state : lsp_vector_families.LspServerState]
  [stdlib-roots : lsp_svec.Vec]) : LspHandleResult
  (match (lsp-tl-request-uri (owned_view.compiler-owned-shared-view params))
    [(Missing) (Continue state)]
    [(Ok uri)
      (cond
        [(string.eq method "textDocument/didOpen")
          (lsp-server-state-refresh-document-result
            (owned_view.compiler-owned-shared-view state)
            (lsp-did-open params state.documents stdlib-roots)
            uri
            false)]
        [(string.eq method "textDocument/didChange")
          (lsp-server-state-refresh-document-result
            (owned_view.compiler-owned-shared-view state)
            (lsp-did-change params state.documents stdlib-roots)
            uri
            false)]
        [else
          ;; Closing an overlay reloads the current disk file when it remains
          ;; eligible; a preceding watched delete therefore removes the row.
          (lsp-server-state-refresh-document-result
            (owned_view.compiler-owned-shared-view state)
            (lsp-did-close params state.documents)
            uri
            false)])]))

(define (lsp-handle-stateful-notification
  [method : String]
  [message : json.Json]
  [state : lsp_vector_families.LspServerState]
  [stdlib-roots : lsp_svec.Vec]) : LspHandleResult
  (let
    [params-key : String "params"]
    (match (json.object-get message (& params-key))
      [(JsonMissing) (Continue state)]
      [(JsonFound params)
        (cond
          [(or
              (string.eq method "textDocument/didOpen")
              (string.eq method "textDocument/didChange")
              (string.eq method "textDocument/didClose"))
            (lsp-handle-document-event method params state stdlib-roots)]
          [(string.eq method "workspace/didChangeWatchedFiles")
            (Continue (lsp-server-state-did-change-watched-files state params))]
          [else
            (Continue
              (lsp-server-state-did-change-workspace-folders state params))])])))

(define (lsp-handle-workspace-symbol-with-params!
  [id : json.Json]
  [params : json.Json]
  [state : (& state lsp_vector_families.LspServerState)]) : unit
  (match (lsp-json-string-field params "query")
    [(Missing)
      (lsp-write-error id -32602 "workspace/symbol requires a string query")]
    [(Ok query)
      (lsp-write-response
        id
        (lsp-workspace-symbol-result-json (& state.workspace) query))]))

(define (lsp-handle-project-search-with-params!
  [id : json.Json]
  [params : json.Json]
  [state : (& state lsp_vector_families.LspServerState)]) : unit
  (match (lsp-json-string-field params "name")
    [(Missing) (lsp-write-error id -32600 "Missing name parameter")]
    [(Ok name)
      (if (= (string.string-length name) 0)
        (lsp-write-error id -32600 "name cannot be empty")
        (lsp-write-response
          id
          (lsp-project-search-result-json (& state.workspace) name)))]))

(define (lsp-reference-include-declaration? [params : json.Json]) : bool
  (let
    [context-key : String "context"]
    [include-key : String "includeDeclaration"]
    (match (json.object-get params (& context-key))
      [(JsonMissing) false]
      [(JsonFound context)
        (match (json.object-get context (& include-key))
          [(JsonMissing) false]
          [(JsonFound include)
            (match include
              [(JsonBool enabled) enabled]
              [_ false])])])))

(define (lsp-reference-write-query-result!
  [id : json.Json]
  [query : (& query LspWorkspaceSemanticQuery)]
  [include-declaration : bool]) : unit
  (if (= query.completeness 0)
    (lsp-write-response
      id
      (lsp-reference-result-json query include-declaration))
    (lsp-write-error
      id
      -32803
      "Workspace semantic references are currently incomplete")))

(define (lsp-reference-query-with-key!
  [id : json.Json]
  [state : lsp_vector_families.LspServerState]
  [stdlib-roots : lsp_svec.Vec]
  [canonical-key : (& canonical-key str)]
  [include-declaration : bool]) : lsp_vector_families.LspServerState
  (let
    [query : LspWorkspaceSemanticQuery
      (lsp-workspace-semantic-query (& state) stdlib-roots canonical-key)]
    (if (= query.completeness 1)
      (let
        [refreshed : lsp_vector_families.LspServerState
          (lsp-server-state-refresh-semantic-cache
            state
            (lsp-global-shared-view stdlib-roots))]
        [refreshed-query : LspWorkspaceSemanticQuery
          (lsp-workspace-semantic-query
            (& refreshed)
            stdlib-roots
            canonical-key)]
        (begin
          (lsp-reference-write-query-result!
            id
            (& refreshed-query)
            include-declaration)
          refreshed))
      (begin
        (lsp-reference-write-query-result! id (& query) include-declaration)
        state))))

(define (lsp-handle-references-position!
  [id : json.Json]
  [position : json.Json]
  [params : json.Json]
  [state : lsp_vector_families.LspServerState]
  [stdlib-roots : lsp_svec.Vec]
  [doc : (& doc lsp_vector_families.LspDocument)]) : lsp_vector_families.LspServerState
  (if (not
    (and
      (lsp-json-int-field-usable? (lsp-global-shared-view position) "line")
      (lsp-json-int-field-usable? (lsp-global-shared-view position) "character")))
    (begin
      (lsp-write-response id (lsp-json-array (json.list-empty)))
      state)
    (let
      [line : i64 (lsp-json-int-field-default position "line" -1)]
      [character : i64 (lsp-json-int-field-default position "character" -1)]
      (match (lsp-offset-at-position-checked
        (string.copy (& doc.text))
        line
        character)
        [(Missing)
          (begin
            (lsp-write-response id (lsp-json-array (json.list-empty)))
            state)]
        [(Found offset)
          (let
            [canonical-key : String
              (lsp-document-semantic-canonical-key-at doc offset)]
            (if (= (string.string-length canonical-key) 0)
              (begin
                (lsp-write-response id (lsp-json-array (json.list-empty)))
                state)
              (lsp-reference-query-with-key!
                id
                state
                stdlib-roots
                canonical-key
                (lsp-reference-include-declaration? params))))]))))

(define (lsp-handle-references-with-params!
  [id : json.Json]
  [params : json.Json]
  [state : lsp_vector_families.LspServerState]
  [stdlib-roots : lsp_svec.Vec]) : lsp_vector_families.LspServerState
  (match (lsp-tl-request-uri (lsp-global-shared-view params))
    [(Missing)
      (begin
        (lsp-write-response id (lsp-json-array (json.list-empty)))
        state)]
    [(Ok uri)
      (let
        [doc-index : i64 (lsp-documents-find-index state.documents uri)]
        (if (< doc-index 0)
          (begin
            (lsp-write-response id (lsp-json-array (json.list-empty)))
            state)
          (let
            [position-key : String "position"]
            [doc : lsp_vector_families.LspDocument
              (lsp_document_vec.get
                (& state.documents)
                doc-index
                (lsp-document-fallback))]
            (match (json.object-get
              (lsp-global-shared-view params)
              (& position-key))
              [(JsonMissing)
                (begin
                  (lsp-write-response id (lsp-json-array (json.list-empty)))
                  state)]
              [(JsonFound position)
                (lsp-handle-references-position!
                  id
                  position
                  params
                  state
                  stdlib-roots
                  (& doc))]))))]))

;; References may refresh the persistent unopened-source cache. Request-local
;; keys, facts, and JSON live in a scratch arena and are released after the
;; response has been framed, while a refreshed state keeps its own arena.
(define (lsp-handle-references-message
  [message : json.Json]
  [state : lsp_vector_families.LspServerState]
  [stdlib-roots : lsp_svec.Vec]) : LspHandleResult
  (let
    [id-key : String "id"]
    (match (json.object-get (lsp-global-shared-view message) (& id-key))
      [(JsonMissing) (Continue state)]
      [(JsonFound id)
        (let
          [previous : i64 (arena.tl_arena_current)]
          [scratch : i64 (arena.tl_arena_make)]
          [_install : unit
            (unsafe
              (arena.tl_arena_set scratch))]
          [params-key : String "params"]
          [next : lsp_vector_families.LspServerState
            (match (json.object-get message (& params-key))
              [(JsonMissing)
                (begin
                  (lsp-write-response id (lsp-json-array (json.list-empty)))
                  state)]
              [(JsonFound params)
                (lsp-handle-references-with-params!
                  id
                  params
                  state
                  stdlib-roots)])]
          (begin
            (unsafe
              (arena.tl_arena_set previous))
            (unsafe
              (arena.tl_arena_destroy scratch))
            (Continue next)))])))

(define (lsp-rename-write-result!
  [method : String]
  [id : json.Json]
  [params : json.Json]
  [state : (& state lsp_vector_families.LspServerState)]
  [query : (& query LspWorkspaceSemanticQuery)]
  [target : LspRenameTarget]) : unit
  (if (string.eq method "textDocument/prepareRename")
    (match (lsp-rename-validate-query state query target "" false)
      [(Ok _) (lsp-write-response id (lsp-prepare-rename-result target))]
      [(Err message) (lsp-write-error id -32803 message)])
    (match (lsp-json-string-field params "newName")
      [(Missing)
        (lsp-write-error id -32602 "textDocument/rename requires newName")]
      [(Ok new-name)
        (cond
          [(not (lsp-rename-valid-new-name-for-target? target new-name))
            (lsp-write-error
              id
              -32602
              "newName is not a valid TypeLisp identifier")]
          [(string.eq new-name target.surface-name)
            (lsp-write-error id -32602 "newName is unchanged")]
          [else
            (match (lsp-rename-module-move
              state
              query
              (lsp-global-shared-view target)
              (lsp-global-shared-view new-name))
              [(Err message) (lsp-write-error id -32803 message)]
              [(Ok module-move)
                (match (lsp-rename-validate-query
                  state
                  query
                  target
                  (lsp-global-shared-view new-name)
                  true)
                  [(Ok _)
                    (lsp-write-response
                      id
                      (lsp-rename-workspace-edit
                        state
                        query
                        target
                        new-name
                        module-move))]
                  [(Err message) (lsp-write-error id -32803 message)])])])])))

(define (lsp-handle-rename-position!
  [method : String]
  [id : json.Json]
  [position : json.Json]
  [params : json.Json]
  [state : lsp_vector_families.LspServerState]
  [stdlib-roots : lsp_svec.Vec]
  [doc : (& doc lsp_vector_families.LspDocument)]) : lsp_vector_families.LspServerState
  (if (not
    (and
      (lsp-json-int-field-usable? (lsp-global-shared-view position) "line")
      (lsp-json-int-field-usable? (lsp-global-shared-view position) "character")))
    (begin
      (lsp-write-error id -32602 "Rename requires a valid position")
      state)
    (match (lsp-document-semantic-snapshot-status doc)
      [(Current _ complete)
        (if (not complete)
          (begin
            (lsp-write-error
              id
              -32803
              "Current document semantic snapshot is incomplete")
            state)
          (let
            [line : i64 (lsp-json-int-field-default position "line" -1)]
            [character : i64
              (lsp-json-int-field-default position "character" -1)]
            (match (lsp-offset-at-position-checked
              (string.copy (& doc.text))
              line
              character)
              [(Missing)
                (begin
                  (lsp-write-response id JsonNull)
                  state)]
              [(Found offset)
                (match (lsp-rename-target-at doc offset)
                  [(Missing)
                    (begin
                      (lsp-write-response id JsonNull)
                      state)]
                  [(Found target)
                    (let
                      [query : LspWorkspaceSemanticQuery
                        (lsp-workspace-semantic-query
                          (& state)
                          stdlib-roots
                          target.canonical-key)]
                      (if (= query.completeness 1)
                        (let
                          [refreshed : lsp_vector_families.LspServerState
                            (lsp-server-state-refresh-semantic-cache
                              state
                              (lsp-global-shared-view stdlib-roots))]
                          [refreshed-query : LspWorkspaceSemanticQuery
                            (lsp-workspace-semantic-query
                              (& refreshed)
                              stdlib-roots
                              target.canonical-key)]
                          (begin
                            (lsp-rename-write-result!
                              method
                              id
                              params
                              (& refreshed)
                              (& refreshed-query)
                              target)
                            refreshed))
                        (begin
                          (lsp-rename-write-result!
                            method
                            id
                            params
                            (& state)
                            (& query)
                            target)
                          state)))])])))]
      [_
        (begin
          (lsp-write-error
            id
            -32803
            "Current document semantic snapshot is stale")
          state)])))

(define (lsp-handle-rename-with-params!
  [method : String]
  [id : json.Json]
  [params : json.Json]
  [state : lsp_vector_families.LspServerState]
  [stdlib-roots : lsp_svec.Vec]) : lsp_vector_families.LspServerState
  (match (lsp-tl-request-uri (lsp-global-shared-view params))
    [(Missing)
      (begin
        (lsp-write-error id -32602 "Rename requires textDocument.uri")
        state)]
    [(Ok uri)
      (let
        [doc-index : i64 (lsp-documents-find-index state.documents uri)]
        (if (< doc-index 0)
          (begin
            (lsp-write-response id JsonNull)
            state)
          (let
            [position-key : String "position"]
            [doc : lsp_vector_families.LspDocument
              (lsp_document_vec.get
                (& state.documents)
                doc-index
                (lsp-document-fallback))]
            (match (json.object-get
              (lsp-global-shared-view params)
              (& position-key))
              [(JsonMissing)
                (begin
                  (lsp-write-error id -32602 "Rename requires position")
                  state)]
              [(JsonFound position)
                (lsp-handle-rename-position!
                  method
                  id
                  position
                  params
                  state
                  stdlib-roots
                  (& doc))]))))]))

(define (lsp-handle-rename-message
  [method : String]
  [message : json.Json]
  [state : lsp_vector_families.LspServerState]
  [stdlib-roots : lsp_svec.Vec]) : LspHandleResult
  (let
    [id-key : String "id"]
    (match (json.object-get (lsp-global-shared-view message) (& id-key))
      [(JsonMissing) (Continue state)]
      [(JsonFound id)
        (let
          [previous : i64 (arena.tl_arena_current)]
          [scratch : i64 (arena.tl_arena_make)]
          [_install : unit
            (unsafe
              (arena.tl_arena_set scratch))]
          [params-key : String "params"]
          [next : lsp_vector_families.LspServerState
            (match (json.object-get message (& params-key))
              [(JsonMissing)
                (begin
                  (lsp-write-error id -32602 "Rename requires params")
                  state)]
              [(JsonFound params)
                (lsp-handle-rename-with-params!
                  method
                  id
                  params
                  state
                  stdlib-roots)])]
          (begin
            (unsafe
              (arena.tl_arena_set previous))
            (unsafe
              (arena.tl_arena_destroy scratch))
            (Continue next)))])))

;; Workspace queries are read-only and run in a request-local arena. Repeated
;; searches therefore retain neither candidate arrays nor JSON result graphs,
;; while the immutable state-owned declaration rows remain untouched.
(define (lsp-handle-workspace-query-message
  [method : String]
  [message : json.Json]
  [state : lsp_vector_families.LspServerState]) : LspHandleResult
  (let
    [id-key : String "id"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view message)
      (& id-key))
      [(JsonMissing) (Continue state)]
      [(JsonFound id)
        (let
          [previous : i64 (arena.tl_arena_current)]
          [scratch : i64 (arena.tl_arena_make)]
          [_install : unit
            (unsafe
              (arena.tl_arena_set scratch))]
          [params-key : String "params"]
          (begin
            (match (json.object-get message (& params-key))
              [(JsonMissing)
                (if (string.eq method "workspace/symbol")
                  (lsp-write-error
                    id
                    -32602
                    "workspace/symbol requires a string query")
                  (lsp-write-error id -32600 "Missing params"))]
              [(JsonFound params)
                (if (string.eq method "workspace/symbol")
                  (lsp-handle-workspace-symbol-with-params! id params (& state))
                  (lsp-handle-project-search-with-params! id params (& state)))])
            (unsafe
              (begin
                (arena.tl_arena_set previous)
                (arena.tl_arena_destroy scratch)))
            (Continue state)))])))

;; Semantic-token arrays and their lexical stream are request-local. The open
;; document and its immutable semantic owner remain in the server-state arena.
(define (lsp-handle-semantic-tokens-message
  [message : json.Json]
  [state : lsp_vector_families.LspServerState]) : LspHandleResult
  (let
    [id-key : String "id"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view message)
      (& id-key))
      [(JsonMissing) (Continue state)]
      [(JsonFound id)
        (let
          [previous : i64 (arena.tl_arena_current)]
          [scratch : i64 (arena.tl_arena_make)]
          [_install : unit
            (unsafe
              (arena.tl_arena_set scratch))]
          [params-key : String "params"]
          (begin
            (match (json.object-get message (& params-key))
              [(JsonMissing) (lsp-write-response id JsonNull)]
              [(JsonFound params)
                (lsp-handle-semantic-tokens-with-params!
                  id
                  params
                  (owned_view.compiler-owned-shared-view state.documents))])
            (unsafe
              (begin
                (arena.tl_arena_set previous)
                (arena.tl_arena_destroy scratch)))
            (Continue state)))])))

;; Production state dispatch. All long-lived data crosses the loop through the
;; explicit aggregate; document providers never receive mutable workspace
;; vectors.
(define (lsp-handle-message
  [message : json.Json]
  [state : lsp_vector_families.LspServerState]
  [stdlib-roots : lsp_svec.Vec]
  [job-state : tc.TcJobState]) : LspHandleResult
  (match (lsp-json-string-field message "method")
    [(Missing) (Continue state)]
    [(Ok method)
      (cond
        [(string.eq method "initialize")
          (lsp-handle-initialize-state message state)]
        [(or
            (string.eq method "textDocument/didOpen")
            (string.eq method "textDocument/didChange")
            (string.eq method "textDocument/didClose")
            (string.eq method "workspace/didChangeWatchedFiles")
            (string.eq method "workspace/didChangeWorkspaceFolders"))
          (lsp-handle-stateful-notification method message state stdlib-roots)]
        [(string.eq method "$/cancelRequest") (Continue state)]
        [(or
            (string.eq method "textDocument/prepareRename")
            (string.eq method "textDocument/rename"))
          (lsp-handle-rename-message method message state stdlib-roots)]
        [(string.eq method "textDocument/references")
          (lsp-handle-references-message message state stdlib-roots)]
        [(string.eq method "textDocument/completion")
          (lsp-handle-completion-message message state)]
        [(string.eq method "textDocument/semanticTokens/full")
          (lsp-handle-semantic-tokens-message message state)]
        [(or
            (string.eq method "workspace/symbol")
            (string.eq method "tl/projectSearch"))
          (lsp-handle-workspace-query-message method message state)]
        [else
          (let
            [document-result : LspDocumentHandleResult
              (lsp-handle-document-message
                message
                (owned_view.compiler-owned-shared-view state.documents)
                stdlib-roots
                job-state)]
            (cond
              [(lsp-tool-method-mutates-document? method)
                (lsp-server-state-copy-document-result
                  state
                  document-result
                  true)]
              ;; `tl/check` memoizes its result in the open document without
              ;; changing text or declarations.
              [(string.eq method "tl/check")
                (lsp-server-state-copy-document-result
                  state
                  document-result
                  false)]
              [else
                (match document-result
                  [(Continue _) (Continue state)]
                  [(Exit _) (Exit state)])]))])]))

(define (lsp-known-tool-method? [method : String]) : bool
  (or
    (string.eq method "tl/listFunctions")
    (string.eq method "tl/findPosition")
    (string.eq method "tl/replace")
    (string.eq method "tl/move")
    (string.eq method "tl/expandMacro")
    (string.eq method "tl/check")
    (string.eq method "tl/getType")
    (string.eq method "tl/appendFunction")
    (string.eq method "tl/replaceBody")
    (string.eq method "tl/replacePattern")
    (string.eq method "tl/patch")
    (string.eq method "tl/delete")
    (string.eq method "tl/insertAfter")
    (string.eq method "tl/batch")
    (string.eq method "tl/read")))

(define (lsp-handle-tool-missing-params!
  [method : String]
  [message : json.Json]
  [id : json.Json]) : unit
  (cond
    [(string.eq method "tl/listFunctions")
      (begin
        (lsp-write-response id (lsp-json-array (json.list-empty)))
        unit)]
    [(lsp-known-tool-method? method)
      (begin
        (lsp-write-error id -32600 "Missing params")
        unit)]
    [else
      (begin
        (lsp-maybe-write-method-not-found message)
        unit)]))

(define (lsp-handle-tool-with-params!
  [method : String]
  [message : json.Json]
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]
  [stdlib-roots : lsp_svec.Vec]
  [job-state : tc.TcJobState]) : LspDocumentHandleResult
  (cond
    [(string.eq method "tl/listFunctions")
      (lsp-handle-tl-list-functions id params docs)]
    [(string.eq method "tl/findPosition")
      (lsp-handle-tl-find-position id params docs)]
    [(string.eq method "tl/replace")
      (lsp-handle-tl-structural-replace-at id params docs)]
    [(string.eq method "tl/move")
      (lsp-handle-tl-structural-move id params docs)]
    [(string.eq method "tl/expandMacro")
      (lsp-handle-tl-expand-macro id params docs)]
    [(string.eq method "tl/check")
      (lsp-handle-tl-check id params docs stdlib-roots)]
    [(string.eq method "tl/getType")
      (let
        [tool-result : LspDocumentHandleResult
          (LspDocumentHandleResult.Continue
            (owned_view.compiler-owned-shared-view docs))]
        (begin
          (lsp-typecheck-tool-session-before!)
          (set!
            tool-result
            (lsp-handle-tl-get-type-at id params docs stdlib-roots job-state))
          (lsp-typecheck-tool-session-after!)
          tool-result))]
    [(string.eq method "tl/appendFunction")
      (lsp-handle-tl-append-function id params docs)]
    [(string.eq method "tl/replaceBody")
      (lsp-handle-tl-replace-body id params docs)]
    [(string.eq method "tl/replacePattern")
      (lsp-handle-tl-replace-pattern-at id params docs)]
    [(string.eq method "tl/patch") (lsp-handle-tl-patch id params docs)]
    [(string.eq method "tl/delete") (lsp-handle-tl-delete-at id params docs)]
    [(string.eq method "tl/insertAfter")
      (lsp-handle-tl-insert-after id params docs)]
    [(string.eq method "tl/batch") (lsp-handle-tl-batch id params docs)]
    [(string.eq method "tl/read") (lsp-handle-tl-read-form-at id params docs)]
    [else
      (begin
        (lsp-maybe-write-method-not-found message)
        (LspDocumentHandleResult.Continue docs))]))

(define (lsp-handle-tool-message!
  [method : String]
  [message : json.Json]
  [docs : lsp_document_vec.Vec]
  [stdlib-roots : lsp_svec.Vec]
  [job-state : tc.TcJobState]) : LspDocumentHandleResult
  (let
    [id-key : String "id"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view message)
      (& id-key))
      [(JsonFound id)
        (let
          [params-key : String "params"]
          (match (json.object-get
            (owned_view.compiler-owned-shared-view message)
            (& params-key))
            [(JsonFound params)
              (lsp-handle-tool-with-params!
                method
                message
                id
                params
                docs
                stdlib-roots
                job-state)]
            [(JsonMissing)
              (begin
                (lsp-handle-tool-missing-params! method message id)
                (LspDocumentHandleResult.Continue docs))]))]
      [(JsonMissing)
        (begin
          (if (not (lsp-known-tool-method? method))
            (lsp-maybe-write-method-not-found message)
            unit)
          (LspDocumentHandleResult.Continue docs))])))

(define (lsp-stdlib-roots-from [idx : i64] [count : i64]) : lsp_svec.Vec
  (let
    [i : i64 idx]
    [roots : lsp_svec.Vec (lsp_svec.new)]
    (begin
      (while (< i count)
        (if (string.eq (io.arg i) "--stdlib-root")
          (if (< (+ i 1) count)
            (begin
              (lsp_svec.push-ref! (&mut roots) (io.arg (+ i 1)))
              (set! i (+ i 2)))
            (set! i count))
          (set! i (+ i 1))))
      roots)))

(define (lsp-prefix-cache-stats-from [idx : i64] [count : i64]) : bool
  (let
    [i : i64 idx]
    [enabled : bool false]
    (begin
      (while (< i count)
        (begin
          (if (string.eq (io.arg i) "--prefix-cache-stats")
            (set! enabled true)
            unit)
          (set! i (+ i 1))))
      enabled)))

(define (lsp-frame-session-cache-enable!) : unit
  (compiler_load.compiler-load-session-cache-enable!))

(define (lsp-frame-run-with-config
  [stdlib-roots : lsp_svec.Vec]
  [prefix-cache-stats : bool]) : i64
  (let
    [done : bool false]
    [status : i64 0]
    [state : lsp_vector_families.LspServerState (lsp-server-state-new)]
    [job-state : tc.TcJobState (tc.tc-job-state-new)]
    (begin
      (lsp-language-config-reset!)
      (lsp-frame-session-cache-enable!)
      (while (not done)
        (match (lsp-frame-read-message)
          [(Ok payload)
            (let
              [text : String payload]
              (match (json.parse (& text))
                [(OkJson message)
                  (match (lsp-handle-message
                    message
                    (owned_view.compiler-owned-shared-view state)
                    (owned_view.compiler-owned-shared-view stdlib-roots)
                    job-state)
                    [(Continue next-state) (set! state next-state)]
                    [(Exit next-state)
                      (begin
                        (set! state next-state)
                        (set! done true))])]
                [(ErrJson message) (lsp-write-parse-error message)]))]
          [(Eof) (set! done true)]
          [(Err message)
            (begin
              (lsp-write-parse-error
                (owned_view.compiler-owned-shared-view message))
              (lsp-frame-stderr-write message)
              (set! status 1)
              (set! done true))]))
      (if prefix-cache-stats
        (tc.tc-prefix-snapshot-cache-print-stats "lsp")
        unit)
      (tc.tc-inlay-hints-reset-for-state!
        (tc.tc-job-state-inlay-hints job-state))
      (lsp-server-state-destroy! state)
      status)))

;; Clear every serial LSP/compiler owner before a transcript arena is retired.
;; Server state is destroyed by lsp-frame-run-with-config; clearing the cache
;; arena here leaves no owner visible to the next run.
(define (lsp-frame-fresh-session-reset!) : unit
  (begin
    (lsp-frame-memory-reset!)
    (lsp-language-config-reset!)
    (set! lsp-document-cache-arena 0)
    (tc.tc-prefix-snapshot-cache-clear!)
    (compiler_load.compiler-load-session-fresh-reset!)
    (tc.compiler-typecheck-reset-intern-owned-state!)
    (cbi.compiler-builtin-reset!)
    (ctfe.ctfe-builtin-reset!)
    (tc.compiler-typecheck-reset-file-state!)
    (ast.ast-node-pool-active-context-clear!)))

;; Run exact framed bytes through the production parser and request handlers.
;; Input and captured results live in the enclosing arena; all transient
;; parser, document, check, and transport state lives in a destroyable arena.
(define (lsp-frame-run-transcript
  [input : (& input str)]
  [stdlib-roots : lsp_svec.Vec]
  [prefix-cache-stats : bool]) : LspTranscriptResult
  (let
    [enclosing : i64 (arena.tl_arena_current)]
    [_fresh-before : unit (lsp-frame-fresh-session-reset!)]
    [session : i64 (arena.tl_arena_make)]
    [_install-session : unit
      (unsafe
        (arena.tl_arena_set session))]
    [transport : i64 (arena.tl_arena_make)]
    [_install-transport : unit (lsp-frame-memory-install! input transport)]
    [status : i64 (lsp-frame-run-with-config stdlib-roots prefix-cache-stats)]
    [_restore-enclosing : unit
      (unsafe
        (arena.tl_arena_set enclosing))]
    [captured-stdout : String (string.copy (& lsp-frame-memory-state.stdout))]
    [captured-stderr : String (string.copy (& lsp-frame-memory-state.stderr))]
    [transport-head : i64 lsp-frame-memory-state.owner.handle]
    [_fresh-after : unit (lsp-frame-fresh-session-reset!)]
    [_destroy-session : unit
      (unsafe
        (arena.tl_arena_destroy session))]
    [_destroy-transport : unit
      (unsafe
        (arena.tl_arena_destroy transport-head))]
    (LspTranscriptResult captured-stdout captured-stderr status)))

(define lsp-transcript-batch-header : String
  "typelisp-lsp-transcript-batch-v1")

(define (lsp-transcript-batch-tab
  [text : (& text str)]
  [start : i64]
  [end : i64]) : i64
  (let
    [i : i64 start]
    (begin
      (while (and (< i end) (not (= (string.string-ref text i) '\t')))
        (set! i (+ i 1)))
      i)))

(define (lsp-transcript-batch-field
  [text : (& text str)]
  [start : i64]
  [end : i64]) : String
  (string.substring text start (- end start)))

(define (lsp-transcript-batch-parse-entry
  [text : (& text str)]
  [start : i64]
  [end : i64]
  [line-number : i64]) : ResultLspTranscriptBatchEntry
  (let
    [tab1 : i64 (lsp-transcript-batch-tab text start end)]
    [tab2 : i64
      (if (< tab1 end)
        (lsp-transcript-batch-tab text (+ tab1 1) end)
        end)]
    [tab3 : i64
      (if (< tab2 end)
        (lsp-transcript-batch-tab text (+ tab2 1) end)
        end)]
    [tab4 : i64
      (if (< tab3 end)
        (lsp-transcript-batch-tab text (+ tab3 1) end)
        end)]
    [extra : i64
      (if (< tab4 end)
        (lsp-transcript-batch-tab text (+ tab4 1) end)
        end)]
    [line-label : String
      (str_cat.str-cat
        "lsp: invalid transcript batch manifest line "
        (string.int->string line-number))]
    (if (or (= tab1 end) (= tab2 end) (= tab3 end) (= tab4 end) (< extra end))
      (Err (str_cat.str-cat line-label ": expected five tab-separated fields"))
      (let
        [case-id : String (lsp-transcript-batch-field text start tab1)]
        [input-path : String (lsp-transcript-batch-field text (+ tab1 1) tab2)]
        [stdout-path : String (lsp-transcript-batch-field text (+ tab2 1) tab3)]
        [stderr-path : String (lsp-transcript-batch-field text (+ tab3 1) tab4)]
        [status-path : String (lsp-transcript-batch-field text (+ tab4 1) end)]
        (if (or
          (= (string.string-length case-id) 0)
          (= (string.string-length input-path) 0)
          (= (string.string-length stdout-path) 0)
          (= (string.string-length stderr-path) 0)
          (= (string.string-length status-path) 0))
          (Err (str_cat.str-cat line-label ": fields must be non-empty"))
          (Ok
            (LspTranscriptBatchEntry
              case-id
              input-path
              stdout-path
              stderr-path
              status-path)))))))

(define (lsp-transcript-batch-id-seen?
  [ids : (& ids lsp_svec.Vec)]
  [case-id : (& case-id str)]) : bool
  (let
    [i : i64 0]
    [seen : bool false]
    (begin
      (while (and (< i (lsp_svec.len (& ids))) (not seen))
        (begin
          (if (string.eq (lsp_svec.get (& ids) i "") case-id)
            (set! seen true)
            unit)
          (set! i (+ i 1))))
      seen)))

(define (lsp-transcript-batch-validate [text : (& text str)]) : String
  (let
    [n : i64 (string.string-length text)]
    [first-end : i64 (source_text.line-end text 0)]
    [first : String (lsp-transcript-batch-field text 0 first-end)]
    [cursor : i64 (source_text.next-line-start text first-end)]
    [line-number : i64 2]
    [entries : i64 0]
    [ids : lsp_svec.Vec (lsp_svec.new)]
    [result-paths : lsp_svec.Vec (lsp_svec.new)]
    [error : String ""]
    (begin
      (if (not (string.eq first lsp-transcript-batch-header))
        (set! error "lsp: invalid transcript batch manifest header")
        unit)
      (while (and (= (string.string-length error) 0) (< cursor n))
        (let
          [line-end : i64 (source_text.line-end text cursor)]
          [next : i64 (source_text.next-line-start text line-end)]
          (begin
            (if (= cursor line-end)
              (set!
                error
                (str_cat.str-cat
                  "lsp: invalid transcript batch manifest empty line "
                  (string.int->string line-number)))
              (match (lsp-transcript-batch-parse-entry
                text
                cursor
                line-end
                line-number)
                [(Err message) (set! error message)]
                [(Ok entry)
                  (let
                    [case-id : String entry.case-id]
                    [stdout-path : String entry.stdout-path]
                    [stderr-path : String entry.stderr-path]
                    [status-path : String entry.status-path]
                    (cond
                      [(lsp-transcript-batch-id-seen? ids case-id)
                        (set!
                          error
                          (str_cat.str-cat
                            "lsp: duplicate transcript batch case id: "
                            case-id))]
                      [(or
                          (lsp-transcript-batch-id-seen?
                            result-paths
                            stdout-path)
                          (lsp-transcript-batch-id-seen?
                            result-paths
                            stderr-path)
                          (lsp-transcript-batch-id-seen?
                            result-paths
                            status-path)
                          (string.eq stdout-path stderr-path)
                          (string.eq stdout-path status-path)
                          (string.eq stderr-path status-path))
                        (set!
                          error
                          (str_cat.str-cat
                            "lsp: duplicate transcript batch result path in case: "
                            case-id))]
                      [(not
                          (io.file-exists?
                            (owned_view.compiler-owned-shared-view
                              entry.input-path)))
                        (set!
                          error
                          (str_cat.str-cat
                            "lsp: transcript batch input does not exist: "
                            entry.input-path))]
                      [else
                        (begin
                          (lsp_svec.push-ref! (&mut ids) case-id)
                          (lsp_svec.push-ref! (&mut result-paths) stdout-path)
                          (lsp_svec.push-ref! (&mut result-paths) stderr-path)
                          (lsp_svec.push-ref! (&mut result-paths) status-path)
                          (set! entries (+ entries 1)))]))]))
            (set! cursor next)
            (set! line-number (+ line-number 1)))))
      (if (and (= (string.string-length error) 0) (= entries 0))
        "lsp: transcript batch manifest has no entries"
        error))))

(define (lsp-transcript-batch-run-entries
  [text : (& text str)]
  [stdlib-roots : lsp_svec.Vec]
  [prefix-cache-stats : bool]) : i64
  (let
    [n : i64 (string.string-length text)]
    [first-end : i64 (source_text.line-end text 0)]
    [cursor : i64 (source_text.next-line-start text first-end)]
    [line-number : i64 2]
    [status : i64 0]
    (begin
      (while (and (= status 0) (< cursor n))
        (let
          [line-end : i64 (source_text.line-end text cursor)]
          [next : i64 (source_text.next-line-start text line-end)]
          (begin
            (match (lsp-transcript-batch-parse-entry
              text
              cursor
              line-end
              line-number)
              [(Err message)
                (begin
                  (io.print-error message)
                  (io.print-error "\n")
                  (set! status 2))]
              [(Ok entry)
                (let
                  [input : String
                    (byte_buf.to-string (io.read-file entry.input-path))]
                  [result : LspTranscriptResult
                    (lsp-frame-run-transcript
                      (& input)
                      (owned_view.compiler-owned-shared-view stdlib-roots)
                      prefix-cache-stats)]
                  (begin
                    (lsp-write-file-text entry.stdout-path result.stdout)
                    (lsp-write-file-text entry.stderr-path result.stderr)
                    (lsp-write-file-text
                      entry.status-path
                      (str_cat.str-cat (string.int->string result.status) "\n"))
                    (io.print-format
                      "{}"
                      (lsp-str3
                        "lsp-transcript-batch-result\t"
                        entry.case-id
                        "\n"))))])
            (set! cursor next)
            (set! line-number (+ line-number 1)))))
      status)))

(define (lsp-transcript-batch-run
  [manifest-path : String]
  [stdlib-roots : lsp_svec.Vec]
  [prefix-cache-stats : bool]) : i64
  (if (not
    (io.file-exists? (owned_view.compiler-owned-shared-view manifest-path)))
    (begin
      (io.print-error
        (str_cat.str-cat
          "lsp: transcript batch manifest does not exist: "
          manifest-path))
      (io.print-error "\n")
      2)
    (let
      [text : String (byte_buf.to-string (io.read-file manifest-path))]
      [error : String (lsp-transcript-batch-validate text)]
      (if (> (string.string-length error) 0)
        (begin
          (io.print-error error)
          (io.print-error "\n")
          2)
        (lsp-transcript-batch-run-entries text stdlib-roots prefix-cache-stats)))))

(define (lsp-transcript-batch-option-from [idx : i64] [count : i64]) : LspTranscriptBatchOption
  (let
    [i : i64 idx]
    [path : String ""]
    [error : String ""]
    (begin
      (while (and (< i count) (= (string.string-length error) 0))
        (if (string.eq (io.arg i) "--transcript-batch")
          (if (>= (+ i 1) count)
            (set! error "lsp: --transcript-batch requires a manifest path")
            (if (> (string.string-length path) 0)
              (set! error "lsp: --transcript-batch was provided more than once")
              (begin
                (set! path (io.arg (+ i 1)))
                (set! i (+ i 1)))))
          unit)
        (set! i (+ i 1)))
      (if (> (string.string-length error) 0)
        (Err error)
        (if (> (string.string-length path) 0)
          (Path path)
          (None))))))

(define (lsp-frame-run-from [idx : i64] [count : i64]) : i64
  (let
    [roots : lsp_svec.Vec (lsp-stdlib-roots-from idx count)]
    [prefix-cache-stats : bool (lsp-prefix-cache-stats-from idx count)]
    (match (lsp-transcript-batch-option-from idx count)
      [(None) (lsp-frame-run-with-config roots prefix-cache-stats)]
      [(Path manifest-path)
        (lsp-transcript-batch-run manifest-path roots prefix-cache-stats)]
      [(Err message)
        (begin
          (io.print-error message)
          (io.print-error "\n")
          2)])))

(define (lsp-replace-pattern-words
  [text : String]
  [old : (& old str)]
  [new : String]) : String
  (let
    [n : i64 (string.string-length text)]
    [old-len : i64 (string.string-length old)]
    [result : String ""]
    [i : i64 0]
    (begin
      (while (<= i (- n old-len))
        (if (and
          (string.eq (string.substring text i old-len) old)
          (or (= i 0) (not (lsp-ident-char? (string.string-ref text (- i 1)))))
          (or
            (>= (+ i old-len) n)
            (not (lsp-ident-char? (string.string-ref text (+ i old-len))))))
          (begin
            (set!
              result
              (str_cat.str-cat
                result
                (owned_view.compiler-owned-shared-view new)
                ""))
            (set! i (+ i old-len)))
          (begin
            (set!
              result
              (str_cat.str-cat result (string.substring text i 1) ""))
            (set! i (+ i 1)))))
      (while (< i n)
        (begin
          (set! result (str_cat.str-cat result (string.substring text i 1) ""))
          (set! i (+ i 1))))
      result)))

(define (lsp-replace-body-text-with-decls
  [text : String]
  [name : String]
  [new-body : String]
  [decls : lsp_decl_vec.Vec]) : LspEditResult
  (let
    [i : i64 0]
    [n : i64 (lsp_decl_vec.len (& decls))]
    [found : bool false]
    [result : String ""]
    [err : String ""]
    (begin
      (while (and (< i n) (not found))
        (let
          [entry : lsp_vector_families.LspDeclEntry
            (lsp_decl_vec.get (& decls) i (lsp-decl-entry-fallback))]
          (if (string.eq entry.name name)
            (begin
              (set! found true)
              (let
                [kind : String entry.kind]
                [n2 : i64 (string.string-length text)]
                (if (or (string.eq kind "function") (string.eq kind "macro"))
                  (let
                    [form-start-off : i64
                      (lsp-offset-at-position
                        text
                        (- entry.form-start-line 1)
                        (- entry.form-start-col 1))]
                    [after-kw : i64
                      (source_text.source-text-skip-space
                        text
                        (+ form-start-off 1)
                        n2)]
                    [kw-end : i64 (lsp-scan-ident text after-kw n2)]
                    [after-kw2 : i64
                      (source_text.source-text-skip-space text kw-end n2)]
                    (if (and
                      (< after-kw2 n2)
                      (= (string.string-ref text after-kw2) '('))
                      (let
                        [body-start-off : i64
                          (lsp-find-body-start-offset text form-start-off)]
                        [body-end-off : i64
                          (-
                            (lsp-offset-at-position
                              text
                              (- entry.form-end-line 1)
                              (- entry.form-end-col 1))
                            1)]
                        [body-start-lc : LspLineCol
                          (lsp-line-col-at-offset text body-start-off)]
                        [body-end-lc : LspLineCol
                          (lsp-line-col-at-offset text body-end-off)]
                        (if (not
                          (lsp-text-is-valid-forms
                            (owned_view.compiler-owned-shared-view new-body)))
                          (begin
                            (set!
                              err
                              (lsp-str2
                                "newBody is not a valid form: "
                                (lsp-validate-forms-error
                                  (owned_view.compiler-owned-shared-view
                                    new-body))))
                            (set! result ""))
                          (set!
                            result
                            (lsp-edit-at-pos
                              (owned_view.compiler-owned-shared-view text)
                              body-start-lc.line
                              body-start-lc.col
                              body-end-lc.line
                              body-end-lc.col
                              (owned_view.compiler-owned-shared-view new-body)))))
                      (set!
                        err
                        "replaceBody only supported for function/macro definitions with parameter lists")))
                  (set!
                    err
                    "replaceBody only supported for define and defmacro"))))
            (begin
              (set! i (+ i 1))
              unit))))
      (unless found (return (Err "Declaration not found")))
      (unless (string.eq err "") (return (Err err)))
      (when (string.eq result "") (return (Err "replaceBody: unknown error")))
      (Ok result))))

(define (lsp-replace-pattern-text-with-decls
  [text : String]
  [name : String]
  [old-pattern : String]
  [new-pattern : String]
  [decls : lsp_decl_vec.Vec]) : LspEditResult
  (if (string.eq old-pattern "")
    (Err "oldPattern cannot be empty")
    (let
      [i : i64 0]
      [n : i64 (lsp_decl_vec.len (& decls))]
      [found : bool false]
      [result : String ""]
      [err : String ""]
      (begin
        (while (and (< i n) (not found))
          (let
            [entry : lsp_vector_families.LspDeclEntry
              (lsp_decl_vec.get (& decls) i (lsp-decl-entry-fallback))]
            (if (string.eq entry.name name)
              (begin
                (set! found true)
                (let
                  [kind : String entry.kind]
                  [n2 : i64 (string.string-length text)]
                  (if (or (string.eq kind "function") (string.eq kind "macro"))
                    (let
                      [form-start-off : i64
                        (lsp-offset-at-position
                          text
                          (- entry.form-start-line 1)
                          (- entry.form-start-col 1))]
                      [after-kw : i64
                        (source_text.source-text-skip-space
                          text
                          (+ form-start-off 1)
                          n2)]
                      [kw-end : i64 (lsp-scan-ident text after-kw n2)]
                      [after-kw2 : i64
                        (source_text.source-text-skip-space text kw-end n2)]
                      (if (and
                        (< after-kw2 n2)
                        (= (string.string-ref text after-kw2) '('))
                        (let
                          [body-start-off : i64
                            (lsp-find-body-start-offset text form-start-off)]
                          [body-end-off : i64
                            (-
                              (lsp-offset-at-position
                                text
                                (- entry.form-end-line 1)
                                (- entry.form-end-col 1))
                              1)]
                          [body-start-lc : LspLineCol
                            (lsp-line-col-at-offset text body-start-off)]
                          [body-end-lc : LspLineCol
                            (lsp-line-col-at-offset text body-end-off)]
                          [body-text : String
                            (string.substring
                              text
                              body-start-off
                              (- body-end-off body-start-off))]
                          [replaced-body : String
                            (lsp-replace-pattern-words
                              body-text
                              old-pattern
                              (owned_view.compiler-owned-shared-view
                                new-pattern))]
                          (if (not
                            (lsp-text-is-valid-forms
                              (owned_view.compiler-owned-shared-view
                                replaced-body)))
                            (begin
                              (set!
                                err
                                (lsp-str2
                                  "newPattern produces an invalid form in body: "
                                  (lsp-validate-forms-error replaced-body)))
                              (set! result ""))
                            (set!
                              result
                              (lsp-edit-at-pos
                                (owned_view.compiler-owned-shared-view text)
                                body-start-lc.line
                                body-start-lc.col
                                body-end-lc.line
                                body-end-lc.col
                                replaced-body))))
                        (set!
                          err
                          "replacePattern only supported for function/macro definitions with parameter lists")))
                    (set!
                      err
                      "replacePattern only supported for define and defmacro"))))
              (begin
                (set! i (+ i 1))
                unit))))
        (unless found (return (Err "Declaration not found")))
        (unless (string.eq err "") (return (Err err)))
        (when
          (string.eq result "")
          (return (Err "replacePattern: unknown error")))
        (Ok result)))))

(define (lsp-structural-replace-text-with-decls
  [text : String]
  [name : String]
  [new-text : String]
  [decls : lsp_decl_vec.Vec]) : LspEditResult
  (if (not
    (lsp-text-is-valid-forms (owned_view.compiler-owned-shared-view new-text)))
    (Err
      (lsp-str2
        "newText is not valid form(s): "
        (lsp-validate-forms-error new-text)))
    (let
      [i : i64 0]
      [n : i64 (lsp_decl_vec.len (& decls))]
      [found : bool false]
      [result : String ""]
      (begin
        (while (and (< i n) (not found))
          (let
            [entry : lsp_vector_families.LspDeclEntry
              (lsp_decl_vec.get (& decls) i (lsp-decl-entry-fallback))]
            (if (string.eq entry.name name)
              (begin
                (set!
                  result
                  (lsp-edit-at-pos
                    (owned_view.compiler-owned-shared-view text)
                    entry.form-start-line
                    entry.form-start-col
                    entry.form-end-line
                    entry.form-end-col
                    (owned_view.compiler-owned-shared-view new-text)))
                (set! found true)
                unit)
              (begin
                (set! i (+ i 1))
                unit))))
        (if found
          (Ok result)
          (Err "Declaration not found"))))))

;; tl/patch - Find and replace text anywhere in the file, then validate
(define (lsp-patch-text [text : String] [old-text : String] [new-text : String]) : LspEditResult
  (let
    [n : i64 (string.string-length text)]
    [old-len : i64 (string.string-length old-text)]
    (if (string.eq old-text "")
      (Err "oldText cannot be empty")
      (let
        [first-byte : char (string.string-ref old-text 0)]
        [i : i64 0]
        [found-at : i64 -1]
        [matches : i64 0]
        [limit : i64 (- n old-len)]
        (begin
          (while (and (<= i limit) (<= matches 1))
            (let
              [idx : i64
                (string.index-of-byte (& text) i (cast first-byte : u8))]
              (if (= idx -1)
                (set! i (+ limit 1))
                (if (<= idx limit)
                  (if (string.is-string-prefix-at (& text) (& old-text) idx)
                    (begin
                      (when (= found-at -1) (set! found-at idx))
                      (set! matches (+ matches 1))
                      (set! i (+ idx 1)))
                    (set! i (+ idx 1)))
                  (set! i (+ limit 1))))))
          (if (= matches 0)
            (Err "oldText not found in document")
            (if (> matches 1)
              (Err "oldText occurs more than once in document")
              (let
                [replaced : String (string.replace text old-text new-text)]
                (if (not
                  (lsp-text-is-valid-forms
                    (owned_view.compiler-owned-shared-view replaced)))
                  (Err
                    (lsp-str2
                      "Patch produces invalid form(s): "
                      (lsp-validate-forms-error replaced)))
                  (Ok replaced))))))))))

;; tl/patch - Handler for find-and-replace patch
(define (lsp-handle-tl-patch
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document
    (owned_view.compiler-owned-shared-view params)
    (owned_view.compiler-owned-shared-view docs))
    [(Found path text _)
      (match (lsp-json-string-field params "oldText")
        [(Ok old-text)
          (match (lsp-json-string-field params "newText")
            [(Ok new-text)
              (match (lsp-patch-text text old-text new-text)
                [(Ok replaced)
                  (lsp-write-structural-edit-success id params docs replaced)]
                [(Err message)
                  (begin
                    (lsp-write-error id -32600 message)
                    (LspDocumentHandleResult.Continue docs))])]
            [(Missing)
              (begin
                (lsp-write-error id -32600 "Missing newText parameter")
                (LspDocumentHandleResult.Continue docs))])]
        [(Missing)
          (begin
            (lsp-write-error id -32600 "Missing oldText parameter")
            (LspDocumentHandleResult.Continue docs))])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; Position-based editing helpers
;; Find start index of innermost form containing offset. Returns -1 if not found.
;; Uses string.string-ref on literal parens since char literals for parens confuse the parser.
(define (lsp-find-form-at-offset [text : String] [offset : i64]) : i64
  (if (or (< offset 0) (>= offset (string.string-length text)))
    -1
    (let
      [i : i64 offset]
      [depth : i64 0]
      [result : i64 -1]
      (begin
        (while (and (>= i 0) (= result -1))
          (let
            [c : char (string.string-ref text i)]
            (begin
              (if (= c (string.string-ref ")" 0))
                (set! depth (+ depth 1))
                (if (= c (string.string-ref "(" 0))
                  (if (= depth 0)
                    (set! result i)
                    (set! depth (- depth 1)))
                  unit))
              (set! i (- i 1)))))
        result))))

;; Find end index (exclusive) of form starting at start. Returns -1 if unterminated.
(define (lsp-find-form-end-at-offset [text : String] [start : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    (if (or
      (< start 0)
      (>= start n)
      (not (= (string.string-ref text start) (string.string-ref "(" 0))))
      -1
      (let
        [i : i64 (+ start 1)]
        [depth : i64 1]
        [result : i64 -1]
        (begin
          (while (and (< i n) (= result -1))
            (let
              [c : char (string.string-ref text i)]
              (begin
                (if (= c (string.string-ref "(" 0))
                  (set! depth (+ depth 1))
                  (if (= c (string.string-ref ")" 0))
                    (begin
                      (set! depth (- depth 1))
                      (if (= depth 0)
                        (set! result (+ i 1))
                        unit))
                    unit))
                (set! i (+ i 1)))))
          result)))))

;; Replace top-level form at position (line, col) with new-text.
;; Any position inside a top-level form selects that entire form.
(define (lsp-replace-form-at-position-with-decls
  [text : String]
  [decls : lsp_decl_vec.Vec]
  [line : i64]
  [col : i64]
  [new-text : String]) : LspEditResult
  (let
    [idx : i64 (lsp-decl-index-at-position text decls line col)]
    (if (= idx -1)
      (Err "No form found at position")
      (let
        [entry : lsp_vector_families.LspDeclEntry
          (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))]
        [start : i64 (lsp-offset-from-entry-start text entry)]
        [end : i64 (lsp-offset-from-entry-end text entry)]
        (if (or (< start 0) (<= end start) (> end (string.string-length text)))
          (Err "Declaration range is invalid")
          (Ok (lsp-edit-range-at-offset text start end new-text)))))))

(define (lsp-replace-form-at-position-from-params-with-decls
  [text : String]
  [decls : lsp_decl_vec.Vec]
  [params : json.Json]
  [new-text : String]) : LspEditResult
  (let
    [pos-key : String "position"]
    (match (json.object-get params (& pos-key))
      [(JsonFound position)
        (let
          [line : i64 (lsp-json-int-field-default position "line" 0)]
          [col : i64 (lsp-json-int-field-default position "character" 0)]
          (lsp-replace-form-at-position-with-decls text decls line col new-text))]
      [(JsonMissing) (Err "Missing name or position parameter")])))

;; tl/replace - Replace a top-level declaration by name, with position fallback
(define (lsp-handle-tl-structural-replace-at
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (match (lsp-json-string-field params "newText")
        [(Ok new-text)
          (if (lsp-json-has-field?
            (owned_view.compiler-owned-shared-view params)
            "path")
            (match (lsp-json-path-field
              (owned_view.compiler-owned-shared-view params))
              [(Ok path-items)
                (lsp-write-structural-edit-result
                  id
                  params
                  docs
                  (lsp-replace-form-by-path-with-decls
                    text
                    path-items
                    new-text
                    decls))]
              [(Err message)
                (begin
                  (lsp-write-error id -32600 message)
                  (LspDocumentHandleResult.Continue docs))])
            (match (lsp-json-string-field params "name")
              [(Ok name)
                (if (= (string.string-length name) 0)
                  (lsp-write-structural-edit-result
                    id
                    (owned_view.compiler-owned-shared-view params)
                    docs
                    (lsp-replace-form-at-position-from-params-with-decls
                      text
                      decls
                      params
                      new-text))
                  (lsp-write-structural-edit-result
                    id
                    params
                    docs
                    (lsp-structural-replace-text-with-decls
                      text
                      name
                      new-text
                      decls)))]
              [(Missing)
                (lsp-write-structural-edit-result
                  id
                  (owned_view.compiler-owned-shared-view params)
                  docs
                  (lsp-replace-form-at-position-from-params-with-decls
                    text
                    decls
                    params
                    new-text))]))]
        [(Missing)
          (begin
            (lsp-write-error id -32600 "Missing newText parameter")
            (LspDocumentHandleResult.Continue docs))])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; Find the start of the outer form enclosing the form at start.
;; outer = 0 means return start itself.
(define (lsp-find-outer-form-start [text : String] [start : i64] [outer : i64]) : i64
  (if (<= outer 0)
    start
    (if (<= start 0)
      -1
      (let
        [prev-start : i64
          (lsp-find-form-at-offset
            (owned_view.compiler-owned-shared-view text)
            (- start 1))]
        (if (= prev-start -1)
          -1
          (lsp-find-outer-form-start text prev-start (- outer 1)))))))

;; Read the form at a given (line, col), optionally going outer levels up.
(define (lsp-read-form-at-position
  [text : String]
  [line : i64]
  [col : i64]
  [outer : i64]) : String
  (if (or (< line 0) (< col 0))
    ""
    (let
      [offset : i64 (lsp-offset-at-position text line col)]
      (if (>= offset (string.string-length text))
        ""
        (let
          [form-start : i64
            (lsp-find-form-at-offset
              (owned_view.compiler-owned-shared-view text)
              offset)]
          (if (= form-start -1)
            ""
            (let
              [actual-start : i64
                (lsp-find-outer-form-start
                  (owned_view.compiler-owned-shared-view text)
                  form-start
                  outer)]
              (if (= actual-start -1)
                ""
                (let
                  [form-end : i64
                    (lsp-find-form-end-at-offset
                      (owned_view.compiler-owned-shared-view text)
                      actual-start)]
                  (if (= form-end -1)
                    ""
                    (string.substring
                      text
                      actual-start
                      (- form-end actual-start))))))))))))

(define (lsp-read-form-at-position-from-params
  [text : String]
  [params : json.Json]) : LspStringResult
  (let
    [pos-key : String "position"]
    (match (json.object-get
      (owned_view.compiler-owned-shared-view params)
      (& pos-key))
      [(JsonFound position)
        (let
          [line : i64 (lsp-json-int-field-default position "line" 0)]
          [col : i64 (lsp-json-int-field-default position "character" 0)]
          [outer : i64 (lsp-json-int-field-default params "outer" 0)]
          [form-text : String (lsp-read-form-at-position text line col outer)]
          (if (= (string.string-length form-text) 0)
            (Err "No form found at position")
            (Ok form-text)))]
      [(JsonMissing) (Err "Missing name or position parameter")])))

(define (lsp-form-text-by-entry
  [text : (& text str)]
  [entry : lsp_vector_families.LspDeclEntry]) : LspStringResult
  (let
    [start : i64 (lsp-offset-from-entry-start text entry)]
    [end : i64 (lsp-offset-from-entry-end text entry)]
    (if (or (< start 0) (<= end start) (> end (string.string-length text)))
      (Err "Declaration range is invalid")
      (Ok (string.substring text start (- end start))))))

(define (lsp-read-form-by-name-with-decls
  [text : String]
  [name : String]
  [decls : lsp_decl_vec.Vec]) : LspStringResult
  (let
    [idx : i64 (lsp-decl-list-find-name (& decls) name)]
    (if (= idx -1)
      (Err "Declaration not found")
      (lsp-form-text-by-entry
        text
        (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))))))

(define (lsp-json-has-field? [value : json.Json] [key : String]) : bool
  (match (json.object-get value (& key))
    [(JsonFound _) true]
    [(JsonMissing) false]))

(define (lsp-json-list-all-strings? [items : json.JsonSeq]) : bool
  (let
    [n : i64 (json.list-count (owned_view.compiler-owned-shared-view items))]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i n))
        (match (json.list-get-index
          (owned_view.compiler-owned-shared-view items)
          i)
          [(JsonFound entry)
            (match entry
              [(JsonString _) (set! i (+ i 1))]
              [_ (set! ok false)])]
          [(JsonMissing) (set! ok false)]))
      ok)))

(define (lsp-json-path-field [params : json.Json]) : LspPathParam
  (let
    [key : String "path"]
    (match (json.object-get params (& key))
      [(JsonFound value)
        (match value
          [(JsonArray items)
            (let
              [path-items : json.JsonSeq (deref items)]
              (if (=
                (json.list-count
                  (owned_view.compiler-owned-shared-view path-items))
                0)
                (Err "path must not be empty")
                (if (lsp-json-list-all-strings?
                  (owned_view.compiler-owned-shared-view path-items))
                  (Ok path-items)
                  (Err "path entries must be strings"))))]
          [_ (Err "path must be an array")])]
      [(JsonMissing) (Err "Missing path parameter")])))

(define (lsp-json-path-single-name [path : json.JsonSeq]) : String
  (if (= (json.list-count (owned_view.compiler-owned-shared-view path)) 1)
    (match (json.list-get-index path 0)
      [(JsonFound first)
        (match first
          [(JsonString name) name]
          [_ ""])]
      [(JsonMissing) ""])
    ""))

(define (lsp-form-head-name-at [text : (& text str)] [start : i64] [end : i64]) : String
  (let
    [n0 : i64 (string.string-length text)]
    [limit : i64
      (if (> end n0)
        n0
        end)]
    (if (or
      (< start 0)
      (>= start limit)
      (not (= (string.string-ref text start) (string.string-ref "(" 0))))
      ""
      (let
        [head-start : i64
          (source_text.source-text-skip-space text (+ start 1) limit)]
        [head-end : i64 0]
        (begin
          (set! head-end (lsp-scan-ident text head-start limit))
          (if (> head-end head-start)
            (lsp-symbol-base
              (string.substring text head-start (- head-end head-start)))
            ""))))))

(define (lsp-offset-position-json [text : (& text str)] [off : i64]) : json.Json
  (let
    [lc : LspLineCol (lsp-line-col-at-offset text off)]
    (lsp-json-object2
      "line"
      (lsp-json-number (- lc.line 1))
      "character"
      (lsp-json-number (- lc.col 1)))))

(define (lsp-offset-range-json [text : (& text str)] [start : i64] [end : i64]) : json.Json
  (lsp-json-object2
    "start"
    (lsp-offset-position-json text start)
    "end"
    (lsp-offset-position-json text end)))

(define (lsp-find-nested-form-by-head
  [text : (& text str)]
  [start : i64]
  [end : i64]
  [needle : (& needle str)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [limit : i64
      (if (> end n)
        n
        end)]
    [i : i64 (+ start 1)]
    [found : i64 -1]
    (begin
      (while (and (< i limit) (= found -1))
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c ';')
              (set! i (source_text.source-text-skip-line text i limit))]
            [(= c '\'')
              (set! i (source_text.source-text-skip-char-literal text i limit))]
            [(= c '"')
              (set! i (source_text.source-text-skip-string text i limit))]
            [(= c '(')
              (let
                [head : String
                  (lsp-form-head-name-at
                    text
                    i
                    (lsp-skip-paren-group text i limit))]
                (if (string.eq head needle)
                  (set! found i)
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      found)))

(define (lsp-lookup-form-path-tail
  [text : (& text str)]
  [path : json.JsonSeq]
  [start : i64]
  [end : i64]) : LspPathLookup
  (match (json.list-get-index (owned_view.compiler-owned-shared-view path) 0)
    [(JsonMissing) (Found start end (lsp-form-head-name-at text start end))]
    [(JsonFound first)
      (match first
        [(JsonString name)
          (let
            [child-start : i64
              (lsp-find-nested-form-by-head text start end name)]
            (if (= child-start -1)
              (Err (lsp-str2 "Path segment not found: " name))
              (let
                [child-end : i64 (lsp-skip-paren-group text child-start end)]
                (if (<= child-end child-start)
                  (Err "Path target range is invalid")
                  (lsp-lookup-form-path-tail
                    text
                    (json.list-rest path)
                    child-start
                    child-end)))))]
        [_ (Err "path entries must be strings")])]))

(define (lsp-lookup-form-path
  [text : (& text str)]
  [decls : lsp_decl_vec.Vec]
  [path : json.JsonSeq]) : LspPathLookup
  (match (json.list-get-index (owned_view.compiler-owned-shared-view path) 0)
    [(JsonMissing) (Err "path must not be empty")]
    [(JsonFound first)
      (match first
        [(JsonString name)
          (let
            [idx : i64
              (lsp-decl-list-find-name
                (& decls)
                (owned_view.compiler-owned-shared-view name))]
            (if (= idx -1)
              (Err "Declaration not found")
              (let
                [entry : lsp_vector_families.LspDeclEntry
                  (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))]
                [start : i64 (lsp-offset-from-entry-start text entry)]
                [end : i64 (lsp-offset-from-entry-end text entry)]
                (if (or
                  (< start 0)
                  (<= end start)
                  (> end (string.string-length text)))
                  (Err "Declaration range is invalid")
                  (if (<=
                    (json.list-count
                      (owned_view.compiler-owned-shared-view path))
                    1)
                    (Found start end name)
                    (lsp-lookup-form-path-tail
                      text
                      (json.list-rest path)
                      start
                      end))))))]
        [_ (Err "path entries must be strings")])]))

(define (lsp-replace-form-by-path-with-decls
  [text : String]
  [path : json.JsonSeq]
  [new-text : String]
  [decls : lsp_decl_vec.Vec]) : LspEditResult
  (if (not
    (lsp-text-is-valid-forms (owned_view.compiler-owned-shared-view new-text)))
    (Err
      (lsp-str2
        "newText is not valid form(s): "
        (lsp-validate-forms-error new-text)))
    (match (lsp-lookup-form-path text decls path)
      [(Found start end _)
        (Ok (lsp-edit-range-at-offset text start end new-text))]
      [(Err message) (Err message)])))

(define (lsp-generic-form-body-start
  [text : (& text str)]
  [start : i64]
  [end : i64]) : i64
  (let
    [head-start : i64 (source_text.source-text-skip-space text (+ start 1) end)]
    [head-end : i64 (lsp-scan-ident text head-start end)]
    (source_text.source-text-skip-space text head-end end)))

(define (lsp-replace-body-by-path-with-decls
  [text : String]
  [path : json.JsonSeq]
  [new-body : String]
  [decls : lsp_decl_vec.Vec]) : LspEditResult
  (let
    [single-name : String
      (lsp-json-path-single-name (owned_view.compiler-owned-shared-view path))]
    (if (> (string.string-length single-name) 0)
      (lsp-replace-body-text-with-decls text single-name new-body decls)
      (if (not
        (lsp-text-is-valid-forms
          (owned_view.compiler-owned-shared-view new-body)))
        (Err
          (lsp-str2
            "newBody is not a valid form: "
            (lsp-validate-forms-error new-body)))
        (match (lsp-lookup-form-path text decls path)
          [(Found start end _)
            (let
              [body-start : i64 (lsp-generic-form-body-start text start end)]
              [body-end : i64 (- end 1)]
              (if (or (< body-start 0) (< body-end body-start))
                (Err "Path target range is invalid")
                (Ok
                  (lsp-edit-range-at-offset text body-start body-end new-body))))]
          [(Err message) (Err message)])))))

(define (lsp-delete-form-at-position-with-decls
  [text : String]
  [decls : lsp_decl_vec.Vec]
  [line : i64]
  [col : i64]) : LspEditResult
  (let
    [idx : i64 (lsp-decl-index-at-position text decls line col)]
    (if (= idx -1)
      (Err "No form found at position")
      (let
        [entry : lsp_vector_families.LspDeclEntry
          (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))]
        [start : i64 (lsp-offset-from-entry-start text entry)]
        [end : i64 (lsp-offset-from-entry-end text entry)]
        (if (or (< start 0) (<= end start) (> end (string.string-length text)))
          (Err "Declaration range is invalid")
          (Ok (lsp-edit-range-at-offset text start end "")))))))

(define (lsp-delete-form-at-position-from-params-with-decls
  [text : String]
  [decls : lsp_decl_vec.Vec]
  [params : json.Json]) : LspEditResult
  (let
    [pos-key : String "position"]
    (match (json.object-get params (& pos-key))
      [(JsonFound position)
        (let
          [line : i64 (lsp-json-int-field-default position "line" 0)]
          [col : i64 (lsp-json-int-field-default position "character" 0)]
          (lsp-delete-form-at-position-with-decls text decls line col))]
      [(JsonMissing) (Err "Missing name or position parameter")])))

(define (lsp-delete-form-by-name-with-decls
  [text : String]
  [name : String]
  [decls : lsp_decl_vec.Vec]) : LspEditResult
  (let
    [idx : i64 (lsp-decl-list-find-name (& decls) name)]
    (if (= idx -1)
      (Err "Declaration not found")
      (let
        [entry : lsp_vector_families.LspDeclEntry
          (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))]
        [start : i64 (lsp-offset-from-entry-start text entry)]
        [end : i64 (lsp-offset-from-entry-end text entry)]
        (if (or (< start 0) (<= end start) (> end (string.string-length text)))
          (Err "Declaration range is invalid")
          (Ok (lsp-edit-range-at-offset text start end "")))))))

(define (lsp-insert-after-entry
  [text : (& text str)]
  [entry : lsp_vector_families.LspDeclEntry]
  [new-text : String]) : LspEditResult
  (let
    [form-end : i64 (lsp-offset-from-entry-end text entry)]
    (if (or (< form-end 0) (> form-end (string.string-length text)))
      (Err "Declaration range is invalid")
      (let
        [before : String (string.substring text 0 form-end)]
        [after : String
          (string.substring
            text
            form-end
            (- (string.string-length text) form-end))]
        (Ok (lsp-str4 before "\n" new-text after))))))

(define (lsp-insert-after-position-with-decls
  [text : (& text str)]
  [decls : lsp_decl_vec.Vec]
  [line : i64]
  [col : i64]
  [new-text : String]) : LspEditResult
  (let
    [idx : i64 (lsp-decl-index-at-position text decls line col)]
    (if (= idx -1)
      (Err "No form found at position")
      (lsp-insert-after-entry
        text
        (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))
        new-text))))

(define (lsp-insert-after-position-from-params-with-decls
  [text : String]
  [decls : lsp_decl_vec.Vec]
  [params : json.Json]
  [new-text : String]) : LspEditResult
  (let
    [pos-key : String "position"]
    (match (json.object-get params (& pos-key))
      [(JsonFound position)
        (let
          [line : i64 (lsp-json-int-field-default position "line" 0)]
          [col : i64 (lsp-json-int-field-default position "character" 0)]
          (lsp-insert-after-position-with-decls text decls line col new-text))]
      [(JsonMissing) (Err "Missing name or position parameter")])))

(define (lsp-insert-after-text-with-decls
  [text : String]
  [params : json.Json]
  [new-text : String]
  [decls : lsp_decl_vec.Vec]) : LspEditResult
  (if (not
    (lsp-text-is-valid-forms (owned_view.compiler-owned-shared-view new-text)))
    (Err
      (lsp-str2
        "newText is not valid form(s): "
        (lsp-validate-forms-error new-text)))
    (match (lsp-json-string-field params "name")
      [(Ok name)
        (if (= (string.string-length name) 0)
          (lsp-insert-after-position-from-params-with-decls
            text
            decls
            params
            new-text)
          (let
            [idx : i64 (lsp-decl-list-find-name (& decls) name)]
            (if (= idx -1)
              (Err "Declaration not found")
              (lsp-insert-after-entry
                text
                (lsp_decl_vec.get (& decls) idx (lsp-decl-entry-fallback))
                new-text))))]
      [(Missing)
        (lsp-insert-after-position-from-params-with-decls
          text
          decls
          params
          new-text)])))

;; tl/delete - Delete the form by name, with position fallback
(define (lsp-handle-tl-delete-at
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (match (lsp-json-string-field params "name")
        [(Ok name)
          (if (= (string.string-length name) 0)
            (lsp-write-structural-edit-result
              id
              (owned_view.compiler-owned-shared-view params)
              docs
              (lsp-delete-form-at-position-from-params-with-decls
                text
                decls
                params))
            (lsp-write-structural-edit-result
              id
              params
              docs
              (lsp-delete-form-by-name-with-decls text name decls)))]
        [(Missing)
          (lsp-write-structural-edit-result
            id
            (owned_view.compiler-owned-shared-view params)
            docs
            (lsp-delete-form-at-position-from-params-with-decls
              text
              decls
              params))])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; tl/insertAfter - Insert a new form after the form at a given position
(define (lsp-handle-tl-insert-after
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (match (lsp-json-string-field params "newText")
        [(Ok new-text)
          (lsp-write-structural-edit-result
            id
            (owned_view.compiler-owned-shared-view params)
            docs
            (lsp-insert-after-text-with-decls text params new-text decls))]
        [(Missing)
          (begin
            (lsp-write-error id -32600 "Missing newText parameter")
            (LspDocumentHandleResult.Continue docs))])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; tl/replaceBody - Replace body of a function by name, with position fallback
(define (lsp-handle-tl-replace-body
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (match (lsp-json-string-field params "newBody")
        [(Ok new-body)
          (if (not
            (lsp-text-is-valid-forms
              (owned_view.compiler-owned-shared-view new-body)))
            (lsp-write-replace-body-validation-error id docs new-body)
            (if (lsp-json-has-field?
              (owned_view.compiler-owned-shared-view params)
              "path")
              (match (lsp-json-path-field
                (owned_view.compiler-owned-shared-view params))
                [(Ok path-items)
                  (lsp-write-structural-edit-result
                    id
                    params
                    docs
                    (lsp-replace-body-by-path-with-decls
                      text
                      path-items
                      new-body
                      decls))]
                [(Err message)
                  (begin
                    (lsp-write-error id -32600 message)
                    (LspDocumentHandleResult.Continue docs))])
              (let
                [name : String
                  (lsp-structural-move-name-with-decls
                    (owned_view.compiler-owned-shared-view params)
                    (owned_view.compiler-owned-shared-view text)
                    decls)]
                (if (= (string.string-length name) 0)
                  (lsp-write-missing-structural-name-error id params docs)
                  (lsp-write-structural-edit-result
                    id
                    params
                    docs
                    (lsp-replace-body-text-with-decls text name new-body decls))))))]
        [(Missing)
          (begin
            (lsp-write-error id -32600 "Missing newBody parameter")
            (LspDocumentHandleResult.Continue docs))])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; tl/replacePattern - Replace a pattern in a function by name, with position fallback
(define (lsp-handle-tl-replace-pattern-at
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (match (lsp-json-string-field params "oldPattern")
        [(Ok old-pattern)
          (match (lsp-json-string-field params "newPattern")
            [(Ok new-pattern)
              (let
                [name : String
                  (lsp-structural-move-name-with-decls
                    (owned_view.compiler-owned-shared-view params)
                    (owned_view.compiler-owned-shared-view text)
                    decls)]
                (if (= (string.string-length name) 0)
                  (lsp-write-missing-structural-name-error id params docs)
                  (lsp-write-structural-edit-result
                    id
                    params
                    docs
                    (lsp-replace-pattern-text-with-decls
                      text
                      name
                      old-pattern
                      new-pattern
                      decls))))]
            [(Missing)
              (begin
                (lsp-write-error id -32600 "Missing newPattern parameter")
                (LspDocumentHandleResult.Continue docs))])]
        [(Missing)
          (begin
            (lsp-write-error id -32600 "Missing oldPattern parameter")
            (LspDocumentHandleResult.Continue docs))])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

;; tl/read - Read a top-level declaration by name, with position fallback
(define (lsp-handle-tl-read-form-at
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-get-document-decls params docs)
    [(Found path text _ decls)
      (match (lsp-json-string-field params "name")
        [(Ok name)
          (if (= (string.string-length name) 0)
            (lsp-write-read-form-result
              id
              (owned_view.compiler-owned-shared-view params)
              (lsp-read-form-at-position-from-params text params)
              docs)
            (lsp-write-read-form-result
              id
              params
              (lsp-read-form-by-name-with-decls text name decls)
              docs))]
        [(Missing)
          (lsp-write-read-form-result
            id
            (owned_view.compiler-owned-shared-view params)
            (lsp-read-form-at-position-from-params text params)
            docs)])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspDocumentHandleResult.Continue docs))]))

(define (lsp-structural-move-after-destination-text
  [text : String]
  [decls : (& decls lsp_decl_vec.Vec)]
  [name : String]
  [destination : String]) : LspEditResult
  (let
    [found-idx : i64 (lsp-decl-list-find-name (& decls) name)]
    [dest-idx : i64 (lsp-decl-list-find-name (& decls) destination)]
    (cond
      [(= found-idx -1) (Err "Declaration not found")]
      [(= dest-idx -1) (Err "Destination declaration not found")]
      [(= found-idx dest-idx) (Err "Cannot move declaration to itself")]
      [else
        (let
          [found-entry : lsp_vector_families.LspDeclEntry
            (lsp_decl_vec.get (& decls) found-idx (lsp-decl-entry-fallback))]
          [dest-entry : lsp_vector_families.LspDeclEntry
            (lsp_decl_vec.get (& decls) dest-idx (lsp-decl-entry-fallback))]
          (Ok (lsp-move-form-after text found-entry dest-entry)))])))

(define (lsp-structural-move-direction-text
  [text : (& text str)]
  [decls : (& decls lsp_decl_vec.Vec)]
  [name : String]
  [direction : String]) : LspEditResult
  (let
    [found-idx : i64 (lsp-decl-list-find-name (& decls) name)]
    [n : i64 (lsp_decl_vec.len (& decls))]
    [target-idx : i64
      (if (string.eq direction "up")
        (- found-idx 1)
        (if (string.eq direction "down")
          (+ found-idx 1)
          -1))]
    (cond
      [(= found-idx -1) (Err "Declaration not found")]
      [(or (< target-idx 0) (>= target-idx n) (= target-idx -1))
        (Err "Invalid direction or cannot move further")]
      [else
        (let
          [found-entry : lsp_vector_families.LspDeclEntry
            (lsp_decl_vec.get (& decls) found-idx (lsp-decl-entry-fallback))]
          [target-entry : lsp_vector_families.LspDeclEntry
            (lsp_decl_vec.get (& decls) target-idx (lsp-decl-entry-fallback))]
          [found-first : bool (< found-idx target-idx)]
          [first-entry : lsp_vector_families.LspDeclEntry
            (if found-first
              (owned_view.compiler-owned-shared-view found-entry)
              (owned_view.compiler-owned-shared-view target-entry))]
          [second-entry : lsp_vector_families.LspDeclEntry
            (if found-first
              target-entry
              found-entry)]
          [first-start : i64 (lsp-offset-from-entry-start text first-entry)]
          [first-end : i64 (lsp-offset-from-entry-end text first-entry)]
          [second-start : i64 (lsp-offset-from-entry-start text second-entry)]
          [second-end : i64 (lsp-offset-from-entry-end text second-entry)]
          [text-before : String (string.substring text 0 first-start)]
          [second-text : String
            (string.substring text second-start (- second-end second-start))]
          [middle : String
            (string.substring text first-end (- second-start first-end))]
          [first-text : String
            (string.substring text first-start (- first-end first-start))]
          [text-after : String
            (string.substring
              text
              second-end
              (- (string.string-length text) second-end))]
          (Ok (lsp-str5 text-before second-text middle first-text text-after)))])))

(define (lsp-structural-move-text-with-decls
  [text : String]
  [params : json.Json]
  [decls : lsp_decl_vec.Vec]) : LspEditResult
  (let
    [name : String
      (lsp-structural-move-name-with-decls
        (owned_view.compiler-owned-shared-view params)
        (owned_view.compiler-owned-shared-view text)
        decls)]
    (if (= (string.string-length name) 0)
      (Err "Missing name or position parameter")
      (match (lsp-json-string-field params "destination")
        [(Ok destination)
          (lsp-structural-move-after-destination-text
            text
            decls
            name
            destination)]
        [(Missing)
          (match (lsp-json-string-field params "direction")
            [(Ok direction)
              (lsp-structural-move-direction-text text decls name direction)]
            [(Missing) (Err "Missing direction or destination parameter")])]))))

(define (lsp-batch-apply-edit
  [method : String]
  [params : json.Json]
  [text : String]) : LspEditResult
  (let
    [text-copy : String (string.copy (& text))]
    [decls : lsp_decl_vec.Vec (lsp-scan-decls text-copy)]
    (cond
      [(string.eq method "tl/replace")
        (match (lsp-json-string-field params "newText")
          [(Ok new-text)
            (if (lsp-json-has-field?
              (owned_view.compiler-owned-shared-view params)
              "path")
              (match (lsp-json-path-field params)
                [(Ok path-items)
                  (lsp-replace-form-by-path-with-decls
                    text
                    path-items
                    new-text
                    decls)]
                [(Err message) (Err message)])
              (match (lsp-json-string-field params "name")
                [(Ok name)
                  (if (= (string.string-length name) 0)
                    (lsp-replace-form-at-position-from-params-with-decls
                      text
                      decls
                      params
                      new-text)
                    (lsp-structural-replace-text-with-decls
                      text
                      name
                      new-text
                      decls))]
                [(Missing)
                  (lsp-replace-form-at-position-from-params-with-decls
                    text
                    decls
                    params
                    new-text)]))]
          [(Missing) (Err "Missing newText parameter")])]
      [(string.eq method "tl/delete")
        (match (lsp-json-string-field params "name")
          [(Ok name)
            (if (= (string.string-length name) 0)
              (lsp-delete-form-at-position-from-params-with-decls
                text
                decls
                params)
              (lsp-delete-form-by-name-with-decls text name decls))]
          [(Missing)
            (lsp-delete-form-at-position-from-params-with-decls
              text
              decls
              params)])]
      [(string.eq method "tl/insertAfter")
        (match (lsp-json-string-field params "newText")
          [(Ok new-text)
            (lsp-insert-after-text-with-decls text params new-text decls)]
          [(Missing) (Err "Missing newText parameter")])]
      [(string.eq method "tl/move")
        (lsp-structural-move-text-with-decls text params decls)]
      [(string.eq method "tl/replaceBody")
        (match (lsp-json-string-field params "newBody")
          [(Ok new-body)
            (if (lsp-json-has-field?
              (owned_view.compiler-owned-shared-view params)
              "path")
              (match (lsp-json-path-field params)
                [(Ok path-items)
                  (lsp-replace-body-by-path-with-decls
                    text
                    path-items
                    new-body
                    decls)]
                [(Err message) (Err message)])
              (let
                [name : String
                  (lsp-structural-move-name-with-decls
                    params
                    (owned_view.compiler-owned-shared-view text)
                    decls)]
                (if (= (string.string-length name) 0)
                  (Err "Missing name or position parameter")
                  (lsp-replace-body-text-with-decls text name new-body decls))))]
          [(Missing) (Err "Missing newBody parameter")])]
      [(string.eq method "tl/replacePattern")
        (match (lsp-json-string-field params "oldPattern")
          [(Ok old-pattern)
            (match (lsp-json-string-field params "newPattern")
              [(Ok new-pattern)
                (let
                  [name : String
                    (lsp-structural-move-name-with-decls
                      params
                      (owned_view.compiler-owned-shared-view text)
                      decls)]
                  (if (= (string.string-length name) 0)
                    (Err "Missing name or position parameter")
                    (lsp-replace-pattern-text-with-decls
                      text
                      name
                      old-pattern
                      new-pattern
                      decls)))]
              [(Missing) (Err "Missing newPattern parameter")])]
          [(Missing) (Err "Missing oldPattern parameter")])]
      [else (Err (lsp-str2 "Unsupported batch operation: " method))])))

(define (lsp-batch-operation-result [index : i64]) : json.Json
  (lsp-json-object2 "index" (lsp-json-number index) "success" (JsonBool true)))

(define (lsp-batch-position-error?
  [operation : json.Json]
  [message : (& message str)]) : bool
  (if (lsp-json-has-field? operation "position")
    (or
      (string.eq message "No form found at position")
      (string.eq message "Missing name or position parameter"))
    false))

(define (lsp-batch-position-message [operation : json.Json] [message : String]) : String
  (if (lsp-batch-position-error?
    (owned_view.compiler-owned-shared-view operation)
    message)
    (let
      [pos-key : String "position"]
      (match (json.object-get operation (& pos-key))
        [(JsonFound position)
          (let
            [line : i64 (lsp-json-int-field-default position "line" 0)]
            [col : i64 (lsp-json-int-field-default position "character" 0)]
            [base : String
              (if (string.eq message "No form found at position")
                "No form found at position"
                "Could not extract function name at position")]
            (lsp-position-error-message base line col))]
        [(JsonMissing) message]))
    message))

(define (lsp-batch-position-context
  [operation : json.Json]
  [text : String]
  [message : String]) : json.Json
  (if (lsp-batch-position-error?
    (owned_view.compiler-owned-shared-view operation)
    message)
    (let
      [pos-key : String "position"]
      (match (json.object-get operation (& pos-key))
        [(JsonFound position)
          (let
            [line : i64 (lsp-json-int-field-default position "line" 0)]
            [col : i64 (lsp-json-int-field-default position "character" 0)]
            (lsp-position-context-json text line col))]
        [(JsonMissing) JsonNull]))
    JsonNull))

(define (lsp-batch-contextual-error-message
  [operation : json.Json]
  [text : String]
  [message : String]) : String
  (cond
    [(and
        (string.eq
          (lsp-json-string-field-default
            (owned_view.compiler-owned-shared-view operation)
            "method"
            "")
          "tl/replaceBody")
        (source_text.starts-with? message "newBody is not a valid form: "))
      (match (lsp-json-string-field operation "newBody")
        [(Ok new-body) (lsp-replace-body-validation-message new-body)]
        [(Missing) message])]
    [(lsp-batch-position-error?
        (owned_view.compiler-owned-shared-view operation)
        message)
      (lsp-batch-position-message operation message)]
    [(string.eq message "Declaration not found")
      (lsp-declaration-not-found-message
        (lsp-structural-move-name operation text))]
    [(string.eq message "Destination declaration not found")
      (match (lsp-json-string-field operation "destination")
        [(Ok destination)
          (lsp-str3 "Destination declaration '" destination "' not found")]
        [(Missing) message])]
    [else message]))

(define (lsp-batch-contextual-error-context
  [operation : json.Json]
  [text : String]
  [message : String]) : json.Json
  (if (and
    (string.eq
      (lsp-json-string-field-default
        (owned_view.compiler-owned-shared-view operation)
        "method"
        "")
      "tl/replaceBody")
    (source_text.starts-with? message "newBody is not a valid form: "))
    (match (lsp-json-string-field operation "newBody")
      [(Ok new-body) (lsp-replace-body-validation-data new-body)]
      [(Missing) (lsp-batch-position-context operation text message)])
    (lsp-batch-position-context operation text message)))

(define (lsp-batch-apply-operation
  [operation : json.Json]
  [index : i64]
  [text : String]) : LspBatchOpResult
  (match (lsp-json-string-field operation "method")
    [(Ok method)
      (match (lsp-batch-apply-edit
        method
        (owned_view.compiler-owned-shared-view operation)
        (owned_view.compiler-owned-shared-view text))
        [(Ok next-text)
          (match (lsp-validate-edited-document
            (owned_view.compiler-owned-shared-view next-text))
            [(Ok _) (Ok next-text (lsp-batch-operation-result index))]
            [(Err message) (Err message JsonNull)])]
        [(Err message)
          (Err
            (lsp-batch-contextual-error-message
              (owned_view.compiler-owned-shared-view operation)
              (owned_view.compiler-owned-shared-view text)
              (owned_view.compiler-owned-shared-view message))
            (lsp-batch-contextual-error-context operation text message))])]
    [(Missing) (Err "Missing method parameter" JsonNull)]))

(define (lsp-batch-run-operations
  [ops : json.JsonSeq]
  [index : i64]
  [text : String]) : LspBatchRunResult
  (match (json.list-get-index (owned_view.compiler-owned-shared-view ops) 0)
    [(JsonMissing) (Ok text (json.list-empty))]
    [(JsonFound first)
      (match (lsp-batch-apply-operation
        first
        index
        (owned_view.compiler-owned-shared-view text))
        [(Ok next-text result-json)
          (match (lsp-batch-run-operations
            (json.list-rest ops)
            (+ index 1)
            next-text)
            [(Ok final-text tail-results)
              (Ok final-text (lsp-json-list-cons result-json tail-results))]
            [(Err message failed-index partial-text context)
              (Err message failed-index partial-text context)])]
        [(Err message context) (Err message index text context)])]))

(define (lsp-batch-success-json [text : String] [results : json.JsonSeq]) : json.Json
  (lsp-json-object4
    "success"
    (JsonBool true)
    "text"
    (JsonString (owned_view.compiler-owned-shared-view text))
    "results"
    (lsp-json-array results)
    "positionMap"
    (lsp-position-map-for-text text)))

(define (lsp-batch-failure-json
  [message : String]
  [failed-index : i64]
  [partial-text : String]
  [context : json.Json]) : json.Json
  (match (lsp-global-shared-view context)
    [(JsonNull)
      (lsp-json-object4
        "success"
        (JsonBool false)
        "error"
        (JsonString message)
        "failedIndex"
        (lsp-json-number failed-index)
        "partialText"
        (JsonString partial-text))]
    [_
      (lsp-json-object
        (lsp-json-member
          "success"
          (JsonBool false)
          (lsp-json-member
            "error"
            (JsonString message)
            (lsp-json-member
              "failedIndex"
              (lsp-json-number failed-index)
              (lsp-json-member
                "partialText"
                (JsonString partial-text)
                (lsp-json-member "context" context (json.member-list-empty)))))))]))

(define (lsp-batch-save-success-or-failure
  [id : json.Json]
  [docs : lsp_document_vec.Vec]
  [uri : String]
  [path : String]
  [diagnostic-uris : lsp_vector_families.LspDiagnosticUris]
  [edited-text : String]
  [formatted : String]
  [results : json.JsonSeq]) : LspDocumentHandleResult
  (match (lsp-validate-edited-document
    (owned_view.compiler-owned-shared-view formatted))
    [(Ok _)
      (match (lsp-tl-save-doc
        (owned_view.compiler-owned-shared-view docs)
        uri
        path
        diagnostic-uris
        (owned_view.compiler-owned-shared-view formatted))
        [(Ok next-docs)
          (begin
            (lsp-write-response id (lsp-batch-success-json formatted results))
            (LspDocumentHandleResult.Continue next-docs))]
        [(Err message)
          (begin
            (lsp-write-error id -32600 message)
            (LspDocumentHandleResult.Continue docs))])]
    [(Err message)
      (begin
        (lsp-write-response
          id
          (lsp-batch-failure-json message -1 edited-text JsonNull))
        (LspDocumentHandleResult.Continue docs))]))

(define (lsp-handle-tl-batch
  [id : json.Json]
  [params : json.Json]
  [docs : lsp_document_vec.Vec]) : LspDocumentHandleResult
  (match (lsp-tl-request-uri (owned_view.compiler-owned-shared-view params))
    [(Ok uri)
      (match (lsp-documents-lookup-resynced
        (owned_view.compiler-owned-shared-view docs)
        uri)
        [(Found path text diagnostic-uris)
          (let
            [operations-key : String "operations"]
            (match (json.object-get params (& operations-key))
              [(JsonFound operations)
                (match operations
                  [(JsonArray items)
                    (match (lsp-batch-run-operations (deref items) 0 text)
                      [(Ok edited-text results)
                        (let
                          [formatted : String
                            (lsp-format-edit-text
                              (owned_view.compiler-owned-shared-view
                                edited-text))]
                          (lsp-batch-save-success-or-failure
                            id
                            docs
                            uri
                            path
                            diagnostic-uris
                            edited-text
                            formatted
                            results))]
                      [(Err message failed-index partial-text context)
                        (begin
                          (lsp-write-response
                            id
                            (lsp-batch-failure-json
                              message
                              failed-index
                              partial-text
                              context))
                          (LspDocumentHandleResult.Continue docs))])]
                  [_
                    (begin
                      (lsp-write-error id -32600 "operations must be an array")
                      (LspDocumentHandleResult.Continue docs))])]
              [(JsonMissing)
                (begin
                  (lsp-write-error id -32600 "Missing operations parameter")
                  (LspDocumentHandleResult.Continue docs))]))]
        [(Missing)
          (begin
            (lsp-write-error id -32600 "Document not found")
            (LspDocumentHandleResult.Continue docs))])]
    [(Missing)
      (begin
        (lsp-write-error id -32600 "Missing uri in textDocument parameter")
        (LspDocumentHandleResult.Continue docs))]))