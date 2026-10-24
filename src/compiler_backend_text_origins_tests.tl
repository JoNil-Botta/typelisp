(import compiler_backend_text_origins as origins)
(import compiler_ir_types as ir)
(import compiler_stack_traffic as traffic)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.test)
(import compiler_owned_view as owned_view)

(define (text-origin-test-ok [result : origins.CompilerBackendOriginTextResult]) : String
  (match result
    [(Ok text) text]
    [(Err message) (io.panic message)]))

(define (text-origin-test-error
  [result : origins.CompilerBackendOriginTextResult]) : unit
  (match result
    [(Err _) unit]
    [(Ok _) (test.assert-true false "invalid origin transport must reject")]))

(define (text-origin-test-span
  [capture : origins.CompilerBackendTextOrigins]
  [text : (& str)]
  [index : i64]
  [start : i64]
  [end : i64]
  [token : i64]) : unit
  (let
    [found : (__tl_dyn-array origins.CompilerBackendTextOrigin)
      (origins.compiler-backend-text-origins-find capture text)]
    (test.assert-true
      (< index (array-length found))
      "expected transported origin")
    (let
      [span : (& found origins.CompilerBackendTextOrigin)
        (& (array-ref found index))]
      (test.assert-i64-eq span.start start "origin byte start")
      (test.assert-i64-eq span.end end "origin byte end")
      (test.assert-i64-eq span.token token "emitter-issued identity"))))

(define (text-origin-construction-test) : unit
  (let
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [other : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [raw : String "-8(%rbp)"]
    [first : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-mark
          capture
          (owned_view.compiler-owned-shared-view raw)
          11))]
    [second : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-mark
          capture
          (owned_view.compiler-owned-shared-view raw)
          12))]
    [foreign : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-mark
          other
          (owned_view.compiler-owned-shared-view raw)
          11))]
    [parts : (Array String 5)
      (array
        "movq "
        (owned_view.compiler-owned-shared-view first)
        ", "
        (owned_view.compiler-owned-shared-view second)
        "\n")]
    [text : String
      (origins.compiler-backend-text-origins-concat capture (& parts))]
    (test.assert-string-eq
      first
      second
      "equal physical operands retain distinct logical identities")
    (text-origin-test-span capture (& first) 0 0 8 11)
    (text-origin-test-span capture (& second) 0 0 8 12)
    (text-origin-test-span other (& foreign) 0 0 8 11)
    (test.assert-i64-eq
      (array-length
        (origins.compiler-backend-text-origins-find capture (& raw)))
      0
      "unmarked bytes do not gain an origin")
    (test.assert-i64-eq
      (array-length
        (origins.compiler-backend-text-origins-find capture (& foreign)))
      0
      "interleaved jobs are distinct")
    (test.assert-string-eq
      text
      "movq -8(%rbp), -8(%rbp)\n"
      "origin metadata does not alter bytes")
    (text-origin-test-span capture (& text) 0 5 13 11)
    (text-origin-test-span capture (& text) 1 15 23 12)
    (let
      [line : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-slice capture (& text) 5 18))]
      [rebased : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-retarget
            capture
            (owned_view.compiler-owned-shared-view first)
            "120(%rsp)"))]
      (text-origin-test-span capture (& line) 0 0 8 11)
      (text-origin-test-span capture (& line) 1 10 18 12)
      (text-origin-test-span capture (& rebased) 0 0 9 11))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-slice capture (& text) 6 18))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-slice capture (& text) 0 6))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-slice capture (& text) -1 0))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-slice capture (& text) 0 25))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-mark
        capture
        (owned_view.compiler-owned-shared-view first)
        99))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-retarget
        capture
        (owned_view.compiler-owned-shared-view text)
        "0(%rsp)"))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-retarget
        capture
        (owned_view.compiler-owned-shared-view first)
        ""))
    (let
      [copy : String (string.copy (& first))]
      [empty : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-slice capture (& text) 0 5))]
      [duplicate-parts : (Array String 2)
        (array
          (owned_view.compiler-owned-shared-view first)
          (owned_view.compiler-owned-shared-view first))]
      [duplicate : String
        (origins.compiler-backend-text-origins-concat
          capture
          (& duplicate-parts))]
      (test.assert-i64-eq
        (array-length
          (origins.compiler-backend-text-origins-find capture (& copy)))
        0
        "an untracked text copy loses proof, never guesses by content")
      (test.assert-i64-eq
        (array-length
          (origins.compiler-backend-text-origins-find capture (& empty)))
        0
        "dropping whole origins is explicit")
      (text-origin-test-span capture (& duplicate) 0 0 8 11)
      (text-origin-test-span capture (& duplicate) 1 8 16 11))
    (origins.compiler-backend-text-origins-release! (&mut other))
    (origins.compiler-backend-text-origins-release! (&mut capture))
    (test.assert-i64-eq capture.owner 0 "release clears the owner")
    (test.assert-true (= capture.storage 0) "release clears the opaque handle")))

