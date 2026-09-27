;; compiler_intern_tests.tl - White-box tests for the interner: syntax ids,
;; id-space capacity, generated names, slices, persistent arenas, resets,
;; source-name sessions and qualified metadata.
(import compiler_intern as ci)

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
      [ok : bool true]
      (begin
        ;; A power of two, so `intern-bucket` masks instead of dividing.
        (unless (> capacity 0) (set! ok false))
        (unless (= (bit-and capacity (- capacity 1)) 0) (set! ok false))
        ;; Each dedup map has to outsize the lane it indexes. A map smaller than
        ;; its lane cannot hold a full lane, and the overflow is an abort inside
        ;; the probe loop, not a resize.
        (unless
          (>= (array-length ci.intern-map-id-slots) capacity)
          (set! ok false))
        (unless (>= ci.intern-generated-map-capacity capacity) (set! ok false))
        ;; A renderable id is a pool id and nothing else.
        (unless (ci.intern-renderable-id? (- capacity 1)) (set! ok false))
        (unless (not (ci.intern-renderable-id? capacity)) (set! ok false))
        ;; Both lanes address the one pool: source ids grow up from zero and
        ;; generated ids grow down from capacity-1, so the capacity is the sum
        ;; the two lanes must fit in, and they meet only when it is exhausted.
        (unless (= (ci.intern-pool-len) 0) (set! ok false))
        (unless (= (ci.intern-generated-count) 0) (set! ok false))
        (unless (= (ci.intern "id-space-lane-probe") 0) (set! ok false))
        (unless (= (ci.intern-syntax-source-name-id-or 0 -1) 0) (set! ok false))
        (unless
          (ci.intern-private-string-eq
            (ci.intern-syntax-name-text-or capacity "missing")
            "missing")
          (set! ok false))
        (unless
          (= (ci.intern-generated-name "id-space-lane-probe") (- capacity 1))
          (set! ok false))
        (unless
          (= (ci.intern-generated-id-at-allocation-index 0) (- capacity 1))
          (set! ok false))
        (unless (= (ci.intern-pool-len) 1) (set! ok false))
        (unless (= (ci.intern-generated-count) 1) (set! ok false))
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
        (unless (= (ci.intern-pool-len) source-len) (set! ok false))
        (unless (= opaque-id (- (ci.intern-capacity) 1)) (set! ok false))
        (unless (= opaque-again-id (- (ci.intern-capacity) 2)) (set! ok false))
        (unless
          (= duplicate-display-id (- (ci.intern-capacity) 3))
          (set! ok false))
        (unless (= qualified-id (- (ci.intern-capacity) 4)) (set! ok false))
        (unless (= dotted-id (- (ci.intern-capacity) 5)) (set! ok false))
        (unless (= (ci.intern-generated-count) 5) (set! ok false))
        (unless
          (= (ci.intern-generated-id-at-allocation-index 0) opaque-id)
          (set! ok false))
        (unless
          (= (ci.intern-generated-id-at-allocation-index 4) dotted-id)
          (set! ok false))
        (unless
          (= (ci.intern-generated-id-at-allocation-index -1) -1)
          (set! ok false))
        (unless
          (= (ci.intern-generated-id-at-allocation-index 5) -1)
          (set! ok false))
        (unless (not (= opaque-id opaque-again-id)) (set! ok false))
        (unless
          (ci.intern-private-string-eq
            (ci.intern-str opaque-id)
            "hygiene/local")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok?
            opaque-id
            false
            -1
            ""
            "hygiene/local")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok?
            qualified-id
            true
            16
            "generated-module"
            "generated-base")
          (set! ok false))
        (unless (= (ci.intern-first-dot dotted-id) 14) (set! ok false))
        (unless
          (= (ci.intern-leading-dot-id dotted-id) base-id)
          (set! ok false))
        (unless
          (= (ci.intern-dotted-prefix-id dotted-id) dotted-prefix-id)
          (set! ok false))
        (unless
          (= (ci.intern-dotted-tail-id dotted-id) dotted-tail-id)
          (set! ok false))
        (unless (ci.intern-dotted? dotted-id) (set! ok false))
        (unless (not (ci.intern-qualified? dotted-id)) (set! ok false))
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
            (unless (= canonical-id canonical-again-id) (set! ok false))
            (unless (= (ci.intern-generated-count) 8) (set! ok false))
            (unless
              (ci.intern-generated-canonical-id? canonical-id)
              (set! ok false))
            (unless
              (ci.intern-generated-canonical-id? canonical-dotted-id)
              (set! ok false))
            (unless
              (ci.intern-generated-canonical-id? canonical-qualified-id)
              (set! ok false))
            (unless
              (not (ci.intern-generated-canonical-id? opaque-id))
              (set! ok false))
            (unless
              (= canonical-dotted-id canonical-dotted-again-id)
              (set! ok false))
            (unless
              (= (ci.intern-leading-dot-id canonical-dotted-id) base-id)
              (set! ok false))
            (unless
              (=
                (ci.intern-dotted-prefix-id canonical-dotted-id)
                dotted-prefix-id)
              (set! ok false))
            (unless
              (= canonical-qualified-id canonical-qualified-again-id)
              (set! ok false))
            (unless
              (not (= canonical-qualified-id canonical-id))
              (set! ok false))
            (unless
              (intern-qualified-metadata-case-ok?
                canonical-qualified-id
                true
                -1
                "generated-module"
                "generated-base")
              (set! ok false))
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
                (unless
                  (= canonical-id (- (ci.intern-capacity) 6))
                  (set! ok false))
                (unless (= source-observed-id source-len) (set! ok false))
                (unless
                  (not (= source-observed-id canonical-id))
                  (set! ok false))
                (match (ci.intern-lookup-content "computed-name")
                  [(InternLookupFound found-id)
                    (unless (= found-id source-observed-id) (set! ok false))]
                  [(InternLookupMissing) (set! ok false)])))))
        (ci.intern-reset-to! source-len)
        (let
          [after-reset-to-id : i64 (ci.intern-generated-name "after/reset-to")]
          (begin
            (unless (= (ci.intern-pool-len) source-len) (set! ok false))
            (unless
              (= after-reset-to-id (- (ci.intern-capacity) 1))
              (set! ok false))
            (unless
              (ci.intern-private-string-eq
                (ci.intern-str after-reset-to-id)
                "after/reset-to")
              (set! ok false))
            unit))
        (ci.intern-reset!)
        (let
          [after-reset-id : i64 (ci.intern-generated-name "after/reset")]
          (begin
            (unless (= (ci.intern-pool-len) 0) (set! ok false))
            (unless
              (= after-reset-id (- (ci.intern-capacity) 1))
              (set! ok false))
            (unless
              (ci.intern-private-string-eq
                (ci.intern-str after-reset-id)
                "after/reset")
              (set! ok false))
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
                grown-arena
                (ci.intern-structural-kind-pair)
                (+ 1000000 structural-grow-index)
                0
                (+ 2000000 structural-grow-index))
              (set! structural-grow-index (+ structural-grow-index 1))))
          (unless grew? (set! ok false))
          (unless (= grown-arena initial-arena) (set! ok false))
          (unless (not (= grown-head initial-head)) (set! ok false))
          (unless
            (ci.intern-private-string-eq before-text "state/pre-growth")
            (set! ok false))
          (unless
            (ci.intern-private-string-eq
              (ci.intern-compat-state-str state before-id)
              "state/pre-growth")
            (set! ok false))
          (unless
            (ci.intern-private-string-eq
              (ci.intern-compat-state-str state post-id)
              "state/post-growth")
            (set! ok false))
          (unless
            (ci.intern-private-string-eq
              (ci.intern-compat-state-str state generated-id)
              "state/generated-after-growth")
            (set! ok false))
          (unless
            (ci.intern-private-string-eq
              rendered-name
              "state/pre-growth+state/post-growth")
            (set! ok false))
          (unless
            (= (ci.intern-private-string-length post-copy) 64)
            (set! ok false))
          (unless
            (=
              (ci.intern-private-string-ref post-copy 0)
              (ci.intern-private-string-ref source 0))
            (set! ok false))
          (unless post-copy-restored? (set! ok false))
          (unless (= (ci.tl_arena_current) home) (set! ok false))
          (let
            [grown-structural-table : ci.InternStructuralTable
              (ci.intern-array-shared-view state.structural-table-cell 0)]
            (begin
              (unless
                (>= (array-length grown-structural-table.kinds) 512)
                (set! ok false))
              (unless
                (>= (array-length grown-structural-table.map-slots) 1024)
                (set! ok false))))
          (unless
            (=
              equal-branch-head
              (ci.intern-compat-state-persistent-arena-current-head state))
            (set! ok false))
          (unless
            (= (ci.intern-private-string-length equal-copy) 64)
            (set! ok false))
          (unless
            (=
              (ci.intern-private-string-ref equal-copy 0)
              (ci.intern-private-string-ref source 1))
            (set! ok false))
          (unless (= (ci.tl_arena_current) home) (set! ok false))
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
        (unless (= (ci.intern-pool-len) mark) (set! ok false))
        (unless (= (ci.intern "keep/name") kept) (set! ok false))
        (unless (= (ci.intern "plain") plain) (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? kept true 4 "keep" "name")
          (set! ok false))
        (match (ci.intern-lookup "drop/name")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (unless (= (ci.intern "drop/name") mark) (set! ok false))
        (ci.intern-reset!)
        ok))))

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
      (unless persistent-handle-restored? (set! ok false))
      (unless
        (= persistent-handle-session.table-id session-a.table-id)
        (set! ok false))
      (unless
        (=
          persistent-handle-session.reset-generation
          session-a.reset-generation)
        (set! ok false))
      (match (ci.intern-compat-state-lookup state-a "equal")
        [(InternLookupFound id) (unless (= id equal-id) (set! ok false))]
        [(InternLookupMissing) (set! ok false)])
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-str state-a equal-id)
          "equal")
        (set! ok false))
      (unless
        (ci.intern-compat-state-qualified? state-a qualified-id)
        (set! ok false))
      (unless
        (= (ci.intern-id-value qualified-slice-id) qualified-id)
        (set! ok false))
      (unless (= slice-mark-after slice-mark) (set! ok false))
      (unless
        (= (intern-compat-state-qualified-last-slash state-a qualified-id) 3)
        (set! ok false))
      (unless
        (= (ci.intern-compat-state-first-dot state-a qualified-id) 10)
        (set! ok false))
      (unless
        (ci.intern-compat-state-dotted? state-a qualified-id)
        (set! ok false))
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-str
            state-a
            (ci.intern-compat-state-qualified-module-id state-a qualified-id))
          "pkg")
        (set! ok false))
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-str
            state-a
            (ci.intern-compat-state-qualified-base-id state-a qualified-id))
          "module.name")
        (set! ok false))
      ;; The captured owner is not the installed compatibility pool. Dotted
      ;; root projections must read that owner, just like final-leaf queries.
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-str
            state-a
            (ci.intern-source-name-session-handle-leading-dot-id
              persistent-handle
              (ci.intern-source-name-session-handle-qualified-base-id
                persistent-handle
                qualified-id)))
          "module")
        (set! ok false))
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-str
            state-a
            (ci.intern-compat-state-dotted-prefix-id state-a qualified-id))
          "pkg/module")
        (set! ok false))
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-str
            state-a
            (ci.intern-compat-state-dotted-tail-id state-a qualified-id))
          "name")
        (set! ok false))
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-str
            state-a
            (ci.intern-compat-state-dotted-final-id state-a qualified-id))
          "name")
        (set! ok false))
      (match (ci.intern-source-name-session-resolve
        session-a
        parsed-a
        "different")
        [(ci.InternSourceNameResolution.ParsedIdentity id)
          (unless (= id equal-id) (set! ok false))]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve
        session-a
        generated-a
        "equal")
        [(ci.InternSourceNameResolution.GeneratedIdentity id lookup)
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
        [(ci.InternSourceNameResolution.GeneratedIdentity id lookup)
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
        [(ci.InternSourceNameResolution.GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupMissing) unit]
            [(InternLookupFound _) (set! ok false)])]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve session-a generated-a "")
        [(ci.InternSourceNameResolution.GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupFound id) (unless (= id empty-id) (set! ok false))]
            [(InternLookupMissing) (set! ok false)])]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve
        session-a
        generated-a
        "pkg/module.name")
        [(ci.InternSourceNameResolution.GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupFound id)
              (unless (= id qualified-id) (set! ok false))]
            [(InternLookupMissing) (set! ok false)])]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve
        session-a
        generated-a
        "local#hygiene")
        [(ci.InternSourceNameResolution.GeneratedIdentity _ lookup)
          (match lookup
            [(InternLookupFound id) (unless (= id hygiene-id) (set! ok false))]
            [(InternLookupMissing) (set! ok false)])]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve session-b parsed-a "equal")
        [(ci.InternSourceNameResolution.WrongOwner) unit]
        [_ (set! ok false)])
      (match (ci.intern-source-name-session-resolve
        session-a
        (ci.InternSyntaxTextIdentity
          session-a.table-id
          session-a.reset-generation
          -1)
        "equal")
        [(ci.InternSourceNameResolution.InvalidIdentity) unit]
        [_ (set! ok false)])
      (ci.intern-compat-state-reset-to! (&mut state-a) source-mark)
      (match (ci.intern-source-name-session-resolve
        session-a
        generated-a
        "equal")
        [(ci.InternSourceNameResolution.StaleGeneration) unit]
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
          [(ci.InternSourceNameResolution.GeneratedIdentity _ lookup)
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
      (unless (= lambda-a lambda-a-again) (set! ok false))
      (unless (not (= lambda-a clone-a)) (set! ok false))
      (unless (not (= lambda-a source-collision-a)) (set! ok false))
      (unless
        (ci.intern-compat-state-generated-role-symbol?
          state-a
          lambda-a
          (ci.intern-generated-symbol-role-lambda))
        (set! ok false))
      (when
        (ci.intern-compat-state-generated-role-symbol?
          state-a
          lambda-a
          (ci.intern-generated-symbol-role-clone-helper))
        (set! ok false))
      (when
        (ci.intern-compat-state-generated-role-symbol?
          state-a
          source-collision-a
          (ci.intern-generated-symbol-role-lambda))
        (set! ok false))
      ;; Both recipes render as `__enum_obj_A_B_C`; component boundaries stay
      ;; structural so they cannot silently alias before the output boundary.
      (unless (not (= enum-boundary-a enum-boundary-b)) (set! ok false))
      (unless
        (=
          (ci.intern-private-string-length
            (ci.intern-compat-state-str state-a lambda-a))
          0)
        (set! ok false))
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-generated-role-symbol-materialize!
            (&mut state-a)
            (ci.intern-generated-symbol-role-lambda)
            lambda-a
            "__tl_lambda_component_0")
          "__tl_lambda_component_0")
        (set! ok false))
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-generated-role-symbol-materialize!
            (&mut state-b)
            (ci.intern-generated-symbol-role-lambda)
            lambda-b
            "state_b_lambda")
          "state_b_lambda")
        (set! ok false))
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-str state-a lambda-a)
          "__tl_lambda_component_0")
        (set! ok false))
      (unless
        (ci.intern-private-string-eq
          (ci.intern-compat-state-str state-b lambda-b)
          "state_b_lambda")
        (set! ok false))
      (ci.intern-compat-state-generated-role-symbol-materialize!
        (&mut state-a)
        (ci.intern-generated-symbol-role-cleanup-helper)
        qualified-a
        "pkg/__tl_cleanup_cleanup")
      (unless
        (ci.intern-compat-state-qualified? state-a qualified-a)
        (set! ok false))
      (unless
        (=
          (ci.intern-compat-state-qualified-module-id state-a qualified-a)
          module-a)
        (set! ok false))
      (unless
        (=
          (ci.intern-compat-state-qualified-base-id state-a qualified-a)
          base-a)
        (set! ok false))
      (unless
        (= (intern-compat-state-qualified-last-slash state-a qualified-a) 3)
        (set! ok false))
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
        (begin
          (unless (not (= compat-id role-id)) (set! ok false))
          (unless
            (ci.intern-private-string-eq
              (ci.intern-str compat-id)
              "compat-generated")
            (set! ok false))))
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
        (begin
          (unless (= state-role-id compat-role-id) (set! ok false))
          (unless
            (ci.intern-compat-state-generated-role-symbol?
              active-state
              state-role-id
              role)
            (set! ok false))
          (unless
            (ci.intern-private-string-eq
              (ci.intern-compat-state-generated-role-symbol-materialize!
                (&mut active-state)
                role
                state-role-id
                "clone$SharedRole")
              "clone$SharedRole")
            (set! ok false))))
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
      [ok : bool true]
      (begin
        (unless
          (intern-qualified-metadata-case-ok? plain false -1 "" "name")
          (set! ok false))
        (unless (= (ci.intern-qualified-base-id plain) plain) (set! ok false))
        (unless (= (ci.intern-qualified-module-id plain) -1) (set! ok false))
        (unless (= (ci.intern-first-dot plain) -1) (set! ok false))
        (unless (not (ci.intern-dotted? plain)) (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? qualified true 6 "module" "name")
          (set! ok false))
        (unless (= (ci.intern-first-dot qualified) -1) (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? nested true 7 "pkg/sub" "name")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? leading true 0 "" "name")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? trailing true 6 "module" "")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? slash true 0 "" "")
          (set! ok false))
        (unless (= (ci.intern-first-dot dotted) 5) (set! ok false))
        (unless (ci.intern-dotted? dotted) (set! ok false))
        (unless
          (= (ci.intern-dotted-prefix-id dotted) (ci.intern "point"))
          (set! ok false))
        (unless
          (ci.intern-private-string-eq
            (ci.intern-str (ci.intern-dotted-tail-id dotted))
            "x")
          (set! ok false))
        (unless
          (ci.intern-private-string-eq
            (ci.intern-str (ci.intern-dotted-final-id dotted))
            "x")
          (set! ok false))
        (unless (= (ci.intern-first-dot nested-dotted) 5) (set! ok false))
        (unless
          (ci.intern-private-string-eq
            (ci.intern-str (ci.intern-dotted-prefix-id nested-dotted))
            "point.inner")
          (set! ok false))
        (unless
          (ci.intern-private-string-eq
            (ci.intern-str
              (ci.intern-dotted-prefix-id
                (ci.intern-dotted-prefix-id nested-dotted)))
            "point")
          (set! ok false))
        (unless
          (ci.intern-private-string-eq
            (ci.intern-str (ci.intern-dotted-tail-id nested-dotted))
            "inner.x")
          (set! ok false))
        (unless
          (ci.intern-private-string-eq
            (ci.intern-str (ci.intern-dotted-final-id nested-dotted))
            "x")
          (set! ok false))
        (unless (ci.intern-dotted? dotted) (set! ok false))
        (unless (= (ci.intern-first-dot dotted) 5) (set! ok false))
        (unless (intern-slice-tests-ok?) (set! ok false))
        (unless (intern-generated-name-tests-ok?) (set! ok false))
        (unless (intern-persistent-arena-tests-ok?) (set! ok false))
        (unless
          (intern-compat-state-persistent-arena-growth-tests-ok?)
          (set! ok false))
        (unless (intern-reset-to-tests-ok?) (set! ok false))
        (unless (intern-persistent-floor-reset-tests-ok?) (set! ok false))
        (unless (intern-source-name-session-tests-ok?) (set! ok false))
        (unless (intern-generated-role-symbol-tests-ok?) (set! ok false))
        (ci.intern-reset!)
        ok))))