;;;; Arena-aware text buffer utilities for incremental string construction.
;;;;
;;;; `TextBuf` is a byte-oriented text builder backed by active-arena chunk
;;;; nodes. Appending records chunks without concatenating the accumulated
;;;; prefix on every step; `text-buf-render` is the single operation that
;;;; materializes an owned `String` in the active arena.
;;;;
;;;; Usage: `(import "stdlib/text_buf.tl")`
;;;;
;;;; ```typelisp
;;;; (import "stdlib/text_buf.tl")
;;;; (define (main) : i64
;;;;   (let ([buf : TextBuf
;;;;     (text-buf-append-int (text-buf-append (text-buf-empty) "n=") 7)])
;;;;     (if (string-eq (text-buf-render buf) "n=7") 42 1)))
;;;; ```
;;;;
;;;; The buffer and rendered strings allocate in the active arena: the default
;;;; program-lifetime arena outside `(with-region ...)`, or the scoped arena
;;;; inside one. No borrow-typed `str` API is exposed yet because the owned
;;;; `String` / borrowed `str` split is still tracked by #807.
;;; Reversed chunk list. Each cons node is allocated in the active arena.
(defenum TextBufChunkList
  (TextBufChunkNil)
  (TextBufChunkCons String TextBufChunkList))

;;; Text buffer value with reversed chunks and cached byte length.
(defenum TextBuf
  (TextBuf TextBufChunkList i64))

;;; Printable ASCII lookup table used by `text-buf-append-char`.
(define text-buf-ascii-printable-table : String
  " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")

;;; Return an empty text buffer.
(define (text-buf-empty) : TextBuf
  (TextBuf TextBufChunkNil 0))

;;; Return true when `buf` contains no bytes.
(define (text-buf-empty? [buf : TextBuf]) : bool
  (match buf
    [(TextBuf _ len) (= len 0)]))

;;; Return the byte length currently represented by `buf`.
(define (text-buf-length [buf : TextBuf]) : i64
  (match buf
    [(TextBuf _ len) len]))

;;; Append `chunk` to `buf` without rendering the existing prefix.
(define (text-buf-append [buf : TextBuf] [chunk : String]) : TextBuf
  (let
    [chunk-len : i64 (string-length chunk)]
    (if (= chunk-len 0)
      buf
      (match buf
        [(TextBuf chunks len)
          (TextBuf (TextBufChunkCons chunk chunks) (+ len chunk-len))]))))

;;; Convert a supported byte-sized char to a one-byte String.
(define (text-buf-char-string [c : char]) : String
  (let
    [code : i64 (cast c : i64)]
    (if (= code 9)
      "\t"
      (if (= code 10)
        "\n"
        (if (= code 13)
          "\r"
          (if (and (>= code 32) (<= code 126))
            (substring text-buf-ascii-printable-table (- code 32) 1)
            (panic "text-buf: unsupported non-printable char")))))))

;;; Append one char byte to `buf`.
(define (text-buf-append-char [buf : TextBuf] [c : char]) : TextBuf
  (text-buf-append buf (text-buf-char-string c)))

;;; Append the decimal text for `value` to `buf`.
(define (text-buf-append-int [buf : TextBuf] [value : i64]) : TextBuf
  (text-buf-append buf (int->string value)))

;;; Concatenate chunk lists while preserving their current order.
(define (text-buf-chunk-list-concat
  [front : TextBufChunkList]
  [back : TextBufChunkList]) : TextBufChunkList
  (match front
    [(TextBufChunkNil) back]
    [(TextBufChunkCons chunk rest)
      (TextBufChunkCons chunk (text-buf-chunk-list-concat rest back))]))

;;; Append all chunks from `right` after `left`.
(define (text-buf-append-buffer [left : TextBuf] [right : TextBuf]) : TextBuf
  (match left
    [(TextBuf left-chunks left-len)
      (match right
        [(TextBuf right-chunks right-len)
          (if (= right-len 0)
            left
            (if (= left-len 0)
              right
              (TextBuf
                (text-buf-chunk-list-concat right-chunks left-chunks)
                (+ left-len right-len))))])]))

;;; Render reversed chunks into `out`.
(define (text-buf-chunks-render-rev [chunks : TextBufChunkList] [out : String]) : String
  (match chunks
    [(TextBufChunkNil) out]
    [(TextBufChunkCons chunk rest)
      (text-buf-chunks-render-rev rest (string-append chunk out))]))

;;; Render `buf` to an owned String allocated in the active arena.
(define (text-buf-render [buf : TextBuf]) : String
  (match buf
    [(TextBuf chunks _) (text-buf-chunks-render-rev chunks "")]))

;;; Return an empty buffer, leaving the old immutable `buf` value unchanged.
(define (text-buf-clear [buf : TextBuf]) : TextBuf
  (match buf
    [(TextBuf _ _) (text-buf-empty)]))

;;; Alias for `text-buf-clear` for call sites that model builder reuse as reset.
(define (text-buf-reset [buf : TextBuf]) : TextBuf
  (text-buf-clear buf))