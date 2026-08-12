;; Expression macro expansion must recurse through every operand-bearing raw
;; pointer form before the ordinary unsafe/typechecking pass (#6029).
(import stdlib.test)

(defmacro (raw-pointer-operand [value : Expr]) : Expr
  value)

(test
  macro-expands-in-every-raw-pointer-operand
  (let
    [slot : i64 41]
    (unsafe
      (let
        [address : u64 (ptr->int (ptr-addr-of slot))]
        [casted : (Ptr u8)
          (ptr-cast (raw-pointer-operand (ptr-addr-of slot)) : (Ptr u8))]
        [round-trip : (Ptr i64)
          (int->ptr (raw-pointer-operand address) : (Ptr i64))]
        (begin
          (test.assert-false
            (ptr-null? (raw-pointer-operand (ptr-addr-of slot)))
            "ptr-null? expands its pointer operand")
          (test.assert-i64-eq
            (ptr-read (raw-pointer-operand (ptr-addr-of slot)))
            41
            "ptr-read expands its pointer operand")
          (ptr-write!
            (raw-pointer-operand (ptr-addr-of slot))
            (raw-pointer-operand 42))
          (test.assert-i64-eq
            (ptr-read
              (ptr-offset
                (raw-pointer-operand (ptr-addr-of slot))
                (raw-pointer-operand 0)))
            42
            "ptr-offset expands both operands")
          (test.assert-false
            (ptr-null? casted)
            "ptr-cast expands its operand and preserves the target type")
          (test.assert-true
            (= (ptr->int (raw-pointer-operand casted)) address)
            "ptr->int expands its pointer operand")
          (test.assert-i64-eq
            (ptr-read round-trip)
            42
            "int->ptr expands its operand and preserves the target type"))))))