;; explain_cli_core.tl - Long-form diagnostic code explanations.
;; Published codes and meanings are append-only.
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_diagnostic as cdiag)

(defenum DiagnosticExplainLookup
  (DiagnosticExplainUnknown)
  (DiagnosticExplainDetailed String))

(define (diagnostic-explain-help-text) : String
  "Usage:
    typelisp explain <code>
    typelisp explain --list
    typelisp explain --search <term>

Summary:
    Explain, list, or search TypeLisp diagnostic codes. Code lookup is
    ASCII case-insensitive.
")

(define (diagnostic-explain-e0100) : String
  "E0100: parse error

Description:
    The parser could not turn the source tokens into a valid TypeLisp form.
    The message and highlighted span identify the malformed construct.

Minimal failing example:
    (define (main) : i64
      (+ 1)

Fix:
    Balance delimiters and use the grammar expected by the enclosing form.
    Here, add the missing closing `)` after the function body.

See also:
    README.md, \"Language sketch\"; SPEC.md, \"Surface grammar\".
")

(define (diagnostic-explain-e0200) : String
  "E0200: unclassified typecheck error

Description:
    Type checking rejected the program, but the diagnostic has not yet been
    assigned a more specific stable code. The message remains authoritative.

Minimal failing example:
    There is intentionally no stable source example: once a reproducible error
    kind is known, it must receive a specific code instead of E0200.

Fix:
    Follow the diagnostic message. If no specific E0201-E0212 code describes
    it, report the source and full diagnostic so the taxonomy can be extended.

See also:
    CONTRIBUTING.md; docs/compiler-architecture.md, \"Diagnostics\".
")

(define (diagnostic-explain-e0201) : String
  "E0201: unbound name

Description:
    A value or type name was used where no visible definition, parameter, or
    import provides it.

Minimal failing example:
    (define (main) : i64
      missing-value)

Fix:
    Define the name before using it, correct its spelling, or import the module
    that provides it. For example:

    (define missing-value : i64 42)
    (define (main) : i64
      missing-value)

See also:
    SPEC.md, \"Names and bindings\"; README.md, \"Modules\".
")

(define (diagnostic-explain-e0202) : String
  "E0202: arity mismatch

Description:
    A function, constructor, builtin, or pattern received the wrong number of
    arguments.

Minimal failing example:
    (define (add [left : i64] [right : i64]) : i64
      (+ left right))
    (define (main) : i64
      (add 1))

Fix:
    Supply exactly the parameters required by the declaration. Here, call
    `(add 1 2)`.

See also:
    SPEC.md, \"Functions\" and \"Pattern matching\".
")

(define (diagnostic-explain-e0203) : String
  "E0203: non-exhaustive match

Description:
    A match expression does not cover every possible value of its scrutinee.

Minimal failing example:
    (defenum Choice (Yes) (No))
    (define (score [choice : Choice]) : i64
      (match choice
        [(Yes) 1]))

Fix:
    Add an arm for every missing variant, or use a wildcard arm when one
    fallback behavior is correct. Here, add `[(No) 0]`.

See also:
    SPEC.md, \"Pattern matching\"; tests/safety/generated_match_pattern_non_exhaustive_reject.tl.
")

(define (diagnostic-explain-e0204) : String
  "E0204: unknown struct field

Description:
    A field access or update names a field that the struct does not declare.

Minimal failing example:
    (defstruct Point (x i64) (y i64))
    (define (main) : i64
      (let [point : Point (Point 1 2)] point.z))

Fix:
    Use one of the fields listed by the diagnostic, or add the intended field
    to the struct definition. Here, use `point.x` or `point.y`.

See also:
    SPEC.md, \"Structs\"; src/tests/compiler_check_smoke.tl.
")

(define (diagnostic-explain-e0205) : String
  "E0205: region escape

Description:
    A value tied to an arena or lexical region would outlive its storage.
    Macro diagnostics identify expansion and invocation locations when known.

Minimal failing example:
    (import stdlib.string)
    (define (main) : String
      (with-arena phase (string.int->string 41)))

Fix:
    Consume the value before leaving its scope, or use `with-escape` for a
    supported owned clone. Returning a length computed inside is also safe.

See also:
    SPEC.md, \"Arena regions\"; tests/safety/region_escape_reject.tl.
")

(define (diagnostic-explain-e0206) : String
  "E0206: type mismatch

Description:
    An expression's inferred type does not match the type required there.

Minimal failing example:
    (define (main) : i64
      true)

Fix:
    Produce the required type, or change the declaration when that is the
    intended contract. Here, return an `i64` such as `0`.

See also:
    SPEC.md, \"Types\" and \"Type checking\".
")

(define (diagnostic-explain-e0207) : String
  "E0207: borrow violation

Description:
    A borrow targets a temporary or conflicts with a live borrow. A borrowed
    place also cannot be assigned or moved until that borrow ends.

Minimal failing example:
    (define (take [value : (& n i64)]) : i64 0)
    (define (main [n : i64]) : i64
      (take (& (+ n 1))))

Fix:
    Bind temporary values before borrowing, shorten the conflicting borrow's
    live range, or avoid mutating or moving the borrowed place.

See also:
    SPEC.md, \"Borrowing\"; tests/safety/mutable_reference_reject.tl.
")

(define (diagnostic-explain-e0208) : String
  "E0208: move violation

Description:
    An owning value or projection was consumed and then used again, or a move
    was attempted through a global/shared place that cannot transfer ownership.

Minimal failing example:
    (import stdlib.string)
    (define (main [cell : (Box String)]) : i64
      (let [value : String (deref cell)]
        (+ (string-length value)
           (string-length (__tl-box-place cell)))))

Fix:
    Use the value only before it is consumed, transfer it once, or explicitly
    clone data whose type supports an independent owned copy.

See also:
    SPEC.md, \"Move semantics\"; tests/safety/box_take_use_after_move_reject.tl.
")

(define (diagnostic-explain-e0209) : String
  "E0209: unsafe context required

Description:
    A raw pointer, syscall, arena-control, or other unchecked operation was
    requested outside an `unsafe` form.

Minimal failing example:
    (define (read [pointer : (Ptr i64)]) : i64
      (ptr-read pointer))

Fix:
    Prefer a safe wrapper. When necessary, put the smallest expression in
    `unsafe` and document the invariant that makes the operation safe.

See also:
    SPEC.md, \"Unsafe operations\"; tests/safety/safe_raw_pointer_read_reject.tl.
")

(define (diagnostic-explain-e0210) : String
  "E0210: lifetime mismatch

Description:
    A reference lifetime is missing, ambiguous, or too short for where the
    reference would be stored, passed, or returned.

Minimal failing example:
    (define (bad [value : (& source i64)]) : (& source i64)
      (let [local : i64 1]
        (& source local)))

Fix:
    Tie returned references to input lifetimes, preserve the source lifetime
    in annotations, or keep the reference inside the shorter scope.

See also:
    SPEC.md, \"Reference lifetimes\"; tests/safety/signature_lifetime_alias_local_return_reject.tl.
")

(define (diagnostic-explain-e0211) : String
  "E0211: resource ownership violation

Description:
    A cleanup-owning resource would be leaked, overwritten, moved out of its
    cleanup scope, or stored where cleanup cannot be guaranteed.

Minimal failing example:
    (import stdlib.sync)
    (import (sync.mutex i64) as mutex_i64)
    (define (bad [mutex : mutex_i64.Mutex]) : i64
      (let [guard : mutex_i64.Guard (mutex_i64.lock mutex)]
        (mutex_i64.get guard)))

Fix:
    Acquire cleanup-required resources with `with`, retain their owner through
    cleanup, and move or clean up an initialized owner before overwrite.

See also:
    SPEC.md, \"Cleanup ownership\"; tests/safety/sync_mutex_guard_let_reject.tl.
")

(define (diagnostic-explain-e0212) : String
  "E0212: arena ownership violation

Description:
    An arena control operation requires the live direct owner, but received an
    alias, shadowed value, ordinary handle, or missing owner proof.

Minimal failing example:
    (import stdlib.arena)
    (define (phase-of [owner : arena.Arena]) : arena.ArenaPhase
      (arena.phase owner))

Fix:
    Perform phase, rewind, and destroy operations where the direct owner is in
    scope. Do not pass or capture ordinary handles across owner boundaries.

See also:
    SPEC.md, \"Arena ownership\"; tests/safety/arena_phase_non_direct_owner_reject.tl.
")

(define (diagnostic-explain-e0213) : String
  "E0213: invalid pattern

Description:
    A match, tuple, struct, or box pattern has the wrong shape, contains a
    refutable subpattern where only binding is allowed, or is unreachable.

Minimal failing example:
    (defstruct Point (x i64) (y i64))
    (define (main [point : Point]) : i64
      (match point
        [(Point x y) (+ x y)]
        [_ 0]))

Fix:
    Use the pattern forms allowed for the scrutinee and context. Move value
    tests into nested matches, and remove arms hidden by an earlier wildcard.

See also:
    SPEC.md, \"Pattern matching\"; tests/safety/struct_match_pattern_unreachable_reject.tl.
")

(define (diagnostic-explain-e0214) : String
  "E0214: SPMD restriction

Description:
    An operation is not uniform, lane-safe, or supported in the current SPMD
    `foreach`, reduce, scan, broadcast, shuffle, or masked execution context.

Minimal failing example:
    (define (main [items : (__tl_dyn-array i64)] [count : i64]) : i64
      (let [sum : i64 0]
        (begin
          (foreach ([index : i64 0 count])
            (set! sum (+ sum (array-ref items index))))
          sum)))

Fix:
    Keep writes lane-local and contiguous, use supported scalar lane types, and
    move uniform control flow or side effects outside the SPMD region.

See also:
    SPEC.md, section 5.15; tests/safety/spmd_outer_mutation_reject.tl.
")

(define (diagnostic-explain-e0215) : String
  "E0215: invalid storage place

Description:
    An operation that mutates, borrows, replaces, or takes storage received a
    temporary, invalid projection, or place without the required ownership.

Minimal failing example:
    (defstruct Pair (x i64) (y i64))
    (define (main) : unit
      (__tl-project-set-field (Pair 1 2) x 3))

Fix:
    Bind the value to a mutable local or use a valid field/element projection
    rooted in owned storage before applying the place operation.

See also:
    SPEC.md, \"Places and assignment\"; tests/safety/struct_field_set_temporary_reject.tl.
")

(define (diagnostic-explain-e0216) : String
  "E0216: control-flow misuse

Description:
    `break` or `continue` appears without an enclosing scalar loop that it can
    target, or crosses a function/lambda boundary.

Minimal failing example:
    (define (main) : unit
      (break))

Fix:
    Put the operation directly inside the intended `while`, or return from a
    helper/lambda and let the enclosing loop decide whether to stop.

See also:
    SPEC.md, \"Loops\"; tests/safety/while_break_outside_reject.tl.
")

(define (diagnostic-explain-e0217) : String
  "E0217: thread-safety violation

Description:
    A spawned task or channel would carry a raw pointer, scoped arena value,
    reference, or other value whose ownership cannot safely cross the thread boundary.

Minimal failing example:
    (import stdlib.thread)
    (import (thread.handle i64) as thread_i64)
    (define (main) : i64
      (unsafe
        (let [pointer : (Ptr i64)
              (int->ptr (cast 0 : u64) : (Ptr i64))]
          (match (thread_i64.spawn
            (lambda () : i64 (cast (ptr->int pointer) : i64)))
            [(thread_i64.I64SpawnErr _) 0]
            [(thread_i64.I64SpawnOk worker)
              (match (thread_i64.join worker)
                [(thread_i64.I64JoinErr _) 0]
                [(thread_i64.I64JoinOk value) value])]))))

Fix:
    Transfer an owned thread-safe value, use an atomic arena where supported,
    and join before destroying shared ownership. Raw pointers need a reviewed
    unsafe synchronization design rather than safe capture.

See also:
    docs/concurrency-and-simd.md; tests/safety/thread_spawn_i64_raw_pointer_capture_reject.tl.
")

(define (diagnostic-explain-e0218) : String
  "E0218: compile-time constraint

Description:
    A form requires a compile-time type, count, or local capability, but the
    supplied value is runtime-only, negative, or otherwise unavailable then.

Minimal failing example:
    (define (make-items [count : i64]) : (Array i64 3)
      (make-array i64 count))

Fix:
    Supply the requested constant/type through a compile-time form, or use the
    dynamic runtime operation when the value is intentionally computed at runtime.

See also:
    SPEC.md, \"Compile-time evaluation\"; tests/safety/fixed_make_array_runtime_count_reject.tl.
")

(define (diagnostic-explain-e0219) : String
  "E0219: unsafe callable effect erasure

Description:
    A function or extern declared unsafe was used as a plain function value.
    The ordinary function-pointer type cannot retain its required unsafe-call
    effect, so storing, passing, returning, branching over, or capturing the
    value would allow a later safe call.

Minimal failing example:
    (unsafe (define (danger [value : i64]) : i64 value))
    (define (main) : i64
      (let [leaked : (-> i64 i64) (unsafe danger)]
        (leaked 42)))

Fix:
    Call the unsafe declaration directly inside the smallest explicit unsafe
    expression. To expose a safe callable, write a wrapper whose own body
    performs that explicit unsafe call and documents the required invariant.

See also:
    SPEC.md, \"(unsafe declaration)\"; tests/safety/unsafe_callable_value_launder_reject.tl.
")

(define (diagnostic-explain-ascii-fold-char [c : char]) : char
  (if (and (>= c 'A') (<= c 'Z'))
    (cast (+ (cast c : i64) 32) : char)
    c))

(define (diagnostic-explain-ascii-case-eq
  [left : (& left str)]
  [right : (& right str)]) : bool
  (let
    [left-n : i64 (string.string-length left)]
    [right-n : i64 (string.string-length right)]
    [index : i64 0]
    [same : bool (= left-n right-n)]
    (begin
      (while (and same (< index left-n))
        (begin
          (if (=
            (diagnostic-explain-ascii-fold-char (string.string-ref left index))
            (diagnostic-explain-ascii-fold-char (string.string-ref right index)))
            unit
            (set! same false))
          (set! index (+ index 1))))
      same)))

(define (diagnostic-explain-ascii-case-contains
  [haystack : (& haystack str)]
  [needle : (& needle str)]) : bool
  (let
    [haystack-n : i64 (string.string-length haystack)]
    [needle-n : i64 (string.string-length needle)]
    [start : i64 0]
    [found : bool (= needle-n 0)]
    (begin
      (while (and (not found) (<= (+ start needle-n) haystack-n))
        (let
          [offset : i64 0]
          [same : bool true]
          (begin
            (while (and same (< offset needle-n))
              (begin
                (if (=
                  (diagnostic-explain-ascii-fold-char
                    (string.string-ref haystack (+ start offset)))
                  (diagnostic-explain-ascii-fold-char
                    (string.string-ref needle offset)))
                  unit
                  (set! same false))
                (set! offset (+ offset 1))))
            (if same
              (set! found true)
              unit)))
        (set! start (+ start 1)))
      found)))

(define (diagnostic-explain-lookup [code : String]) : DiagnosticExplainLookup
  (cond
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-parse))
      (DiagnosticExplainDetailed (diagnostic-explain-e0100))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck))
      (DiagnosticExplainDetailed (diagnostic-explain-e0200))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-unbound-name))
      (DiagnosticExplainDetailed (diagnostic-explain-e0201))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-arity-mismatch))
      (DiagnosticExplainDetailed (diagnostic-explain-e0202))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-non-exhaustive-match))
      (DiagnosticExplainDetailed (diagnostic-explain-e0203))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-unknown-struct-field))
      (DiagnosticExplainDetailed (diagnostic-explain-e0204))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-region-escape))
      (DiagnosticExplainDetailed (diagnostic-explain-e0205))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-type-mismatch))
      (DiagnosticExplainDetailed (diagnostic-explain-e0206))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-borrow-violation))
      (DiagnosticExplainDetailed (diagnostic-explain-e0207))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-move-violation))
      (DiagnosticExplainDetailed (diagnostic-explain-e0208))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-unsafe-context))
      (DiagnosticExplainDetailed (diagnostic-explain-e0209))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-lifetime-mismatch))
      (DiagnosticExplainDetailed (diagnostic-explain-e0210))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-resource-ownership))
      (DiagnosticExplainDetailed (diagnostic-explain-e0211))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-arena-ownership))
      (DiagnosticExplainDetailed (diagnostic-explain-e0212))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-pattern))
      (DiagnosticExplainDetailed (diagnostic-explain-e0213))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-spmd))
      (DiagnosticExplainDetailed (diagnostic-explain-e0214))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-place))
      (DiagnosticExplainDetailed (diagnostic-explain-e0215))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-control-flow))
      (DiagnosticExplainDetailed (diagnostic-explain-e0216))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-thread-safety))
      (DiagnosticExplainDetailed (diagnostic-explain-e0217))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-comptime-constraint))
      (DiagnosticExplainDetailed (diagnostic-explain-e0218))]
    [(diagnostic-explain-ascii-case-eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-unsafe-callable-effect))
      (DiagnosticExplainDetailed (diagnostic-explain-e0219))]
    [else DiagnosticExplainUnknown]))

