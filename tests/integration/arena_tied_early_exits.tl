(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)

;; Early exits whose declared result carries the value's region, or whose
;; value carries no region, stay accepted (#9442).
(define (tied [owner : (& handle (arena.Arena source))] [n : i64]) : (in
    source
    String)
  (return (in-arena owner (string.int->string n))))

(define (tied-when [owner : (& handle (arena.Arena source))] [n : i64]) : (in
    source
    String)
  (in-arena
    owner
    (when (< n 0) (return (string.int->string n)))
    (if (> n 100)
      (return (string.append "big" ""))
      (string.append "small" ""))))

(define (scalar-inside [owner : (& handle (arena.Arena source))] [n : i64]) : i64
  (in-arena
    owner
    (let
      [text (string.int->string n)]
      (when (< n 0) (return (string.string-length text)))
      0)))

(define (untagged-inside [owner : (& handle (arena.Arena source))] [n : i64]) : String
  (let
    [text (string.int->string n)]
    (in-arena owner (when (< n 0) (return text)))
    (string.append "pos" "")))

(define (program-inside
  [owner : (arena.Arena source)]
  [text : (in program String)]) : (in program String)
  (in-arena owner (return text)))

(defenum Word
  (Ok String)
  (Err i64))

(define (read-word [n : i64]) : Word
  (if (> n 0)
    (Word.Ok (string.int->string n))
    (Word.Err n)))

;; A scalar error residual leaves through `try`; only the length stays (the
;; accepted twin of the rejected manual `(return (Word.Err code))`).
(define (scalar-try-inside [owner : (& handle (arena.Arena source))] [n : i64]) : Word
  (let
    [length : i64
      (in-arena
        owner
        (let
          [text (try (read-word n))]
          (string.string-length text)))]
    (Word.Ok (string.int->string length))))

;; A brand activated only after the return still ties a declared result.
(defstruct Holder
  (:lifetimes r)
  (owner (arena.Arena r)))

(define (make [h : (& handle (Holder source))] [n : i64]) : (in source String)
  (in-arena h.owner (string.int->string n)))

(define (keep [h : (& handle (Holder source))] [n : i64]) : (in source String)
  (when (< n 0) (return (make h n)))
  (in-arena h.owner 0)
  (in-arena h.owner (string.append "x" "")))

(define (atomic-lambda [n : i64]) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [make-text : (-> String)
      (lambda () : String
        (when (< n 0) (return (in-arena owner (string.int->string n))))
        (in-arena owner (string.append "pos" "")))]
    (string.string-length (make-text))))

(define (value) : i64
  (let
    [owner (arena.make)]
    [early (tied (& owner) -12345)]
    [branch (tied-when (& owner) -1)]
    [big (tied-when (& owner) 101)]
    [small (tied-when (& owner) 7)]
    [length : i64
      (+
        (string.string-length early)
        (string.string-length branch)
        (string.string-length big)
        (string.string-length small))]
    (arena.destroy-safe! owner)
    (let
      [other (arena.make)]
      [scalar : i64 (scalar-inside (& other) -123)]
      [plain (untagged-inside (& other) -1)]
      [score : i64
        (match (scalar-try-inside (& other) -9)
          [(Word.Ok _) 100]
          [(Word.Err code) (+ code 9)])]
      [counted : i64
        (match (scalar-try-inside (& other) 99)
          [(Word.Ok text) (string.string-length text)]
          [(Word.Err _) 100])]
      [holder (Holder (arena.make))]
      [kept (keep (& holder) -123)]
      [kept-length : i64 (string.string-length kept)]
      (arena.destroy-safe! holder.owner)
      (arena.destroy-safe! other)
      (+
        length
        scalar
        (string.string-length plain)
        (string.string-length (program-inside (arena.make) "program"))
        score
        counted
        (atomic-lambda -12)
        kept-length
        5))))

(define (main) : i64
  (let
    [result : i64 (value)]
    (io.println "{}" result)
    result))