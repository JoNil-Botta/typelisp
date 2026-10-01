;; Structural record columns and maps are destroyed as soon as growth publishes
;; their replacement, and reclaim poisoning overwrites the retired storage. Two
;; owners grow over overlapping record indices, one installed and one reached
;; only through its explicit session. Identities, every kind through 255,
;; generated-role handles and rendered names survive; every persistent reset
;; releases the owner's generations and leaves the installed owner intact.
(import compiler_intern as ci)
(import compiler_intern_state as cis)

(extern (tl_arena_poison_enable) : unit)

(define (session-for [state : (& state ci.InternCompatState)]) : cis.InternStructuralSessionHandle
  (cis.intern-structural-session-handle-from-source-names
    (ci.intern-source-name-session-handle-from-state state)))

;; Pairs inserted through the installed owner's compatibility path.
(define (grow-active! [base : i64] [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (let
        [_raw : i64 (ci.intern-composite-pair-id base (+ base index 1))]
        (set! index (+ index 1))))))

;; Pairs inserted through an explicit session whose owner may be inactive.
(define (grow-session!
  [session : cis.InternStructuralSessionHandle]
  [base : i64]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (let
        [_key : cis.InternStructuralKey
          (cis.intern-structural-session-composite-pair-key
            session
            base
            (+ base index 1))]
        (set! index (+ index 1))))))

(define (session-pair-raw
  [session : cis.InternStructuralSessionHandle]
  [left : i64]
  [right : i64]) : i64
  (let
    [key : cis.InternStructuralKey
      (cis.intern-structural-session-composite-pair-key session left right)]
    key.value))

;; Unpublished addresses can still read correct records once the kernel maps
;; a later generation at a retired one's address, so check them directly.
(define (active-columns-published? [state : (& state ci.InternCompatState)]) : bool
  (let
    [table : ci.InternStructuralTable
      (ci.intern-array-shared-view state.structural-table-cell 0)]
    (and
      (= ci.intern-active-structural-owner table.owner)
      (=
        ci.intern-active-structural-kinds-address
        (ci.intern-i64-array-address table.kinds))
      (=
        ci.intern-active-structural-lefts-address
        (ci.intern-i64-array-address table.lefts))
      (=
        ci.intern-active-structural-middles-address
        (ci.intern-i64-array-address table.middles))
      (=
        ci.intern-active-structural-rights-address
        (ci.intern-i64-array-address table.rights)))))

