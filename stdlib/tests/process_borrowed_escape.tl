(import "stdlib/process_borrowed.tl")

; Must fail: the returned command would borrow executable text allocated in the
; inner arena.
(define (main [outer : String]) : (ProcessBorrowedCommand
  outer
  outer
  outer
  outer
  outer)
  (with-arena
    inner
    (let
      [exe : String "inner"]
      (process-borrowed-command-empty (& exe)))))