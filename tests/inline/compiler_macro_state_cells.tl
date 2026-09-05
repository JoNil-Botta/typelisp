;; Exercise every lazy payload slot through the existing typed entry points.
(import compiler_typecheck_core as tc)
(import stdlib.arena)
(import stdlib.profile)
(import stdlib.test)

(define (new-state [owner : i64]) : tc.TcMacroState
  (in-arena
    (arena.Arena owner)
    (tc.tc-job-state-macro-state (tc.tc-job-state-new))))

(define (initializers) : (Array (-> tc.TcMacroState i64) 12)
  (array
    tc.tc-macro-module-env-state-address-initialize
    tc.tc-macro-helper-state-address-initialize
    tc.tc-macro-abstract-state-address-initialize
    tc.tc-macro-walk-state-address-initialize
    tc.tc-macro-generated-module-state-address-initialize
    tc.tc-macro-generated-decls-state-address-initialize
    tc.tc-macro-surface-call-state-address-initialize
    tc.tc-macro-hygiene-produced-state-address-initialize
    tc.tc-macro-import-index-state-address-initialize
    tc.tc-macro-result-identity-state-address-initialize
    tc.tc-macro-proof-reuse-state-address-initialize
    tc.tc-macro-identity-state-address-initialize))

(define (accessors) : (Array (-> tc.TcMacroState i64) 12)
  (array
    tc.tc-macro-module-env-state-address
    tc.tc-macro-helper-state-address
    tc.tc-macro-abstract-state-address
    tc.tc-macro-walk-state-address
    tc.tc-macro-generated-module-state-address
    tc.tc-macro-generated-decls-state-address
    tc.tc-macro-surface-call-state-address
    tc.tc-macro-hygiene-produced-state-address
    tc.tc-macro-import-index-state-address
    tc.tc-macro-result-identity-state-address
    tc.tc-macro-proof-reuse-state-address
    tc.tc-macro-identity-state-address))

(define (initialize-and-probe [a : tc.TcMacroState] [b : tc.TcMacroState]) : unit
  (let
    [init : (Array (-> tc.TcMacroState i64) 12) (initializers)]
    [get : (Array (-> tc.TcMacroState i64) 12) (accessors)]
    [slot : i64 0]
    (while (< slot 12)
      (let
        [initialize : (-> tc.TcMacroState i64) (array-ref init slot)]
        [address-of : (-> tc.TcMacroState i64) (array-ref get slot)]
        (begin
          (test.assert-i64-eq
            (tc.tc-macro-state-slot-address a slot)
            0
            "A starts lazy")
          (test.assert-i64-eq
            (tc.tc-macro-state-slot-address b slot)
            0
            "B starts lazy")
          (let
            [address-a : i64 (initialize a)]
            [address-b : i64 (address-of b)]
            [before : i64 (profile.alloc-total)]
            [same-a : i64 (initialize a)]
            [same-b : i64 (initialize b)]
            [hot-a : i64 (address-of a)]
            [hot-b : i64 (address-of b)]
            [after : i64 (profile.alloc-total)]
            (begin
              (test.assert-true
                (and
                  (> address-a 0)
                  (> address-b 0)
                  (not (= address-a address-b)))
                "independent cells")
              (test.assert-i64-eq
                (tc.tc-macro-state-slot-address a slot)
                address-a
                "exact A slot")
              (test.assert-i64-eq
                (tc.tc-macro-state-slot-address b slot)
                address-b
                "exact B slot")
              (test.assert-true
                (and
                  (= same-a address-a)
                  (= same-b address-b)
                  (= hot-a address-a)
                  (= hot-b address-b))
                "initialization is idempotent")
              (test.assert-i64-eq
                after
                before
                "warm initialization and access allocate nothing")))
          (set! slot (+ slot 1)))))))

(test
  macro-state-cells-own-lifetime
  (let
    [owner-a : i64 (arena.tl_arena_make)]
    [owner-b : i64 (arena.tl_arena_make)]
    [scratch : i64 (arena.tl_arena_make)]
    [a : tc.TcMacroState (new-state owner-a)]
    [b : tc.TcMacroState (new-state owner-b)]
    (begin
      (in-arena (arena.Arena scratch) (initialize-and-probe a b))
      (unsafe
        ;; lint-allow: raw-arena-op -- exercise retirement of a different owner.
        (arena.destroy (arena.Arena scratch)))
      ;; Typed writes after scratch retirement still reach the owner cells.
      (tc.tc-macro-result-identity-state-data-set!
        a
        (tc.TcMacroResultIdentityStateData 11 12 13 14 15))
      (tc.tc-macro-result-identity-state-data-set!
        b
        (tc.TcMacroResultIdentityStateData 21 22 23 24 25))
      (tc.macro-alias-derived-cache-reset-for-state! a)
      (unsafe
        ;; lint-allow: raw-arena-op -- no A handles are used after this point.
        (arena.destroy (arena.Arena owner-a)))
      (let
        [data : tc.TcMacroResultIdentityStateData
          (tc.tc-macro-result-identity-state-data b)]
        (test.assert-true
          (and
            (= data.table-id 21)
            (= data.reset-generation 22)
            (= data.source-count 23)
            (= data.module-id 24)
            (= data.macro-id 25))
          "resetting and destroying A preserves every field in B"))
      (test.assert-true
        (> (tc.tc-macro-helper-state-address b) 0)
        "B remains live")
      (unsafe
        ;; lint-allow: raw-arena-op -- final retirement after all B assertions.
        (arena.destroy (arena.Arena owner-b))))))