(define (text-origin-scratch-test) : unit
  (let
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [scratch : i64 (arena.tl_arena_make_small)]
    [marked : String
      (in-arena
        (arena.Arena scratch)
        (let
          [raw : String (string.copy "operand")]
          (text-origin-test-ok
            (origins.compiler-backend-text-origins-mark capture raw 7))))]
    [combined : String
      (in-arena
        (arena.Arena scratch)
        (let
          [parts : (Array String 3)
            (array
              "before "
              (owned_view.compiler-owned-shared-view marked)
              " after")]
          (origins.compiler-backend-text-origins-concat capture (& parts))))]
    (unsafe
      (arena.tl_arena_destroy scratch))
    (test.assert-string-eq
      combined
      "before operand after"
      "annotated results outlive emitter scratch")
    (text-origin-test-span capture (& combined) 0 7 14 7)
    (let
      [pieces : (__tl_dyn-array String) (__tl_make-array String 65)]
      (for [index (iterator.range 0 65)]
        (set!
          (array-ref pieces index)
          (text-origin-test-ok
            (origins.compiler-backend-text-origins-mark capture "equal" index))))
      (for [index (iterator.range 0 65)]
        (text-origin-test-span capture (& (array-ref pieces index)) 0 0 5 index)))
    (origins.compiler-backend-text-origins-release! (&mut capture))))

(define (text-origin-boundaries-test) : unit
  (let
    [disabled : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-disabled)]
    [parts : (Array String 2) (array "a" "b")]
    [text : String
      (origins.compiler-backend-text-origins-concat disabled (& parts))]
    (test.assert-string-eq text "ab" "disabled transport emits ordinary bytes")
    (test.assert-i64-eq
      (array-length
        (origins.compiler-backend-text-origins-find disabled (& text)))
      0
      "disabled has no metadata")
    (text-origin-test-error
      (origins.compiler-backend-text-origins-mark disabled "" 0))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-mark disabled "x" -1))
    (let
      [empty-parts : (__tl_dyn-array String) (__tl_make-array String 0)]
      (test.assert-string-eq
        (origins.compiler-backend-text-origins-concat
          disabled
          (slice-view (& empty-parts) 0 0))
        ""
        "empty concatenation"))
    (origins.compiler-backend-text-origins-release! (&mut disabled))))

(test
  text-origins-preserve-identity-through-construction
  (text-origin-construction-test))

(test
  text-origins-own-intermediates-across-scratch-retirement
  (text-origin-scratch-test))

(test
  text-origins-disabled-and-invalid-boundaries
  (text-origin-boundaries-test))

(define (text-origin-count-part! [count : (&mut count i64)] [part : String]) : String
  (+= (deref count) 1)
  part)

(define (text-origin-macro-test) : unit
  (let
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [marked : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-mark capture "home" 31))]
    [count : i64 0]
    [text : String
      (origins.compiler-backend-text-origins-cat
        capture
        (text-origin-count-part! (&mut count) "a")
        marked
        (origins.compiler-backend-text-origins-cat capture "b" marked))]
    (test.assert-i64-eq count 1 "macro evaluates each part once")
    (test.assert-string-eq text "ahomebhome" "nested construction")
    (text-origin-test-span capture (& text) 0 1 5 31)
    (text-origin-test-span capture (& text) 1 6 10 31)
    (test.assert-string-eq
      (origins.compiler-backend-text-origins-cat capture)
      ""
      "zero parts")
    (let
      [one : String (origins.compiler-backend-text-origins-cat capture marked)]
      (text-origin-test-span capture (& one) 0 0 4 31))
    (origins.compiler-backend-text-origins-release! (&mut capture))))

(test text-origins-concat-macro-is-single-evaluation (text-origin-macro-test))

