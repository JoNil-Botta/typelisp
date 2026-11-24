;; #9257: `args.option-list-copy!` requires `unsafe` because it reads through a
;; raw `(MutPtr ArgsOption)` argument.
(import stdlib.args)

(define (main) : i64
  (let
    [dst : (__tl_dyn-array args.ArgsOption) (__tl_make-array args.ArgsOption 1)]
    [src : (MutPtr args.ArgsOption) (ptr-null : (MutPtr args.ArgsOption))]
    (args.option-list-copy! (&mut dst) src 0 1)
    0))