(define (diagnostic-explain-print-registry-row [index : i64]) : unit
  (io.print-format
    "{}: {}\n"
    (cdiag.compiler-diagnostic-code-registry-code index)
    (cdiag.compiler-diagnostic-code-registry-title index)))

(define (diagnostic-explain-list) : i64
  (let
    [index : i64 0]
    [count : i64 (cdiag.compiler-diagnostic-code-registry-count)]
    (begin
      (while (< index count)
        (begin
          (diagnostic-explain-print-registry-row index)
          (set! index (+ index 1))))
      0)))

(define (diagnostic-explain-search [term : String]) : i64
  (let
    [index : i64 0]
    [count : i64 (cdiag.compiler-diagnostic-code-registry-count)]
    [matches : i64 0]
    (begin
      (while (< index count)
        (let
          [code : String (cdiag.compiler-diagnostic-code-registry-code index)]
          [title : String (cdiag.compiler-diagnostic-code-registry-title index)]
          (match (diagnostic-explain-lookup (string.copy (& code)))
            [(DiagnosticExplainDetailed text)
              (if (or
                (diagnostic-explain-ascii-case-contains code term)
                (diagnostic-explain-ascii-case-contains title term)
                (diagnostic-explain-ascii-case-contains text term))
                (begin
                  (diagnostic-explain-print-registry-row index)
                  (set! matches (+ matches 1)))
                unit)]
            [DiagnosticExplainUnknown unit]))
        (set! index (+ index 1)))
      (if (> matches 0)
        0
        (begin
          (io.print-error
            (str_cat.str-cat "explain: no diagnostic codes match `" term "`\n"))
          1)))))

