(import compiler_ir_types as ir)
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (let
    [mode : i64 (string.>int (io.arg 1))]
    [index : i64 (string.>int (io.arg 2))]
    (match mode
      [0
        (let
          [seq : ir.CompilerIrInstrSeq
            (ir.compiler-ir-instr-seq1 (Return (Some (I64 42))))]
          (match (ir.compiler-ir-instr-seq-borrow seq index)
            [(Return (Some (I64 value))) value]
            [_ 0]))]
      [1
        (let
          [seq : ir.CompilerIrPhiInputSeq
            (ir.CompilerIrPhiInputSeq
              (__tl_make-array
                (ir.CompilerIrPhiInput (I64 7) 11)
                (ir.CompilerIrPhiInput (I64 9) 42))
              1
              1)]
          [entry (ir.compiler-ir-phi-input-seq-borrow seq index)]
          entry.label)]
      [_
        (let
          [seq : ir.CompilerIrBlockSeq
            (ir.compiler-ir-block-list-seq (ir.compiler-ir-block-list-empty))]
          (match (ir.compiler-ir-block-seq-borrow seq index)
            [(Block label _) label]))])))