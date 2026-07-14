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

(define (lsp-documents-drop-last! [docs : (&mut docs lsp_document_vec.Vec)]) : unit
  (if (> (struct-get docs len) 0)
    (set! (struct-get docs len) (- (struct-get docs len) 1))
    unit))