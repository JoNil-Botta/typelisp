;: An element read lends the whole array, which a live mutable borrow excludes.
(define (grow [target : (&mut target (__tl_dyn-array String))] [value : String]) : unit
  (__tl_array-push! target value))

(define (run [names : (__tl_dyn-array String)]) : i64
  (let
    [handle : (&mut names (__tl_dyn-array String)) (&mut names)]
    [length : i64 (__tl_string_length (array-ref names 0))]
    (begin
      (grow handle "x")
      length)))

(define (main) : i64
  0)