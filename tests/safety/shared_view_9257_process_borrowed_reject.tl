;; #9257: `stdlib.process_borrowed/borrowed-string-list-shared-view` must not exist.
(import stdlib.process_borrowed)

(define (main) : i64
  (let
    [arg : String "hello"]
    [list : (process_borrowed.ProcessBorrowedStringList arg)
      (process_borrowed.args-single (& arg))]
    [_alias : (process_borrowed.ProcessBorrowedStringList arg)
      (process_borrowed.borrowed-string-list-shared-view (& list))]
    0))