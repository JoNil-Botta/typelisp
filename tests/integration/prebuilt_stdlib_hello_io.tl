;; A minimal stdlib program links its io calls from the prebuilt sysroot.
(import stdlib.io)

(define (main) : i64
  (io.print "hello prebuilt\n")
  42)