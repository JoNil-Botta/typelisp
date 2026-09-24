;; A dispatch back to already-processed loop headers and forward to distinct
;; exits exercises the repeated-scan case in the CFG index's actual RPO.
(import compiler_optimize as opt)
(import compiler_ir_types as ir)
(import compiler_builtin_ids as cbi)
(import stdlib.string)
(import stdlib.test)
(import stdlib.arena)

(define (graph [headers : i64] [exits : i64] [join : bool]) : opt.OptCfgIndex
  (let
    [count : i64 (+ (+ headers exits) 1)]
    [blocks : (__tl_dyn-array ir.CompilerIrBlock)
      (__tl_make-array ir.CompilerIrBlock count)]
    [cases : (__tl_dyn-array ir.CompilerIrSwitchCase)
      (__tl_make-array ir.CompilerIrSwitchCase (+ headers exits))]
    [labels : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [i : i64 (- count 1)]
    (begin
      ;; Label intern order need not match CFG order.
      (while (>= i 0)
        (begin
          (set!
            (array-ref labels i)
            (ir.compiler-ir-label (string.int->string (+ i 10000))))
          (set! i (- i 1))))
      (set! i 0)
      (while (< i (+ headers exits))
        (begin
          (set!
            (array-ref cases i)
            (ir.CompilerIrSwitchCase.Case
              i
              (array-ref
                labels
                (if (< i headers)
                  i
                  (+ i 1)))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i count)
        (let
          [slots : (__tl_dyn-array ir.CompilerIrInstr)
            (__tl_make-array ir.CompilerIrInstr 1)]
          (begin
            (set!
              (array-ref slots 0)
              (cond
                [(and join (= i 0))
                  (ir.CompilerIrInstr.Branch
                    (ir.CompilerIrValue.Var 0)
                    (array-ref labels 1)
                    (array-ref labels (+ headers 1)))]
                [(< i headers)
                  (ir.CompilerIrInstr.Jump (array-ref labels (+ i 1)))]
                [(= i headers)
                  (ir.CompilerIrInstr.Switch
                    (ir.CompilerIrValue.Var 0)
                    (+ headers exits)
                    (ir.CompilerIrSwitchCaseSeq
                      (opt.compiler-opt-global-shared-view cases)
                      (+ headers exits))
                    (array-ref labels 0))]
                [else
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 i)))]))
            (set!
              (array-ref blocks i)
              (ir.CompilerIrBlock.Block
                (array-ref labels i)
                (ir.CompilerIrInstrSeq slots 1)))
            (set! i (+ i 1)))))
      (opt.opt-cfg-index-build
        (ir.CompilerIrBlockList.Array (ir.CompilerIrBlockSeq blocks count))))))

(define (check-rpo [headers : i64] [exits : i64]) : unit
  (let
    [index (graph headers exits false)]
    [processed : (__tl_dyn-array bool)
      (__tl_make-array bool (+ (+ headers exits) 1))]
    [i : i64 0]
    (begin
      (test.assert-i64-eq
        index.reach-count
        (+ (+ headers exits) 1)
        "all graph blocks reachable")
      (while (< i index.reach-count)
        (let
          [id : i64 (array-ref index.rpo i)]
          (begin
            (when
              (> id headers)
              (test.assert-i64-eq
                (opt.opt-load-gvn-take-pred
                  (opt.compiler-opt-global-shared-view index)
                  (opt.compiler-opt-global-shared-view processed)
                  id)
                (if (and
                  (<= (+ headers exits) 32)
                  (= i (- index.reach-count 1)))
                  headers
                  -1)
                "only the last exit takes a small dispatch state"))
            (set! (array-ref processed id) true)
            (set! i (+ i 1))))))))

(define (check-shared-exit [headers : i64] [exits : i64]) : unit
  (let
    [index (graph headers exits true)]
    [processed : (__tl_dyn-array bool)
      (__tl_make-array bool (+ (+ headers exits) 1))]
    [i : i64 0]
    (begin
      (while (< i (array-length processed))
        (begin
          (set! (array-ref processed i) true)
          (set! i (+ i 1))))
      ;; Even after all other readers finish, a join may reread both incoming
      ;; states while constructing its phis. It must not take either state.
      (test.assert-i64-eq
        (opt.opt-load-gvn-take-pred index processed (+ headers 1))
        -1
        "a join retains both predecessor exit states"))))

(test
  bounded_load_gvn_last_reader
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [headers : i64 1]
      (while (<= headers 33)
        (begin
          (let
            [exits : i64 1]
            (while (<= exits 33)
              (begin
                (let
                  [scope (arena.make)]
                  (begin
                    (in-arena
                      scope
                      (begin
                        (check-rpo headers exits)
                        (check-shared-exit headers exits)))
                    (arena.destroy-safe! scope)))
                (set! exits (+ exits 1)))))
          (set! headers (+ headers 1)))))
    (let
      [scope (arena.make)]
      (begin
        (in-arena scope (check-rpo 2048 2048))
        (arena.destroy-safe! scope)))))