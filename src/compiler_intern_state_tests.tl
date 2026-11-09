;; Focused ownership, reset, and growth coverage for session-owned syntax ids.
(import stdlib.iterator)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import stdlib.test)
(import compiler_owned_view as owned_view)
(import compiler_allocation_profile as allocation_profile)
(import stdlib.arena)

;; Layout queries need the struct names unqualified. Lint does not count a use
;; inside `(type ...)`.
;; lint-allow: unused-import
(import compiler_intern_state.InternFreshLocalIdentity)

;; lint-allow: unused-import
(import compiler_intern_state.InternTemplateSourceIdentity)

(define (intern-identity-test-session [state : (& state ci.InternCompatState)]) : cis.InternStructuralSessionHandle
  (cis.intern-structural-session-handle-from-source-names
    (ci.intern-source-name-session-handle-from-state state)))

(define (intern-template-record-source-or
  [session : cis.InternStructuralSessionHandle]
  [raw : i64]
  [fallback : i64]) : i64
  (match (cis.intern-structural-session-template-source-record-for-raw
    session
    raw)
    [(Some record) record.source-name-id]
    [(No) fallback]))

(define (intern-fresh-record-components-match?
  [session : cis.InternStructuralSessionHandle]
  [raw : i64]
  [ordinal : i64]
  [source-name-id : i64]) : bool
  (match (cis.intern-structural-session-fresh-local-record-for-raw session raw)
    [(Some record)
      (and (= record.ordinal ordinal) (= record.source-name-id source-name-id))]
    [(No) false]))

(test
  compiler-intern-template-fresh-record-ownership
  (let
    [left : ci.InternCompatState (ci.intern-compat-state-new)]
    [right : ci.InternCompatState (ci.intern-compat-state-new)]
    [left-source : i64 (ci.intern-compat-state-intern (&mut left) "left-name")]
    [right-source : i64
      (ci.intern-compat-state-intern (&mut right) "right-name")]
    [left-session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& left))]
    [right-session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& right))]
    [template : cis.InternTemplateSourceIdentity
      (cis.intern-structural-session-template-source-identity
        left-session
        left-source)]
    [template-again : cis.InternTemplateSourceIdentity
      (cis.intern-structural-session-template-source-identity
        left-session
        left-source)]
    [fresh : cis.InternFreshLocalIdentity
      (cis.intern-structural-session-fresh-local-identity
        left-session
        17
        left-source)]
    [macro-definition : cis.InternMacroDefinitionIdentity
      (cis.intern-structural-session-macro-definition-identity
        left-session
        9
        left-source)]
    [macro-global : cis.InternMacroGlobalIdentity
      (cis.intern-structural-session-macro-global-identity
        left-session
        Legacy
        9
        left-source)]
    [macro-local : cis.InternMacroLocalIdentity
      (cis.intern-structural-session-macro-local-identity
        left-session
        macro-definition
        3
        left-source)]
    [right-template : cis.InternTemplateSourceIdentity
      (cis.intern-structural-session-template-source-identity
        right-session
        right-source)]
    [invalid-role-macro-global : i64
      (cis.intern-structural-key-raw
        (cis.intern-structural-session-key
          left-session
          (ci.intern-structural-kind-macro-global)
          4
          9
          left-source))]
    [malformed-template : i64
      (cis.intern-structural-key-raw
        (cis.intern-structural-session-key
          left-session
          (ci.intern-structural-kind-template-source)
          1
          0
          left-source))]
    [malformed-fresh : i64
      (cis.intern-structural-key-raw
        (cis.intern-structural-session-key
          left-session
          (ci.intern-structural-kind-fresh-local)
          17
          1
          left-source))]
    (test.assert-i64-eq
      (intern-template-source-identity-size)
      8
      "template identity remains one machine word")
    (test.assert-i64-eq
      (intern-fresh-local-identity-size)
      8
      "fresh-local identity remains one machine word")
    (test.assert-i64-eq
      (cis.intern-template-source-identity-raw template)
      (cis.intern-template-source-identity-raw template-again)
      "template records canonicalize identical components")
    (test.assert-i64-eq
      (intern-template-record-source-or
        left-session
        (cis.intern-template-source-identity-raw template)
        -1)
      left-source
      "template record round-trips its source component")
    (test.assert-true
      (intern-fresh-record-components-match?
        left-session
        (cis.intern-fresh-local-identity-raw fresh)
        17
        left-source)
      "fresh-local record round-trips ordinal and source")
    (test.assert-i64-eq
      (cis.intern-structural-session-syntax-source-name-id-or
        left-session
        (cis.intern-template-source-identity-raw template)
        -1)
      left-source
      "mixed renderer decodes a template source")
    (test.assert-i64-eq
      (cis.intern-structural-session-syntax-source-name-id-or
        left-session
        (cis.intern-fresh-local-identity-raw fresh)
        -1)
      left-source
      "mixed renderer decodes a fresh local")
    (test.assert-i64-eq
      (cis.intern-structural-session-syntax-source-name-id-or
        left-session
        (cis.intern-macro-global-identity-raw macro-global)
        -1)
      left-source
      "mixed renderer decodes a macro global")
    (test.assert-i64-eq
      (cis.intern-structural-session-syntax-source-name-id-or
        left-session
        (cis.intern-macro-local-identity-raw macro-local)
        -1)
      left-source
      "mixed renderer decodes a macro local")
    (test.assert-false
      (cis.intern-structural-session-template-source-id?
        right-session
        (cis.intern-template-source-identity-raw template))
      "template decoder rejects a wrong owner")
    (test.assert-false
      (cis.intern-structural-session-fresh-local-id?
        left-session
        (cis.intern-template-source-identity-raw template))
      "fresh-local decoder rejects the template kind")
    (test.assert-false
      (cis.intern-structural-session-template-source-id?
        left-session
        malformed-template)
      "template decoder rejects a populated reserved lane")
    (test.assert-i64-eq
      (cis.intern-structural-session-syntax-source-name-id-or
        left-session
        malformed-template
        -1)
      -1
      "mixed renderer rejects a malformed template")
    (test.assert-false
      (cis.intern-structural-session-fresh-local-id?
        left-session
        malformed-fresh)
      "fresh-local decoder rejects a populated reserved lane")
    (test.assert-true
      (match (cis.intern-structural-session-macro-global-record-for-raw
        left-session
        invalid-role-macro-global)
        [(No) true]
        [(Some _) false])
      "macro-global decoder rejects an unknown role code")
    (test.assert-i64-eq
      (cis.intern-structural-session-syntax-source-name-id-or
        left-session
        invalid-role-macro-global
        -1)
      -1
      "mixed renderer rejects an unknown macro-global role code")
    (test.assert-i64-eq
      (cis.intern-structural-session-syntax-source-name-id-or
        right-session
        (cis.intern-template-source-identity-raw template)
        -1)
      -1
      "mixed renderer rejects a wrong owner")
    (test.assert-false
      (=
        (cis.intern-template-source-identity-raw template)
        (cis.intern-template-source-identity-raw right-template))
      "different sessions produce distinct process-local handles")))

