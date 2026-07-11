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
  (form-end-col i64))

(vector.family LspDeclEntry LspDeclList lsp-decl-list)

(defenum LspCheckCache
  (LspCheckCacheInvalid)
  (LspCheckCacheOk)
  (LspCheckCacheErr String))

(defstruct LspDocument
  (uri String)
  (path String)
  (text String)
  (diagnostic-uri String)
  (decls LspDeclList)
  (decls-valid bool)
  (check-cache LspCheckCache))

(vector.family LspDocument LspDocuments lsp-documents)

(define (lsp-documents-drop-last! [docs : (&mut docs LspDocuments)]) : unit
  (if (> (struct-get docs len) 0)
    (set! (struct-get docs len) (- (struct-get docs len) 1))
    unit))