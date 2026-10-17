(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import stdlib.test)
(import stdlib.iterator)

(define (span-key [kind : i64] [function : i64] [id : i64]) : ir.CompilerSourceSpansInstrKey
  (let
    [symbol : ir.CompilerIrSymbolId (ir.compiler-ir-symbol-typed-id function)]
    (cond
      [(= kind 0) (Value symbol id)]
      [(= kind 1) (Store symbol id)]
      [else (Bounds symbol id)])))

(define (span-add
  [entries : ir.CompilerSourceSpansInstrEntryList]
  [key : ir.CompilerSourceSpansInstrKey]
  [path : i64]) : ir.CompilerSourceSpansInstrEntryList
  (ir.compiler-source-spans-instr-entry-list-append
    entries
    (ir.compiler-source-spans-instr-entry
      key
      path
      (ast.ast-source-span 1 2 3 4))))

(define (span-path
  [entries : (& ir.CompilerSourceSpansInstrEntryList)]
  [key : ir.CompilerSourceSpansInstrKey]) : i64
  (match (ir.compiler-source-spans-instr-entry-list-lookup entries key)
    [(Some location) location.path-id]
    [(No) -1]))

;; Descriptors over one array differ only in their logical length. Vary it
;; while retaining the same storage and index to exercise shared old/new
;; prefixes without introducing unsafe aliases in the test itself.
(define (span-prefix-path
  [entries : (&mut entries ir.CompilerSourceSpansInstrEntryList)]
  [len : i64]
  [key : ir.CompilerSourceSpansInstrKey]) : i64
  (let
    [saved : i64 entries.len]
    [_ : unit (set! entries.len len)]
    [path : i64 (span-path entries key)]
    (set! entries.len saved)
    path))

(define (source-spans-history-ok?) : bool
  (let
    [entries : ir.CompilerSourceSpansInstrEntryList
      (ir.compiler-source-spans-instr-entry-list-from-slots
        (__tl_make-array ir.CompilerSourceSpansInstrEntry 8)
        0)]
    [f : ir.CompilerSourceSpansInstrKey (span-key 0 11 1)]
    [g : ir.CompilerSourceSpansInstrKey (span-key 1 22 1)]
    [ok : bool (= (span-path (& entries) f) -1)]
    (set! entries (span-add entries f 1))
    (set! entries (span-add entries f 2))
    (set! entries (span-add entries g 3))
    (set!
      ok
      (and
        ok
        (= (span-prefix-path (&mut entries) 1 f) 1)
        (= (span-prefix-path (&mut entries) 1 g) -1)
        (= (span-prefix-path (&mut entries) 2 f) 2)
        (= (span-path (& entries) g) 3)))
    ;; Replay the exact suffix through an older prefix, then extend it.
    (set! entries.len 1)
    (set! entries (span-add entries f 2))
    (set! entries (span-add entries g 3))
    (set! entries (span-add entries f 5))
    (set! ok (and ok (= (span-prefix-path (&mut entries) 3 f) 2)))
    ;; Divergence unlinks the index; longer prefixes retain the original tail.
    (set! entries.len 1)
    (set! entries (span-add entries g 4))
    (set!
      ok
      (and
        ok
        (= (span-path (& entries) g) 4)
        (= (span-prefix-path (&mut entries) 3 g) 3)
        (= (span-prefix-path (&mut entries) 4 f) 5)))
    ;; An append beyond the indexed prefix remains visible through that tail.
    (set! entries.len 4)
    (set! entries (span-add entries (span-key 2 33 1) 6))
    (set! ok (and ok (= (span-path (& entries) (span-key 2 33 1)) 6)))
    ;; Same key/path, different span: divergence rather than replay.
    (set! entries.len 1)
    (set!
      entries
      (ir.compiler-source-spans-instr-entry-list-append
        entries
        (ir.compiler-source-spans-instr-entry
          g
          4
          (ast.ast-source-span 31 32 33 34))))
    (set!
      ok
      (and
        ok
        (match (ir.compiler-source-spans-instr-entry-list-lookup (& entries) g)
          [(Some location)
            (= (ast.ast-source-span-start-line location.span) 31)]
          [_ false])
        (= (span-prefix-path (&mut entries) 5 (span-key 2 33 1)) 6)))
    ;; Overwrite the remaining tail and grow beyond its original allocation.
    (for [i (iterator.range 0 100)]
      (set!
        entries
        (span-add entries (span-key (% i 3) (+ i 100) i) (+ i 1000))))
    (for [i (iterator.range 0 100)]
      (set!
        ok
        (and
          ok
          (= (span-path (& entries) (span-key (% i 3) (+ i 100) i)) (+ i 1000)))))
    (and ok (= (span-path (& entries) f) 1) (= (span-path (& entries) g) 4))))