(define (text-origin-record-test) : unit
  (let
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [access : origins.CompilerBackendStackAccessOrigin
      (origins.CompilerBackendStackAccessOrigin
        (ir.CompilerIrSymbolId 0)
        (SourceBlock 3)
        7
        32
        (Allocator)
        (Vector)
        32
        (Read))]
    (for [invalid (iterator.range 0 12)]
      (let
        [bad : origins.CompilerBackendStackAccessOrigin (clone access)]
        (cond
          [(= invalid 0) (set! bad.function (ir.CompilerIrSymbolId -1))]
          [(= invalid 1) (set! bad.anchor (SourceBlock -1))]
          [(= invalid 2) (set! bad.home -1)]
          [(= invalid 3) (set! bad.access-bytes 0)]
          [(= invalid 4) (set! bad.home-bytes 0)]
          [(= invalid 5) (set! bad.home-bytes 16)]
          [(= invalid 6) (set! bad.anchor (FunctionEntry))]
          [(= invalid 7) (set! bad.anchor (FunctionExit))]
          [(= invalid 10) (set! bad.anchor (FunctionParameters))]
          [(= invalid 11)
            (set! bad.anchor (FunctionParameters))
            (set! bad.owner (CallAbi))
            (set! bad.access (Write))]
          [else
            (set! bad.owner (CallAbi))
            (set!
              bad.anchor
              (if (= invalid 8)
                (FunctionEntry)
                (FunctionExit)))
            (set!
              bad.access
              (if (= invalid 8)
                (Read)
                (Write)))])
        (text-origin-test-error
          (origins.compiler-backend-text-origins-record capture bad "-64(%rbp)"))))
    (test.assert-i64-eq
      (origins.compiler-backend-text-origins-accesses capture).len
      0
      "invalid emitter facts publish nothing")
    (let
      [marked : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-record
            capture
            (clone access)
            "-64(%rbp)"))]
      (text-origin-test-span capture (& marked) 0 0 9 0)
      (text-origin-test-error
        (origins.compiler-backend-text-origins-record
          capture
          (clone access)
          (owned_view.compiler-owned-shared-view marked)))
      (test.assert-i64-eq
        (origins.compiler-backend-text-origins-accesses capture).len
        1
        "refused retag leaves no orphan token"))
    (for [saving (iterator.range 0 2)]
      (let
        [abi : origins.CompilerBackendStackAccessOrigin (clone access)]
        (set! abi.owner (CallAbi))
        (set!
          abi.anchor
          (if (= saving 1)
            (FunctionEntry)
            (FunctionExit)))
        (set!
          abi.access
          (if (= saving 1)
            (Write)
            (Read)))
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-record capture abi "%r12"))))
    (origins.compiler-backend-text-origins-release! (&mut capture))))

(test text-origins-record-typed-facts-transactionally (text-origin-record-test))

(define (text-origin-check-ok [result : origins.CompilerBackendOriginCheck]) : unit
  (match result
    [(Ok) unit]
    [(Err message) (io.panic message)]))

(define (text-origin-check-error [result : origins.CompilerBackendOriginCheck]) : unit
  (match result
    [(Err _) unit]
    [(Ok) (test.assert-true false "invalid buffer step must reject")]))

