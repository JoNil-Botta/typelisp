;; compiler_intern_tests.tl - White-box tests for the interner: syntax ids,
;; id-space capacity, generated names, slices, persistent arenas, resets,
;; source-name sessions and qualified metadata.
(import compiler_intern as ci)
(import compiler_str_cat as str_cat)
(import stdlib.string)

;; Layout queries need the struct names unqualified. Lint does not count a use
;; inside `(type ...)`.
;; lint-allow: unused-import
(import compiler_intern.InternId)

;; lint-allow: unused-import
(import compiler_intern.InternSyntaxId)

(cfg
  test
  (define (intern-id-size) : i64
    (comptime (size-of (type InternId)))))

(cfg
  test
  (define (intern-syntax-id-size) : i64
    (comptime (size-of (type InternSyntaxId)))))

(define (intern-compat-state-qualified-last-slash
  [state : (& state ci.InternCompatState)]
  [id : i64]) : i64
  (cast (array-ref state.pool-last-slash-slots id) : i64))

(define (intern-qualified-module [id : i64]) : String
  (let
    [module-id : i64 (ci.intern-qualified-module-id id)]
    (if (< module-id 0)
      ""
      (ci.intern-str module-id))))

(define (intern-qualified-metadata-case-ok?
  [id : i64]
  [qualified : bool]
  [last-slash : i64]
  [module-name : String]
  [base-name : String]) : bool
  (and
    (= (ci.intern-qualified-last-slash id) last-slash)
    (= (ci.intern-qualified? id) qualified)
    (ci.intern-private-string-eq (intern-qualified-module id) module-name)
    (ci.intern-private-string-eq (ci.intern-qualified-base id) base-name)))

(define (intern-syntax-id-tests-ok?) : bool
  (begin
    (ci.intern-reset!)
    (let
      [source : ci.InternId (ci.intern-source-slice-id "pkg/name" 0 8)]
      [source-raw : i64 (ci.intern-id-value source)]
      [source-syntax : ci.InternSyntaxId
        (ci.intern-syntax-id-from-renderable source)]
      [generated : ci.InternId
        (ci.intern-id-from-renderable
          (ci.intern-generated-canonical-name "generated-name"))]
      [ok : bool
        (and
          (= (ci.intern-syntax-id-value source-syntax) source-raw)
          (ci.intern-private-string-eq
            (ci.intern-syntax-id-text source-syntax)
            "pkg/name")
          (ci.intern-private-string-eq
            (ci.intern-syntax-id-text
              (ci.intern-syntax-id-from-renderable generated))
            "generated-name"))]
      (begin
        (ci.intern-reset!)
        ok))))

;; The pool capacity remains a power-of-two storage and lookup-map contract.
;; Structural identities are session records and deliberately absent here.
(define (intern-id-space-capacity-tests-ok?) : bool
  (begin
    (ci.intern-reset!)
    (let
      [capacity : i64 (ci.intern-capacity)]
      [ok : bool
        (and
          ;; A power of two, so `intern-bucket` masks instead of dividing.
          (> capacity 0)
          (= (bit-and capacity (- capacity 1)) 0)
          ;; Each dedup map has to outsize the lane it indexes. A map smaller than
          ;; its lane cannot hold a full lane, and the overflow is an abort inside
          ;; the probe loop, not a resize.
          (>= (array-length ci.intern-map-id-slots) capacity)
          (>= ci.intern-generated-map-capacity capacity)
          ;; A renderable id is a pool id and nothing else.
          (ci.intern-renderable-id? (- capacity 1))
          (not (ci.intern-renderable-id? capacity))
          ;; Both lanes address the one pool: source ids grow up from zero and
          ;; generated ids grow down from capacity-1, so the capacity is the sum
          ;; the two lanes must fit in, and they meet only when it is exhausted.
          (= (ci.intern-pool-len) 0)
          (= (ci.intern-generated-count) 0)
          (= (ci.intern "id-space-lane-probe") 0)
          (= (ci.intern-syntax-source-name-id-or 0 -1) 0)
          (ci.intern-private-string-eq
            (ci.intern-syntax-name-text-or capacity "missing")
            "missing")
          (= (ci.intern-generated-name "id-space-lane-probe") (- capacity 1))
          (= (ci.intern-generated-id-at-allocation-index 0) (- capacity 1))
          (= (ci.intern-pool-len) 1)
          (= (ci.intern-generated-count) 1))]
      (begin
        (ci.intern-reset!)
        ok))))

