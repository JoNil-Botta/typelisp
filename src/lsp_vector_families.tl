;; lsp_vector_families.tl - vector-backed LSP state collections.
(import stdlib.array)
(import stdlib.vector)
(import compiler_semantic_index)

(defstruct LspDeclEntry
  (kind String)
  (name String)
  (name-line i64)
  (name-col i64)
  (name-len i64)
  (form-start-line i64)
  (form-start-col i64)
  (form-end-line i64)
  (form-end-col i64)
  (symbol-kind i64))

(import (vector.vector LspDeclEntry core) as lsp_decl_vec)

(defenum LspCheckCache
  (LspCheckCacheInvalid)
  (LspCheckCacheOk)
  (LspCheckCacheErr String))

;; Ordered URI set used by diagnostic publication. `len` is a persistent
;; snapshot boundary: later appends may share spare slots, while growth copies
;; into a larger buffer and leaves older snapshots intact.
(defstruct LspDiagnosticUris
  (slots (__tl_dyn-array String))
  (len i64))

(defstruct LspSemanticSnapshot
  (index compiler_semantic_index.CompilerSemanticSourceIndex)
  (version i64)
  (source-path String)
  (source-text String)
  (present bool))

(defstruct LspDocument
  (uri String)
  (path String)
  (text String)
  ;; LSP's client-owned document version. A negative value means that the
  ;; source did not arrive from a versioned open/change notification and must
  ;; not be the target of a versioned WorkspaceEdit.
  (version i64)
  (diagnostic-uris LspDiagnosticUris)
  (decls lsp_decl_vec.Vec)
  (decls-valid bool)
  (check-cache LspCheckCache)
  (semantic LspSemanticSnapshot))

(import (vector.vector LspDocument core) as lsp_document_vec)

;; Normalized client workspace identity. `uri` is the canonical file URI
;; derived from the normalized absolute `path`; client order is preserved.
(defstruct LspWorkspaceRoot
  (uri String)
  (path String))

;; One current source snapshot. Disk text is intentionally not retained:
;; providers query immutable declaration summaries, while open buffers keep
;; their authoritative text in `LspDocument`.
(defstruct LspWorkspaceSource
  (root-uri String)
  (root-path String)
  (uri String)
  (path String)
  (module String)
  (explicit-module bool)
  (overlay bool)
  (decls lsp_decl_vec.Vec))

;; Hand-grown dense collections avoid two generated vector-family
;; instantiations in the self-host compiler. The state snapshot owns their
;; backing arrays and replaces the whole arena on mutations.
(defstruct LspWorkspaceRoots
  (slots (__tl_dyn-array LspWorkspaceRoot))
  (len i64))

(defstruct LspWorkspaceSources
  (slots (__tl_dyn-array LspWorkspaceSource))
  (len i64))

(defstruct LspWorkspaceIndex
  (roots LspWorkspaceRoots)
  (sources LspWorkspaceSources))

;; Immutable flattened declaration returned by the workspace query boundary.
;; Callers receive a value row, never either mutable index collection.
(defstruct LspWorkspaceDeclRow
  (root-uri String)
  (root-path String)
  (uri String)
  (path String)
  (module String)
  (explicit-module bool)
  (overlay bool)
  (decl LspDeclEntry))

(defenum LspWorkspaceDeclLookup
  (Found LspWorkspaceDeclRow)
  (Missing))

(defenum LspWorkspaceRootLookup
  (Found LspWorkspaceRoot)
  (Missing))

;; Every long-lived LSP collection is owned by `owner-arena`. Mutating
;; protocol events create a fresh snapshot, swap this aggregate, and destroy
;; the previous arena so retained memory depends on live state, not history.
(defstruct LspServerState
  (owner-arena i64)
  (documents lsp_document_vec.Vec)
  (workspace LspWorkspaceIndex))

;; One candidate `textDocument/foldingRange` result. Positions stay 1-based
;; internally like every other LSP scanner here; `kind` is 0 for an unlabelled
;; region and 1 for a comment block. `parent` links an open form to the form
;; that encloses it while the scan is inside it, so the scanner needs no
;; separate delimiter stack. `emit` stays false until the range is known to be
;; multiline, which also drops never-closed forms in malformed buffers.
(defstruct LspFoldRange
  (start-line i64)
  (start-char i64)
  (end-line i64)
  (end-char i64)
  (kind i64)
  (parent i64)
  (emit bool))

