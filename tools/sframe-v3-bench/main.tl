;; main.tl - scalable GNU SFrame v3 codec workload (#7621).
(import compiler_sframe_v3 as sframe)
(import stdlib.io)

(define (sframe-v3-bench-function-count) : i64
  (cond [(= (io.arg-count) 1) 1000] [(= (io.arg-count) 2) 10000] [else 100000]))

(define (sframe-v3-bench-image [function-count : i64]) : sframe.CompilerSframeV3Image
  (let
    [functions : (__tl_dyn-array sframe.CompilerSframeV3Function)
      (__tl_make-array sframe.CompilerSframeV3Function function-count)]
    [rows : (__tl_dyn-array sframe.CompilerSframeV3Row)
      (__tl_make-array sframe.CompilerSframeV3Row function-count)]
    [index : i64 0]
    (begin
      (while (< index function-count)
        (begin
          (set!
            (array-ref rows index)
            (sframe.CompilerSframeV3Row
              0
              false
              sframe.compiler-sframe-v3-dwarf-rsp
              false
              8
              (sframe.CompilerSframeV3Rule.Fixed -8)
              (sframe.CompilerSframeV3Rule.Unavailable)))
          (set!
            (array-ref functions index)
            (sframe.CompilerSframeV3Function
              (+ 1048576 (* index 8))
              8
              false
              0
              false
              false
              0
              0
              index
              1))
          (set! index (+ index 1))))
      (sframe.CompilerSframeV3Image 0 -8 true false functions rows))))

(define (sframe-v3-bench-run [function-count : i64]) : i64
  (let
    [image : sframe.CompilerSframeV3Image
      (sframe-v3-bench-image function-count)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.CompilerSframeV3Limits
        16777216
        16777216
        100000
        100000
        134217728
        1000000)]
    (match (sframe.compiler-sframe-v3-plan (& image) (& limits))
      [(sframe.ResultCompilerSframeV3Plan.Err _)
        (begin
          (io.print-error "sframe-v3-bench: planning failed\n")
          1)]
      [(sframe.ResultCompilerSframeV3Plan.Ok plan)
        (match (sframe.compiler-sframe-v3-encode (& image) 524288 (& limits))
          [(sframe.ResultCompilerSframeV3Bytes.Err _)
            (begin
              (io.print-error "sframe-v3-bench: encoding failed\n")
              1)]
          [(sframe.ResultCompilerSframeV3Bytes.Ok bytes)
            (match (sframe.compiler-sframe-v3-decode
              (& bytes)
              524288
              (& limits))
              [(sframe.ResultCompilerSframeV3Image.Err _)
                (begin
                  (io.print-error "sframe-v3-bench: decoding failed\n")
                  1)]
              [(sframe.ResultCompilerSframeV3Image.Ok decoded)
                (let
                  [decoded-function-count : i64
                    (array-length decoded.functions)]
                  ;; The allocation/byte counters are derived from the codec's
                  ;; explicit ownership model: one output buffer, one decoded
                  ;; function array, and one flat decoded row array.
                  (begin
                    (io.println "functions={}" function-count)
                    (io.println "rows={}" plan.row-count)
                    (io.println "output_bytes={}" plan.total-bytes)
                    (io.println "bytes_visited={}" (* plan.total-bytes 2))
                    (io.println "modeled_codec_owned_allocations={}" 3)
                    (io.println
                      "modeled_codec_owned_bytes={}"
                      (+ plan.total-bytes (* function-count 320)))
                    (if (= decoded-function-count function-count)
                      0
                      1)))])])])))

(define (main) : i64
  (sframe-v3-bench-run (sframe-v3-bench-function-count)))