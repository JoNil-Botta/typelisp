;; lsp_vector_families.tl - generated vector-backed LSP state collections.
(import stdlib.vector)

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

(defstruct LspDocument
  (uri String)
  (path String)
  (text String)
  (diagnostic-uri String)
  (decls lsp_decl_vec.Vec)
  (decls-valid bool)
  (check-cache LspCheckCache))

(import (vector.vector LspDocument core) as lsp_document_vec)

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

(import (vector.vector LspFoldRange core) as lsp_fold_vec)

(define (lsp-documents-drop-last! [docs : (&mut docs lsp_document_vec.Vec)]) : unit
  (if (> (struct-get docs len) 0)
    (set! (struct-get docs len) (- (struct-get docs len) 1))
    unit))