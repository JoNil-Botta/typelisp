;; Refs #9436: the borrowed collector retains the original visitor's set/order.
(import compiler_optimize as opt)
(import compiler_ir_types as ir)
(import compiler_ir_text as irt)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.test)

(define (visitor-scan [frame : i64] [blocks : ir.CompilerIrBlockList]) : opt.OptFunctionAddrTakenScan
  (let
    [scan (opt.opt-function-addr-taken-scan-new frame)]
    (opt.opt-blocks-visit
      blocks
      opt.opt-function-addr-taken-scan-instr!
      (&mut scan))
    scan))

(test
  borrowed-address-collector-matches-visitor
  (for [kind (iterator.range 0 2)]
    (for [mode (iterator.range 0 4)]
      (let
        [frame : i64
          (cond [(= mode 0) 0] [(= mode 1) 1] [(= mode 2) 4] [else 32])]
        ;; Small frames deliberately exercise the collector's out-of-range
        ;; source handling without asking the whole-function verifier to admit it.
        [text
          (if (= kind 0)
            "entry:\n%1 = mov 2 : i64\njump end\nend:\nreturn"
            "entry:\n%1 = mov 2 : i64\njump middle\nmiddle:\n%4 = addr_of %2\n%5 = addr_of %31\njump end\nend:\n%6 = addr_of %2\n%7 = addr_of %0\nreturn")]
        [expected (visitor-scan frame (irt.blocks (string.copy (& text))))]
        [blocks (irt.blocks text)]
        [actual (opt.opt-function-addr-taken-scan-new frame)]
        (opt.opt-function-addr-taken-scan-blocks! (&mut actual) (& blocks))
        (test.assert-i64-eq
          (array-length actual.marks)
          (array-length expected.marks)
          "no addresses keep an empty mark array")
        (test.assert-i64-eq
          actual.ids.len
          expected.ids.len
          "the same bounded sources are listed once")
        (when
          (= (array-length actual.marks) (array-length expected.marks))
          (for [index (iterator.range 0 (array-length expected.marks))]
            (test.assert-true
              (=
                (array-ref actual.marks index)
                (array-ref expected.marks index))
              "late-block marks equal the original visitor")))
        (when
          (= actual.ids.len expected.ids.len)
          (for [index (iterator.range 0 expected.ids.len)]
            (test.assert-i64-eq
              (array-ref actual.ids.slots index)
              (array-ref expected.ids.slots index)
              "first-encounter order and duplicate elimination are unchanged")))))))