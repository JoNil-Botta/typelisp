(import stdlib.process_borrowed)

; Must fail: the returned command would borrow executable text allocated in the
; inner arena.
(define (main [outer : String]) : (process_borrowed.ProcessBorrowedCommand
    outer
    outer
    outer
    outer
    outer)
  (with-arena
    inner
    (let
      [exe : String "inner"]
      (process_borrowed.process-borrowed-command-empty (& exe)))))