(test
  compiler-intern-fresh-local-deliberate-hash-collision
  (let
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    [source : i64 (ci.intern-compat-state-intern (&mut state) "collision-name")]
    [session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& state))]
    ;; The initial map has 512 slots. Its lower hash bits for equal kind,
    ;; middle, and right repeat when this left/ordinal lane differs by 512.
    [first : i64
      (cis.intern-fresh-local-identity-raw
        (cis.intern-structural-session-fresh-local-identity session 0 source))]
    [colliding : i64
      (cis.intern-fresh-local-identity-raw
        (cis.intern-structural-session-fresh-local-identity session 512 source))]
    (test.assert-false (= first colliding) "colliding records do not alias")
    (test.assert-true
      (intern-fresh-record-components-match? session first 0 source)
      "first colliding record remains reachable")
    (test.assert-true
      (intern-fresh-record-components-match? session colliding 512 source)
      "linear probing retains the colliding record")))

(test
  compiler-intern-template-fresh-stale-reset
  (let
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    [source : i64 (ci.intern-compat-state-intern (&mut state) "reset-name")]
    [stale-session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& state))]
    [stale-template : i64
      (cis.intern-template-source-identity-raw
        (cis.intern-structural-session-template-source-identity
          stale-session
          source))]
    (ci.intern-compat-state-reset! (&mut state))
    (let
      [next-source : i64
        (ci.intern-compat-state-intern (&mut state) "reset-name")]
      [next-session : cis.InternStructuralSessionHandle
        (intern-identity-test-session (& state))]
      [next-template : i64
        (cis.intern-template-source-identity-raw
          (cis.intern-structural-session-template-source-identity
            next-session
            next-source))]
      (test.assert-false
        (cis.intern-structural-session-valid? stale-session)
        "reset invalidates the captured structural session")
      (test.assert-i64-eq
        (intern-template-record-source-or stale-session stale-template -1)
        -1
        "stale template handle fails closed")
      (test.assert-false
        (= stale-template next-template)
        "reset re-owners newly canonicalized records"))))

