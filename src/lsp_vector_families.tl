;; lsp_vector_families.tl - generated vector-backed LSP state collections.
(import stdlib.vector)
(import stdlib.array as array_ops)

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

(import (vector LspDeclEntry) as lsp_decl_vec)

;; Keep the domain structs directly cloneable; generated vectors own
;; construction and growth rebuilds without exposing a compatibility alias.
(defstruct LspDeclList
  (slots (Array LspDeclEntry))
  (len i64))

(define (lsp-decl-list-new) : LspDeclList
  (let
    [items : lsp_decl_vec.Vec (lsp_decl_vec.new)]
    (LspDeclList (struct-get items slots) (struct-get items len))))

(define (lsp-decl-list-with-capacity [capacity : i64]) : LspDeclList
  (let
    [items : lsp_decl_vec.Vec (lsp_decl_vec.with-capacity capacity)]
    (LspDeclList (struct-get items slots) (struct-get items len))))

(define (lsp-decl-list-len [decls : (& decls LspDeclList)]) : i64
  (struct-get decls len))

(define (lsp-decl-list-get
  [decls : (& decls LspDeclList)]
  [index : i64]
  [fallback : LspDeclEntry]) : LspDeclEntry
  (if (if (>= index 0)
    (< index (struct-get decls len))
    false)
    (array_ops.ref (struct-get decls slots) index)
    fallback))

(define (lsp-decl-list-push
  [decls : (&mut decls LspDeclList)]
  [value : LspDeclEntry]) : unit
  (let
    [len : i64 (struct-get decls len)]
    [capacity : i64 (array_ops.length (struct-get decls slots))]
    (begin
      (if (< len capacity)
        unit
        (let
          [items : lsp_decl_vec.Vec
            (lsp_decl_vec.with-capacity
              (if (< capacity 1)
                1
                (* capacity 2)))]
          (begin
            (lsp_decl_vec.extend
              (&mut items)
              (& (struct-get decls slots))
              (struct-get decls len))
            (set! (struct-get decls slots) (struct-get items slots))
            (set! (struct-get decls len) (struct-get items len)))))
      (let
        [index : i64 (struct-get decls len)]
        (begin
          (array-set! (struct-get decls slots) index value)
          (set! (struct-get decls len) (+ index 1)))))))

(defstruct LspDocument
  (uri String)
  (path String)
  (text String)
  (diagnostic-uri String)
  (decls LspDeclList)
  (decls-valid bool))

(import (vector LspDocument) as lsp_document_vec)

(defstruct LspDocuments
  (slots (Array LspDocument))
  (len i64))

(define (lsp-documents-new) : LspDocuments
  (let
    [items : lsp_document_vec.Vec (lsp_document_vec.new)]
    (LspDocuments (struct-get items slots) (struct-get items len))))

(define (lsp-documents-len [docs : (& docs LspDocuments)]) : i64
  (struct-get docs len))

(define (lsp-documents-get
  [docs : (& docs LspDocuments)]
  [index : i64]
  [fallback : LspDocument]) : LspDocument
  (if (if (>= index 0)
    (< index (struct-get docs len))
    false)
    (array_ops.ref (struct-get docs slots) index)
    fallback))

(define (lsp-documents-set!
  [docs : (&mut docs LspDocuments)]
  [index : i64]
  [value : LspDocument]) : unit
  (if (if (>= index 0)
    (< index (struct-get docs len))
    false)
    (array-set! (struct-get docs slots) index value)
    unit))

(define (lsp-documents-push
  [docs : (&mut docs LspDocuments)]
  [value : LspDocument]) : unit
  (let
    [len : i64 (struct-get docs len)]
    [capacity : i64 (array_ops.length (struct-get docs slots))]
    (begin
      (if (< len capacity)
        unit
        (let
          [items : lsp_document_vec.Vec
            (lsp_document_vec.with-capacity
              (if (< capacity 1)
                1
                (* capacity 2)))]
          (begin
            (lsp_document_vec.extend
              (&mut items)
              (& (struct-get docs slots))
              (struct-get docs len))
            (set! (struct-get docs slots) (struct-get items slots))
            (set! (struct-get docs len) (struct-get items len)))))
      (let
        [index : i64 (struct-get docs len)]
        (begin
          (array-set! (struct-get docs slots) index value)
          (set! (struct-get docs len) (+ index 1)))))))

(define (lsp-documents-drop-last! [docs : (&mut docs LspDocuments)]) : unit
  (if (> (struct-get docs len) 0)
    (set! (struct-get docs len) (- (struct-get docs len) 1))
    unit))