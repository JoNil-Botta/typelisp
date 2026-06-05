(import "stdlib/arena.tl")

(defstruct EscapeBundle
  (name String)
  (items (Array String))
  (fixed (Array String 2))
  (cell (Box String)))

(defenum EscapeOutcome
  (Escaped EscapeBundle)
  (NoEscape))

(define (piece [seed : i64] [slot : i64]) : String
  (string-append
    (string-append "escape:" (int->string seed))
    (string-append ":" (int->string slot))))

(define (make-items [seed : i64]) : (Array String)
  (let
    [items : (Array String) (make-array String 2)]
    (begin
      (array-set! items 0 (piece seed 1))
      (array-set! items 1 (piece seed 2))
      items)))

(define (escape-items [scratch : i64] [seed : i64]) : (Array String)
  (with-escape scratch (make-items seed)))

(define (escape-cell [scratch : i64] [seed : i64]) : (Box String)
  (with-escape scratch (box (piece seed 3))))

(define (escape-bundle [scratch : i64] [seed : i64]) : EscapeOutcome
  (with-escape
    scratch
    (Escaped
      (EscapeBundle
        (piece seed 0)
        (make-items seed)
        (array (piece seed 4) (piece seed 5))
        (box (piece seed 6))))))

(define (items-ok? [items : (Array String)] [seed : i64]) : bool
  (and
    (string-eq (array-ref items 0) (piece seed 1))
    (string-eq (array-ref items 1) (piece seed 2))))

(define (cell-ok? [cell : (Box String)] [seed : i64] [slot : i64]) : bool
  (string-eq (box-get cell) (piece seed slot)))

(define (bundle-ok? [bundle : EscapeBundle] [seed : i64]) : bool
  (and
    (string-eq (struct-get bundle name) (piece seed 0))
    (and
      (items-ok? (struct-get bundle items) seed)
      (and
        (string-eq (array-ref (struct-get bundle fixed) 0) (piece seed 4))
        (and
          (string-eq (array-ref (struct-get bundle fixed) 1) (piece seed 5))
          (cell-ok? (struct-get bundle cell) seed 6))))))

(define (outcome-ok? [outcome : EscapeOutcome] [seed : i64]) : bool
  (match outcome
    [(Escaped bundle) (bundle-ok? bundle seed)]
    [NoEscape false]))

(define (main) : i64
  (let
    [scratch : i64 (arena-make)]
    [items : (Array String) (escape-items scratch 10)]
    [cell : (Box String) (escape-cell scratch 20)]
    [bundle : EscapeOutcome (escape-bundle scratch 30)]
    [noise : EscapeOutcome (escape-bundle scratch 99)]
    (if (and
      (items-ok? items 10)
      (and
        (cell-ok? cell 20 3)
        (and (outcome-ok? bundle 30) (outcome-ok? noise 99))))
      42
      1)))