(define (intern-generated-name-tests-ok?) : bool
  (begin
    (ci.intern-reset!)
    (let
      [source-id : i64 (ci.intern "generated-source-anchor")]
      [module-id : i64 (ci.intern "generated-module")]
      [base-id : i64 (ci.intern "generated-base")]
      [dotted-prefix-id : i64 (ci.intern "generated-base.Variant")]
      [dotted-tail-id : i64 (ci.intern "Variant.Item")]
      [source-len : i64 (ci.intern-pool-len)]
      [opaque-id : i64
        (with-scratch
          (let
            [temporary : String (ci.intern-substring "xxhygiene/localyy" 2 13)]
            (ci.intern-generated-name temporary)))]
      [opaque-again-id : i64 (ci.intern-generated-name "hygiene/local")]
      [duplicate-display-id : i64
        (ci.intern-generated-name
          (ci.intern-substring "xxgenerated-source-anchorzz" 2 23))]
      [qualified-id : i64
        (ci.intern-generated-qualified-name
          "generated-module/generated-base"
          module-id
          base-id)]
      [dotted-id : i64
        (ci.intern-generated-dotted-name
          "generated-base.Variant.Item"
          base-id
          dotted-prefix-id
          dotted-tail-id)]
      [ok : bool true]
      (begin
        (set!
          ok
          (and
            ok
            (= (ci.intern-pool-len) source-len)
            (= opaque-id (- (ci.intern-capacity) 1))
            (= opaque-again-id (- (ci.intern-capacity) 2))
            (= duplicate-display-id (- (ci.intern-capacity) 3))
            (= qualified-id (- (ci.intern-capacity) 4))
            (= dotted-id (- (ci.intern-capacity) 5))
            (= (ci.intern-generated-count) 5)
            (= (ci.intern-generated-id-at-allocation-index 0) opaque-id)
            (= (ci.intern-generated-id-at-allocation-index 4) dotted-id)
            (= (ci.intern-generated-id-at-allocation-index -1) -1)
            (= (ci.intern-generated-id-at-allocation-index 5) -1)
            (not (= opaque-id opaque-again-id))
            (ci.intern-private-string-eq
              (ci.intern-str opaque-id)
              "hygiene/local")
            (intern-qualified-metadata-case-ok?
              opaque-id
              false
              -1
              ""
              "hygiene/local")
            (intern-qualified-metadata-case-ok?
              qualified-id
              true
              16
              "generated-module"
              "generated-base")
            (= (ci.intern-first-dot dotted-id) 14)
            (= (ci.intern-leading-dot-id dotted-id) base-id)
            (= (ci.intern-dotted-prefix-id dotted-id) dotted-prefix-id)
            (= (ci.intern-dotted-tail-id dotted-id) dotted-tail-id)
            (ci.intern-dotted? dotted-id)
            (not (ci.intern-qualified? dotted-id))))
        (match (ci.intern-lookup "hygiene/local")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (match (ci.intern-lookup "generated-module/generated-base")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (unless (= (ci.intern-pool-len) source-len) (set! ok false))
        (match (ci.intern-lookup "generated-base.Variant.Item")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (match (ci.intern-lookup "generated-source-anchor")
          [(InternLookupFound found-id)
            (unless (= found-id source-id) (set! ok false))]
          [(InternLookupMissing) (set! ok false)])
        (let
          [canonical-id : i64
            (ci.intern-generated-canonical-name "computed-name")]
          [canonical-again-id : i64
            (ci.intern-generated-canonical-name
              (ci.intern-substring "xxcomputed-nameyy" 2 13))]
          [canonical-dotted-id : i64
            (ci.intern-generated-canonical-dotted-name
              "generated-base.Variant.Item"
              base-id
              dotted-prefix-id
              dotted-tail-id)]
          [canonical-dotted-again-id : i64
            (ci.intern-generated-canonical-dotted-name
              "generated-base.Variant.Item"
              base-id
              dotted-prefix-id
              dotted-tail-id)]
          [canonical-qualified-id : i64
            (ci.intern-generated-canonical-qualified-name
              "computed-name"
              module-id
              base-id)]
          [canonical-qualified-again-id : i64
            (ci.intern-generated-canonical-qualified-name
              "computed-name"
              module-id
              base-id)]
          (begin
            (set!
              ok
              (and
                ok
                (= canonical-id canonical-again-id)
                (= (ci.intern-generated-count) 8)
                (ci.intern-generated-canonical-id? canonical-id)
                (ci.intern-generated-canonical-id? canonical-dotted-id)
                (ci.intern-generated-canonical-id? canonical-qualified-id)
                (not (ci.intern-generated-canonical-id? opaque-id))
                (= canonical-dotted-id canonical-dotted-again-id)
                (= (ci.intern-leading-dot-id canonical-dotted-id) base-id)
                (=
                  (ci.intern-dotted-prefix-id canonical-dotted-id)
                  dotted-prefix-id)
                (= canonical-qualified-id canonical-qualified-again-id)
                (not (= canonical-qualified-id canonical-id))
                (intern-qualified-metadata-case-ok?
                  canonical-qualified-id
                  true
                  -1
                  "generated-module"
                  "generated-base")))
            (match (ci.intern-generated-canonical-lookup "computed-name")
              [(InternLookupFound found-id)
                (unless (= found-id canonical-id) (set! ok false))]
              [(InternLookupMissing) (set! ok false)])
            (match (ci.intern-lookup-content "computed-name")
              [(InternLookupFound _) (set! ok false)]
              [(InternLookupMissing) unit])
            (let
              [source-observed-id : i64 (ci.intern "computed-name")]
              (begin
                (set!
                  ok
                  (and
                    ok
                    (= canonical-id (- (ci.intern-capacity) 6))
                    (= source-observed-id source-len)
                    (not (= source-observed-id canonical-id))))
                (match (ci.intern-lookup-content "computed-name")
                  [(InternLookupFound found-id)
                    (unless (= found-id source-observed-id) (set! ok false))]
                  [(InternLookupMissing) (set! ok false)])))))
        (ci.intern-reset-to! source-len)
        (let
          [after-reset-to-id : i64 (ci.intern-generated-name "after/reset-to")]
          (begin
            (set!
              ok
              (and
                ok
                (= (ci.intern-pool-len) source-len)
                (= after-reset-to-id (- (ci.intern-capacity) 1))
                (ci.intern-private-string-eq
                  (ci.intern-str after-reset-to-id)
                  "after/reset-to")))
            unit))
        (ci.intern-reset!)
        (let
          [after-reset-id : i64 (ci.intern-generated-name "after/reset")]
          (begin
            (set!
              ok
              (and
                ok
                (= (ci.intern-pool-len) 0)
                (= after-reset-id (- (ci.intern-capacity) 1))
                (ci.intern-private-string-eq
                  (ci.intern-str after-reset-id)
                  "after/reset")))
            unit))
        (ci.intern-reset!)
        ok))))

(define (intern-slice-tests-ok?) : bool
  (begin
    (ci.intern-reset!)
    (let
      [slice-source : String "alpha beta alpha pkg/name"]
      [slice-alpha : i64 (ci.intern-slice slice-source 0 5)]
      [slice-beta : i64 (ci.intern-slice slice-source 6 4)]
      [slice-alpha-again : i64 (ci.intern-slice slice-source 11 5)]
      [slice-qualified : i64 (ci.intern-slice slice-source 17 8)]
      [long-slice-source : String "xxmultiword-hash-namezz"]
      [long-full : i64 (ci.intern "multiword-hash-name")]
      [long-slice : i64 (ci.intern-slice long-slice-source 2 19)]
      [ok : bool
        (and
          (= slice-alpha slice-alpha-again)
          (not (= slice-alpha slice-beta))
          (= long-full long-slice)
          (ci.intern-private-string-eq
            (ci.intern-str long-slice)
            "multiword-hash-name")
          (ci.intern-private-string-eq (ci.intern-str slice-alpha) "alpha")
          (intern-qualified-metadata-case-ok?
            slice-qualified
            true
            3
            "pkg"
            "name"))]
      (begin
        (ci.intern-reset!)
        ok))))

(define (intern-persistent-arena-tests-ok?) : bool
  (begin
    (ci.intern-reset!)
    (let
      [id : i64
        (with-scratch
          (let
            [name : String (ci.intern-substring "persist/entry" 0 13)]
            (ci.intern name)))]
      [again : i64 (ci.intern "persist/entry")]
      [ok : bool
        (and
          (= id again)
          (ci.intern-private-string-eq (ci.intern-str id) "persist/entry")
          (intern-qualified-metadata-case-ok? id true 7 "persist" "entry"))]
      (begin
        (ci.intern-reset!)
        ok))))

(define (intern-state-arena-growth-source
  [chunk-size : i64]
  [max-iterations : i64]) : String
  (let
    [source-length : i64 (+ chunk-size max-iterations)]
    [buf : (__tl_dyn-array u8) (__tl_make-array u8 source-length)]
    [i : i64 0]
    (begin
      (while (< i source-length)
        (begin
          (set! (array-ref buf i) (cast (bit-and i 255) : u8))
          (set! i (+ i 1))))
      (unsafe
        (string-from-bytes
          (ptr-cast (__tl_array-data buf) : (Ptr u8))
          source-length)))))

;; Record columns and the map grow into generation arenas (#8392). Growth
;; keeps identities, kinds through 255, rendered names and generated-role
;; handles; floor and full persistent resets release both generations; a
;; logical reset keeps them for reuse; two states grow and reset independently.
(define (intern-structural-generation-table
  [state : (& state ci.InternCompatState)]) : ci.InternStructuralTable
  (ci.intern-array-shared-view state.structural-table-cell 0))

(define (intern-structural-generation-fill!
  [state : (&mut state ci.InternCompatState)]
  [base : i64]
  [count : i64]) : i64
  (let
    [index : i64 0]
    [first : i64 0]
    (begin
      (while (< index count)
        (let
          [raw : i64
            (ci.intern-structural-table-intern
              (&mut state.structural-table-cell)
              (ci.intern-structural-kind-pair)
              (+ base index)
              0
              (+ (* base 2) index))]
          (begin
            (when (= index 0) (set! first raw))
            (set! index (+ index 1)))))
      first)))

;; A reset clears the map and cache slots of the records the structural table
;; held, which must leave every slot zero as a full clear does (#8520). The
;; by-record path runs after the map grew; a table holding many records for its
;; capacity takes the full clear. A pair cached before a reset must not answer
;; after it: the record columns keep their old contents, so a surviving cache
;; slot would return the previous owner's raw.
(define (intern-structural-table-cleared?) : bool
  (let
    [table : ci.InternStructuralTable
      (ci.intern-array-shared-view ci.intern-structural-table-cell 0)]
    [clear? : bool (= table.len 0)]
    [index : i64 0]
    (begin
      (while (< index (array-length table.map-slots))
        (begin
          (if (= (array-ref table.map-slots index) 0)
            unit
            (set! clear? false))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index (array-length table.structural-cache-raws))
        (begin
          (if (= (array-ref table.structural-cache-raws index) 0)
            unit
            (set! clear? false))
          (set! index (+ index 1))))
      clear?)))

;; Pairs and triples through the composite paths, which write the cache.
(define (intern-structural-reset-fill! [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (ci.intern-composite-pair-id (+ 1000000 index) (+ 2000000 index))
        (if (= (% index 3) 0)
          (begin
            (ci.intern-composite-triple-id
              (+ 3000000 index)
              index
              (+ 4000000 index))
            unit)
          unit)
        (set! index (+ index 1))))))

(define (intern-structural-table-by-record-reset?) : bool
  (let
    [table : ci.InternStructuralTable
      (ci.intern-array-shared-view ci.intern-structural-table-cell 0)]
    (<
      (* table.len 8)
      (+
        (array-length table.map-slots)
        (array-length table.structural-cache-raws)))))

(define (intern-structural-reset-tests-ok?) : bool
  (begin
    (ci.intern-reset!)
    (intern-structural-reset-fill! 300)
    (let
      [pair : i64 (ci.intern-composite-pair-id 1000005 2000005)]
      [triple : i64 (ci.intern-composite-triple-id 3000006 6 4000006)]
      [table : ci.InternStructuralTable
        (ci.intern-array-shared-view ci.intern-structural-table-cell 0)]
      [grown? : bool (>= (array-length table.map-slots) 1024)]
      [by-record? : bool (intern-structural-table-by-record-reset?)]
      [used? : bool (not (intern-structural-table-cleared?))]
      (begin
        (ci.intern-reset!)
        (let
          [small-clear? : bool (intern-structural-table-cleared?)]
          [pair-again : i64 (ci.intern-composite-pair-id 1000005 2000005)]
          [triple-again : i64 (ci.intern-composite-triple-id 3000006 6 4000006)]
          (begin
            (ci.intern-reset!)
            (intern-structural-reset-fill! 40000)
            (let
              [full? : bool (not (intern-structural-table-by-record-reset?))]
              (begin
                (ci.intern-reset!)
                (and
                  grown?
                  by-record?
                  used?
                  small-clear?
                  (not (= pair-again pair))
                  (not (= triple-again triple))
                  full?
                  (intern-structural-table-cleared?))))))))))

(define (intern-structural-generation-tests-ok?) : bool
  (let
    [live : i64 (ci.intern-structural-generations-live)]
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    [other : ci.InternCompatState (ci.intern-compat-state-new)]
    [left : i64 (ci.intern-compat-state-intern (&mut state) "generation/left")]
    [right : i64
      (ci.intern-compat-state-intern (&mut state) "generation/right")]
    [pair : i64
      (ci.intern-compat-state-composite-pair-id (&mut state) left right)]
    [_name : String
      (ci.intern-compat-state-composite-rendered-name-record!
        (&mut state)
        pair
        "generation/left+right")]
    [wide : i64
      (ci.intern-structural-table-intern
        (&mut state.structural-table-cell)
        255
        left
        7
        right)]
    [component : i64
      (ci.intern-compat-state-intern (&mut state) "generation/component")]
    [role : i64
      (ci.intern-compat-state-generated-role-symbol-id
        (&mut state)
        (ci.intern-generated-symbol-role-lambda)
        component)]
    [other-pair : i64
      (ci.intern-compat-state-composite-pair-id (&mut other) 3 4)]
    [initial : ci.InternStructuralTable
      (intern-structural-generation-table (& state))]
    [initial-records : i64 initial.records-arena]
    [initial-map : i64 initial.map-arena]
    [first-raw : i64
      (intern-structural-generation-fill! (&mut state) 1000000 3000)]
    [first : ci.InternStructuralTable
      (intern-structural-generation-table (& state))]
    [first-records : i64 first.records-arena]
    [first-map : i64 first.map-arena]
    [first-capacity : i64 (array-length first.kinds)]
    [first-live : i64 (ci.intern-structural-generations-live)]
    [_more : i64 (intern-structural-generation-fill! (&mut state) 5000000 6000)]
    ;; The other state grows over the same record indices in between.
    [_other : i64
      (intern-structural-generation-fill! (&mut other) 1000000 3000)]
    [second : ci.InternStructuralTable
      (intern-structural-generation-table (& state))]
    [wide-index : i64
      (- (bit-and wide (ci.intern-structural-key-index-mask)) 1)]
    [grown-ok? : bool
      (and
        (= initial-records 0)
        (= initial-map 0)
        ;; Each grown table keeps exactly its current two generations.
        (= first-live (+ live 2))
        (= (ci.intern-structural-generations-live) (+ live 4))
        (not (= first-records 0))
        (not (= first-map 0))
        ;; A released generation's address can be reused by a later one, so
        ;; growth shows in the capacity, not in the handle.
        (> (array-length second.kinds) first-capacity)
        (>= (array-length second.kinds) 8192)
        (=
          (ci.intern-compat-state-composite-pair-id (&mut state) left right)
          pair)
        (ci.intern-private-string-eq
          (ci.intern-compat-state-composite-rendered-name state pair)
          "generation/left+right")
        (=
          (ci.intern-structural-table-intern
            (&mut state.structural-table-cell)
            255
            left
            7
            right)
          wide)
        (= (cast (array-ref second.kinds wide-index) : i64) 255)
        (=
          (ci.intern-compat-state-generated-role-symbol-id
            (&mut state)
            (ci.intern-generated-symbol-role-lambda)
            component)
          role)
        (=
          (intern-structural-generation-fill! (&mut state) 1000000 1)
          first-raw)
        (=
          (ci.intern-compat-state-composite-pair-id (&mut other) 3 4)
          other-pair)
        (not (= other-pair pair)))]
    ;; A logical reset reuses the current generation.
    [_logical : unit (ci.intern-compat-state-reset! (&mut state))]
    [logical : ci.InternStructuralTable
      (intern-structural-generation-table (& state))]
    [logical-ok? : bool
      (and
        (= logical.len 0)
        (= logical.records-arena second.records-arena)
        (= logical.map-arena second.map-arena)
        (= (ci.intern-structural-generations-live) (+ live 4)))]
    ;; Floor and full persistent resets release both generations first. The
    ;; floor is marked while the state's persistent arena is current, as the
    ;; loader does.
    [home : i64 (ci.tl_arena_current)]
    [_mark : unit
      (begin
        (unsafe
          (ci.tl_arena_set (ci.intern-compat-state-persistent-arena state)))
        (ci.intern-compat-state-persistent-arena-floor-refresh! (&mut state))
        (unsafe
          (ci.tl_arena_set home)))]
    [_regrow : i64
      (intern-structural-generation-fill! (&mut state) 7000000 600)]
    [_floor : unit
      (ci.intern-compat-state-persistent-arena-reset-to-floor! (&mut state))]
    [floor : ci.InternStructuralTable
      (intern-structural-generation-table (& state))]
    [floor-ok? : bool
      (and
        (= floor.len 0)
        (= floor.records-arena 0)
        (= floor.map-arena 0)
        (= (ci.intern-structural-generations-live) (+ live 2))
        (>= (intern-structural-generation-fill! (&mut state) 8000000 600) 0)
        (= (ci.intern-structural-generations-live) (+ live 4)))]
    [_full : unit (ci.intern-compat-state-persistent-arena-reset! (&mut state))]
    [full : ci.InternStructuralTable
      (intern-structural-generation-table (& state))]
    [after-other : ci.InternStructuralTable
      (intern-structural-generation-table (& other))]
    (and
      grown-ok?
      logical-ok?
      floor-ok?
      (= full.len 0)
      (= full.records-arena 0)
      (= full.map-arena 0)
      (= (ci.intern-structural-generations-live) (+ live 2))
      (not (= after-other.records-arena 0))
      (= (ci.intern-compat-state-composite-pair-id (&mut other) 3 4) other-pair))))

(define (intern-compat-state-persistent-arena-growth-tests-ok?) : bool
  (let
    [home : i64 (ci.tl_arena_current)]
    ;; Keep this raw extent: `state` and `source` deliberately stay live across
    ;; many helper calls, and their APIs cannot express that the independent
    ;; persistent arena inside `state` outlives this scratch owner. The safe
    ;; checker therefore rejects the test's intentional ownership proof.
    [scratch : i64 (ci.tl_arena_make)]
    [state : ci.InternCompatState
      (begin
        (unsafe
          (ci.tl_arena_set scratch))
        (let
          [created : ci.InternCompatState (ci.intern-compat-state-new)]
          (begin
            (unsafe
              (ci.tl_arena_set home))
            created)))]
    [initial-arena : i64 (ci.intern-compat-state-persistent-arena state)]
    [initial-head : i64
      (ci.intern-compat-state-persistent-arena-current-head state)]
    [chunk-size : i64 4194304]
    [max-iterations : i64 24]
    [source : String
      (begin
        (unsafe
          (ci.tl_arena_set scratch))
        (let
          [built : String
            (intern-state-arena-growth-source chunk-size max-iterations)]
          (begin
            (unsafe
              (ci.tl_arena_set home))
            built)))]
    [before-id : i64
      (ci.intern-compat-state-intern (&mut state) "state/pre-growth")]
    [before-text : String (ci.intern-compat-state-str state before-id)]
    [iterations : i64 0]
    [grew? : bool false]
    (begin
      (while (and (not grew?) (< iterations max-iterations))
        (let
          [_copied : String
            (ci.intern-compat-state-persistent-substring
              (&mut state)
              source
              iterations
              chunk-size)]
          (begin
            (set!
              grew?
              (not
                (=
                  (ci.intern-compat-state-persistent-arena-current-head state)
                  initial-head)))
            (set! iterations (+ iterations 1)))))
      (let
        [grown-arena : i64 (ci.intern-compat-state-persistent-arena state)]
        [grown-head : i64
          (ci.intern-compat-state-persistent-arena-current-head state)]
        [post-copy : String
          (ci.intern-compat-state-persistent-substring (&mut state) source 0 64)]
        [post-copy-restored? : bool (= (ci.tl_arena_current) home)]
        [post-id : i64
          (ci.intern-compat-state-intern (&mut state) "state/post-growth")]
        [generated-id : i64
          (ci.intern-compat-state-generated-name
            (&mut state)
            "state/generated-after-growth")]
        [structural-id : i64
          (ci.intern-compat-state-composite-pair-id
            (&mut state)
            before-id
            post-id)]
        [rendered-name : String
          (ci.intern-compat-state-composite-rendered-name-record!
            (&mut state)
            structural-id
            "state/pre-growth+state/post-growth")]
        [structural-grow-index : i64 0]
        [equal-branch-head : i64 -1]
        [equal-copy : String
          (begin
            (unsafe
              (ci.tl_arena_set (ci.intern-compat-state-persistent-arena state)))
            (let
              [copied : String
                (ci.intern-compat-state-persistent-substring
                  (&mut state)
                  source
                  1
                  64)]
              (begin
                (set!
                  equal-branch-head
                  (ci.intern-compat-state-persistent-arena-current-head state))
                (unsafe
                  (ci.tl_arena_set home))
                copied)))]
        [ok : bool true]
        (begin
          ;; Force both retained structural arrays and the open-addressing map
          ;; through their checker-visible target-arena growth extents.
          (while (< structural-grow-index 600)
            (begin
              (ci.intern-structural-table-intern
                (&mut state.structural-table-cell)
                (ci.intern-structural-kind-pair)
                (+ 1000000 structural-grow-index)
                0
                (+ 2000000 structural-grow-index))
              (set! structural-grow-index (+ structural-grow-index 1))))
          (set!
            ok
            (and
              ok
              grew?
              (= grown-arena initial-arena)
              (not (= grown-head initial-head))
              (ci.intern-private-string-eq before-text "state/pre-growth")
              (ci.intern-private-string-eq
                (ci.intern-compat-state-str state before-id)
                "state/pre-growth")
              (ci.intern-private-string-eq
                (ci.intern-compat-state-str state post-id)
                "state/post-growth")
              (ci.intern-private-string-eq
                (ci.intern-compat-state-str state generated-id)
                "state/generated-after-growth")
              (ci.intern-private-string-eq
                rendered-name
                "state/pre-growth+state/post-growth")
              (= (ci.intern-private-string-length post-copy) 64)
              (=
                (ci.intern-private-string-ref post-copy 0)
                (ci.intern-private-string-ref source 0))
              post-copy-restored?
              (= (ci.tl_arena_current) home)))
          (let
            [grown-structural-table : ci.InternStructuralTable
              (ci.intern-array-shared-view state.structural-table-cell 0)]
            (set!
              ok
              (and
                ok
                (>= (array-length grown-structural-table.kinds) 512)
                (>= (array-length grown-structural-table.map-slots) 1024))))
          (set!
            ok
            (and
              ok
              (=
                equal-branch-head
                (ci.intern-compat-state-persistent-arena-current-head state))
              (= (ci.intern-private-string-length equal-copy) 64)
              (=
                (ci.intern-private-string-ref equal-copy 0)
                (ci.intern-private-string-ref source 1))
              (= (ci.tl_arena_current) home)))
          (ci.intern-compat-state-reset! (&mut state))
          (let
            [state-arena : i64 (ci.intern-compat-state-persistent-arena state)]
            (begin
              (unsafe
                (ci.tl_arena_set home)
                (ci.tl_arena_destroy state-arena)
                (ci.tl_arena_destroy scratch))
              ok)))))))

(define (intern-reset-to-tests-ok?) : bool
  (begin
    (ci.intern-reset!)
    (let
      [kept : i64 (ci.intern "keep/name")]
      [plain : i64 (ci.intern "plain")]
      [mark : i64 (ci.intern-pool-len)]
      [_drop : i64 (ci.intern "drop/name")]
      [ok : bool true]
      (begin
        (ci.intern-reset-to! mark)
        (set!
          ok
          (and
            ok
            (= (ci.intern-pool-len) mark)
            (= (ci.intern "keep/name") kept)
            (= (ci.intern "plain") plain)
            (intern-qualified-metadata-case-ok? kept true 4 "keep" "name")))
        (match (ci.intern-lookup "drop/name")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (unless (= (ci.intern "drop/name") mark) (set! ok false))
        (ci.intern-reset!)
        ok))))

;; Resets empty the intern maps by their dirty logs rather than at full
;; capacity (#8520). After every reset the maps must match what a full clear
;; followed by a rebuild of the kept ids produced: the source map below,
;; slot by slot, and an empty generated map.
;;
;; The source map a full clear and rebuild of ids [0, mark) leaves: each id, in
;; id order, at the first empty slot probing from its spelling's bucket, stored
;; as id + 1.
(define (intern-map-rebuilt-model
  [state : (& state ci.InternCompatState)]
  [mark : i64]) : (__tl_dyn-array i64)
  (let
    [capacity : i64 (array-length state.map-id-slots)]
    [model : (__tl_dyn-array i64) (__tl_make-array i64 capacity)]
    [id : i64 0]
    (begin
      (while (< id mark)
        (let
          [name : String (ci.intern-array-shared-view state.pool-slots id)]
          [slot : i64 (ci.intern-bucket (ci.intern-hash (& name)) capacity)]
          (begin
            (while (not (= (array-ref model slot) 0))
              (set! slot (ci.intern-bucket (+ slot 1) capacity)))
            (set! (array-ref model slot) (+ id 1))
            (set! id (+ id 1)))))
      model)))

(define (intern-maps-match-rebuild?
  [state : (& state ci.InternCompatState)]
  [mark : i64]) : bool
  (let
    [model : (__tl_dyn-array i64) (intern-map-rebuilt-model state mark)]
    [ok : bool true]
    [index : i64 0]
    (begin
      (while (< index (array-length state.map-id-slots))
        (begin
          (unless
            (=
              (ci.intern-slot-id-value (array-ref state.map-id-slots index))
              (array-ref model index))
            (set! ok false))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index (array-length state.generated-map-id-slots))
        (begin
          (unless
            (=
              (ci.intern-slot-id-value
                (array-ref state.generated-map-id-slots index))
              0)
            (set! ok false))
          (set! index (+ index 1))))
      ok)))

;; Every seventh spelling is module-qualified and every fifth dotted, so
;; metadata interning puts module, base and prefix ids in between.
(define (intern-maps-fill-name [prefix : (& prefix str)] [index : i64]) : String
  (let
    [stem : String (str_cat.str-cat prefix (string.int->string index))]
    (if (= (% index 7) 0)
      (str_cat.str-cat "mod/" stem)
      (if (= (% index 5) 0)
        (str_cat.str-cat stem ".tail")
        stem))))

;; `count` source spellings, the first `generated` of them also as canonical
;; generated names, through the state path.
(define (intern-maps-fill!
  [state : (&mut state ci.InternCompatState)]
  [prefix : (& prefix str)]
  [count : i64]
  [generated : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (ci.intern-compat-state-intern
          state
          (intern-maps-fill-name prefix index))
        (when
          (< index generated)
          (begin
            (ci.intern-compat-state-generated-canonical-name
              state
              (str_cat.str-cat "gen-" (intern-maps-fill-name prefix index)))
            unit))
        (set! index (+ index 1))))))

;; The same through the installed globals.
(define (intern-maps-fill-installed!
  [prefix : (& prefix str)]
  [count : i64]
  [generated : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (ci.intern (intern-maps-fill-name prefix index))
        (when
          (< index generated)
          (begin
            (ci.intern-generated-canonical-name
              (str_cat.str-cat "gen-" (intern-maps-fill-name prefix index)))
            unit))
        (set! index (+ index 1))))))

(define (intern-map-dirty-reset-tests-ok?) : bool
  (let
    [installed : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    ;; A mark equal to the count keeps every slot where it was.
    [_same : unit (intern-maps-fill! (&mut state) "dirty-a" 300 40)]
    [count : i64 (ci.intern-compat-state-pool-len (& state))]
    [_same-reset : unit (ci.intern-compat-state-reset-to! (&mut state) count)]
    [same-ok? : bool (intern-maps-match-rebuild? (& state) count)]
    ;; A mark inside the source ids drops the later ones.
    [_mid : unit (intern-maps-fill! (&mut state) "dirty-b" 200 40)]
    [_mid-reset : unit (ci.intern-compat-state-reset-to! (&mut state) 137)]
    [mid-ok? : bool (intern-maps-match-rebuild? (& state) 137)]
    ;; Mark 0 and a full reset leave both maps empty.
    [_zero : unit (intern-maps-fill! (&mut state) "dirty-c" 200 40)]
    [_zero-reset : unit (ci.intern-compat-state-reset-to! (&mut state) 0)]
    [zero-ok? : bool (intern-maps-match-rebuild? (& state) 0)]
    [_full : unit (intern-maps-fill! (&mut state) "dirty-d" 200 40)]
    [_full-reset : unit (ci.intern-compat-state-reset! (&mut state))]
    [full-ok? : bool (intern-maps-match-rebuild? (& state) 0)]
    ;; More inserts into each map than its log segment holds: that reset
    ;; clears both maps in full, and the next one follows the logs again.
    [_saturate : unit (intern-maps-fill! (&mut state) "dirty-e" 33000 33000)]
    [saturated? : bool
      (>
        (ci.intern-compat-state-pool-len (& state))
        (ci.intern-map-dirty-limit))]
    [_saturated-reset : unit
      (ci.intern-compat-state-reset-to! (&mut state) 5000)]
    [saturated-ok? : bool (intern-maps-match-rebuild? (& state) 5000)]
    [_after : unit (intern-maps-fill! (&mut state) "dirty-f" 200 40)]
    [_after-reset : unit (ci.intern-compat-state-reset-to! (&mut state) 2500)]
    [after-ok? : bool (intern-maps-match-rebuild? (& state) 2500)]
    ;; Inserts through the installed globals advance the global cursor, not the
    ;; state's own count cell, and the state's reset still empties their slots.
    [_install : unit (ci.intern-compat-state-install! state)]
    [stale : i64 (ci.intern-compat-state-pool-len (& state))]
    [_installed : unit (intern-maps-fill-installed! "dirty-g" 300 40)]
    [advanced? : bool (> (ci.intern-pool-len) stale)]
    [_stale-reset : unit (ci.intern-compat-state-reset-to! (&mut state) 1200)]
    [stale-ok? : bool (intern-maps-match-rebuild? (& state) 1200)]
    ;; The installed-global resets read the same logs.
    [_reinstall : unit (ci.intern-compat-state-install! state)]
    [_global : unit (intern-maps-fill-installed! "dirty-h" 300 40)]
    [_global-reset : unit (ci.intern-reset-to! 600)]
    [global-ok? : bool (intern-maps-match-rebuild? (& state) 600)]
    [_restore : unit (ci.intern-compat-state-install! installed)]
    (and
      same-ok?
      mid-ok?
      zero-ok?
      full-ok?
      saturated?
      saturated-ok?
      after-ok?
      (= stale 2500)
      advanced?
      stale-ok?
      global-ok?)))

(define (intern-persistent-floor-reset-tests-ok?) : bool
  (begin
    (ci.intern-reset!)
    (ci.intern-persistent-arena-reset!)
    (let
      [kept : i64 (ci.intern "floor_keep")]
      (begin
        (ci.intern-persistent-arena-floor-refresh!)
        (let
          [drop-id : i64 (ci.intern "floor_drop")]
          [ok : bool true]
          (begin
            (ci.intern-reset-to! (+ kept 1))
            (ci.intern-persistent-arena-reset-to-floor!)
            (unless (= (ci.intern "floor_keep") kept) (set! ok false))
            (match (ci.intern-lookup "floor_drop")
              [(InternLookupMissing) unit]
              [(InternLookupFound _) (set! ok false)])
            (unless (= (ci.intern "floor_drop") drop-id) (set! ok false))
            (ci.intern-reset!)
            (ci.intern-persistent-arena-reset!)
            ok))))))

(define (intern-source-name-session-tests-ok?) : bool
  (let
    [home : i64 (ci.tl_arena_current)]
    [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [equal-id : i64 (ci.intern-compat-state-intern (&mut state-a) "equal")]
    [empty-id : i64 (ci.intern-compat-state-intern (&mut state-a) "")]
    [qualified-id : i64
      (ci.intern-compat-state-intern (&mut state-a) "pkg/module.name")]
    [slice-mark : i64 (ci.intern-compat-state-pool-len state-a)]
    [qualified-slice-id : ci.InternId
      (ci.intern-compat-state-source-slice-id
        (&mut state-a)
        "xxpkg/module.nameyy"
        2
        15)]
    [slice-mark-after : i64 (ci.intern-compat-state-pool-len state-a)]
    [hygiene-id : i64
      (ci.intern-compat-state-intern (&mut state-a) "local#hygiene")]
    [source-mark : i64 (ci.intern-compat-state-pool-len state-a)]
    [session-a : ci.InternSourceNameSession
      (ci.intern-source-name-session-from-state state-a)]
    [session-b : ci.InternSourceNameSession
      (begin
        (ci.intern-compat-state-intern (&mut state-b) "equal")
        (ci.intern-source-name-session-from-state state-b))]
    [persistent-handle : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-handle
        (ci.intern-global-shared-view session-a))]
    [persistent-handle-session : ci.InternSourceNameSession
      (ci.intern-source-name-session-handle-session persistent-handle)]
    [persistent-handle-restored? : bool (= (ci.tl_arena_current) home)]
    [generated-id : i64 (- (ci.intern-capacity) 1)]
    [generated-a : ci.InternSyntaxTextIdentity
      (ci.intern-source-name-session-identity session-a generated-id)]
    [parsed-a : ci.InternSyntaxTextIdentity
      (ci.intern-source-name-session-identity session-a equal-id)]
    [_late-source-id : i64
      (ci.intern-compat-state-intern (&mut state-a) "after-boundary")]
    [ok : bool true]
    (begin
      (set!
        ok
        (and
          ok
          persistent-handle-restored?
          (= persistent-handle-session.table-id session-a.table-id)
          (=
            persistent-handle-session.reset-generation
            session-a.reset-generation)))
      (match (ci.intern-compat-state-lookup state-a "equal")
        [(InternLookupFound id) (unless (= id equal-id) (set! ok false))]
        [(InternLookupMissing) (set! ok false)])
      (set!
        ok
        (and
          ok
          (ci.intern-private-string-eq
            (ci.intern-compat-state-str state-a equal-id)
            "equal")
          (ci.intern-compat-state-qualified? state-a qualified-id)
          (= (ci.intern-id-value qualified-slice-id) qualified-id)
          (= slice-mark-after slice-mark)
          (= (intern-compat-state-qualified-last-slash state-a qualified-id) 3)
          (= (ci.intern-compat-state-first-dot state-a qualified-id) 10)
          (ci.intern-compat-state-dotted? state-a qualified-id)
          (ci.intern-private-string-eq
            (ci.intern-compat-state-str
              state-a
              (ci.intern-compat-state-qualified-module-id state-a qualified-id))
            "pkg")
          (ci.intern-private-string-eq
            (ci.intern-compat-state-str
              state-a
              (ci.intern-compat-state-qualified-base-id state-a qualified-id))
            "module.name")
          ;; The captured owner is not the installed compatibility pool. Dotted
          ;; root projections must read that owner, just like final-leaf queries.
          (ci.intern-private-string-eq
            (ci.intern-compat-state-str
              state-a
              (ci.intern-source-name-session-handle-leading-dot-id
                persistent-handle
                (ci.intern-source-name-session-handle-qualified-base-id
                  persistent-handle
                  qualified-id)))
            "module")
          (ci.intern-private-string-eq
            (ci.intern-compat-state-str
              state-a
              (ci.intern-compat-state-dotted-prefix-id state-a qualified-id))
            "pkg/module")
          (ci.intern-private-string-eq
            (ci.intern-compat-state-str
              state-a
              (ci.intern-compat-state-dotted-tail-id state-a qualified-id))
            "name")
          (ci.intern-private-string-eq
            (ci.intern-compat-state-str
              state-a
              (ci.intern-compat-state-dotted-final-id state-a qualified-id))
            "name")))
      (match (ci.intern-source-name-session-resolve
        session-a
        parsed-a
        "different")
        [(ParsedIdentity id) (unless (= id equal-id) (set! ok false))]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve
        session-a
        generated-a
        "equal")
        [(GeneratedIdentity id lookup)
          (begin
            (unless (= id generated-id) (set! ok false))
            (match lookup
              [(InternLookupFound source-id)
                (unless (= source-id equal-id) (set! ok false))]
              [(InternLookupMissing) (set! ok false)]))]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve
        session-a
        generated-a
        "missing")
        [(GeneratedIdentity id lookup)
          (begin
            (unless (= id generated-id) (set! ok false))
            (match lookup
              [(InternLookupMissing) unit]
              [(InternLookupFound _) (set! ok false)]))]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve
        session-a
        generated-a
        "after-boundary")
        [(GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupMissing) unit]
            [(InternLookupFound _) (set! ok false)])]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve session-a generated-a "")
        [(GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupFound id) (unless (= id empty-id) (set! ok false))]
            [(InternLookupMissing) (set! ok false)])]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve
        session-a
        generated-a
        "pkg/module.name")
        [(GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupFound id)
              (unless (= id qualified-id) (set! ok false))]
            [(InternLookupMissing) (set! ok false)])]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve
        session-a
        generated-a
        "local#hygiene")
        [(GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupFound id) (unless (= id hygiene-id) (set! ok false))]
            [(InternLookupMissing) (set! ok false)])]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve session-b parsed-a "equal")
        [(WrongOwner) unit]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve
        session-a
        (ci.InternSyntaxTextIdentity
          session-a.table-id
          session-a.reset-generation
          -1)
        "equal")
        [(InvalidIdentity) unit]
        [_ (set! ok false)])
      (ci.intern-compat-state-reset-to! (&mut state-a) source-mark)
      (match (ci.intern-source-name-session-resolve
        session-a
        generated-a
        "equal")
        [(StaleGeneration) unit]
        [_ (set! ok false)])
      (let
        [next-session : ci.InternSourceNameSession
          (ci.intern-source-name-session-from-state state-a)]
        [next-generated : ci.InternSyntaxTextIdentity
          (ci.intern-source-name-session-identity next-session generated-id)]
        (match (ci.intern-source-name-session-resolve
          next-session
          next-generated
          "equal")
          [(GeneratedIdentity _ lookup)
            (match lookup
              [(InternLookupFound id) (unless (= id equal-id) (set! ok false))]
              [(InternLookupMissing) (set! ok false)])]
          [_ (set! ok false)]))
      ok)))