(test
  compiler-intern-fresh-local-growth-beyond-pool-capacity
  (let
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    [source : i64 (ci.intern-compat-state-intern (&mut state) "growth-name")]
    [session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& state))]
    [_template : cis.InternTemplateSourceIdentity
      (cis.intern-structural-session-template-source-identity session source)]
    [limit : i64 131073]
    [last : i64 -1]
    (for [index (iterator.range 0 limit)]
      (set!
        last
        (cis.intern-fresh-local-identity-raw
          (cis.intern-structural-session-fresh-local-identity
            session
            index
            source))))
    (test.assert-true
      (intern-fresh-record-components-match? session last (- limit 1) source)
      "the record after the old 131072 pool limit round-trips")
    (test.assert-i64-eq
      (cis.intern-structural-session-kind-count
        session
        (ci.intern-structural-kind-fresh-local))
      limit
      "fresh-local kind count includes every growth insertion")
    (test.assert-i64-eq
      (cis.intern-structural-session-kind-count
        session
        (ci.intern-structural-kind-template-source))
      1
      "template-source kind count remains independent")
    (test.assert-i64-eq
      (intern-structural-session-record-count session)
      (+ limit 1)
      "structural record count is independent of source-name capacity")
    (test.assert-true
      (>= (intern-structural-session-record-capacity session) limit)
      "record columns grow to retain collision-probed insertions")
    (test.assert-i64-eq
      (ci.intern-structural-record-slot-bytes)
      37
      "each reserved structural record slot uses 37 payload bytes")
    (test.assert-true
      (>=
        (intern-structural-session-record-reserved-bytes session)
        (* limit (ci.intern-structural-record-slot-bytes)))
      "reserved-byte metric covers all retained records")))

(cfg
  test
  (define (intern-template-source-identity-size) : i64
    (comptime (size-of (type InternTemplateSourceIdentity)))))

(cfg
  test
  (define (intern-fresh-local-identity-size) : i64
    (comptime (size-of (type InternFreshLocalIdentity)))))

(define (intern-structural-session-key-middle
  [handle : cis.InternStructuralSessionHandle]
  [key : cis.InternStructuralKey]) : i64
  (if (cis.intern-structural-session-key-owned? handle key)
    (let
      [session : ci.InternSourceNameSession
        (cis.intern-structural-session-handle-session handle)]
      [table : ci.InternStructuralTable
        (owned_view.compiler-owned-array-element-shared-view
          session.structural-table-cell
          0)]
      (array-ref table.middles (cis.intern-structural-session-key-index key)))
    (ci.tl_oob_abort)))

(define (intern-structural-session-record-count
  [handle : cis.InternStructuralSessionHandle]) : i64
  (if (not (cis.intern-structural-session-valid? handle))
    0
    (let
      [session : ci.InternSourceNameSession
        (cis.intern-structural-session-handle-session handle)]
      [table : ci.InternStructuralTable
        (owned_view.compiler-owned-array-element-shared-view
          session.structural-table-cell
          0)]
      table.len)))

(define (intern-structural-session-record-capacity
  [handle : cis.InternStructuralSessionHandle]) : i64
  (if (not (cis.intern-structural-session-valid? handle))
    0
    (let
      [session : ci.InternSourceNameSession
        (cis.intern-structural-session-handle-session handle)]
      [table : ci.InternStructuralTable
        (owned_view.compiler-owned-array-element-shared-view
          session.structural-table-cell
          0)]
      (array-length table.kinds))))

(define (intern-structural-session-record-reserved-bytes
  [handle : cis.InternStructuralSessionHandle]) : i64
  (*
    (intern-structural-session-record-capacity handle)
    (ci.intern-structural-record-slot-bytes)))

