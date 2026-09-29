;; main.tl - scalable .eh_frame/.eh_frame_hdr codec workload (#7736).
;;
;; Builds a relocatable-style section of one CIE and N FDEs (the GNU as
;; fixture's framed-function program), decodes it, canonically encodes every
;; FDE at a distinct final address, and encodes and decodes the search header.
(import compiler_eh_frame as eh)
(import stdlib.io)

(define (eh-frame-bench-count) : i64
  (cond [(= (io.arg-count) 1) 1000] [(= (io.arg-count) 2) 10000] [else 100000]))

(define (eh-frame-bench-cie) : (__tl_dyn-array u8)
  (__tl_make-array
    0x14
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x01
    0x7a
    0x52
    0x00
    0x01
    0x78
    0x10
    0x01
    0x1b
    0x0c
    0x07
    0x08
    0x90
    0x01
    0x00
    0x00))

(define (eh-frame-bench-program) : (__tl_dyn-array u8)
  (__tl_make-array
    0x41
    0x0e
    0x10
    0x86
    0x02
    0x43
    0x0d
    0x06
    0x41
    0x83
    0x03
    0x49
    0x0a
    0x45
    0x0c
    0x07
    0x08
    0x41
    0x0b
    0x45
    0xc3
    0x41
    0x0c
    0x07
    0x08))

(define (eh-frame-bench-put-u32!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [at : i64]
  [value : i64]) : unit
  (let
    [index : i64 0]
    (while (< index 4)
      (begin
        (set!
          (array-ref bytes (+ at index))
          (cast (bit-and (shr value (* index 8)) 255) : u8))
        (set! index (+ index 1))))))

;; 24 CIE bytes, then 44-byte FDEs: length 40, CIE pointer, zero location
;; field, range 0x1b, empty augmentation, 25 program bytes, 3 nops.
(define (eh-frame-bench-section [count : i64]) : (__tl_dyn-array u8)
  (let
    [cie : (__tl_dyn-array u8) (eh-frame-bench-cie)]
    [program : (__tl_dyn-array u8) (eh-frame-bench-program)]
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 (+ 24 (* count 44)))]
    [index : i64 0]
    (begin
      (while (< index 24)
        (begin
          (set! (array-ref bytes index) (array-ref cie index))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index count)
        (let
          [at : i64 (+ 24 (* index 44))]
          [byte : i64 0]
          (begin
            (eh-frame-bench-put-u32! (&mut bytes) at 40)
            (eh-frame-bench-put-u32! (&mut bytes) (+ at 4) (+ at 4))
            (eh-frame-bench-put-u32! (&mut bytes) (+ at 12) 0x1b)
            (while (< byte 25)
              (begin
                (set!
                  (array-ref bytes (+ (+ at 17) byte))
                  (array-ref program byte))
                (set! byte (+ byte 1))))
            (set! index (+ index 1)))))
      bytes)))

(define (eh-frame-bench-run [count : i64]) : i64
  (let
    [section : (__tl_dyn-array u8) (eh-frame-bench-section count)]
    [limits : eh.CompilerEhFrameLimits (eh.compiler-eh-frame-default-limits)]
    (match (eh.compiler-eh-frame-decode (& section) 1 (& limits))
      [(eh.ResultCompilerEhFrameImage.Err error)
        (begin
          (io.print-error error.message)
          1)]
      [(eh.ResultCompilerEhFrameImage.Ok image)
        (let
          [images : (__tl_dyn-array eh.CompilerEhFrameImage)
            (__tl_make-array eh.CompilerEhFrameImage 1)]
          [selections : (__tl_dyn-array eh.CompilerEhFrameSelection)
            (__tl_make-array eh.CompilerEhFrameSelection count)]
          [index : i64 0]
          (begin
            (set! (array-ref images 0) image)
            ;; Reverse final order, 32 bytes of code per function.
            (while (< index count)
              (begin
                (set!
                  (array-ref selections index)
                  (eh.CompilerEhFrameSelection
                    0
                    index
                    (+ 0x400000 (* (- (- count 1) index) 32))))
                (set! index (+ index 1))))
            (match (eh.compiler-eh-frame-encode
              (& images)
              (& selections)
              0x9000000
              (& limits))
              [(eh.ResultCompilerEhFrameOutput.Err error)
                (begin
                  (io.print-error error.message)
                  1)]
              [(eh.ResultCompilerEhFrameOutput.Ok output)
                (match (eh.compiler-eh-frame-encode-header
                  (& output.rows)
                  0x8000000
                  0x9000000
                  (& limits))
                  [(eh.ResultCompilerEhFrameHeaderBytes.Ok header)
                    (match (eh.compiler-eh-frame-decode-header
                      (& header)
                      0x8000000
                      (& limits))
                      [(eh.ResultCompilerEhFrameHeader.Ok table)
                        (begin
                          (io.println "fdes={}" count)
                          (io.println "input_bytes={}" (array-length section))
                          (io.println
                            "output_bytes={}"
                            (array-length output.bytes))
                          (io.println "header_bytes={}" (array-length header))
                          ;; Decode reads the input once; encoding reads each
                          ;; program once and writes the output; the header is
                          ;; written and read back.
                          (io.println
                            "bytes_visited={}"
                            (+
                              (+
                                (array-length section)
                                (* 2 (array-length output.bytes)))
                              (* 2 (array-length header))))
                          (if (= (array-length table.rows) count)
                            0
                            1))]
                      [(eh.ResultCompilerEhFrameHeader.Err error)
                        (begin
                          (io.print-error error.message)
                          1)])]
                  [_
                    (begin
                      (io.print-error
                        "eh-frame-bench: header encoding failed\n")
                      1)])])))])))

(define (main) : i64
  (eh-frame-bench-run (eh-frame-bench-count)))