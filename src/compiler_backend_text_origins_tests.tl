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
        3
        7
        32
        (Allocator)
        (Vector)
        32
        (Read))]
    (for [invalid (iterator.range 0 6)]
      (let
        [bad : origins.CompilerBackendStackAccessOrigin (clone access)]
        (cond
          [(= invalid 0) (set! bad.function (ir.CompilerIrSymbolId -1))]
          [(= invalid 1) (set! bad.block -1)]
          [(= invalid 2) (set! bad.home -1)]
          [(= invalid 3) (set! bad.access-bytes 0)]
          [(= invalid 4) (set! bad.home-bytes 0)]
          [else (set! bad.home-bytes 16)])
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