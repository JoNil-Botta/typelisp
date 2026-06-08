(import "std.tl")

(extern (print-string [arg0 : String]) : unit)

(defenum Maybe
  (Some i64)
  (None))

(defstruct Point
  (x i64)
  (y i64))