;; lsp_frame_smoke.tl - Runnable smoke for LSP diagnostic metadata adapters.
(import stdlib.fs)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.arena)
(import stdlib.json)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector String) as lsp_svec)
(import "../lsp_frame_core.tl")
(import (vector.vector LspDeclEntry core) as lsp_decl_vec)
(import (vector.vector LspDocument core) as lsp_document_vec)

(define (lsp-smoke-write-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (lsp-smoke-mkdir [path : String]) : unit
  (match (fs.try-mkdir-if-missing (& path))
    [(io.OkIoUnit) unit]
    [(io.ErrIoUnit _) unit]))

(define (lsp-smoke-remove-file [path : String]) : unit
  (match (fs.try-remove-file-if-exists (& path))
    [(io.OkIoUnit) unit]
    [(io.ErrIoUnit _) unit]))

(define (lsp-smoke-make-directory-cycle-link [path : String]) : bool
  (cfg
    windows
    true
    (let
      [target-bytes : (__tl_dyn-array u8) (io.c-string ".")]
      [path-bytes : (__tl_dyn-array u8) (io.c-string path)]
      [status : i64
        (io.linux-syscall-status
          (unsafe
            (syscall
              266
              (io.linux-ptr-arg (io.array-const-ptr target-bytes))
              -100
              (io.linux-ptr-arg (io.array-const-ptr path-bytes)))))]
      (= status 0))))

(define (lsp-smoke-folder-json [uri : String]) : json.Json
  (lsp-json-object2
    "uri"
    (json.JsonString uri)
    "name"
    (json.JsonString "workspace")))

(define (lsp-smoke-folder-list-from [roots : lsp_svec.Vec] [index : i64]) : json.JsonSeq
  (if (>= index (lsp_svec.len (& roots)))
    (json.list-empty)
    (lsp-json-list-cons
      (lsp-smoke-folder-json (lsp_svec.get (& roots) index ""))
      (lsp-smoke-folder-list-from roots (+ index 1)))))

(define (lsp-smoke-initialize-message
  [roots : lsp_svec.Vec]
  [root-uri : String]) : json.Json
  (lsp-json-object1
    "params"
    (lsp-json-object2
      "workspaceFolders"
      (lsp-json-array (lsp-smoke-folder-list-from roots 0))
      "rootUri"
      (if (> (string.string-length root-uri) 0)
        (json.JsonString root-uri)
        json.JsonNull))))

(define (lsp-smoke-initialize-state [roots : lsp_svec.Vec] [root-uri : String]) : LspServerState
  (let
    [state : LspServerState (lsp-server-state-new)]
    (lsp-server-state-initialize-workspaces
      state
      (lsp-smoke-initialize-message roots root-uri))))

(define (lsp-smoke-state-name-count
  [state : (& state LspServerState)]
  [name : String]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    [total : i64 (lsp-server-state-declaration-count state)]
    (begin
      (while (< index total)
        (begin
          (match (lsp-server-state-declaration-at state index)
            [(LspWorkspaceDeclLookup.Missing) unit]
            [(LspWorkspaceDeclLookup.Found row)
              (if (string.eq (struct-get (struct-get row decl) name) name)
                (set! count (+ count 1))
                unit)])
          (set! index (+ index 1))))
      count)))

(define (lsp-smoke-state-name-at
  [state : (& state LspServerState)]
  [index : i64]) : String
  (match (lsp-server-state-declaration-at state index)
    [(LspWorkspaceDeclLookup.Missing) ""]
    [(LspWorkspaceDeclLookup.Found row) (struct-get (struct-get row decl) name)]))

(define (lsp-smoke-state-row-matches?
  [state : (& state LspServerState)]
  [name : String]
  [module : String]
  [root-uri : String]
  [explicit-module : bool]
  [overlay : bool]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    [total : i64 (lsp-server-state-declaration-count state)]
    (begin
      (while (and (< index total) (not found))
        (begin
          (match (lsp-server-state-declaration-at state index)
            [(LspWorkspaceDeclLookup.Missing) unit]
            [(LspWorkspaceDeclLookup.Found row)
              (if (and
                (string.eq (struct-get (struct-get row decl) name) name)
                (string.eq (struct-get row module) module)
                (string.eq (struct-get row root-uri) root-uri)
                (= (struct-get row explicit-module) explicit-module)
                (= (struct-get row overlay) overlay))
                (set! found true)
                unit)])
          (set! index (+ index 1))))
      found)))

(define (lsp-smoke-state-with-overlay
  [state : LspServerState]
  [path : String]
  [text : String]
  [version : i64]) : LspServerState
  (let
    [normalized : String (lsp-normalized-absolute-path path)]
    [uri : String (lsp-resolved-path-to-file-uri normalized)]
    [docs : lsp_document_vec.Vec
      (lsp-documents-set-versioned
        (struct-get state documents)
        uri
        normalized
        text
        version
        (lsp-diagnostic-uris-empty))]
    (match (lsp-server-state-refresh-document-result
      state
      (LspDocumentHandleResult.Continue docs)
      uri
      false)
      [(LspHandleResult.Continue next) next]
      [(LspHandleResult.Exit next) next])))

(define (lsp-smoke-state-close [state : LspServerState] [path : String]) : LspServerState
  (let
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [docs : lsp_document_vec.Vec
      (lsp-documents-remove (struct-get state documents) uri)]
    (match (lsp-server-state-refresh-document-result
      state
      (LspDocumentHandleResult.Continue docs)
      uri
      false)
      [(LspHandleResult.Continue next) next]
      [(LspHandleResult.Exit next) next])))

(define (lsp-smoke-watcher-params [uri : String] [kind : i64]) : json.Json
  (lsp-json-object1
    "changes"
    (lsp-json-array
      (lsp-json-list-cons
        (lsp-json-object2
          "uri"
          (json.JsonString uri)
          "type"
          (lsp-json-number kind))
        (json.list-empty)))))

(define (lsp-smoke-state-watch
  [state : LspServerState]
  [path : String]
  [kind : i64]) : LspServerState
  (let
    [uri : String (lsp-resolved-path-to-file-uri path)]
    (lsp-server-state-did-change-watched-files
      state
      (lsp-smoke-watcher-params uri kind))))

(define (lsp-smoke-workspace-event-params
  [added : lsp_svec.Vec]
  [removed : lsp_svec.Vec]) : json.Json
  (lsp-json-object1
    "event"
    (lsp-json-object2
      "added"
      (lsp-json-array (lsp-smoke-folder-list-from added 0))
      "removed"
      (lsp-json-array (lsp-smoke-folder-list-from removed 0)))))

(define (lsp-smoke-state-workspace-event
  [state : LspServerState]
  [added : lsp_svec.Vec]
  [removed : lsp_svec.Vec]) : LspServerState
  (lsp-server-state-did-change-workspace-folders
    state
    (lsp-smoke-workspace-event-params added removed)))

(define (lsp-smoke-state-root-count [state : (& state LspServerState)]) : i64
  (lsp-workspace-roots-len (& (struct-get (struct-get state workspace) roots))))

(define (lsp-smoke-state-source-count [state : (& state LspServerState)]) : i64
  (lsp-workspace-sources-len
    (& (struct-get (struct-get state workspace) sources))))

(define (lsp-smoke-state-root-uri-at
  [state : (& state LspServerState)]
  [index : i64]) : String
  (struct-get
    (lsp-workspace-roots-get
      (& (struct-get (struct-get state workspace) roots))
      index)
    uri))

(define (lsp-smoke-string-vec-contains?
  [items : lsp_svec.Vec]
  [needle : String]) : bool
  (let
    [idx : i64 0]
    [found : bool false]
    (begin
      (while (< idx (lsp_svec.len (& items)))
        (if (string.eq (lsp_svec.get (& items) idx "") needle)
          (begin
            (set! found true)
            (set! idx (lsp_svec.len (& items))))
          (set! idx (+ idx 1))))
      found)))

(define (lsp-completion-smoke-ok?) : bool
  (let
    [src : String
      "(define (square [x : i64]) : i64 (* x x)) (define answer : i64 42)"]
    [names : lsp_svec.Vec (lsp-collect-def-names src (lsp_svec.new))]
    [keywords : lsp_svec.Vec (lsp-split-spaces (lsp-completion-keywords))]
    [builtins : lsp_svec.Vec (lsp-split-spaces (lsp-completion-builtins))]
    [types : lsp_svec.Vec (lsp-split-spaces (lsp-completion-types))]
    (and
      (lsp-smoke-string-vec-contains? names "square")
      (lsp-smoke-string-vec-contains? names "answer")
      (lsp-smoke-string-vec-contains? keywords "define")
      (lsp-smoke-string-vec-contains? builtins "make-array")
      (lsp-smoke-string-vec-contains? types "i64"))))

(define (lsp-smoke-index-of [haystack : String] [needle : String]) : i64
  (let
    [n : i64 (string.string-length haystack)]
    [m : i64 (string.string-length needle)]
    [i : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< i n) (< found 0))
        (if (and
          (<= (+ i m) n)
          (string.is-string-prefix-at (& haystack) (& needle) i))
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (lsp-transcript-frame [body : String]) : String
  (lsp-str5
    "Content-Length: "
    (string.int->string (string.string-length body))
    "\r\n\r\n"
    body
    ""))

(define (lsp-transcript-run [input : String]) : LspTranscriptResult
  (lsp-frame-run-transcript (& input) (lsp_svec.new) false))

(define (lsp-transcript-result-contains?
  [result : LspTranscriptResult]
  [needle : String]) : bool
  (string.contains (& (struct-get result stdout)) (& needle)))

(define (lsp-smoke-count-substring [text : String] [needle : String]) : i64
  (let
    [text-len : i64 (string.string-length text)]
    [needle-len : i64 (string.string-length needle)]
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (<= (+ index needle-len) text-len)
        (if (string.is-string-prefix-at (& text) (& needle) index)
          (begin
            (set! count (+ count 1))
            (set! index (+ index needle-len)))
          (set! index (+ index 1))))
      count)))