(define (diagnostic-explain-one [code : String]) : i64
  (match (diagnostic-explain-lookup (string.copy (& code)))
    [(DiagnosticExplainDetailed text)
      (begin
        (io.print-format "{}" text)
        0)]
    [DiagnosticExplainUnknown
      (begin
        (io.print-error
          (str_cat.str-cat "explain: unknown diagnostic code `" code "`\n"))
        1)]))

(define (diagnostic-explain-run-from [idx : i64] [count : i64]) : i64
  (cond
    [(= count (+ idx 1))
      (let
        [arg : String (io.arg idx)]
        (if (diagnostic-explain-ascii-case-eq arg "--list")
          (diagnostic-explain-list)
          (diagnostic-explain-one arg)))]
    [(= count (+ idx 2))
      (let
        [arg : String (io.arg idx)]
        [term : String (io.arg (+ idx 1))]
        (if (diagnostic-explain-ascii-case-eq arg "--search")
          (diagnostic-explain-search term)
          (begin
            (io.print-error (diagnostic-explain-help-text))
            1)))]
    [else
      (begin
        (io.print-error (diagnostic-explain-help-text))
        1)]))

(cfg
  test
  (define (diagnostic-explain-detailed-entry-ok? [code : String]) : bool
    (match (diagnostic-explain-lookup code)
      [(DiagnosticExplainDetailed text)
        (and
          (string.contains (& text) "Description:")
          (string.contains (& text) "Minimal failing example:")
          (string.contains (& text) "Fix:")
          (string.contains (& text) "See also:"))]
      [DiagnosticExplainUnknown false])))

