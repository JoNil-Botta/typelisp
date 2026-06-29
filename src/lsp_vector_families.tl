;; lsp_vector_families.tl - named generated vector families for LSP state.
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

(defstruct LspDocument
  (uri String)
  (path String)
  (text String)
  (diagnostic-uri String)
  (decls LspDeclList)
  (decls-valid bool))

(vector.family LspDocument LspDocuments lsp-documents)