(define (lsp-transcript-framing-smoke-ok?) : bool
  (let
    [clean : LspTranscriptResult (lsp-transcript-run "")]
    [unterminated : LspTranscriptResult
      (lsp-transcript-run "Content-Length: 2")]
    [missing : LspTranscriptResult (lsp-transcript-run "\r\n")]
    [invalid : LspTranscriptResult
      (lsp-transcript-run "Content-Length: nope\r\n\r\n")]
    [truncated : LspTranscriptResult
      (lsp-transcript-run "Content-Length: 5\r\n\r\n{}")]
    [malformed : LspTranscriptResult
      (lsp-transcript-run (lsp-transcript-frame "{]"))]
    [parse-code : String "\"code\":-32700"]
    (and
      (= (struct-get clean status) 0)
      (string.eq (struct-get clean stdout) "")
      (string.eq (struct-get clean stderr) "")
      (= (struct-get unterminated status) 1)
      (string.eq
        (struct-get unterminated stderr)
        "lsp: EOF before header terminator")
      (lsp-transcript-result-contains? unterminated parse-code)
      (= (struct-get missing status) 1)
      (string.eq (struct-get missing stderr) "lsp: missing Content-Length")
      (lsp-transcript-result-contains? missing parse-code)
      (= (struct-get invalid status) 1)
      (string.eq (struct-get invalid stderr) "lsp: invalid Content-Length")
      (lsp-transcript-result-contains? invalid parse-code)
      (= (struct-get truncated status) 1)
      (string.eq (struct-get truncated stderr) "lsp: truncated payload")
      (lsp-transcript-result-contains? truncated parse-code)
      (= (struct-get malformed status) 0)
      (string.eq (struct-get malformed stderr) "")
      (lsp-transcript-result-contains? malformed parse-code))))

(define (lsp-transcript-order-and-id-smoke-ok?) : bool
  (let
    [initialize : String
      "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"initialize\",\"params\":{}}"]
    [shutdown : String
      "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"shutdown\"}"]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [input : String
      (string.append
        (lsp-transcript-frame initialize)
        (string.append
          (lsp-transcript-frame shutdown)
          (lsp-transcript-frame exit)))]
    [ordered : LspTranscriptResult (lsp-transcript-run input)]
    [out : String (struct-get ordered stdout)]
    [first-id : String "\"id\":41"]
    [second-id : String "\"id\":42"]
    [first-pos : i64 (lsp-smoke-index-of out first-id)]
    [second-pos : i64 (lsp-smoke-index-of out second-id)]
    [next-initialize : String
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"initialize\",\"params\":{}}"]
    [next-input : String
      (string.append
        (lsp-transcript-frame next-initialize)
        (lsp-transcript-frame exit))]
    [next : LspTranscriptResult (lsp-transcript-run next-input)]
    [old-id : String "\"id\":41"]
    [new-id : String "\"id\":3"]
    (and
      (= (struct-get ordered status) 0)
      (string.eq (struct-get ordered stderr) "")
      (>= first-pos 0)
      (> second-pos first-pos)
      (= (struct-get next status) 0)
      (lsp-transcript-result-contains? next new-id)
      (not (lsp-transcript-result-contains? next old-id)))))

(define (lsp-transcript-did-open [uri : String] [text : String]) : String
  (lsp-str7
    "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\""
    uri
    "\",\"languageId\":\"typelisp\",\"version\":1,\"text\":\""
    text
    "\"}}}"
    ""
    ""))

(define (lsp-transcript-did-change
  [uri : String]
  [text : String]
  [version : i64]) : String
  (lsp-str7
    "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\""
    uri
    "\",\"version\":"
    (string.int->string version)
    "},\"contentChanges\":[{\"text\":\""
    text
    "\"}]}}"))

(define (lsp-transcript-check [uri : String] [id : i64]) : String
  (lsp-str5
    "{\"jsonrpc\":\"2.0\",\"id\":"
    (string.int->string id)
    ",\"method\":\"tl/check\",\"params\":{\"uri\":\""
    uri
    "\"}}"))

(define (lsp-transcript-check-session [uri : String] [text : String] [id : i64]) : LspTranscriptResult
  (let
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [input : String
      (string.append
        (lsp-transcript-frame (lsp-transcript-did-open uri text))
        (string.append
          (lsp-transcript-frame (lsp-transcript-check uri id))
          (lsp-transcript-frame exit)))]
    (lsp-transcript-run input)))

(define (lsp-transcript-reset-leakage-smoke-ok?) : bool
  (let
    [path : String "target/lsp_transcript_reset_missing.tl"]
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [valid-source : String "(define (same) : i64 1)"]
    [invalid-source : String "(define (same) : i64 true)"]
    [first : LspTranscriptResult
      (lsp-transcript-check-session uri valid-source 71)]
    [second : LspTranscriptResult
      (lsp-transcript-check-session uri invalid-source 72)]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [missing-input : String
      (string.append
        (lsp-transcript-frame (lsp-transcript-check uri 73))
        (lsp-transcript-frame exit))]
    [missing : LspTranscriptResult (lsp-transcript-run missing-input)]
    [success : String "\"success\":true"]
    [failure : String "\"success\":false"]
    [unreadable : String "Could not read document"]
    (and
      (= (struct-get first status) 0)
      (lsp-transcript-result-contains? first success)
      (= (struct-get second status) 0)
      (lsp-transcript-result-contains? second failure)
      (= (struct-get missing status) 0)
      (lsp-transcript-result-contains? missing unreadable)
      (not lsp-frame-memory-active)
      (= lsp-document-cache-arena 0))))

(define (lsp-multiple-diagnostics-smoke-ok?) : bool
  (let
    [path : String "target/lsp_multiple_diagnostics.tl"]
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [source : String
      "(define (a) : i64 missing-a) (define (b) : i64 missing-b) (define (main) : i64 0)"]
    [result : LspTranscriptResult (lsp-transcript-check-session uri source 74)]
    [compiler-source : String "\"source\":\"typelisp\""]
    (and
      (= (struct-get result status) 0)
      (string.eq (struct-get result stderr) "")
      (=
        (lsp-smoke-count-substring (struct-get result stdout) compiler-source)
        2))))

(define (lsp-multiple-external-diagnostics-smoke-ok?) : bool
  (let
    [dir : String "target"]
    [root-path : String "target/lsp_multi_root.tl"]
    [dep-a-path : String "target/lsp_multi_dep_a.tl"]
    [dep-b-path : String "target/lsp_multi_dep_b.tl"]
    [root-uri : String (lsp-resolved-path-to-file-uri root-path)]
    [dep-a-uri : String (lsp-resolved-path-to-file-uri dep-a-path)]
    [dep-b-uri : String (lsp-resolved-path-to-file-uri dep-b-path)]
    [source : String
      "(import \\\"lsp_multi_dep_a.tl\\\")\\n(import \\\"lsp_multi_dep_b.tl\\\")\\n(define (main) : i64 0)"]
    [valid-source : String "(define (main) : i64 0)"]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    (begin
      (match (fs.try-mkdir-if-missing (& dir))
        [(io.OkIoUnit) unit]
        [(io.ErrIoUnit _) unit])
      (lsp-smoke-write-text
        dep-a-path
        "(module dep-a)\n(define broken-a : i64 true)")
      (lsp-smoke-write-text
        dep-b-path
        "(module dep-b)\n(define broken-b : i64 \"bad\")")
      (let
        [input : String
          (string.append
            (lsp-transcript-frame (lsp-transcript-did-open root-uri source))
            (string.append
              (lsp-transcript-frame
                (lsp-transcript-did-change root-uri valid-source 2))
              (lsp-transcript-frame exit)))]
        [result : LspTranscriptResult (lsp-transcript-run input)]
        [out : String (struct-get result stdout)]
        [message-a : String
          "typecheck: value definition type mismatch: expected i64, found bool"]
        [message-b : String
          "typecheck: value definition type mismatch: expected i64, found String"]
        (and
          (= (struct-get result status) 0)
          (string.eq (struct-get result stderr) "")
          (string.contains (& out) (& message-a))
          (string.contains (& out) (& message-b))
          (= (lsp-smoke-count-substring out dep-a-uri) 2)
          (= (lsp-smoke-count-substring out dep-b-uri) 2))))))

(define (lsp-transcript-arena-escape-smoke-ok?) : bool
  (let
    [home : i64 (arena.tl_arena_current)]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [result : LspTranscriptResult
      (lsp-transcript-run (lsp-transcript-frame exit))]
    (and
      (= (arena.tl_arena_current) home)
      (= (struct-get result status) 0)
      (string.eq (struct-get result stdout) "")
      (string.eq (struct-get result stderr) "")
      (not lsp-frame-memory-active))))

