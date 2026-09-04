(import compiler_ir_types as ir)
(import compiler_optimize as opt)
(import stdlib.profile)
(import stdlib.test)

(define (fixture-value [index : i64]) : ir.CompilerIrValue
  (match index
    [0 (ir.CompilerIrValue.Var 100)]
    [1 (ir.CompilerIrValue.Global 101)]
    [2 (ir.CompilerIrValue.GlobalAddr 102)]
    [3 (ir.CompilerIrValue.Function 103)]
    [4 (ir.CompilerIrValue.I64 -104)]
    [5 (ir.CompilerIrValue.F64 9223372036854775808)]
    [6 (ir.CompilerIrValue.Bool true)]
    [7 (ir.CompilerIrValue.Char 'x')]
    [8 (ir.CompilerIrValue.String "preserved string")]
    [9 (ir.CompilerIrValue.Bytes "preserved bytes")]
    [10 (ir.CompilerIrValue.RuntimeGlobal 110)]
    [_ (ir.CompilerIrValue.Unit)]))

(define (check-slice [start : i64] [count : i64] [from : i64] [to : i64]) : unit
  (let
    [slots : (__tl_dyn-array ir.CompilerIrPhiInput)
      (__tl_make-array ir.CompilerIrPhiInput 14)]
    [index : i64 0]
    (begin
      (while (< index 14)
        (begin
          (set!
            (array-ref slots index)
            (ir.CompilerIrPhiInput
              (fixture-value (- index 1))
              (if (= (% index 2) 0)
                -7
                9000000000)))
          (set! index (+ index 1))))
      (let
        [inputs : ir.CompilerIrPhiInputSeq
          (ir.CompilerIrPhiInputSeq slots start count)]
        [result : ir.CompilerIrPhiInputSeq
          (ir.compiler-ir-phi-input-seq-relabel
            (ir.compiler-ir-global-shared-view inputs)
            from
            to)]
        (begin
          (test.assert-i64-eq result.len count "visible length")
          (test.assert-i64-eq result.start 0 "compact output")
          (test.assert-i64-eq
            (array-length result.slots)
            count
            "exact capacity")
          (set! index 0)
          (while (< index count)
            (let
              [original : ir.CompilerIrPhiInput
                (ir.compiler-ir-phi-input-seq-ref
                  (ir.compiler-ir-global-shared-view inputs)
                  index)]
              [actual : ir.CompilerIrPhiInput
                (ir.compiler-ir-phi-input-seq-ref
                  (ir.compiler-ir-global-shared-view result)
                  index)]
              [label : i64
                (if (= (% (+ start index) 2) 0)
                  -7
                  9000000000)]
              (begin
                (test.assert-i64-eq original.label label "input unchanged")
                (test.assert-i64-eq
                  actual.label
                  (if (= label from)
                    to
                    label)
                  "only matching edges change")
                (test.assert-true
                  (opt.opt-value-eq actual.value original.value)
                  "values and order preserved")
                (test.assert-true
                  (opt.opt-value-eq
                    original.value
                    (fixture-value (- (+ start index) 1)))
                  "input values unchanged")
                (set! index (+ index 1))))))))))

(test
  phi-relabel-values-slices-and-labels
  (begin
    (check-slice 1 12 -7 9000000000)
    (check-slice 1 12 9000000000 -7)
    (check-slice 1 12 404 -7)
    (check-slice 1 12 -7 -7)
    (check-slice 0 14 -7 0)
    (check-slice 2 1 -7 99)
    (check-slice 1 1 -7 99)
    (check-slice 14 0 -7 99)))

(test
  phi-relabel-linear-allocation
  (let
    [count : i64 4096]
    [slots : (__tl_dyn-array ir.CompilerIrPhiInput)
      (__tl_make-array ir.CompilerIrPhiInput count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ir.CompilerIrPhiInput (ir.CompilerIrValue.Var index) 7))
          (set! index (+ index 1))))
      (let
        [before : i64 (profile.alloc-total)]
        [result : ir.CompilerIrPhiInputSeq
          (ir.compiler-ir-phi-input-seq-relabel
            (ir.CompilerIrPhiInputSeq slots 0 count)
            7
            99)]
        [allocated : i64 (- (profile.alloc-total) before)]
        [last : ir.CompilerIrPhiInput
          (ir.compiler-ir-phi-input-seq-ref result (- count 1))]
        (begin
          ;; Leave room for record-layout changes while rejecting quadratic copies.
          (test.assert-true
            (<= allocated (+ (* count 128) 128))
            "one linear allocation, no recursive prepend")
          (test.assert-i64-eq last.label 99 "last edge relabeled")
          (test.assert-true
            (opt.opt-value-eq last.value (ir.CompilerIrValue.Var (- count 1)))
            "last value preserved"))))))