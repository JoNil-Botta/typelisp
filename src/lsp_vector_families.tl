;; lsp_vector_families.tl - checked-in generated vector families for LSP state.
(defstruct LspDocument
  (uri String)
  (path String)
  (text String)
  (diagnostic-uri String))

(defstruct LspDocuments
  (slots (Array LspDocument))
  (len i64))

(define (lsp-documents-slots [v : LspDocuments]) : (Array LspDocument)
  (struct-get v slots))

(define (lsp-documents-len [v : LspDocuments]) : i64
  (struct-get v len))

(define (lsp-documents-capacity [v : LspDocuments]) : i64
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
  [v : LspDocuments]
  [index : i64]
  [fallback : LspDocument]) : LspDocument
  (if (if (>= index 0)
    (< index (lsp-documents-len v))
    false)
    (array-ref (lsp-documents-slots v) index)
    fallback))

(define (lsp-documents-set!
  [v : LspDocuments]
  [index : i64]
  [value : LspDocument]) : LspDocuments
  (begin
    (if (if (>= index 0)
      (< index (lsp-documents-len v))
      false)
      (array-set! (lsp-documents-slots v) index value)
      unit)
    v))

(define (lsp-documents-copy-range
  [dst : (Array LspDocument)]
  [src : (Array LspDocument)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (lsp-documents-copy-range dst src (+ index 1) count))))

(define (lsp-documents-grow [v : LspDocuments]) : LspDocuments
  (let
    [n : i64 (lsp-documents-len v)]
    [bigger : (Array LspDocument)
      (make-array LspDocument (* (lsp-documents-capacity v) 2))]
    (begin
      (lsp-documents-copy-range bigger (lsp-documents-slots v) 0 n)
      (set! (struct-get v slots) bigger)
      v)))

(define (lsp-documents-push [v : LspDocuments] [value : LspDocument]) : LspDocuments
  (if (< (lsp-documents-len v) (lsp-documents-capacity v))
    (let
      [slots : (Array LspDocument) (lsp-documents-slots v)]
      [index : i64 (lsp-documents-len v)]
      (begin
        (array-set! slots index value)
        (set! (struct-get v len) (+ index 1))
        v))
    (lsp-documents-push (lsp-documents-grow v) value)))

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

(define (lsp-decl-list-slots [v : LspDeclList]) : (Array LspDeclEntry)
  (struct-get v slots))

(define (lsp-decl-list-len [v : LspDeclList]) : i64
  (struct-get v len))

(define (lsp-decl-list-capacity [v : LspDeclList]) : i64
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
  [v : LspDeclList]
  [index : i64]
  [fallback : LspDeclEntry]) : LspDeclEntry
  (if (if (>= index 0)
    (< index (lsp-decl-list-len v))
    false)
    (array-ref (lsp-decl-list-slots v) index)
    fallback))

(define (lsp-decl-list-set!
  [v : LspDeclList]
  [index : i64]
  [value : LspDeclEntry]) : LspDeclList
  (begin
    (if (if (>= index 0)
      (< index (lsp-decl-list-len v))
      false)
      (array-set! (lsp-decl-list-slots v) index value)
      unit)
    v))

(define (lsp-decl-list-copy-range
  [dst : (Array LspDeclEntry)]
  [src : (Array LspDeclEntry)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (lsp-decl-list-copy-range dst src (+ index 1) count))))

(define (lsp-decl-list-grow [v : LspDeclList]) : LspDeclList
  (let
    [n : i64 (lsp-decl-list-len v)]
    [bigger : (Array LspDeclEntry)
      (make-array LspDeclEntry (* (lsp-decl-list-capacity v) 2))]
    (begin
      (lsp-decl-list-copy-range bigger (lsp-decl-list-slots v) 0 n)
      (set! (struct-get v slots) bigger)
      v)))

(define (lsp-decl-list-push [v : LspDeclList] [value : LspDeclEntry]) : LspDeclList
  (if (< (lsp-decl-list-len v) (lsp-decl-list-capacity v))
    (let
      [slots : (Array LspDeclEntry) (lsp-decl-list-slots v)]
      [index : i64 (lsp-decl-list-len v)]
      (begin
        (array-set! slots index value)
        (set! (struct-get v len) (+ index 1))
        v))
    (lsp-decl-list-push (lsp-decl-list-grow v) value)))