;; Deliberately a hand-grown `(__tl_dyn-array LspFoldRange)` rather than a
;; generated `(vector.vector LspFoldRange core)`: one family instantiation
;; measures +87,721,964 Ir (+0.158%) of self_compile on its own, which is 31% of
;; the CI-gated budget for a single collection type (#5646). This is the same
;; growth shape `TlciNativeMacroCaptures` uses in the tlci producer. Revert to
;; the generated vector once #5646 makes instantiation cheap.
(defstruct LspFoldRanges
  (slots (__tl_dyn-array LspFoldRange))
  (len i64))

;; One open delimiter in the signature-help lexical scan. `kind` is 0 for a
;; parenthesized form and 1 for a bracket group. Parenthesized frames progress
;; from an unknown head (`head-state` 0), to an ordinary token head (1), or a
;; non-call head (2). The datum fields track exactly one direct argument while
;; prefixes and nested groups are still incomplete.
(defstruct LspCallFrame
  (kind i64)
  (form-start i64)
  (head-start i64)
  (head-end i64)
  (head-state i64)
  (argument-index i64)
  (datum-active bool)
  (datum-complete bool))

;; Kept hand-grown for the same code-size reason as `LspFoldRanges`. Popped
;; slots are reused, so storage is proportional to maximum source nesting.
(defstruct LspCallFrames
  (slots (__tl_dyn-array LspCallFrame))
  (len i64))

(define (lsp-call-frames-new) : LspCallFrames
  (LspCallFrames (array.make-array LspCallFrame 0) 0))

(define (lsp-call-frames-len [frames : (& frames LspCallFrames)]) : i64
  frames.len)

(define (lsp-call-frames-get
  [frames : (& frames LspCallFrames)]
  [index : i64]
  [fallback : LspCallFrame]) : LspCallFrame
  (if (and (>= index 0) (< index frames.len))
    (array-ref frames.slots index)
    fallback))

(define (lsp-call-frames-set!
  [frames : (&mut frames LspCallFrames)]
  [index : i64]
  [value : LspCallFrame]) : unit
  (if (and (>= index 0) (< index frames.len))
    (set! (array-ref frames.slots index) value)
    unit))

(define (lsp-call-frames-copy-range!
  [dst : (&mut dst (__tl_dyn-array LspCallFrame))]
  [src : (& src (__tl_dyn-array LspCallFrame))]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (set! (array-ref dst i) (array-ref src i))
        (set! i (+ i 1))))))

(define (lsp-call-frames-grow! [frames : (&mut frames LspCallFrames)]) : unit
  (let
    [old-cap : i64 (array-length frames.slots)]
    [new-cap : i64
      (if (< old-cap 4)
        4
        (* old-cap 2))]
    [bigger : (__tl_dyn-array LspCallFrame)
      (array.make-array LspCallFrame new-cap)]
    (begin
      (lsp-call-frames-copy-range! (&mut bigger) (& frames.slots) frames.len)
      (set! frames.slots bigger))))

(define (lsp-call-frames-push!
  [frames : (&mut frames LspCallFrames)]
  [value : LspCallFrame]) : unit
  (begin
    (if (>= frames.len (array-length frames.slots))
      (lsp-call-frames-grow! frames)
      unit)
    (set! (array-ref frames.slots frames.len) value)
    (set! frames.len (+ frames.len 1))))

(define (lsp-call-frames-pop! [frames : (&mut frames LspCallFrames)]) : unit
  (if (> frames.len 0)
    (set! frames.len (- frames.len 1))
    unit))

(define (lsp-call-frames-clear! [frames : (&mut frames LspCallFrames)]) : unit
  (set! frames.len 0))

(define (lsp-fold-ranges-new) : LspFoldRanges
  (LspFoldRanges (array.make-array LspFoldRange 0) 0))

(define (lsp-fold-ranges-len [folds : (& folds LspFoldRanges)]) : i64
  folds.len)

(define (lsp-fold-ranges-get
  [folds : (& folds LspFoldRanges)]
  [index : i64]
  [fallback : LspFoldRange]) : LspFoldRange
  (if (and (>= index 0) (< index folds.len))
    (array-ref folds.slots index)
    fallback))

(define (lsp-fold-ranges-set!
  [folds : (&mut folds LspFoldRanges)]
  [index : i64]
  [value : LspFoldRange]) : unit
  (if (and (>= index 0) (< index folds.len))
    (set! (array-ref folds.slots index) value)
    unit))

(define (lsp-fold-ranges-copy-range!
  [dst : (&mut dst (__tl_dyn-array LspFoldRange))]
  [src : (& src (__tl_dyn-array LspFoldRange))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (lsp-fold-ranges-copy-range! dst src (+ index 1) count))))

(define (lsp-fold-ranges-grow! [folds : (&mut folds LspFoldRanges)]) : unit
  (let
    [old-cap : i64 (array-length folds.slots)]
    [new-cap : i64
      (if (< old-cap 4)
        4
        (* old-cap 2))]
    [bigger : (__tl_dyn-array LspFoldRange)
      (array.make-array LspFoldRange new-cap)]
    (begin
      (lsp-fold-ranges-copy-range! (&mut bigger) (& folds.slots) 0 folds.len)
      (set! folds.slots bigger))))

(define (lsp-fold-ranges-push!
  [folds : (&mut folds LspFoldRanges)]
  [value : LspFoldRange]) : unit
  (begin
    (if (>= folds.len (array-length folds.slots))
      (lsp-fold-ranges-grow! folds)
      unit)
    (set! (array-ref folds.slots folds.len) value)
    (set! folds.len (+ folds.len 1))))

(define (lsp-documents-drop-last! [docs : (&mut docs lsp_document_vec.Vec)]) : unit
  (if (> docs.len 0)
    (set! docs.len (- docs.len 1))
    unit))