(define (text-origin-buffer-test) : unit
  (let
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [buffer : origins.CompilerBackendTextOriginBuffer
      (origins.compiler-backend-text-origin-buffer-new capture)]
    [body : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-mark capture "abc" 21))]
    [late-prefix : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-mark capture "X" 22))]
    [suffix : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-mark capture "Z" 23))]
    (test.assert-true
      (origins.compiler-backend-text-origin-buffer-capture-matches?
        buffer
        capture)
      "fresh buffer belongs to its capture")
    (let
      [other : origins.CompilerBackendTextOrigins
        (origins.compiler-backend-text-origins-new)]
      [disabled : origins.CompilerBackendTextOrigins
        (origins.compiler-backend-text-origins-disabled)]
      (test.assert-true
        (not
          (origins.compiler-backend-text-origin-buffer-capture-matches?
            buffer
            other))
        "foreign capture cannot adopt a buffer")
      (test.assert-true
        (not
          (origins.compiler-backend-text-origin-buffer-capture-matches?
            (origins.CompilerBackendTextOriginBuffer 0)
            capture))
        "an untracked prefix cannot adopt an active capture")
      (test.assert-true
        (origins.compiler-backend-text-origin-buffer-capture-matches?
          (origins.CompilerBackendTextOriginBuffer 0)
          disabled)
        "ordinary buffer remains disabled")
      (origins.compiler-backend-text-origins-release! (&mut other)))
    (text-origin-check-ok
      (origins.compiler-backend-text-origin-buffer-note! buffer "p" 0))
    (text-origin-check-error
      (origins.compiler-backend-text-origin-buffer-note! buffer (& body) 0))
    (text-origin-check-ok
      (origins.compiler-backend-text-origin-buffer-note! buffer (& body) 1))
    (text-origin-check-ok
      (origins.compiler-backend-text-origin-buffer-note! buffer "q" 4))
    (text-origin-check-error
      (origins.compiler-backend-text-origin-buffer-insert!
        buffer
        (& late-prefix)
        2))
    (text-origin-check-error
      (origins.compiler-backend-text-origin-buffer-insert! buffer "x" -1))
    (text-origin-check-error
      (origins.compiler-backend-text-origin-buffer-insert! buffer "x" 6))
    (text-origin-check-ok
      (origins.compiler-backend-text-origin-buffer-insert! buffer "" 2))
    (text-origin-check-ok
      (origins.compiler-backend-text-origin-buffer-insert!
        buffer
        (& late-prefix)
        1))
    (text-origin-check-ok
      (origins.compiler-backend-text-origin-buffer-insert! buffer (& suffix) 6))
    (text-origin-test-error
      (origins.compiler-backend-text-origin-buffer-finish buffer "wrong length"))
    (text-origin-test-error
      (origins.compiler-backend-text-origin-buffer-finish buffer "pXabdqZ"))
    (let
      [text : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origin-buffer-finish buffer "pXabcqZ"))]
      (text-origin-test-span capture (& text) 0 1 2 22)
      (text-origin-test-span capture (& text) 1 2 5 21)
      (text-origin-test-span capture (& text) 2 6 7 23)
      (test.assert-string-eq
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-slice capture (& text) 3 0))
        ""
        "zero-length slice publishes no partial origin"))
    (test.assert-true
      (not
        (origins.compiler-backend-text-origin-buffer-capture-matches?
          buffer
          capture))
      "a finished buffer cannot accept more home operands")
    (text-origin-check-error
      (origins.compiler-backend-text-origin-buffer-note! buffer "later" 7))
    (text-origin-check-error
      (origins.compiler-backend-text-origin-buffer-insert! buffer "later" 7))
    (text-origin-test-error
      (origins.compiler-backend-text-origin-buffer-finish buffer "pXabcqZ"))
    (origins.compiler-backend-text-origins-release! (&mut capture))))

(test text-origins-buffer-order-and-byte-witness (text-origin-buffer-test))

(define (text-origin-copy-test) : unit
  (let
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [other : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [cloned : origins.CompilerBackendOriginCopy
      (with-scratch
        (let
          [marked : String
            (text-origin-test-ok
              (origins.compiler-backend-text-origins-mark capture "-8(%rbp)" 61))]
          [saved : origins.CompilerBackendTextOriginSnapshot
            (origins.compiler-backend-text-origins-snapshot capture (& marked))]
          (origins.CompilerBackendOriginCopy marked saved)))]
    [snapshot : origins.CompilerBackendTextOriginSnapshot cloned.snapshot]
    [escaped : String cloned.text]
    [copy : String (string.copy (& escaped))]
    (test.assert-i64-eq
      (array-length
        (origins.compiler-backend-text-origins-find capture (& copy)))
      0
      "ordinary copy has no inferred origin")
    (for [index (iterator.range 0 65)]
      (let
        [_noise : String
          (text-origin-test-ok
            (origins.compiler-backend-text-origins-mark
              capture
              "noise"
              (+ 100 index)))]
        unit))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-restore-copy
        other
        (clone snapshot)
        (owned_view.compiler-owned-shared-view copy)))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-restore-copy
        capture
        (clone snapshot)
        "-9(%rbp)"))
    (text-origin-test-error
      (origins.compiler-backend-text-origins-restore-copy
        capture
        (Saved capture.storage capture.owner -1)
        "-8(%rbp)"))
    (let
      [restored : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-restore-copy
            capture
            snapshot
            copy))]
      (test.assert-string-eq
        restored
        "-8(%rbp)"
        "scratch clone preserves bytes")
      (text-origin-test-span capture (& restored) 0 0 8 61))
    (let
      [plain : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-restore-copy
            capture
            (None)
            "-8(%rbp)"))]
      (test.assert-i64-eq
        (array-length
          (origins.compiler-backend-text-origins-find capture (& plain)))
        0
        "absent snapshot cannot recover identity by equality"))
    (origins.compiler-backend-text-origins-release! (&mut other))
    (origins.compiler-backend-text-origins-release! (&mut capture))))

