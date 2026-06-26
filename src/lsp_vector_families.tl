;; lsp_vector_families.tl - checked-in generated vector families for LSP state.
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

(defstruct LspDeclList
  (slots (Array LspDeclEntry))
  (len i64))

(define (lsp-decl-list-slots [v : (& v LspDeclList)]) : (&
    v
    (Array LspDeclEntry))
  (& (struct-get v slots)))

(define (lsp-decl-list-len [v : (& v LspDeclList)]) : i64
  (struct-get v len))

(define (lsp-decl-list-capacity [v : (& v LspDeclList)]) : i64
  (array-length (lsp-decl-list-slots v)))

(define (lsp-decl-list-with-capacity [capacity : i64]) : LspDeclList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (LspDeclList (make-array LspDeclEntry cap) 0)))

(define (lsp-decl-list-new) : LspDeclList
  (lsp-decl-list-with-capacity 4))

(define (lsp-decl-list-get
  [v : (& v LspDeclList)]
  [index : i64]
  [fallback : LspDeclEntry]) : LspDeclEntry
  (if (if (>= index 0)
    (< index (lsp-decl-list-len v))
    false)
    (array-ref (lsp-decl-list-slots v) index)
    fallback))

(define (lsp-decl-list-set!
  [v : (&mut v LspDeclList)]
  [index : i64]
  [value : LspDeclEntry]) : unit
  (if (if (>= index 0)
    (< index (struct-get v len))
    false)
    (array-set! (struct-get v slots) index value)
    unit))

(define (lsp-decl-list-copy-range
  [dst : (&mut dst (Array LspDeclEntry))]
  [src : (& src (Array LspDeclEntry))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (lsp-decl-list-copy-range dst src (+ index 1) count))))

(define (lsp-decl-list-grow [v : (&mut v LspDeclList)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array LspDeclEntry) (make-array LspDeclEntry new-cap)]
    (begin
      (lsp-decl-list-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (set! (struct-get v slots) bigger))))

(define (lsp-decl-list-push [v : (&mut v LspDeclList)] [value : LspDeclEntry]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (lsp-decl-list-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(defstruct LspDocument
  (uri String)
  (path String)
  (text String)
  (diagnostic-uri String)
  (decls LspDeclList)
  (decls-valid bool))

(defstruct LspDocuments
  (slots (Array LspDocument))
  (len i64))

(define (lsp-documents-slots [v : (& v LspDocuments)]) : (&
    v
    (Array LspDocument))
  (& (struct-get v slots)))

(define (lsp-documents-len [v : (& v LspDocuments)]) : i64
  (struct-get v len))

(define (lsp-documents-capacity [v : (& v LspDocuments)]) : i64
  (array-length (lsp-documents-slots v)))

(define (lsp-documents-with-capacity [capacity : i64]) : LspDocuments
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (LspDocuments (make-array LspDocument cap) 0)))

(define (lsp-documents-new) : LspDocuments
  (lsp-documents-with-capacity 4))

(define (lsp-documents-get
  [v : (& v LspDocuments)]
  [index : i64]
  [fallback : LspDocument]) : LspDocument
  (if (if (>= index 0)
    (< index (lsp-documents-len v))
    false)
    (array-ref (lsp-documents-slots v) index)
    fallback))

(define (lsp-documents-set!
  [v : (&mut v LspDocuments)]
  [index : i64]
  [value : LspDocument]) : unit
  (if (if (>= index 0)
    (< index (struct-get v len))
    false)
    (array-set! (struct-get v slots) index value)
    unit))

(define (lsp-documents-copy-range
  [dst : (&mut dst (Array LspDocument))]
  [src : (& src (Array LspDocument))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (lsp-documents-copy-range dst src (+ index 1) count))))

(define (lsp-documents-grow [v : (&mut v LspDocuments)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array LspDocument) (make-array LspDocument new-cap)]
    (begin
      (lsp-documents-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (set! (struct-get v slots) bigger))))

(define (lsp-documents-push [v : (&mut v LspDocuments)] [value : LspDocument]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (lsp-documents-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))