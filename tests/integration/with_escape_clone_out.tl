(import "stdlib/arena.tl")
(import "stdlib/string.tl")

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

(define (scratch-items [seed : i64]) : (Array String)
  (with-scratch (make-items seed)))

(define (scratch-cell [seed : i64]) : (Box String)
  (with-scratch (box (piece seed 3))))

(define (scratch-bundle [seed : i64]) : EscapeOutcome
  (with-scratch
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
    (items-ok? (struct-get bundle items) seed)
    (string-eq (array-ref (struct-get bundle fixed) 0) (piece seed 4))
    (string-eq (array-ref (struct-get bundle fixed) 1) (piece seed 5))
    (string-eq (box-get (struct-get bundle cell)) (piece seed 6))))

(define (outcome-ok? [outcome : EscapeOutcome] [seed : i64]) : bool
  (match outcome
    [(Escaped bundle) (bundle-ok? bundle seed)]
    [NoEscape false]))

(define (scratch-rewound? [scratch : i64] [seed : i64]) : bool
  (let
    [home : i64 (arena-current)]
    [before : i64 0]
    [after : i64 0]
    (begin
      (unsafe
        (arena-set! scratch))
      (set! before (arena-mark))
      (unsafe
        (arena-set! home))
      (let
        [items : (Array String) (escape-items scratch seed)]
        (begin
          (unsafe
            (arena-set! scratch))
          (set! after (arena-mark))
          (unsafe
            (arena-set! home))
          (and (= before after) (items-ok? items seed)))))))

(define (main) : i64
  (let
    [scratch : i64 (arena-make)]
    [items : (Array String) (escape-items scratch 10)]
    [cell : (Box String) (escape-cell scratch 20)]
    [bundle : EscapeOutcome (escape-bundle scratch 30)]
    [noise : EscapeOutcome (escape-bundle scratch 99)]
    [scratch-items-out : (Array String) (scratch-items 110)]
    [scratch-cell-out : (Box String) (scratch-cell 120)]
    [scratch-bundle-out : EscapeOutcome (scratch-bundle 130)]
    (if (and
      (items-ok? items 10)
      (cell-ok? cell 20 3)
      (outcome-ok? bundle 30)
      (outcome-ok? noise 99)
      (items-ok? scratch-items-out 110)
      (cell-ok? scratch-cell-out 120 3)
      (outcome-ok? scratch-bundle-out 130)
      (scratch-rewound? scratch 140))
      42
      1)))