(define (lsp-inlay-smoke-ok?) : bool
  (let
    [src : String
      "(define (main) : i64 (let [total 41] [typed : i64 5] [next (+ total 1)] next))"]
    [total-off : i64 (lsp-smoke-index-of src "41")]
    [typed-off : i64 (lsp-smoke-index-of src "5]")]
    [next-off : i64 (lsp-smoke-index-of src "(+ total 1)")]
    (if (or (< total-off 0) (< typed-off 0) (< next-off 0))
      false
      (begin
        (tc-inlay-hints-enable!)
        (tc-inlay-hint-record! 1 (+ total-off 1) "i64")
        (tc-inlay-hint-record! 1 (+ typed-off 1) "i64")
        (tc-inlay-hint-record! 1 (+ next-off 1) "i64")
        (let
          [hints : json.JsonSeq (lsp-inlay-build src 0 0)]
          [rendered : String (json.stringify (lsp-json-array hints))]
          [type-label : String "\": i64\""]
          [total-pos : String "\"character\":33"]
          [next-pos : String "\"character\":59"]
          (begin
            (tc-inlay-hints-disable!)
            (and
              (= (json.list-count hints) 2)
              (string.contains (& rendered) (& type-label))
              (string.contains (& rendered) (& total-pos))
              (string.contains (& rendered) (& next-pos)))))))))

(define (lsp-formatting-smoke-ok?) : bool
  (let
    [messy : String "(define   (f)  :  i64   (+ 1   2))"]
    (match (format-rules-render-source-width-result messy 80)
      [(ResultFormatString.Ok formatted)
        (let
          [rendered : String
            (json.stringify (lsp-formatting-edit messy formatted))]
          [sig : String "(define (f) : i64"]
          [newtext-key : String "\"newText\""]
          [range-key : String "\"range\""]
          (and
            (string.contains (& formatted) (& sig))
            (string.contains (& rendered) (& newtext-key))
            (string.contains (& rendered) (& range-key))))]
      [(ResultFormatString.Err _) false])))

(define (lsp-format-edit-text-smoke-ok?) : bool
  (let
    [messy : String "(define   (f)  :  i64   (+ 1   2))"]
    [invalid : String "(define (f) : i64"]
    [formatted : String (lsp-format-edit-text messy)]
    [fallback : String (lsp-format-edit-text invalid)]
    [sig : String "(define (f) : i64"]
    (and
      (string.contains (& formatted) (& sig))
      (not (string.eq formatted messy))
      (string.eq fallback invalid))))

(define (lsp-check-smoke-ok?) : bool
  (let
    [ok-src : String "(define (main) : i64 42)"]
    [bad-src : String "(define (main) : i64 (+ 1 \"two\"))"]
    [ok-result : bool
      (match (compiler-check-source "ok.tl" ok-src)
        [(ResultCompilerCheck.Ok _) true]
        [(ResultCompilerCheck.Err _) false])]
    [bad-result : bool
      (match (compiler-check-source "bad.tl" bad-src)
        [(ResultCompilerCheck.Ok _) false]
        [(ResultCompilerCheck.Err _) true])]
    (and ok-result bad-result)))

(define (lsp-get-type-smoke-ok?) : bool
  (let
    [src : String
      "(define (main) : i32 (let [total 41] [next (+ total 1)] next))"]
    [total-off : i64 (lsp-smoke-index-of src "41")]
    (if (< total-off 0)
      false
      (begin
        (tc-inlay-hints-enable!)
        (match (compiler-check-source "test.tl" src)
          [(ResultCompilerCheck.Ok _) unit]
          [(ResultCompilerCheck.Err _) unit])
        (let
          [size : i64 (tc-inlay-hints-size)]
          [i : i64 0]
          [found-ok : bool false]
          [near-ok : bool false]
          (begin
            (while (and (< i size) (not found-ok))
              (let
                [hint-line : i64 (tc-inlay-hint-line-at i)]
                [hint-col : i64 (tc-inlay-hint-col-at i)]
                [target-line : i64 1]
                [target-col : i64 (+ total-off 1)]
                (begin
                  (if (and (= hint-line target-line) (= hint-col target-col))
                    (set! found-ok (string.eq (tc-inlay-hint-type-at i) "i32"))
                    unit)
                  (set! i (+ i 1)))))
            (let
              [near-idx : i64
                (lsp-nearest-inlay-hint-index src 1 (+ total-off 3))]
              (if (>= near-idx 0)
                (set!
                  near-ok
                  (string.eq (tc-inlay-hint-type-at near-idx) "i32"))
                unit))
            (tc-inlay-hints-disable!)
            (and found-ok near-ok)))))))

(define (lsp-find-references-smoke-ok?) : bool
  (let
    [src : String
      "(define (foo [x : i64]) : i64 x) (define (bar) : i64 (foo 1))"]
    [refs : json.JsonSeq
      (lsp-find-references-in-text
        src
        "foo"
        0
        (string.string-length src)
        (json.list-empty))]
    [rendered : String (json.stringify (lsp-json-array refs))]
    [count-ok : bool (= (json.list-count refs) 2)]
    [needle0 : String "\"line\":0"]
    [line0-ok : bool (string.contains (& rendered) (& needle0))]
    (and count-ok line0-ok)))

(define (lsp-document-decls-cache-empty-ok?) : bool
  (let
    [uri : String "file:///tmp/cache.tl"]
    [path : String "/tmp/cache.tl"]
    [docs0 : lsp_document_vec.Vec (lsp_document_vec.new)]
    [docs1 : lsp_document_vec.Vec
      (lsp-documents-set docs0 uri path "" (lsp-diagnostic-uris-single uri))]
    [doc1 : LspDocument
      (lsp_document_vec.get (& docs1) 0 (lsp-document-fallback))]
    [empty-decls : lsp_decl_vec.Vec (lsp-document-decls doc1 docs1)]
    [cached-empty-doc : LspDocument
      (lsp_document_vec.get (& docs1) 0 (lsp-document-fallback))]
    [docs2 : lsp_document_vec.Vec
      (lsp-documents-set docs1 uri path "" (lsp-diagnostic-uris-single "diag"))]
    [same-text-doc : LspDocument
      (lsp_document_vec.get (& docs2) 0 (lsp-document-fallback))]
    [docs3 : lsp_document_vec.Vec
      (lsp-documents-set
        docs2
        uri
        path
        "(define cached : i64 1)"
        (lsp-diagnostic-uris-single "diag"))]
    [changed-doc : LspDocument
      (lsp_document_vec.get (& docs3) 0 (lsp-document-fallback))]
    [changed-decls : lsp_decl_vec.Vec (lsp-document-decls changed-doc docs3)]
    [cached-changed-doc : LspDocument
      (lsp_document_vec.get (& docs3) 0 (lsp-document-fallback))]
    (and
      (= (lsp_decl_vec.len (& empty-decls)) 0)
      (struct-get cached-empty-doc decls-valid)
      (= (lsp_decl_vec.len (struct-get cached-empty-doc decls)) 0)
      (struct-get same-text-doc decls-valid)
      (not (struct-get changed-doc decls-valid))
      (= (lsp_decl_vec.len (& changed-decls)) 1)
      (struct-get cached-changed-doc decls-valid))))

(define (lsp-document-disk-resync-ok?) : bool
  (let
    [dir : String "target"]
    [path : String "target/lsp_disk_resync_smoke.tl"]
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [stale-text : String "(define stale : i64 0)"]
    [disk-text : String "(define fresh : i64 1)"]
    [fresh-name : String "fresh"]
    [params : json.Json
      (lsp-json-object1
        "textDocument"
        (lsp-json-object1 "uri" (json.JsonString uri)))]
    [docs : lsp_document_vec.Vec (lsp_document_vec.new)]
    (begin
      (match (fs.try-mkdir-if-missing (& dir))
        [(io.OkIoUnit) unit]
        [(io.ErrIoUnit _) unit])
      (lsp-smoke-write-text path disk-text)
      (set!
        docs
        (lsp-documents-set
          docs
          uri
          path
          stale-text
          (lsp-diagnostic-uris-single uri)))
      (let
        [lookup-ok : bool
          (match (lsp-get-document params docs)
            [(LspDocumentLookup.Found _ text _)
              (string.contains (& text) (& fresh-name))]
            [(LspDocumentLookup.Missing) false])]
        [cached-doc : LspDocument
          (lsp_document_vec.get (& docs) 0 (lsp-document-fallback))]
        [cache-ok : bool
          (and
            (string.contains (& (struct-get cached-doc text)) (& fresh-name))
            (not (struct-get cached-doc decls-valid)))]
        [decls-ok : bool
          (match (lsp-get-document-decls params docs)
            [(LspDocumentDeclsLookup.Found _ text _ decls)
              (let
                [entry : LspDeclEntry
                  (lsp_decl_vec.get (& decls) 0 (lsp-decl-entry-fallback))]
                (and
                  (string.contains (& text) (& fresh-name))
                  (= (lsp_decl_vec.len (& decls)) 1)
                  (string.eq (struct-get entry name) fresh-name)))]
            [(LspDocumentDeclsLookup.Missing) false])]
        [cached-decls-doc : LspDocument
          (lsp_document_vec.get (& docs) 0 (lsp-document-fallback))]
        (and
          lookup-ok
          cache-ok
          decls-ok
          (struct-get cached-decls-doc decls-valid))))))