(define (main) : i64
  (begin
    (tl_arena_poison_enable)
    (let
      [home : ci.InternCompatState (ci.intern-compat-state-capture-active)]
      [live : i64 (ci.intern-structural-generations-live)]
      [a : ci.InternCompatState (ci.intern-compat-state-new)]
      [b : ci.InternCompatState (ci.intern-compat-state-new)]
      [a-left : i64 (ci.intern-compat-state-intern (&mut a) "a-left")]
      [a-right : i64 (ci.intern-compat-state-intern (&mut a) "a-right")]
      [component : i64 (ci.intern-compat-state-intern (&mut a) "a-component")]
      [b-left : i64 (ci.intern-compat-state-intern (&mut b) "b-left")]
      [a-pair : i64
        (ci.intern-compat-state-composite-pair-id (&mut a) a-left a-right)]
      [a-nested : i64
        (ci.intern-compat-state-composite-triple-id
          (&mut a)
          a-pair
          a-left
          a-right)]
      [_a-name : String
        (ci.intern-compat-state-composite-rendered-name-record!
          (&mut a)
          a-pair
          "a-left+a-right")]
      [a-wide : i64
        (ci.intern-structural-table-intern
          (&mut a.structural-table-cell)
          255
          a-left
          7
          a-right)]
      [a-role : i64
        (ci.intern-compat-state-generated-role-symbol-id
          (&mut a)
          (ci.intern-generated-symbol-role-lambda)
          component)]
      [a-session : cis.InternStructuralSessionHandle (session-for (& a))]
      [b-session : cis.InternStructuralSessionHandle (session-for (& b))]
      ;; A grows while installed: every growth republishes the active
      ;; addresses before the previous generation is poisoned.
      [_install-a : unit (ci.intern-compat-state-install! a)]
      [_grow-a : unit (grow-active! 1000 20000)]
      [a-base : i64 (ci.intern-composite-pair-id 1000 1001)]
      [active-ok? : bool
        (and
          (active-columns-published? (& a))
          (= (ci.intern-composite-pair-id a-left a-right) a-pair)
          (ci.intern-private-string-eq
            (ci.intern-composite-rendered-name a-pair)
            "a-left+a-right")
          (= (ci.intern-structural-generations-live) (+ live 2)))]
      ;; B is installed and grows over the same record indices while A grows
      ;; further through its session alone.
      [_capture-a : unit
        (ci.intern-compat-state-capture-from-globals! (&mut a))]
      [_install-b : unit (ci.intern-compat-state-install! b)]
      [_grow-b : unit (grow-active! 1000 20000)]
      [_grow-a-inactive : unit (grow-session! a-session 50000 30000)]
      [b-base : i64 (ci.intern-composite-pair-id 1000 1001)]
      [b-pair : i64 (session-pair-raw b-session b-left b-left)]
      [_nested-name : String
        (cis.intern-structural-session-composite-rendered-name-record-unchecked!
          a-session
          a-nested
          "a-left+a-right/a-left/a-right")]
      [interleaved-ok? : bool
        (and
          (active-columns-published? (& b))
          (not (= a-base b-base))
          (= (session-pair-raw b-session 1000 1001) b-base)
          (= (session-pair-raw a-session 1000 1001) a-base)
          (= (session-pair-raw a-session a-left a-right) a-pair)
          (= (ci.intern-composite-pair-id b-left b-left) b-pair)
          (ci.intern-private-string-eq
            (cis.intern-structural-session-composite-rendered-name-unchecked
              a-session
              a-pair)
            "a-left+a-right")
          (= (ci.intern-structural-generations-live) (+ live 4)))]
      ;; A is installed again over its session-grown table.
      [_capture-b : unit
        (ci.intern-compat-state-capture-from-globals! (&mut b))]
      [_reinstall-a : unit (ci.intern-compat-state-install! a)]
      [reinstalled-ok? : bool
        (and
          (active-columns-published? (& a))
          (= (ci.intern-composite-pair-id 1000 1001) a-base)
          (= (ci.intern-composite-pair-id a-left a-right) a-pair)
          (=
            (ci.intern-compat-state-composite-triple-id
              (&mut a)
              a-pair
              a-left
              a-right)
            a-nested)
          (ci.intern-private-string-eq
            (ci.intern-composite-rendered-name a-nested)
            "a-left+a-right/a-left/a-right")
          (=
            (ci.intern-structural-table-intern
              (&mut a.structural-table-cell)
              255
              a-left
              7
              a-right)
            a-wide)
          (=
            (ci.intern-compat-state-generated-role-symbol-id
              (&mut a)
              (ci.intern-generated-symbol-role-lambda)
              component)
            a-role))]
      ;; Both owners release through persistent resets while the original
      ;; owner is installed again.
      [_capture-a-again : unit
        (ci.intern-compat-state-capture-from-globals! (&mut a))]
      [_restore-home : unit (ci.intern-compat-state-install! home)]
      [_reset-a : unit
        (ci.intern-compat-state-persistent-arena-reset! (&mut a))]
      [after-a : i64 (ci.intern-structural-generations-live)]
      [_reset-b : unit
        (ci.intern-compat-state-persistent-arena-reset! (&mut b))]
      [home-pair : i64 (ci.intern-composite-pair-id 7 8)]
      (cond
        [(not active-ok?) 1]
        [(not interleaved-ok?) 2]
        [(not reinstalled-ok?) 3]
        [(not (= after-a (+ live 2))) 4]
        [(not (= (ci.intern-structural-generations-live) live)) 5]
        [(not (= (ci.intern-composite-pair-id 7 8) home-pair)) 6]
        [else 42]))))