;; Snapshot exact storage and contents, rather than hashes, so a read-only
;; lookup cannot hide record growth, cache promotion or identity allocation.
(defmacro (intern-lookup-image-array!
  [image : Expr]
  [cursor : Expr]
  [items : Expr]
  [width : Expr]) : unit
  `(let
    [address : u64 (ci.intern-i64-array-address ,items)]
    [count : i64 (array-length ,items)]
    (set! (array-ref ,image ,cursor) (cast address : i64))
    (+= ,cursor 1)
    (set! (array-ref ,image ,cursor) count)
    (+= ,cursor 1)
    (for [index (iterator.range 0 (* count ,width))]
      (set!
        (array-ref ,image ,cursor)
        (cast (ci.intern-active-u8-ref address index) : i64))
      (+= ,cursor 1))))

(define (intern-lookup-image [state : (& state ci.InternCompatState)]) : (__tl_dyn-array
    i64)
  (let
    [table : (& state ci.InternStructuralTable)
      (& (array-ref state.structural-table-cell 0))]
    [image : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (+
          16
          30
          (* (array-length table.kinds) 1)
          (* (array-length table.lefts) 8)
          (* (array-length table.middles) 8)
          (* (array-length table.rights) 8)
          (*
            (array-length table.rendered-names)
            (comptime (size-of (type String))))
          (* (array-length table.generated-symbol-handles) 8)
          (* (array-length table.map-slots) 8)
          (* (array-length table.structural-cache-raws) 8)
          (* (array-length state.table-id) 8)
          (* (array-length state.reset-generation) 8)
          (* (array-length state.pool-count) 8)
          (* (array-length state.generated-next-id) 8)
          (* (array-length state.persistent-arena) 8)
          (* (array-length state.persistent-arena-floor-mark) 8)
          (*
            (array-length
              (__tl-project-field
                (array-ref ci.intern-structural-table-cell 0)
                structural-cache-raws))
            8)))]
    [cursor : i64 0]
    (set! (array-ref image cursor) table.owner)
    (+= cursor 1)
    (set! (array-ref image cursor) table.len)
    (+= cursor 1)
    (set! (array-ref image cursor) table.records-arena)
    (+= cursor 1)
    (set! (array-ref image cursor) table.map-arena)
    (+= cursor 1)
    (set! (array-ref image cursor) ci.intern-pool-count)
    (+= cursor 1)
    (set! (array-ref image cursor) ci.intern-generated-next-id)
    (+= cursor 1)
    (set! (array-ref image cursor) ci.intern-active-table-id-value)
    (+= cursor 1)
    (set! (array-ref image cursor) ci.intern-reset-generation)
    (+= cursor 1)
    (set! (array-ref image cursor) ci.intern-active-structural-owner)
    (+= cursor 1)
    (set! (array-ref image cursor) ci.intern-active-structural-prefix)
    (+= cursor 1)
    (set! (array-ref image cursor) ci.intern-active-structural-len)
    (+= cursor 1)
    (set!
      (array-ref image cursor)
      (cast ci.intern-active-structural-kinds-address : i64))
    (+= cursor 1)
    (set!
      (array-ref image cursor)
      (cast ci.intern-active-structural-lefts-address : i64))
    (+= cursor 1)
    (set!
      (array-ref image cursor)
      (cast ci.intern-active-structural-middles-address : i64))
    (+= cursor 1)
    (set!
      (array-ref image cursor)
      (cast ci.intern-active-structural-rights-address : i64))
    (+= cursor 1)
    (set!
      (array-ref image cursor)
      (cast ci.intern-active-structural-cache-raws-address : i64))
    (+= cursor 1)
    (intern-lookup-image-array! image cursor table.kinds 1)
    (intern-lookup-image-array! image cursor table.lefts 8)
    (intern-lookup-image-array! image cursor table.middles 8)
    (intern-lookup-image-array! image cursor table.rights 8)
    (intern-lookup-image-array!
      image
      cursor
      table.rendered-names
      (comptime (size-of (type String))))
    (intern-lookup-image-array! image cursor table.generated-symbol-handles 8)
    (intern-lookup-image-array! image cursor table.map-slots 8)
    (intern-lookup-image-array! image cursor table.structural-cache-raws 8)
    (intern-lookup-image-array! image cursor state.table-id 8)
    (intern-lookup-image-array! image cursor state.reset-generation 8)
    (intern-lookup-image-array! image cursor state.pool-count 8)
    (intern-lookup-image-array! image cursor state.generated-next-id 8)
    (intern-lookup-image-array! image cursor state.persistent-arena 8)
    (intern-lookup-image-array!
      image
      cursor
      state.persistent-arena-floor-mark
      8)
    (intern-lookup-image-array!
      image
      cursor
      (__tl-project-field
        (array-ref ci.intern-structural-table-cell 0)
        structural-cache-raws)
      8)
    (test.assert-i64-eq cursor (array-length image) "complete snapshot")
    image))

(define (intern-lookup-unchanged!
  [state : (& state ci.InternCompatState)]
  [session : cis.InternStructuralSessionHandle]
  [left : i64]
  [middle : i64]
  [right : i64]
  [expected : i64]) : unit
  (let
    [before : (__tl_dyn-array i64) (intern-lookup-image state)]
    [current : i64 (arena.tl_arena_current)]
    [persistent : i64 (array-ref state.persistent-arena 0)]
    [table : (& state ci.InternStructuralTable)
      (& (array-ref state.structural-table-cell 0))]
    [current-bump : i64
      (allocation_profile.compiler-allocation-profile-arena-bump-bytes current)]
    [persistent-bump : i64
      (allocation_profile.compiler-allocation-profile-arena-bump-bytes
        persistent)]
    [records-bump : i64
      (allocation_profile.compiler-allocation-profile-arena-bump-bytes
        table.records-arena)]
    [map-bump : i64
      (allocation_profile.compiler-allocation-profile-arena-bump-bytes
        table.map-arena)]
    [actual : i64
      (cis.intern-structural-session-find-composite-triple-raw
        session
        left
        middle
        right)]
    [current-after : i64
      (allocation_profile.compiler-allocation-profile-arena-bump-bytes current)]
    [persistent-after : i64
      (allocation_profile.compiler-allocation-profile-arena-bump-bytes
        persistent)]
    [records-after : i64
      (allocation_profile.compiler-allocation-profile-arena-bump-bytes
        table.records-arena)]
    [map-after : i64
      (allocation_profile.compiler-allocation-profile-arena-bump-bytes
        table.map-arena)]
    [after : (__tl_dyn-array i64) (intern-lookup-image state)]
    (test.assert-i64-eq actual expected "exact hit or missing sentinel")
    (test.assert-i64-eq
      current-bump
      current-after
      "lookup does not allocate in current arena")
    (test.assert-i64-eq
      persistent-bump
      persistent-after
      "lookup does not allocate persistent records")
    (test.assert-i64-eq
      records-bump
      records-after
      "lookup does not allocate record arena")
    (test.assert-i64-eq map-bump map-after "lookup does not allocate map arena")
    (test.assert-i64-eq
      (array-length before)
      (array-length after)
      "storage lengths unchanged")
    (for [index (iterator.range 0 (array-length before))]
      (test.assert-i64-eq
        (array-ref before index)
        (array-ref after index)
        "storage and cache bytes unchanged"))))

(test
  compiler-intern-triple-lookup-only
  (let
    [saved : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    [session : cis.InternStructuralSessionHandle
      (intern-identity-test-session (& state))]
    [left : i64 9223372036854775807]
    [middle : i64 -9223372036854775807]
    [right : i64 -1]
    [first : i64
      (cis.intern-structural-key-raw
        (cis.intern-structural-session-composite-triple-key
          session
          left
          middle
          right))]
    [table : (& state ci.InternStructuralTable)
      (& (array-ref state.structural-table-cell 0))]
    [bucket : i64
      (ci.intern-structural-table-first-slot
        table
        (ci.intern-structural-kind-triple)
        left
        middle
        right)]
    [other : i64 0]
    (while (not
      (=
        bucket
        (ci.intern-structural-table-first-slot
          table
          (ci.intern-structural-kind-triple)
          other
          middle
          right)))
      (+= other 1))
    (let
      [second : i64
        (cis.intern-structural-key-raw
          (cis.intern-structural-session-composite-triple-key
            session
            other
            middle
            right))]
      (test.assert-false
        (= first second)
        "colliding full-width triples remain distinct")
      ;; Inactive owner: lookup must not install or touch the active cache.
      (intern-lookup-unchanged! (& state) session left middle right first)
      (intern-lookup-unchanged! (& state) session other middle right second)
      (intern-lookup-unchanged! (& state) session left middle 0 -1)
      (ci.intern-compat-state-install! (& state))
      ;; Active owner: no compatibility cache promotion, on hits or misses.
      (intern-lookup-unchanged! (& state) session left middle right first)
      (intern-lookup-unchanged! (& state) session other middle right second)
      (intern-lookup-unchanged! (& state) session left middle 0 -1))
    (ci.intern-compat-state-install! (& saved))
    (ci.intern-compat-state-reset! (&mut state))
    (test.assert-false
      (cis.intern-structural-session-valid? session)
      "reset rejects stale session")
    (let
      [fresh : cis.InternStructuralSessionHandle
        (intern-identity-test-session (& state))]
      (intern-lookup-unchanged! (& state) fresh left middle right -1))))