(define (lsp-edit-save-doc-smoke-ok?) : bool
  (let
    [dir : String "target"]
    [path : String "target/lsp_edit_save_doc_smoke.tl"]
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [initial : String "(define (main) : i64 1)"]
    [updated : String "(define (main) : i64 42)"]
    [docs : lsp_document_vec.Vec
      (lsp-documents-set
        (lsp_document_vec.new)
        uri
        path
        initial
        (lsp-diagnostic-uris-single uri))]
    (begin
      (match (fs.try-mkdir-if-missing (& dir))
        [(io.OkIoUnit) unit]
        [(io.ErrIoUnit _) unit])
      (match (lsp-tl-save-doc
        docs
        uri
        path
        (lsp-diagnostic-uris-single uri)
        updated)
        [(LspSaveResult.Ok next-docs)
          (let
            [disk-text : String (byte_buf.to-string (io.read-file path))]
            [cached-doc : LspDocument
              (lsp_document_vec.get (& next-docs) 0 (lsp-document-fallback))]
            (and
              (string.eq disk-text updated)
              (string.eq (struct-get cached-doc text) updated)
              (not (struct-get cached-doc decls-valid))))]
        [(LspSaveResult.Err _) false]))))

(define (lsp-scan-decls-cache-local-smoke-ok?) : bool
  (let
    [first : String "(define (alpha) : i64 1)"]
    [second : String
      ";; one\n;; two\n;; three\n\n(define (wide) : i64 2)\n(define (next) : i64 3)"]
    [first-decls : lsp_decl_vec.Vec (lsp-scan-decls first)]
    [second-decls : lsp_decl_vec.Vec (lsp-scan-decls second)]
    [wide : LspDeclEntry
      (lsp_decl_vec.get (& second-decls) 0 (lsp-decl-entry-fallback))]
    [next : LspDeclEntry
      (lsp_decl_vec.get (& second-decls) 1 (lsp-decl-entry-fallback))]
    (and
      (= (lsp_decl_vec.len (& first-decls)) 1)
      (= (lsp_decl_vec.len (& second-decls)) 2)
      (string.eq (struct-get wide name) "wide")
      (= (struct-get wide form-start-line) 5)
      (= (struct-get wide form-start-col) 1)
      (= (struct-get wide name-line) 5)
      (= (struct-get wide name-col) 10)
      (string.eq (struct-get next name) "next")
      (= (struct-get next form-start-line) 6)
      (= (struct-get next form-start-col) 1)
      (= (struct-get next name-line) 6)
      (= (struct-get next name-col) 10))))

(define (lsp-document-symbol-smoke-ok?) : bool
  (let
    [source : String
      "(define (fun) : i64 1)\n(define value : i64 2)\n(defstruct Pair (x i64))\n(defenum Choice (Yes))\n(defmacro make [] unit)\n(defdispatch choose [] fun)\n(extern (puts [s : ptr]) : i64)\n(extern errno : i64)\n;; (define hidden : i64 0)\n(define text : String \"(defstruct Hidden)\")"]
    [rendered : String (json.stringify (lsp-document-symbols-for-text source))]
    [capabilities : String (json.stringify (lsp-initialize-result))]
    [fun : String
      "{\"name\":\"fun\",\"kind\":12,\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":22}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":9},\"end\":{\"line\":0,\"character\":12}}}"]
    [value : String
      "{\"name\":\"value\",\"kind\":13,\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":22}},\"selectionRange\":{\"start\":{\"line\":1,\"character\":8},\"end\":{\"line\":1,\"character\":13}}}"]
    [pair : String "{\"name\":\"Pair\",\"kind\":23"]
    [choice : String "{\"name\":\"Choice\",\"kind\":10"]
    [macro : String "{\"name\":\"make\",\"kind\":12"]
    [dispatch : String "{\"name\":\"choose\",\"kind\":12"]
    [function-extern : String "{\"name\":\"puts\",\"kind\":12"]
    [data-extern : String "{\"name\":\"errno\",\"kind\":13"]
    [text-value : String "{\"name\":\"text\",\"kind\":13"]
    [hidden : String "\"name\":\"hidden\""]
    [hidden-in-string : String "\"name\":\"Hidden\""]
    [capability : String "\"documentSymbolProvider\":true"]
    (and
      (string.contains (& capabilities) (& capability))
      (string.contains (& rendered) (& fun))
      (string.contains (& rendered) (& value))
      (string.contains (& rendered) (& pair))
      (string.contains (& rendered) (& choice))
      (string.contains (& rendered) (& macro))
      (string.contains (& rendered) (& dispatch))
      (string.contains (& rendered) (& function-extern))
      (string.contains (& rendered) (& data-extern))
      (string.contains (& rendered) (& text-value))
      (not (string.contains (& rendered) (& hidden)))
      (not (string.contains (& rendered) (& hidden-in-string))))))

(define (lsp-document-highlight-smoke-ok?) : bool
  (let
    [source : String
      "(define foo : i64 1)\n(define foo-bar : i64 foo)\n(define qualified : i64 mod.foo)\n(define another : i64 mod.foo)\n; foo mod.foo\n(define text : String \"foo mod.foo\")\n(define f : char 'f')\n(define punct : i64 foo?)"]
    [foo : String
      (json.stringify
        (lsp-json-array (lsp-document-highlights-in-text source "foo")))]
    [qualified : String
      (json.stringify
        (lsp-json-array (lsp-document-highlights-in-text source "mod.foo")))]
    [letter : String
      (json.stringify
        (lsp-json-array (lsp-document-highlights-in-text source "f")))]
    [capabilities : String (json.stringify (lsp-initialize-result))]
    [foo-want : String
      "[{\"range\":{\"start\":{\"line\":0,\"character\":8},\"end\":{\"line\":0,\"character\":11}},\"kind\":1},{\"range\":{\"start\":{\"line\":1,\"character\":22},\"end\":{\"line\":1,\"character\":25}},\"kind\":1}]"]
    [qualified-want : String
      "[{\"range\":{\"start\":{\"line\":2,\"character\":24},\"end\":{\"line\":2,\"character\":31}},\"kind\":1},{\"range\":{\"start\":{\"line\":3,\"character\":22},\"end\":{\"line\":3,\"character\":29}},\"kind\":1}]"]
    [letter-want : String
      "[{\"range\":{\"start\":{\"line\":6,\"character\":8},\"end\":{\"line\":6,\"character\":9}},\"kind\":1}]"]
    [capability : String "\"documentHighlightProvider\":true"]
    (and
      (string.contains (& capabilities) (& capability))
      (string.eq foo foo-want)
      (string.eq qualified qualified-want)
      (string.eq letter letter-want)
      (string.eq
        (lsp-code-symbol-at-offset source (lsp-offset-at-position source 2 25))
        "mod.foo")
      (string.eq
        (lsp-code-symbol-at-offset source (lsp-offset-at-position source 4 3))
        "")
      (string.eq
        (lsp-code-symbol-at-offset source (lsp-offset-at-position source 5 24))
        ""))))

(define (lsp-fold-render [source : String]) : String
  (json.stringify (lsp-json-array (lsp-folding-ranges-in-text source))))

;; Multiline forms fold from just after the opener to just before the closer;
;; single-line forms produce nothing.
(define (lsp-folding-range-forms-smoke-ok?) : bool
  (let
    [source : String
      "(define (fun) : i64\n  (+ 1\n     2))\n(define small : i64 1)"]
    [want : String
      "[{\"startLine\":0,\"startCharacter\":1,\"endLine\":2,\"endCharacter\":7},{\"startLine\":1,\"startCharacter\":3,\"endLine\":2,\"endCharacter\":6}]"]
    [capabilities : String (json.stringify (lsp-initialize-result))]
    [capability : String "\"foldingRangeProvider\":true"]
    (and
      (string.contains (& capabilities) (& capability))
      (string.eq (lsp-fold-render source) want))))

;; Adjacent comment-only lines fold as one `comment` region. A lone comment
;; line, a trailing comment after code, and a run broken by a blank or code
;; line never produce one.
(define (lsp-folding-range-comments-smoke-ok?) : bool
  (let
    [source : String
      ";; alpha\n;; beta\n\n;; lonely\n(define x : i64 1) ; trailing\n;; gamma\n;; delta"]
    [want : String
      "[{\"startLine\":0,\"startCharacter\":8,\"endLine\":1,\"endCharacter\":7,\"kind\":\"comment\"},{\"startLine\":5,\"startCharacter\":8,\"endLine\":6,\"endCharacter\":8,\"kind\":\"comment\"}]"]
    (string.eq (lsp-fold-render source) want)))