(define (text-origin-replace-test) : unit
  (let
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [operand : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-mark capture "-8(%rbp)" 41))]
    [source : String
      (origins.compiler-backend-text-origins-cat
        capture
        "guard\n"
        operand
        "\nguard\n")]
    [changed : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-replace
          capture
          (owned_view.compiler-owned-shared-view source)
          "guard\n"
          "new-prologue\n"))]
    (test.assert-string-eq
      changed
      "new-prologue\n-8(%rbp)\nguard\n"
      "replacement keeps first-occurrence semantics")
    (text-origin-test-span capture (& changed) 0 13 21 41)
    (text-origin-test-span capture (& source) 0 6 14 41)
    (text-origin-test-error
      (origins.compiler-backend-text-origins-replace
        capture
        (owned_view.compiler-owned-shared-view source)
        "(%rbp)"
        "(%rsp)"))
    (let
      [same-bytes : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-replace
            capture
            (owned_view.compiler-owned-shared-view source)
            "-8(%rbp)"
            "-8(%rbp)"))]
      [unchanged : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-replace
            capture
            (owned_view.compiler-owned-shared-view source)
            "not-found"
            "x"))]
      [prepended : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-replace
            capture
            (owned_view.compiler-owned-shared-view source)
            ""
            "X"))]
      (test.assert-string-eq
        same-bytes
        source
        "an unannotated replacement may have identical bytes")
      (test.assert-i64-eq
        (array-length
          (origins.compiler-backend-text-origins-find capture (& same-bytes)))
        0
        "removed origin is not inferred on replacement text")
      (text-origin-test-span capture (& unchanged) 0 6 14 41)
      (text-origin-test-span capture (& prepended) 0 7 15 41))
    (let
      [inserted : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-mark capture "home" 42))]
      [with-insert : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-replace
            capture
            (owned_view.compiler-owned-shared-view source)
            "guard\n"
            inserted))]
      (text-origin-test-span capture (& with-insert) 0 0 4 42)
      (text-origin-test-span capture (& with-insert) 1 4 12 41))
    (origins.compiler-backend-text-origins-release! (&mut capture))))

(test text-origins-copy-snapshot-survives-clone (text-origin-copy-test))

(test text-origins-replacement-is-explicit (text-origin-replace-test))

(define (text-origin-range-buffer-test) : unit
  (let
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [buffer : origins.CompilerBackendTextOriginBuffer
      (origins.compiler-backend-text-origin-buffer-new capture)]
    [operand : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-mark capture "-8(%rbp)" 91))]
    [source : String
      (origins.compiler-backend-text-origins-cat capture "p" operand "q\n")]
    (text-origin-check-error
      (origins.compiler-backend-text-origin-buffer-append-range!
        buffer
        (& source)
        2
        3))
    (text-origin-check-error
      (origins.compiler-backend-text-origin-buffer-append-range!
        buffer
        (& source)
        -1
        0))
    (text-origin-check-ok
      (origins.compiler-backend-text-origin-buffer-append! buffer "prefix"))
    (text-origin-check-ok
      (origins.compiler-backend-text-origin-buffer-append-range!
        buffer
        (& source)
        1
        8))
    (text-origin-check-ok
      (origins.compiler-backend-text-origin-buffer-append-range!
        buffer
        (& source)
        9
        2))
    (let
      [text : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origin-buffer-finish
            buffer
            "prefix-8(%rbp)q\n"))]
      (text-origin-test-span capture (& text) 0 6 14 91))
    (text-origin-check-error
      (origins.compiler-backend-text-origin-buffer-append!
        buffer
        "after finish"))
    (origins.compiler-backend-text-origins-release! (&mut capture))))

(test
  text-origins-range-buffer-validates-before-append
  (text-origin-range-buffer-test))