(cfg
  test
  (define (diagnostic-explain-registry-entry-ok? [index : i64]) : bool
    (let
      [code : String (cdiag.compiler-diagnostic-code-registry-code index)]
      [title : String (cdiag.compiler-diagnostic-code-registry-title index)]
      (match (diagnostic-explain-lookup (string.copy (& code)))
        [(DiagnosticExplainDetailed text)
          (and
            (string.contains (& text) (& code))
            (string.contains (& text) (& title))
            (diagnostic-explain-detailed-entry-ok? code))]
        [DiagnosticExplainUnknown false]))))

(cfg
  test
  (define (diagnostic-explain-registry-complete?) : bool
    (let
      [index : i64 0]
      [count : i64 (cdiag.compiler-diagnostic-code-registry-count)]
      [ok : bool true]
      (begin
        (while (and ok (< index count))
          (begin
            (if (diagnostic-explain-registry-entry-ok? index)
              unit
              (set! ok false))
            (set! index (+ index 1))))
        ok))))

(cfg
  test
  (test
    diagnostic-explain-registry
    (unless
      (and
        (diagnostic-explain-registry-complete?)
        (diagnostic-explain-detailed-entry-ok? "e0207")
        (diagnostic-explain-ascii-case-contains
          (diagnostic-explain-e0208)
          "MOVE VIOLATION")
        (match (diagnostic-explain-lookup "E9999")
          [DiagnosticExplainUnknown true]
          [_ false]))
      (io.panic "explain: diagnostic registry test failed"))))