;; Delimiters inside string literals, character literals, and comments neither
;; open nor close a fold, so each form still ends at its real closer.
(define (lsp-folding-range-literals-smoke-ok?) : bool
  (let
    [source : String
      "(define a : String\n  \")))\")\n(define b : char\n  ')')\n(define c : i64\n  ;; )))\n  1)"]
    [want : String
      "[{\"startLine\":0,\"startCharacter\":1,\"endLine\":1,\"endCharacter\":7},{\"startLine\":2,\"startCharacter\":1,\"endLine\":3,\"endCharacter\":5},{\"startLine\":4,\"startCharacter\":1,\"endLine\":6,\"endCharacter\":3}]"]
    (string.eq (lsp-fold-render source) want)))

;; Malformed buffers stay in-bounds: never-closed forms drop out entirely and
;; unmatched closers are ignored instead of producing negative coordinates.
(define (lsp-folding-range-malformed-smoke-ok?) : bool
  (let
    [unclosed : String "(define broken : i64\n  (+ 1\n"]
    [extra-closers : String ")))\n(define ok : i64\n  1)"]
    [want-extra : String
      "[{\"startLine\":1,\"startCharacter\":1,\"endLine\":2,\"endCharacter\":3}]"]
    (and
      (string.eq (lsp-fold-render unclosed) "[]")
      (string.eq (lsp-fold-render "") "[]")
      (string.eq (lsp-fold-render extra-closers) want-extra))))

;; Characters are UTF-16 code units: a 2- or 3-byte codepoint counts as one and
;; a 4-byte codepoint as a surrogate pair, never as its UTF-8 byte length.
(define (lsp-folding-range-utf16-smoke-ok?) : bool
  (let
    [source : String
      ";; λ€𝄞\n;; ok\n(define s : String\n  \"λ€𝄞\")"]
    [want : String
      "[{\"startLine\":0,\"startCharacter\":7,\"endLine\":1,\"endCharacter\":5,\"kind\":\"comment\"},{\"startLine\":2,\"startCharacter\":1,\"endLine\":3,\"endCharacter\":8}]"]
    (string.eq (lsp-fold-render source) want)))

;; `depth` nested one-per-line opens followed by `depth` closes.
(define (lsp-fold-nested-source [depth : i64]) : String
  (let
    [buf : text_buf.TextBuf (text_buf.empty)]
    [i : i64 0]
    (begin
      (while (< i depth)
        (begin
          (text_buf.append! buf "(a\n")
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i depth)
        (begin
          (text_buf.append! buf ")\n")
          (set! i (+ i 1))))
      (text_buf.render buf))))

;; `count` sibling two-line forms.
(define (lsp-fold-wide-source [count : i64]) : String
  (let
    [buf : text_buf.TextBuf (text_buf.empty)]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (text_buf.append! buf "(a\n)\n")
          (set! i (+ i 1))))
      (text_buf.render buf))))

(define (lsp-fold-first-json [ranges : json.JsonSeq]) : String
  (match (json.list-get-index ranges 0)
    [(json.JsonFound value) (json.stringify value)]
    [(json.JsonMissing) ""]))

;; Deep nesting and wide documents run through the iterative scan and the
;; iterative result walk, so neither costs host recursion proportional to the
;; document.
(define (lsp-folding-range-scale-smoke-ok?) : bool
  (let
    [depth : i64 2000]
    [nested : json.JsonSeq
      (lsp-folding-ranges-in-text (lsp-fold-nested-source depth))]
    [wide : json.JsonSeq
      (lsp-folding-ranges-in-text (lsp-fold-wide-source depth))]
    [outermost : String
      "{\"startLine\":0,\"startCharacter\":1,\"endLine\":3999,\"endCharacter\":0}"]
    [first-sibling : String
      "{\"startLine\":0,\"startCharacter\":1,\"endLine\":1,\"endCharacter\":0}"]
    (and
      (= (json.list-count nested) depth)
      (string.eq (lsp-fold-first-json nested) outermost)
      (= (json.list-count wide) depth)
      (string.eq (lsp-fold-first-json wide) first-sibling))))

(define (lsp-transcript-folding-range [uri : String] [id : i64]) : String
  (lsp-str5
    "{\"jsonrpc\":\"2.0\",\"id\":"
    (string.int->string id)
    ",\"method\":\"textDocument/foldingRange\",\"params\":{\"textDocument\":{\"uri\":\""
    uri
    "\"}}}"))

;; End-to-end dispatch: an opened document answers foldingRange, an unknown
;; document answers with an empty array rather than an error.
(define (lsp-folding-range-transcript-smoke-ok?) : bool
  (let
    [path : String "target/lsp_folding_range_doc.tl"]
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [missing-uri : String
      (lsp-resolved-path-to-file-uri "target/lsp_folding_range_absent.tl")]
    [source : String "(define (fun) : i64\\n  1)\\n"]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [input : String
      (string.append
        (lsp-transcript-frame (lsp-transcript-did-open uri source))
        (string.append
          (lsp-transcript-frame (lsp-transcript-folding-range uri 81))
          (string.append
            (lsp-transcript-frame (lsp-transcript-folding-range missing-uri 82))
            (lsp-transcript-frame exit))))]
    [result : LspTranscriptResult (lsp-transcript-run input)]
    [found : String
      "\"id\":81,\"result\":[{\"startLine\":0,\"startCharacter\":1,\"endLine\":1,\"endCharacter\":3}]"]
    [empty : String "\"id\":82,\"result\":[]"]
    (and
      (= (struct-get result status) 0)
      (lsp-transcript-result-contains? result found)
      (lsp-transcript-result-contains? result empty))))

(define (lsp-position-encoding-negotiation-smoke-ok?) : bool
  (let
    [missing : String
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}"]
    [offered : String
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-16\",\"utf-8\"]}}}}"]
    [unsupported : String
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-32\"]}}}}"]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [default-result : LspTranscriptResult
      (lsp-transcript-run
        (string.append
          (lsp-transcript-frame missing)
          (lsp-transcript-frame exit)))]
    [utf8-result : LspTranscriptResult
      (lsp-transcript-run
        (string.append
          (lsp-transcript-frame offered)
          (lsp-transcript-frame exit)))]
    [fallback-result : LspTranscriptResult
      (lsp-transcript-run
        (string.append
          (lsp-transcript-frame unsupported)
          (lsp-transcript-frame exit)))]
    [utf16 : String "\"positionEncoding\":\"utf-16\""]
    [utf8 : String "\"positionEncoding\":\"utf-8\""]
    (and
      (lsp-transcript-result-contains? default-result utf16)
      (lsp-transcript-result-contains? utf8-result utf8)
      (lsp-transcript-result-contains? fallback-result utf16))))

(define (lsp-position-encoding-conversion-smoke-ok?) : bool
  (let
    [source : String "aλ€𝄞z"]
    [cache : LspLineColCache (LspLineColCache -1 1 1)]
    [utf16-ok : bool false]
    [utf8-ok : bool false]
    (begin
      (lsp-position-encoding-use-utf16!)
      (let
        [after-two : LspLineCol (lsp-line-col-at-offset source 3)]
        [after-three : LspLineCol
          (lsp-line-col-cache-at-offset! cache source 6)]
        [after-four : LspLineCol
          (lsp-line-col-cache-at-offset! cache source 10)]
        (set!
          utf16-ok
          (and
            (= (lsp-offset-at-position source 0 2) 3)
            (= (lsp-offset-at-position source 0 3) 6)
            (= (lsp-offset-at-position source 0 4) 10)
            (= (lsp-offset-at-position source 0 5) 10)
            (= (struct-get after-two col) 3)
            (= (struct-get after-three col) 4)
            (= (struct-get after-four col) 6))))
      (lsp-position-encoding-use-utf8!)
      (set! cache (LspLineColCache -1 1 1))
      (let
        [after-two : LspLineCol (lsp-line-col-at-offset source 3)]
        [after-three : LspLineCol
          (lsp-line-col-cache-at-offset! cache source 6)]
        [after-four : LspLineCol
          (lsp-line-col-cache-at-offset! cache source 10)]
        (set!
          utf8-ok
          (and
            (= (lsp-offset-at-position source 0 3) 3)
            (= (lsp-offset-at-position source 0 6) 6)
            (= (lsp-offset-at-position source 0 10) 10)
            (= (struct-get after-two col) 4)
            (= (struct-get after-three col) 7)
            (= (struct-get after-four col) 11))))
      (lsp-position-encoding-use-utf16!)
      (and utf16-ok utf8-ok))))

(define (lsp-position-encoding-diagnostic-smoke-ok?) : bool
  (let
    [source : String "λ€𝄞x"]
    [span : CompilerDiagnosticSpan (CompilerDiagnosticSpan "" 1 10 1 11)]
    [utf16-want : String
      "\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":5}"]
    [utf8-want : String
      "\"start\":{\"line\":0,\"character\":9},\"end\":{\"line\":0,\"character\":10}"]
    [utf16-rendered : String ""]
    [utf8-rendered : String ""]
    (begin
      (lsp-position-encoding-use-utf16!)
      (set!
        utf16-rendered
        (json.stringify (lsp-range-from-compiler-span "" source span)))
      (lsp-position-encoding-use-utf8!)
      (set!
        utf8-rendered
        (json.stringify (lsp-range-from-compiler-span "" source span)))
      (lsp-position-encoding-use-utf16!)
      (and
        (string.contains (& utf16-rendered) (& utf16-want))
        (string.contains (& utf8-rendered) (& utf8-want))))))