(define (text-origin-final-test) : unit
  (let
    [capture : origins.CompilerBackendTextOrigins
      (origins.compiler-backend-text-origins-new)]
    [fact : origins.CompilerBackendStackAccessOrigin
      (origins.CompilerBackendStackAccessOrigin
        (ir.CompilerIrSymbolId 44)
        (SourceBlock 30)
        8
        8
        (Allocator)
        (General)
        8
        (Write))]
    [write : String
      (text-origin-test-ok
        (origins.compiler-backend-text-origins-record
          capture
          (clone fact)
          "-8(%rsp)"))]
    (set! fact.home 7)
    (set! fact.access (Read))
    (let
      [read : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-record capture fact "-8(%rsp)"))]
      [merged : String
        (text-origin-test-ok
          (origins.compiler-backend-text-origins-merge-accesses
            capture
            (owned_view.compiler-owned-shared-view read)
            (owned_view.compiler-owned-shared-view write)
            "-8(%rsp)"))]
      [prefix : String ".text\nf:\n"]
      [nop : String "    nop\n"]
      [rmw : String
        (origins.compiler-backend-text-origins-cat
          capture
          "    addq $1, "
          merged
          "\n")]
      [gap : String "\n.Lcold:\n"]
      [load : String
        (origins.compiler-backend-text-origins-cat
          capture
          "    movq "
          read
          ", %rax\n")]
      [text : String
        (origins.compiler-backend-text-origins-cat
          capture
          prefix
          nop
          rmw
          gap
          load
          load)]
      [rmw-start : i64
        (+ (string.string-length prefix) (string.string-length nop))]
      [load-start : i64
        (+ rmw-start (+ (string.string-length rmw) (string.string-length gap)))]
      [operations : (__tl_dyn-array origins.CompilerBackendFinalOperation)
        (__tl_make-array origins.CompilerBackendFinalOperation 6)]
      (set!
        (array-ref operations 0)
        (origins.CompilerBackendFinalOperation
          (string.string-length prefix)
          (- rmw-start 1)
          0))
      (set!
        (array-ref operations 1)
        (origins.CompilerBackendFinalOperation
          rmw-start
          (- (+ rmw-start (string.string-length rmw)) 1)
          0))
      (set!
        (array-ref operations 2)
        (origins.CompilerBackendFinalOperation
          load-start
          (- (+ load-start (string.string-length load)) 1)
          1))
      (set!
        (array-ref operations 3)
        (origins.CompilerBackendFinalOperation
          (+ load-start (string.string-length load))
          (- (string.string-length text) 1)
          1))
      (set!
        (array-ref operations 4)
        (origins.CompilerBackendFinalOperation -1 -1 -1))
      (for [spare (iterator.range 0 2)]
        (let
          [count : i64
            (if (= spare 0)
              4
              6)]
          [copy : (__tl_dyn-array origins.CompilerBackendFinalOperation)
            (__tl_make-array origins.CompilerBackendFinalOperation count)]
          (for [i (iterator.range 0 count)]
            (set! (array-ref copy i) (clone (array-ref operations i))))
          (match (origins.compiler-backend-text-origins-final-accesses
            capture
            (& text)
            (ir.CompilerIrSymbolId 44)
            2
            (slice-view copy 0 4))
            [(Err message) (io.panic message)]
            [(Ok events)
              (test.assert-i64-eq
                (array-length events)
                4
                "surviving RMW pair and both actual tail clones")
              (for [i (iterator.range 0 4)]
                (let
                  [event : (& events origins.CompilerBackendFinalAccess)
                    (& (array-ref events i))]
                  (test.assert-i64-eq
                    event.operation
                    (if (< i 2)
                      1
                      i)
                    "final instruction order ignores labels and directives")
                  (test.assert-i64-eq
                    event.access-index
                    (if (= i 1)
                      1
                      0)
                    "read before write, independent of token issuance")
                  (test.assert-i64-eq
                    event.block
                    (if (< i 2)
                      0
                      1)
                    "one final block for every access of an instruction")
                  (test.assert-i64-eq
                    event.origin.home
                    (if (= i 1)
                      8
                      7)
                    "RMW preserves distinct pre-color homes")
                  (test.assert-true
                    (match (& event.origin.anchor)
                      [(SourceBlock b) (= b 30)]
                      [_ false])
                    "source authority is retained rather than replaced by final CFG block")
                  (test.assert-true
                    (match (& event.origin.access)
                      [(Read) (!= i 1)]
                      [(Write) (= i 1)]
                      [_ false])
                    "clones and folded accesses retain exact directions")))])))
      (for [invalid (iterator.range 0 10)]
        (let
          [bad : (__tl_dyn-array origins.CompilerBackendFinalOperation)
            (clone operations)]
          (cond
            [(= invalid 0) (set! (array-ref bad 0).start -1)]
            [(= invalid 1) (set! (array-ref bad 0).end (array-ref bad 0).start)]
            [(= invalid 2)
              (set! (array-ref bad 1).start (array-ref bad 0).start)]
            [(= invalid 3) (set! (array-ref bad 1).block -1)]
            [(= invalid 4) (set! (array-ref bad 1).block 2)]
            [(= invalid 5) (set! (array-ref bad 1).end (+ rmw-start 15))]
            [(= invalid 6)
              (set! (array-ref bad 3).end (+ 1 (string.string-length text)))]
            [else unit])
          (test.assert-true
            (match (origins.compiler-backend-text-origins-final-accesses
              (if (= invalid 9)
                (origins.compiler-backend-text-origins-disabled)
                capture)
              (& text)
              (ir.CompilerIrSymbolId
                (if (= invalid 7)
                  45
                  44))
              2
              (slice-view
                bad
                0
                (if (= invalid 8)
                  3
                  4)))
              [(Err _) true]
              [_ false])
            "invalid partitions, cut/orphan operands, foreign function and absent capture reject")))
      (let
        [untyped : String
          (text-origin-test-ok
            (origins.compiler-backend-text-origins-mark capture "-8(%rsp)" 99))]
        [line : String
          (origins.compiler-backend-text-origins-cat
            capture
            "    movq "
            untyped
            ", %rax\n")]
        [op : (__tl_dyn-array origins.CompilerBackendFinalOperation)
          (__tl_make-array
            (origins.CompilerBackendFinalOperation
              0
              (- (string.string-length line) 1)
              0))]
        (test.assert-true
          (match (origins.compiler-backend-text-origins-final-accesses
            capture
            (& line)
            (ir.CompilerIrSymbolId 44)
            1
            (slice-view op 0 1))
            [(Err _) true]
            [_ false])
          "text marker without typed issuer cannot become a final event"))
      (test.assert-i64-eq
        (origins.compiler-backend-text-origins-accesses capture).len
        2
        "reconciliation does not mint emitter tokens")
      (let
        [accesses : origins.CompilerBackendStackAccessOriginList
          (origins.compiler-backend-text-origins-accesses capture)]
        (set! (array-ref accesses.slots 0).access-bytes 0)
        (test.assert-true
          (match (origins.compiler-backend-text-origins-final-accesses
            capture
            (& text)
            (ir.CompilerIrSymbolId 44)
            2
            (slice-view operations 0 4))
            [(Err _) true]
            [_ false])
          "retained mutable-array facts are revalidated")
        (set! (array-ref accesses.slots 0).access-bytes 8))
      (let
        [operand : String
          (text-origin-test-ok
            (origins.compiler-backend-text-origins-record
              capture
              (origins.CompilerBackendStackAccessOrigin
                (ir.CompilerIrSymbolId 44)
                (SourceBlock 30)
                9
                8
                (UserLocal)
                (General)
                8
                (ReadWrite))
              "-16(%rsp)"))]
        [line : String
          (origins.compiler-backend-text-origins-cat
            capture
            "    notq "
            operand
            "\n")]
        [op : (__tl_dyn-array origins.CompilerBackendFinalOperation)
          (__tl_make-array
            (origins.CompilerBackendFinalOperation
              0
              (- (string.string-length line) 1)
              0))]
        (match (origins.compiler-backend-text-origins-final-accesses
          capture
          (& line)
          (ir.CompilerIrSymbolId 44)
          1
          (slice-view op 0 1))
          [(Err message) (io.panic message)]
          [(Ok events)
            (test.assert-i64-eq
              (array-length events)
              1
              "one RMW fact remains one event")
            (test.assert-true
              (match (& (array-ref events 0).origin.access)
                [(ReadWrite) true]
                [_ false])
              "single-access read-before-write semantics remain explicit")])))
    (origins.compiler-backend-text-origins-release! (&mut capture))))

(test text-origins-final-instruction-reconciliation (text-origin-final-test))