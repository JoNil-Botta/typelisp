;; format_render_buf.tl - Shared formatter render buffer helpers.
(import stdlib.string as string)

(define (format-width) : i64
  80)

(define (spaces [count : i64]) : String
  (let
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i count)
        (begin
          (set! out (string.string-concat3 out " " ""))
          (set! i (+ i 1))))
      out)))

;; Flat byte buffer for the render pass. The chunk-list `TextBuf` allocates a
;; cons per appended fragment, and rendering the corpus appends roughly one
;; fragment per token plus per line break -- millions of tiny allocations. A
;; growable byte array instead copies each fragment into place with one memcpy
;; (`str-copy-bytes-into`) and materializes the result with a single
;; `string-from-bytes`, with no per-fragment allocation.
(defstruct FmtRenderBuf
  (data (Array u8))
  (len i64))

(define (fmt-render-buf-new) : FmtRenderBuf
  (FmtRenderBuf (make-array u8 1024) 0))

(define (fmt-render-buf-reserve [buf : FmtRenderBuf] [needed : i64]) : unit
  (let
    [cur : (Array u8) (struct-get buf data)]
    [cap : i64 (array-length cur)]
    (if (<= needed cap)
      unit
      (let
        [newcap : i64 cap]
        (begin
          (while (< newcap needed)
            (set! newcap (* newcap 2)))
          (let
            [bigger : (Array u8) (make-array u8 newcap)]
            [n : i64 (struct-get buf len)]
            (begin
              (if (> n 0)
                (string.str-copy-bytes-into
                  (unsafe
                    (ptr-cast (array-data cur) : (Ptr u8)))
                  (unsafe
                    (array-data bigger))
                  0
                  n)
                unit)
              (set! (struct-get buf data) bigger))))))))

(define (fmt-render-buf-append [buf : FmtRenderBuf] [s : String]) : unit
  (let
    [slen : i64 (string.string-length s)]
    (if (= slen 0)
      unit
      (let
        [base : i64 (struct-get buf len)]
        (begin
          (fmt-render-buf-reserve buf (+ base slen))
          (string.str-copy-bytes-into
            (unsafe
              (string-data (& s)))
            (unsafe
              (array-data (struct-get buf data)))
            base
            slen)
          (set! (struct-get buf len) (+ base slen)))))))

(define (fmt-render-buf-string [buf : FmtRenderBuf]) : String
  (let
    [n : i64 (struct-get buf len)]
    (if (= n 0)
      ""
      (unsafe
        (string-from-bytes
          (ptr-cast (array-data (struct-get buf data)) : (Ptr u8))
          n)))))

;; Append a newline plus `indent` spaces to the buffer in place.
(define (render-newline-into! [buf : FmtRenderBuf] [indent : i64]) : unit
  (begin
    (fmt-render-buf-append buf "\n")
    (fmt-render-buf-append buf (spaces indent))))