(define (lsp-code-action-edit-seq
  [first : CompilerDiagnosticTextEdit]
  [second : CompilerDiagnosticTextEdit]
  [third : CompilerDiagnosticTextEdit]) : CompilerDiagnosticTextEditSeq
  (let
    [slots : (__tl_dyn-array CompilerDiagnosticTextEdit)
      (make-array CompilerDiagnosticTextEdit 3)]
    (begin
      (array-set! slots 0 first)
      (array-set! slots 1 second)
      (array-set! slots 2 third)
      (CompilerDiagnosticTextEditSeq slots 3))))

;; Compiler fixes preserve byte-accurate Unicode ranges, group multiple edits
;; per open document, and reject the whole fix when any target is missing or
;; lacks a client-owned document version.
(define (lsp-code-action-workspace-edit-smoke-ok?) : bool
  (let
    [path-a : String "target/code_action_a.tl"]
    [path-b : String "target/code_action_b.tl"]
    [uri-a : String (lsp-resolved-path-to-file-uri path-a)]
    [uri-b : String (lsp-resolved-path-to-file-uri path-b)]
    [docs : lsp_document_vec.Vec (lsp_document_vec.new)]
    [edits : CompilerDiagnosticTextEditSeq
      (lsp-code-action-edit-seq
        (compiler-diagnostic-text-edit-new
          (CompilerDiagnosticSpan path-a 1 3 1 6)
          "bar")
        (compiler-diagnostic-text-edit-new
          (CompilerDiagnosticSpan path-a 2 1 2 2)
          "y")
        (compiler-diagnostic-text-edit-new
          (CompilerDiagnosticSpan path-b 1 1 1 2)
          "z"))]
    [missing-edits : CompilerDiagnosticTextEditSeq
      (compiler-diagnostic-text-edit-single
        (compiler-diagnostic-text-edit-new
          (CompilerDiagnosticSpan "target/generated.tl" 1 1 1 2)
          "no"))]
    (begin
      (lsp-position-encoding-use-utf16!)
      (set!
        docs
        (lsp-documents-set-versioned
          docs
          uri-a
          path-a
          "λfoo\nx"
          7
          (lsp-diagnostic-uris-empty)))
      (set!
        docs
        (lsp-documents-set-versioned
          docs
          uri-b
          path-b
          "q"
          9
          (lsp-diagnostic-uris-empty)))
      (let
        [rendered : String
          (json.stringify (lsp-code-action-workspace-edit docs path-a edits))]
        [utf-range : String
          "\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":4}"]
        [first-version : String "\"version\":7"]
        [second-version : String "\"version\":9"]
        [two-a-edits : String
          "\"edits\":[{\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":1}},\"newText\":\"y\"},{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":4}},\"newText\":\"bar\"}]"]
        [unversioned : lsp_document_vec.Vec
          (lsp-documents-set
            (lsp_document_vec.new)
            uri-a
            path-a
            "λfoo\nx"
            (lsp-diagnostic-uris-empty))]
        (and
          (lsp-code-action-all-edits-open? docs path-a edits)
          (not (lsp-code-action-all-edits-open? docs path-a missing-edits))
          (not
            (lsp-code-action-all-edits-open?
              unversioned
              path-a
              (compiler-diagnostic-text-edit-single
                (compiler-diagnostic-text-edit-new
                  (CompilerDiagnosticSpan path-a 1 3 1 6)
                  "bar"))))
          (string.contains (& rendered) (& uri-a))
          (string.contains (& rendered) (& uri-b))
          (string.contains (& rendered) (& utf-range))
          (string.contains (& rendered) (& first-version))
          (string.contains (& rendered) (& second-version))
          (string.contains (& rendered) (& two-a-edits)))))))

;; Diagnostic tokens are version-checked and range-filtered. Repeated lint
;; findings for the same rule/form collapse to one suppression action, whose
;; insertion preserves the form's indentation.
(define (lsp-code-action-lint-smoke-ok?) : bool
  (let
    [text : String "(define (main) : i64\n  (begin 42))"]
    [span : AstSourceSpan (AstSourceSpan 2 3 2 13)]
    [finding : LintFinding
      (LintFinding
        (lint-rule-single-begin-message)
        (lint-rule-single-begin-id)
        0
        span)]
    [slots : (__tl_dyn-array LintFinding) (make-array LintFinding 2)]
    [request-range : json.Json
      (lsp-json-object2 "start" (lsp-position 2 3) "end" (lsp-position 2 4))]
    [cursor-range : json.Json
      (lsp-json-object2 "start" (lsp-position 2 3) "end" (lsp-position 2 3))]
    [adjacent-range : json.Json
      (lsp-json-object2 "start" (lsp-position 2 2) "end" (lsp-position 2 3))]
    [far-range : json.Json
      (lsp-json-object2 "start" (lsp-position 1 1) "end" (lsp-position 1 2))]
    [diagnostic : json.Json (lsp-lint-finding-diagnostic text 3 0 finding)]
    [diagnostics : json.JsonSeq
      (lsp-json-list-cons diagnostic (json.list-empty))]
    [edit-rendered : String
      (json.stringify
        (lsp-code-action-lint-edit "file:///lint.tl" 3 text finding))]
    [directive : String "\"newText\":\"  ;; lint-allow: single-begin\\n\""]
    [insertion : String
      "\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":0}"]
    (begin
      (array-set! slots 0 finding)
      (array-set! slots 1 finding)
      (let
        [findings : LintFindings (LintFindings slots 2)]
        (and
          (match (lsp-code-action-find-diagnostic-from
            diagnostics
            request-range
            3
            "lint"
            0
            0)
            [(LspJsonValue.Found _) true]
            [(LspJsonValue.Missing) false])
          (match (lsp-code-action-find-diagnostic-from
            diagnostics
            cursor-range
            3
            "lint"
            0
            0)
            [(LspJsonValue.Found _) true]
            [(LspJsonValue.Missing) false])
          (match (lsp-code-action-find-diagnostic-from
            diagnostics
            adjacent-range
            3
            "lint"
            0
            0)
            [(LspJsonValue.Found _) false]
            [(LspJsonValue.Missing) true])
          (match (lsp-code-action-find-diagnostic-from
            diagnostics
            request-range
            4
            "lint"
            0
            0)
            [(LspJsonValue.Found _) false]
            [(LspJsonValue.Missing) true])
          (match (lsp-code-action-find-diagnostic-from
            diagnostics
            far-range
            3
            "lint"
            0
            0)
            [(LspJsonValue.Found _) false]
            [(LspJsonValue.Missing) true])
          (lsp-code-action-lint-duplicate-before? findings finding 1)
          (string.eq (lsp-code-action-newline "a\r\nb") "\r\n")
          (string.contains (& edit-rendered) (& directive))
          (string.contains (& edit-rendered) (& insertion)))))))

(define (lsp-transcript-code-action
  [uri : String]
  [id : i64]
  [version : i64]
  [line : i64]
  [diagnostic-index : i64]
  [only : String]) : String
  (let
    [line-text : String (string.int->string line)]
    [range-prefix : String
      (lsp-str5
        "\"},\"range\":{\"start\":{\"line\":"
        line-text
        ",\"character\":3},\"end\":{\"line\":"
        line-text
        ",\"character\":4}},\"context\":{\"diagnostics\":[{\"range\":{\"start\":{\"line\":")]
    [range-suffix : String
      (lsp-str5
        line-text
        ",\"character\":3},\"end\":{\"line\":"
        line-text
        ",\"character\":4}},\"severity\":1,\"source\":\"typelisp\",\"code\":\"E0201\",\"message\":\"opaque\",\"data\":{\"version\":"
        (string.int->string version))]
    (lsp-str7
      "{\"jsonrpc\":\"2.0\",\"id\":"
      (string.int->string id)
      ",\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\""
      uri
      range-prefix
      range-suffix
      (lsp-str5
        ",\"kind\":\"compiler\",\"index\":"
        (string.int->string diagnostic-index)
        "}}],\"only\":[\""
        only
        "\"]}}}"))))

;; End-to-end dispatch rebuilds a machine-applicable compiler fix, while a
;; stale token and a non-quickfix `context.only` both return an empty result.
(define (lsp-code-action-transcript-smoke-ok?) : bool
  (let
    [path : String "target/lsp_code_action_doc.tl"]
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [source : String
      "(define (render-value [value : i64]) : i64\\n  value)\\n\\n(define (main) : i64\\n  (render-vaule 42))"]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [input : String
      (string.append
        (lsp-transcript-frame (lsp-transcript-did-open uri source))
        (string.append
          (lsp-transcript-frame
            (lsp-transcript-code-action uri 91 1 4 0 "quickfix"))
          (string.append
            (lsp-transcript-frame
              (lsp-transcript-code-action uri 92 0 4 0 "quickfix"))
            (string.append
              (lsp-transcript-frame
                (lsp-transcript-code-action uri 93 1 4 0 "refactor"))
              (lsp-transcript-frame exit)))))]
    [result : LspTranscriptResult (lsp-transcript-run input)]
    [action : String
      "\"id\":91,\"result\":[{\"title\":\"Replace misspelled name\",\"kind\":\"quickfix\""]
    [replacement : String "\"newText\":\"render-value\""]
    [versioned-edit : String "\"version\":1"]
    [stale : String "\"id\":92,\"result\":[]"]
    [filtered : String "\"id\":93,\"result\":[]"]
    [capability : String "\"codeActionKinds\":[\"quickfix\"]"]
    [capabilities : String (json.stringify (lsp-initialize-result))]
    (and
      (= (struct-get result status) 0)
      (string.eq (struct-get result stderr) "")
      (lsp-transcript-result-contains? result action)
      (lsp-transcript-result-contains? result replacement)
      (lsp-transcript-result-contains? result versioned-edit)
      (lsp-transcript-result-contains? result stale)
      (lsp-transcript-result-contains? result filtered)
      (string.contains (& capabilities) (& capability)))))