(define (source-spans-collisions-ok?) : bool
  (let
    [entries : ir.CompilerSourceSpansInstrEntryList
      (ir.compiler-source-spans-instr-entry-list-empty)]
    [ok : bool true]
    (for [i (iterator.range 0 97)]
      ;; Equal normalized hashes, distinct full-width function and id keys.
      (set!
        entries
        (span-add entries (span-key (% i 3) (+ 11 (* i 2147483647)) 9) (+ i 1))))
    (set! entries (span-add entries (span-key 0 11 9) 999))
    (for [i (iterator.range 0 97)]
      (for [kind (iterator.range 0 3)]
        (let
          [function : i64 (+ 11 (* i 2147483647))]
          [expected : i64
            (if (= kind (% i 3))
              (+ i 1)
              -1)]
          (set!
            ok
            (and
              ok
              (=
                (span-prefix-path (&mut entries) 97 (span-key kind function 9))
                expected)
              (=
                (span-path (& entries) (span-key kind function 9))
                (if (and (= i 0) (= kind 0))
                  999
                  expected))
              (= (span-path (& entries) (span-key kind function 2147483656)) -1))))))
    (let
      [escaped : ir.CompilerSourceSpansInstrEntryList
        (ir.compiler-source-spans-instr-entry-list-escape (& entries))]
      [wide : ir.CompilerSourceSpansInstrEntryList
        (span-add
          escaped
          (span-key 2 9223372036854775807 -9223372036854775808)
          1234)]
      [cleared : ir.CompilerSourceSpans
        (ir.compiler-source-spans-clear-instrs
          (Spans
            (ir.compiler-source-spans-entry-list-empty)
            entries
            98
            (ir.compiler-spmd-decisions-empty)))]
      (and
        ok
        (= (span-path (& wide) (span-key 0 11 9)) 999)
        (=
          (span-path
            (& wide)
            (span-key 2 9223372036854775807 -9223372036854775808))
          1234)
        (match (& cleared)
          [(Spans _ empty _ _) (= (span-path empty (span-key 0 11 9)) -1)])))))

(define (source-spans-index-boundaries-ok?) : bool
  (let
    [empty : ir.CompilerSourceSpansInstrEntryList
      (ir.compiler-source-spans-instr-entry-list-empty)]
    [base : ir.CompilerSourceSpansInstrEntryList
      (span-add
        (ir.compiler-source-spans-instr-entry-list-empty)
        (span-key 0 5 6)
        7)]
    [singleton : ir.CompilerSourceSpansInstrEntryList
      (ir.compiler-source-spans-instr-entry-list-escape (& base))]
    [grown : ir.CompilerSourceSpansInstrEntryList
      (span-add singleton (span-key 2 5 10) 11)]
    (and
      (= (span-path (& empty) (span-key 0 5 6)) -1)
      (= (span-path (& base) (span-key 0 5 6)) 7)
      (= (span-path (& base) (span-key 2 5 10)) -1)
      (= (span-path (& grown) (span-key 0 5 6)) 7)
      (= (span-path (& grown) (span-key 2 5 10)) 11)
      (not (ir.compiler-source-spans-instr-index-capacity? -1))
      (not (ir.compiler-source-spans-instr-index-capacity? 0))
      (not (ir.compiler-source-spans-instr-index-capacity? 1))
      (ir.compiler-source-spans-instr-index-capacity? 2)
      (ir.compiler-source-spans-instr-index-capacity? 1073741823)
      (not (ir.compiler-source-spans-instr-index-capacity? 1073741824)))))

(define (source-spans-self-test) : unit
  (test.assert-true (source-spans-history-ok?) "source-span shared history")
  (test.assert-true
    (source-spans-collisions-ok?)
    "source-span colliding full-width keys")
  (test.assert-true
    (source-spans-index-boundaries-ok?)
    "source-span index boundaries"))

(test source-span-shared-index-histories (source-spans-self-test))