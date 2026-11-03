(import compiler_intern as ci)
(import compiler_builtin_ids as cbi)
(cfg test (import compiler_ast_types as ast))
(import compiler_typecheck_core as tc)
(import compiler_typecheck_variance_dag as fixture)
(cfg test (import stdlib.io))
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(cfg test (import stdlib.iterator))

(defstruct VarianceIdentityFixture
  (context tc.TcContext)
  (ordinary i64)
  (qualified i64))

(define (variance-identity-fixture) : VarianceIdentityFixture
  ;; Reserve owner tokens through the ordinary allocator; no owner is reused.
  (let
    [boundary : i64
      (* (/ (+ ci.intern-next-structural-owner 2097151) 2097152) 2097152)]
    (while (< ci.intern-next-structural-owner boundary)
      (let
        [_reserved : i64 (ci.intern-structural-owner-allocate!)]
        unit)))
  (ci.intern-reset!)
  (cbi.compiler-builtin-initialize-for-parse!)
  (let
    [module-id : i64 (ci.intern "qualified")]
    [target-id : i64 (ci.intern "Target")]
    [_r : i64 (ci.intern "r")]
    [_value : i64 (ci.intern "value")]
    [dummy : i64 (ci.intern "dummy-owner-key")]
    [serial : i64 0]
    [last : i64
      (bit-and
        (ci.intern-composite-pair-id dummy serial)
        (ci.intern-structural-key-index-mask))]
    [wanted : i64 (ci.intern-pool-len)]
    (when (>= last wanted) (set! wanted (+ last 2)))
    (while (< (ci.intern-pool-len) wanted)
      (let
        [_pad : i64
          (ci.intern
            (str_cat.str-cat "owner-key-pad-" (string.int->string serial)))]
        (+= serial 1)))
    (while (< last (- wanted 1))
      (+= serial 1)
      (set!
        last
        (bit-and
          (ci.intern-composite-pair-id dummy serial)
          (ci.intern-structural-key-index-mask))))
    (let
      [qualified : i64 (ci.intern-composite-pair-id module-id target-id)]
      [ordinary : i64 (ci.intern "Ordinary")]
      [ctx : tc.TcContext
        (fixture.variance-source-context
          "(defstruct Ordinary (:lifetimes r) (value (& r i64)))
         (defstruct Wrapper (:lifetimes r) (positive (Ordinary r)) (negative (qualified.Target r)))
         (module qualified)
         (defstruct Target (:lifetimes r) (value (-> (& r i64) i64)))")]
      (VarianceIdentityFixture ctx ordinary qualified))))

(define (variance-identity-answer [ctx : tc.TcContext] [name : i64]) : i64
  (tc.tc-variance-code
    (tc.tc-nominal-lifetime-variance-at ctx name 0 tc.TcNameIdList.Nil)))

(define (variance-identity-fresh-context [ctx : tc.TcContext]) : tc.TcContext
  (let
    [fresh : tc.TcContext ctx]
    (set! fresh.job-state (tc.tc-job-state-new))
    fresh))

(cfg
  test
  (define (variance-identity-self-test) : unit
    (let
      [installed : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      [f : VarianceIdentityFixture (variance-identity-fixture)]
      ;; The qualified declaration's owner key differs in bits discarded by
      ;; the old owner*4096 key. Both declarations live in one unchanged epoch.
      (unless
        (and
          (!= f.ordinary f.qualified)
          (= (* f.ordinary 4096) (* f.qualified 4096)))
        (io.panic "identity collision fixture did not reach the boundary"))
      (for [mode (iterator.range 0 3)]
        (tc.tc-variance-test-reset! mode)
        (unless
          (and
            (= (variance-identity-answer f.context f.ordinary) 1)
            (= (variance-identity-answer f.context f.qualified) 2)
            (= (variance-identity-answer f.context f.qualified) 2))
          (io.panic "cross-query declaration identity: forward 1/2/2"))
        ;; A distinct job ensures reverse order starts with an empty cache.
        (let
          [reverse : tc.TcContext (variance-identity-fresh-context f.context)]
          (unless
            (and
              (= (variance-identity-answer reverse f.qualified) 2)
              (= (variance-identity-answer reverse f.ordinary) 1)
              (= (variance-identity-answer reverse f.qualified) 2))
            (io.panic "cross-query declaration identity: reverse 2/1/2")))
        ;; The query table must also distinguish the two dependencies before
        ;; either has a completed answer. Reuse a fresh job for each oracle.
        (let
          [wrapper : tc.TcContext (variance-identity-fresh-context f.context)]
          (unless
            (= (variance-identity-answer wrapper (ci.intern "Wrapper")) 3)
            (io.panic "same-query opposite declarations must be invariant"))))
      (unless
        (=
          (tc.tc-variance-code
            (tc.tc-nominal-lifetime-variance-at
              f.context
              f.ordinary
              4096
              tc.TcNameIdList.Nil))
          3)
        (io.panic "variance parameter 4096 was not rejected"))
      (io.print
        "IDENTITY owner={} forward=1/2/2 reverse=2/1/2 wrapper=3 modes=0,1,2\n"
        ci.intern-active-structural-owner)
      (tc.tc-variance-test-reset! 0)
      (ast.ast-node-pool-context-install! installed))))

(cfg
  test
  (define (variance-identity-boundaries-self-test) : unit
    (let
      [owners : (Array i64 8)
        (array 0 1 2097151 2097152 2097153 4194304 2145386496 2147483647)]
      [lanes : (Array i64 3) (array 0 620 2147483647)]
      [parameters : (Array i64 3) (array 0 1 4095)]
      ;; Synthetic values exercise the complete encoded key domain, including
      ;; reserved lane zero, without allocating billions of structural records.
      (for [a (iterator.range 0 8)]
        (for [b (iterator.range 0 3)]
          (let
            [left : i64
              (+
                4611686018427387904
                (+ (* (array-ref owners a) 2147483648) (array-ref lanes b)))]
            (for [c (iterator.range 0 8)]
              (for [d (iterator.range 0 3)]
                (let
                  [right : i64
                    (+
                      4611686018427387904
                      (+
                        (* (array-ref owners c) 2147483648)
                        (array-ref lanes d)))]
                  (for [p (iterator.range 0 3)]
                    (for [q (iterator.range 0 3)]
                      (unless
                        (=
                          (tc.tc-variance-position-same?
                            left
                            (array-ref parameters p)
                            right
                            (array-ref parameters q))
                          (and (= a c) (= b d) (= p q)))
                        (io.panic "exact variance key boundary collision")))))))
            (unless
              (and
                (not
                  (tc.tc-variance-position-same? left 0 (array-ref lanes b) 0))
                (not (tc.tc-variance-position-same? left 0 left 4096)))
              (io.panic
                "structural/ordinary or parameter coordinates collapsed"))))))))

(test variance-exact-declaration-identity (variance-identity-self-test))

(test variance-exact-key-boundary-fuzz (variance-identity-boundaries-self-test))

(define (main) : i64
  (cfg
    test
    (begin
      (variance-identity-self-test)
      (variance-identity-boundaries-self-test)))
  42)