(define (lsp-second-diagnostic-code-action-smoke-ok?) : bool
  (let
    [path : String "target/lsp_second_code_action_doc.tl"]
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [source : String
      "(define (render-value [value : i64]) : i64\\n  value)\\n\\n(define (first) : i64\\n  (render-vaule 1))\\n\\n(define (second) : i64\\n  (render-vlaue 2))\\n\\n(define (main) : i64 0)"]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [input : String
      (string.append
        (lsp-transcript-frame (lsp-transcript-did-open uri source))
        (string.append
          (lsp-transcript-frame
            (lsp-transcript-code-action uri 94 1 7 1 "quickfix"))
          (lsp-transcript-frame exit)))]
    [result : LspTranscriptResult (lsp-transcript-run input)]
    [out : String (struct-get result stdout)]
    [action : String
      "\"id\":94,\"result\":[{\"title\":\"Replace misspelled name\",\"kind\":\"quickfix\""]
    [replacement : String "\"newText\":\"render-value\""]
    [second-index : String "\"index\":1"]
    (and
      (= (struct-get result status) 0)
      (string.eq (struct-get result stderr) "")
      (string.contains (& out) (& action))
      (string.contains (& out) (& replacement))
      (string.contains (& out) (& second-index)))))

(define (lsp-workspace-index-smoke-ok?) : bool
  (let
    [base : String "target/lsp_workspace_index"]
    [root-a : String "target/lsp_workspace_index/a"]
    [root-a-src : String "target/lsp_workspace_index/a/src"]
    [root-a-target : String "target/lsp_workspace_index/a/target"]
    [root-a-tests : String "target/lsp_workspace_index/a/tests"]
    [root-a-nested : String "target/lsp_workspace_index/a/nested"]
    [root-a-cycle : String "target/lsp_workspace_index/a/cycle"]
    [root-b : String "target/lsp_workspace_index/b"]
    [disk-path : String "target/lsp_workspace_index/a/src/disk.tl"]
    [explicit-path : String "target/lsp_workspace_index/a/src/explicit.tl"]
    [target-path : String "target/lsp_workspace_index/a/target/ignored.tl"]
    [tests-path : String "target/lsp_workspace_index/a/tests/ignored_test.tl"]
    [nested-manifest : String
      "target/lsp_workspace_index/a/nested/typelisp.pkg"]
    [nested-path : String
      "target/lsp_workspace_index/a/nested/ignored_nested.tl"]
    [b-path : String "target/lsp_workspace_index/b/b.tl"]
    [create-path : String "target/lsp_workspace_index/b/create.tl"]
    [refresh-path : String "target/lsp_workspace_index/b/refresh.tl"]
    [single-path : String "target/lsp_workspace_index/single.tl"]
    [root-a-uri : String (lsp-resolved-path-to-file-uri root-a)]
    [root-a-src-uri : String (lsp-resolved-path-to-file-uri root-a-src)]
    [root-b-uri : String (lsp-resolved-path-to-file-uri root-b)]
    [workspace-capabilities : String (json.stringify (lsp-initialize-result))]
    [workspace-capability : String
      "\"workspaceFolders\":{\"supported\":true,\"changeNotifications\":true}"]
    [roots : lsp_svec.Vec (lsp_svec.new)]
    [ok : bool true]
    [_setup : unit
      (begin
        (lsp-smoke-mkdir base)
        (lsp-smoke-mkdir root-a)
        (lsp-smoke-mkdir root-a-src)
        (lsp-smoke-mkdir root-a-target)
        (lsp-smoke-mkdir root-a-tests)
        (lsp-smoke-mkdir root-a-nested)
        (lsp-smoke-mkdir root-b)
        (lsp-smoke-remove-file root-a-cycle)
        (lsp-smoke-remove-file create-path)
        (lsp-smoke-remove-file refresh-path)
        (lsp-smoke-write-text disk-path "(define disk-value : i64 1)")
        (lsp-smoke-write-text
          explicit-path
          "(module explicit.mod) (define explicit-value : i64 2)")
        (lsp-smoke-write-text
          target-path
          "(define ignored-target-value : i64 3)")
        (lsp-smoke-write-text tests-path "(define ignored-test-value : i64 4)")
        (lsp-smoke-write-text nested-manifest "")
        (lsp-smoke-write-text
          nested-path
          "(define ignored-nested-value : i64 5)")
        (lsp-smoke-write-text b-path "(define b-value : i64 6)")
        (if (lsp-smoke-make-directory-cycle-link root-a-cycle)
          unit
          (begin
            (io.print-error "workspace index smoke: cannot create cycle link\n")
            (set! ok false)))
        (lsp_svec.push (&mut roots) root-a-uri)
        (lsp_svec.push (&mut roots) root-a-uri)
        (lsp_svec.push (&mut roots) root-a-src-uri)
        (lsp_svec.push (&mut roots) root-b-uri)
        (lsp_svec.push (&mut roots) "https://example.invalid/workspace"))]
    [single-state : LspServerState
      (lsp-smoke-state-with-overlay
        (lsp-server-state-new)
        single-path
        "(define single-value : i64 7)"
        1)]
    [_single-check : unit
      (begin
        (let
          [open-index : i64 1]
          (while (< open-index 17)
            (let
              [suffix : String (string.int->string open-index)]
              [path : String
                (lsp-str4 "target/lsp_workspace_index/single-" suffix "" ".tl")]
              [text : String
                (lsp-str4 "(define single-value-" suffix " : i64 " "7)")]
              (begin
                (set!
                  single-state
                  (lsp-smoke-state-with-overlay
                    single-state
                    path
                    text
                    open-index))
                (set! open-index (+ open-index 1))))))
        (if (and
          (= (lsp-smoke-state-root-count (& single-state)) 0)
          (= (lsp_document_vec.len (& (struct-get single-state documents))) 17)
          (= (lsp-smoke-state-source-count (& single-state)) 17)
          (= (lsp-server-state-declaration-count (& single-state)) 17)
          (= (lsp-smoke-state-name-count (& single-state) "single-value-16") 1)
          (lsp-smoke-state-row-matches?
            (& single-state)
            "single-value"
            "single"
            ""
            false
            true))
          unit
          (begin
            (io.print-error "workspace index smoke: single-file mode\n")
            (set! ok false)))
        (lsp-server-state-destroy! single-state))]
    [state : LspServerState (lsp-smoke-initialize-state roots "")]
    (begin
      (if (and
        (= (lsp-smoke-state-root-count (& state)) 3)
        (= (lsp-smoke-state-source-count (& state)) 3)
        (= (lsp-server-state-declaration-count (& state)) 3)
        (string.eq (lsp-smoke-state-name-at (& state) 0) "disk-value")
        (string.eq (lsp-smoke-state-name-at (& state) 1) "explicit-value")
        (string.eq (lsp-smoke-state-name-at (& state) 2) "b-value")
        (string.contains (& workspace-capabilities) (& workspace-capability))
        (string.eq (lsp-smoke-state-root-uri-at (& state) 0) root-a-uri)
        (string.eq (lsp-smoke-state-root-uri-at (& state) 1) root-a-src-uri)
        (string.eq (lsp-smoke-state-root-uri-at (& state) 2) root-b-uri)
        (lsp-smoke-state-row-matches?
          (& state)
          "disk-value"
          "src.disk"
          root-a-uri
          false
          false)
        (lsp-smoke-state-row-matches?
          (& state)
          "explicit-value"
          "explicit.mod"
          root-a-uri
          true
          false)
        (= (lsp-smoke-state-name-count (& state) "b-value") 1)
        (= (lsp-smoke-state-name-count (& state) "ignored-target-value") 0)
        (= (lsp-smoke-state-name-count (& state) "ignored-test-value") 0)
        (= (lsp-smoke-state-name-count (& state) "ignored-nested-value") 0))
        unit
        (begin
          (io.print-error "workspace index smoke: initial discovery\n")
          (set! ok false)))
      (set!
        state
        (lsp-smoke-state-with-overlay
          state
          disk-path
          "(define overlay-value : i64 8)"
          2))
      (if (and
        (= (lsp-smoke-state-name-count (& state) "disk-value") 0)
        (lsp-smoke-state-row-matches?
          (& state)
          "overlay-value"
          "src.disk"
          root-a-uri
          false
          true)
        (string.eq (lsp-smoke-state-name-at (& state) 0) "overlay-value"))
        unit
        (begin
          (io.print-error "workspace index smoke: open overlay\n")
          (set! ok false)))
      (lsp-smoke-write-text disk-path "(define watcher-value : i64 9)")
      (set! state (lsp-smoke-state-watch state disk-path 2))
      (if (and
        (= (lsp-smoke-state-name-count (& state) "watcher-value") 0)
        (= (lsp-smoke-state-name-count (& state) "overlay-value") 1)
        (string.eq (lsp-smoke-state-name-at (& state) 0) "overlay-value"))
        unit
        (begin
          (io.print-error "workspace index smoke: watcher below overlay\n")
          (set! ok false)))
      (lsp-smoke-remove-file disk-path)
      (set! state (lsp-smoke-state-watch state disk-path 3))
      (if (= (lsp-smoke-state-name-count (& state) "overlay-value") 1)
        unit
        (begin
          (io.print-error "workspace index smoke: delete below overlay\n")
          (set! ok false)))
      (set! state (lsp-smoke-state-close state disk-path))
      (if (and
        (= (lsp-smoke-state-name-count (& state) "overlay-value") 0)
        (= (lsp-smoke-state-source-count (& state)) 2))
        unit
        (begin
          (io.print-error "workspace index smoke: close missing overlay\n")
          (set! ok false)))
      (lsp-smoke-write-text create-path "(define created-value : i64 10)")
      (set! state (lsp-smoke-state-watch state create-path 1))
      (if (= (lsp-smoke-state-name-count (& state) "created-value") 1)
        unit
        (begin
          (io.print-error "workspace index smoke: create event\n")
          (set! ok false)))
      (lsp-smoke-write-text create-path "(define changed-value : i64 11)")
      (set! state (lsp-smoke-state-watch state create-path 2))
      (if (and
        (= (lsp-smoke-state-name-count (& state) "created-value") 0)
        (= (lsp-smoke-state-name-count (& state) "changed-value") 1)
        (string.eq (lsp-smoke-state-name-at (& state) 2) "changed-value"))
        unit
        (begin
          (io.print-error "workspace index smoke: change event\n")
          (set! ok false)))
      (set!
        state
        (lsp-smoke-state-with-overlay
          state
          create-path
          "(define create-overlay-value : i64 12)"
          3))
      (set! state (lsp-smoke-state-close state create-path))
      (if (and
        (= (lsp-smoke-state-name-count (& state) "create-overlay-value") 0)
        (= (lsp-smoke-state-name-count (& state) "changed-value") 1))
        unit
        (begin
          (io.print-error "workspace index smoke: close restores disk\n")
          (set! ok false)))
      (lsp-smoke-remove-file create-path)
      (set! state (lsp-smoke-state-watch state create-path 3))
      (if (= (lsp-smoke-state-name-count (& state) "changed-value") 0)
        unit
        (begin
          (io.print-error "workspace index smoke: delete event\n")
          (set! ok false)))
      (lsp-smoke-write-text refresh-path "(define refresh-value-0 : i64 13)")
      (set! state (lsp-smoke-state-watch state refresh-path 1))
      (let
        [iteration : i64 1]
        (while (< iteration 21)
          (let
            [owner : i64 (struct-get state owner-arena)]
            [name : String
              (lsp-str3 "refresh-value-" (string.int->string iteration) "")]
            [source : String (lsp-str3 "(define " name " : i64 13)")]
            (begin
              (lsp-smoke-write-text refresh-path source)
              (set! state (lsp-smoke-state-watch state refresh-path 2))
              (if (and
                (not (= owner (struct-get state owner-arena)))
                (= (lsp-smoke-state-source-count (& state)) 3)
                (= (lsp-server-state-declaration-count (& state)) 3)
                (= (lsp-smoke-state-name-count (& state) name) 1)
                (string.eq (lsp-smoke-state-name-at (& state) 2) name))
                unit
                (begin
                  (io.print-error "workspace index smoke: repeated refresh\n")
                  (set! ok false)))
              (set! iteration (+ iteration 1))))))
      (let
        [added : lsp_svec.Vec (lsp_svec.new)]
        [removed : lsp_svec.Vec (lsp_svec.new)]
        (begin
          (lsp_svec.push (&mut removed) root-a-uri)
          (set! state (lsp-smoke-state-workspace-event state added removed))))
      (if (and
        (= (lsp-smoke-state-root-count (& state)) 2)
        (= (lsp-smoke-state-source-count (& state)) 3)
        (lsp-smoke-state-row-matches?
          (& state)
          "explicit-value"
          "explicit.mod"
          root-a-src-uri
          true
          false))
        unit
        (begin
          (io.print-error "workspace index smoke: overlapping root removal\n")
          (set! ok false)))
      (let
        [added : lsp_svec.Vec (lsp_svec.new)]
        [removed : lsp_svec.Vec (lsp_svec.new)]
        (begin
          (lsp_svec.push (&mut removed) root-b-uri)
          (set! state (lsp-smoke-state-workspace-event state added removed))))
      (if (and
        (= (lsp-smoke-state-root-count (& state)) 1)
        (= (lsp-smoke-state-source-count (& state)) 1)
        (= (lsp-smoke-state-name-count (& state) "b-value") 0)
        (= (lsp-smoke-state-name-count (& state) "refresh-value-20") 0))
        unit
        (begin
          (io.print-error "workspace index smoke: root removal\n")
          (set! ok false)))
      (let
        [added : lsp_svec.Vec (lsp_svec.new)]
        [removed : lsp_svec.Vec (lsp_svec.new)]
        (begin
          (lsp_svec.push (&mut added) root-b-uri)
          (set! state (lsp-smoke-state-workspace-event state added removed))))
      (if (and
        (= (lsp-smoke-state-root-count (& state)) 2)
        (= (lsp-smoke-state-source-count (& state)) 3)
        (= (lsp-smoke-state-name-count (& state) "b-value") 1)
        (= (lsp-smoke-state-name-count (& state) "refresh-value-20") 1))
        unit
        (begin
          (io.print-error "workspace index smoke: root addition\n")
          (set! ok false)))
      (let
        [fallback-roots : lsp_svec.Vec (lsp_svec.new)]
        [fallback-state : LspServerState
          (lsp-smoke-initialize-state fallback-roots root-b-uri)]
        (begin
          (if (and
            (= (lsp-smoke-state-root-count (& fallback-state)) 1)
            (= (lsp-smoke-state-source-count (& fallback-state)) 2)
            (string.eq
              (lsp-smoke-state-root-uri-at (& fallback-state) 0)
              root-b-uri))
            unit
            (begin
              (io.print-error "workspace index smoke: rootUri fallback\n")
              (set! ok false)))
          (lsp-server-state-destroy! fallback-state)))
      (lsp-server-state-destroy! state)
      (lsp-smoke-remove-file root-a-cycle)
      ok)))