(define (intern-generated-role-symbol-tests-ok?) : bool
  (let
    [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [component-a : i64
      (ci.intern-compat-state-intern (&mut state-a) "component")]
    [component-b : i64
      (ci.intern-compat-state-intern (&mut state-b) "component")]
    [source-collision-a : i64
      (ci.intern-compat-state-intern (&mut state-a) "__tl_lambda_component_0")]
    [lambda-a : i64
      (ci.intern-compat-state-generated-role-symbol-id
        (&mut state-a)
        (ci.intern-generated-symbol-role-lambda)
        component-a)]
    [lambda-a-again : i64
      (ci.intern-compat-state-generated-role-symbol-id
        (&mut state-a)
        (ci.intern-generated-symbol-role-lambda)
        component-a)]
    [clone-a : i64
      (ci.intern-compat-state-generated-role-symbol-id
        (&mut state-a)
        (ci.intern-generated-symbol-role-clone-helper)
        component-a)]
    [lambda-b : i64
      (ci.intern-compat-state-generated-role-symbol-id
        (&mut state-b)
        (ci.intern-generated-symbol-role-lambda)
        component-b)]
    [module-a : i64 (ci.intern-compat-state-intern (&mut state-a) "pkg")]
    [base-a : i64 (ci.intern-compat-state-intern (&mut state-a) "cleanup")]
    [qualified-a : i64
      (ci.intern-compat-state-generated-role-qualified-symbol-id
        (&mut state-a)
        (ci.intern-generated-symbol-role-cleanup-helper)
        component-a
        module-a
        base-a)]
    [enum-boundary-a-left : i64
      (ci.intern-compat-state-intern (&mut state-a) "A_B")]
    [enum-boundary-a-right : i64
      (ci.intern-compat-state-intern (&mut state-a) "C")]
    [enum-boundary-a-components : i64
      (ci.intern-compat-state-composite-pair-id
        (&mut state-a)
        enum-boundary-a-left
        enum-boundary-a-right)]
    [enum-boundary-a : i64
      (ci.intern-compat-state-generated-role-symbol-id
        (&mut state-a)
        (ci.intern-generated-symbol-role-nullary-enum-object)
        enum-boundary-a-components)]
    [enum-boundary-b-left : i64
      (ci.intern-compat-state-intern (&mut state-a) "A")]
    [enum-boundary-b-right : i64
      (ci.intern-compat-state-intern (&mut state-a) "B_C")]
    [enum-boundary-b-components : i64
      (ci.intern-compat-state-composite-pair-id
        (&mut state-a)
        enum-boundary-b-left
        enum-boundary-b-right)]
    [enum-boundary-b : i64
      (ci.intern-compat-state-generated-role-symbol-id
        (&mut state-a)
        (ci.intern-generated-symbol-role-nullary-enum-object)
        enum-boundary-b-components)]
    [ok : bool true]
    (begin
      (set!
        ok
        (and
          ok
          (= lambda-a lambda-a-again)
          (not (= lambda-a clone-a))
          (not (= lambda-a source-collision-a))
          (ci.intern-compat-state-generated-role-symbol?
            state-a
            lambda-a
            (ci.intern-generated-symbol-role-lambda))
          (not
            (ci.intern-compat-state-generated-role-symbol?
              state-a
              lambda-a
              (ci.intern-generated-symbol-role-clone-helper)))
          (not
            (ci.intern-compat-state-generated-role-symbol?
              state-a
              source-collision-a
              (ci.intern-generated-symbol-role-lambda)))
          ;; Both recipes render as `__enum_obj_A_B_C`; component boundaries stay
          ;; structural so they cannot silently alias before the output boundary.
          (not (= enum-boundary-a enum-boundary-b))
          (=
            (ci.intern-private-string-length
              (ci.intern-compat-state-str state-a lambda-a))
            0)
          (ci.intern-private-string-eq
            (ci.intern-compat-state-generated-role-symbol-materialize!
              (&mut state-a)
              (ci.intern-generated-symbol-role-lambda)
              lambda-a
              "__tl_lambda_component_0")
            "__tl_lambda_component_0")
          (ci.intern-private-string-eq
            (ci.intern-compat-state-generated-role-symbol-materialize!
              (&mut state-b)
              (ci.intern-generated-symbol-role-lambda)
              lambda-b
              "state_b_lambda")
            "state_b_lambda")
          (ci.intern-private-string-eq
            (ci.intern-compat-state-str state-a lambda-a)
            "__tl_lambda_component_0")
          (ci.intern-private-string-eq
            (ci.intern-compat-state-str state-b lambda-b)
            "state_b_lambda")))
      (ci.intern-compat-state-generated-role-symbol-materialize!
        (&mut state-a)
        (ci.intern-generated-symbol-role-cleanup-helper)
        qualified-a
        "pkg/__tl_cleanup_cleanup")
      (set!
        ok
        (and
          ok
          (ci.intern-compat-state-qualified? state-a qualified-a)
          (=
            (ci.intern-compat-state-qualified-module-id state-a qualified-a)
            module-a)
          (=
            (ci.intern-compat-state-qualified-base-id state-a qualified-a)
            base-a)
          (= (intern-compat-state-qualified-last-slash state-a qualified-a) 3)))
      (let
        [growth-first : i64
          (ci.intern-compat-state-generated-role-symbol-id
            (&mut state-a)
            (ci.intern-generated-symbol-role-global-initializer)
            1000)]
        ;; The initial structural map has 512 slots; components differing by
        ;; 512 deliberately share the role triple's first bucket.
        [hash-collision : i64
          (ci.intern-compat-state-generated-role-symbol-id
            (&mut state-a)
            (ci.intern-generated-symbol-role-global-initializer)
            1512)]
        [index : i64 0]
        (begin
          (unless (not (= growth-first hash-collision)) (set! ok false))
          (while (< index 300)
            (begin
              (ci.intern-compat-state-generated-role-symbol-id
                (&mut state-a)
                (ci.intern-generated-symbol-role-global-initializer)
                (+ 2000 index))
              (set! index (+ index 1))))
          (unless
            (=
              growth-first
              (ci.intern-compat-state-generated-role-symbol-id
                (&mut state-a)
                (ci.intern-generated-symbol-role-global-initializer)
                1000))
            (set! ok false))))
      (let
        [mark-b : i64 (ci.intern-compat-state-pool-len state-b)]
        (begin
          (ci.intern-compat-state-reset-to! (&mut state-b) mark-b)
          (unless
            (not (ci.intern-compat-state-generated-id-active? state-b lambda-b))
            (set! ok false))))
      (ci.intern-compat-state-reset! (&mut state-a))
      (unless
        (not (ci.intern-compat-state-generated-id-active? state-a lambda-a))
        (set! ok false))
      (let
        [next-component : i64
          (ci.intern-compat-state-intern (&mut state-a) "next-component")]
        [next-lambda : i64
          (ci.intern-compat-state-generated-role-symbol-id
            (&mut state-a)
            (ci.intern-generated-symbol-role-lambda)
            next-component)]
        (begin
          (unless
            (=
              (ci.intern-private-string-length
                (ci.intern-compat-state-str state-a next-lambda))
              0)
            (set! ok false))
          (ci.intern-compat-state-generated-role-symbol-materialize!
            (&mut state-a)
            (ci.intern-generated-symbol-role-lambda)
            next-lambda
            "after_reset")))
      ;; Compatibility macro/typecheck callers may advance the active global
      ;; generated lane after a driver snapshots its explicit state. The next
      ;; structural allocation refreshes that frontier and cannot reuse the
      ;; live compatibility ID.
      (ci.intern-reset!)
      (let
        [active-state : ci.InternCompatState
          (ci.intern-compat-state-capture-active)]
        [compat-id : i64 (ci.intern-generated-name "compat-generated")]
        [role-id : i64
          (ci.intern-compat-state-generated-role-symbol-id
            (&mut active-state)
            (ci.intern-generated-symbol-role-lambda)
            99)]
        (set!
          ok
          (and
            ok
            (not (= compat-id role-id))
            (ci.intern-private-string-eq
              (ci.intern-str compat-id)
              "compat-generated"))))
      ;; Reusing a role first published by the active compatibility view also
      ;; refreshes the explicit state's generated frontier. This is distinct
      ;; from the new-role allocation case above: the structural record and
      ;; handle already exist before the state-side lookup.
      (ci.intern-reset!)
      (let
        [component : i64 (ci.intern "shared-role-component")]
        [active-state : ci.InternCompatState
          (ci.intern-compat-state-capture-active)]
        [role : i64 (ci.intern-generated-symbol-role-clone-helper)]
        [compat-role-id : i64
          (ci.intern-generated-role-symbol-id role component)]
        [state-role-id : i64
          (ci.intern-compat-state-generated-role-symbol-id
            (&mut active-state)
            role
            component)]
        (set!
          ok
          (and
            ok
            (= state-role-id compat-role-id)
            (ci.intern-compat-state-generated-role-symbol?
              active-state
              state-role-id
              role)
            (ci.intern-private-string-eq
              (ci.intern-compat-state-generated-role-symbol-materialize!
                (&mut active-state)
                role
                state-role-id
                "clone$SharedRole")
              "clone$SharedRole"))))
      ok)))

(define (intern-qualified-metadata-tests-ok?) : bool
  (begin
    (ci.intern-reset!)
    (let
      [plain : i64 (ci.intern "name")]
      [qualified : i64 (ci.intern "module/name")]
      [nested : i64 (ci.intern "pkg/sub/name")]
      [leading : i64 (ci.intern "/name")]
      [trailing : i64 (ci.intern "module/")]
      [slash : i64 (ci.intern "/")]
      [dotted : i64 (ci.intern "point.x")]
      [nested-dotted : i64 (ci.intern "point.inner.x")]
      [ok : bool
        (and
          (intern-qualified-metadata-case-ok? plain false -1 "" "name")
          (= (ci.intern-qualified-base-id plain) plain)
          (= (ci.intern-qualified-module-id plain) -1)
          (= (ci.intern-first-dot plain) -1)
          (not (ci.intern-dotted? plain))
          (intern-qualified-metadata-case-ok? qualified true 6 "module" "name")
          (= (ci.intern-first-dot qualified) -1)
          (intern-qualified-metadata-case-ok? nested true 7 "pkg/sub" "name")
          (intern-qualified-metadata-case-ok? leading true 0 "" "name")
          (intern-qualified-metadata-case-ok? trailing true 6 "module" "")
          (intern-qualified-metadata-case-ok? slash true 0 "" "")
          (= (ci.intern-first-dot dotted) 5)
          (ci.intern-dotted? dotted)
          (= (ci.intern-dotted-prefix-id dotted) (ci.intern "point"))
          (ci.intern-private-string-eq
            (ci.intern-str (ci.intern-dotted-tail-id dotted))
            "x")
          (ci.intern-private-string-eq
            (ci.intern-str (ci.intern-dotted-final-id dotted))
            "x")
          (= (ci.intern-first-dot nested-dotted) 5)
          (ci.intern-private-string-eq
            (ci.intern-str (ci.intern-dotted-prefix-id nested-dotted))
            "point.inner")
          (ci.intern-private-string-eq
            (ci.intern-str
              (ci.intern-dotted-prefix-id
                (ci.intern-dotted-prefix-id nested-dotted)))
            "point")
          (ci.intern-private-string-eq
            (ci.intern-str (ci.intern-dotted-tail-id nested-dotted))
            "inner.x")
          (ci.intern-private-string-eq
            (ci.intern-str (ci.intern-dotted-final-id nested-dotted))
            "x")
          (ci.intern-dotted? dotted)
          (= (ci.intern-first-dot dotted) 5)
          (intern-slice-tests-ok?)
          (intern-generated-name-tests-ok?)
          (intern-persistent-arena-tests-ok?)
          (intern-compat-state-persistent-arena-growth-tests-ok?)
          (intern-structural-generation-tests-ok?)
          (intern-structural-reset-tests-ok?)
          (intern-reset-to-tests-ok?)
          (intern-map-dirty-reset-tests-ok?)
          (intern-persistent-floor-reset-tests-ok?)
          (intern-source-name-session-tests-ok?)
          (intern-generated-role-symbol-tests-ok?))]
      (begin
        (ci.intern-reset!)
        ok))))