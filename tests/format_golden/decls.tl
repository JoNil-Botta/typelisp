(import "std.tl")
(import "ffi.tl")

(extern (print-string [arg0 : String]) : unit (:abi c) (:symbol "tl_print_string"))
(extern (print-int [arg0 : i64]) : unit)

(define KEY_A : i64 1)
(define KEY_B : i64 2)