(define (main) : i64
  (let
    [base-result : i64 (lsp-diagnostic-metadata-smoke)]
    (if (not (= base-result 42))
      base-result
      (begin
        (unless (lsp-completion-smoke-ok?) (return 6))
        (unless (lsp-inlay-smoke-ok?) (return 7))
        (unless (lsp-formatting-smoke-ok?) (return 8))
        (unless (lsp-format-edit-text-smoke-ok?) (return 14))
        (unless (lsp-check-smoke-ok?) (return 9))
        (unless (lsp-get-type-smoke-ok?) (return 10))
        (unless (lsp-find-references-smoke-ok?) (return 11))
        (unless (lsp-document-decls-cache-empty-ok?) (return 12))
        (unless (lsp-document-disk-resync-ok?) (return 15))
        (unless (lsp-edit-save-doc-smoke-ok?) (return 16))
        (unless (lsp-scan-decls-cache-local-smoke-ok?) (return 13))
        (unless (lsp-document-symbol-smoke-ok?) (return 17))
        (unless (lsp-document-highlight-smoke-ok?) (return 22))
        (unless (lsp-folding-range-forms-smoke-ok?) (return 23))
        (unless (lsp-folding-range-comments-smoke-ok?) (return 24))
        (unless (lsp-folding-range-literals-smoke-ok?) (return 25))
        (unless (lsp-folding-range-malformed-smoke-ok?) (return 26))
        (unless (lsp-folding-range-utf16-smoke-ok?) (return 27))
        (unless (lsp-folding-range-scale-smoke-ok?) (return 28))
        (unless (lsp-folding-range-transcript-smoke-ok?) (return 29))
        (unless (lsp-position-encoding-negotiation-smoke-ok?) (return 30))
        (unless (lsp-position-encoding-conversion-smoke-ok?) (return 31))
        (unless (lsp-position-encoding-diagnostic-smoke-ok?) (return 32))
        (unless (lsp-code-action-workspace-edit-smoke-ok?) (return 33))
        (unless (lsp-code-action-lint-smoke-ok?) (return 34))
        (unless (lsp-code-action-transcript-smoke-ok?) (return 35))
        (unless (lsp-second-diagnostic-code-action-smoke-ok?) (return 38))
        (unless (lsp-workspace-index-smoke-ok?) (return 39))
        (unless (lsp-transcript-framing-smoke-ok?) (return 18))
        (unless (lsp-transcript-order-and-id-smoke-ok?) (return 19))
        (unless (lsp-transcript-reset-leakage-smoke-ok?) (return 20))
        (unless (lsp-multiple-diagnostics-smoke-ok?) (return 36))
        (unless (lsp-multiple-external-diagnostics-smoke-ok?) (return 37))
        (unless (lsp-transcript-arena-escape-smoke-ok?) (return 21))
        42))))