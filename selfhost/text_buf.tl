;; text_buf.tl - Deterministic self-hosted text buffer utilities (#336).
;;
;; The buffer is intentionally monomorphic and list-backed: append is cheap
;; enough for current selfhost compiler slices, and render preserves append
;; order exactly by walking the reversed chunk list once.
(defenum TextChunkList
  (TextChunkNil)
  (TextChunkCons String TextChunkList))

(defenum TextBuf
  (TextBuf TextChunkList))

(define (text-buf-empty) : TextBuf
  (TextBuf TextChunkNil))

(define (text-buf-append [buf : TextBuf] [chunk : String]) : TextBuf
  (match buf
    [(TextBuf chunks) (TextBuf (TextChunkCons chunk chunks))]))

(define (text-chunk-list-concat [front : TextChunkList] [back : TextChunkList]) : TextChunkList
  (match front
    [(TextChunkNil) back]
    [(TextChunkCons chunk rest)
      (TextChunkCons chunk (text-chunk-list-concat rest back))]))

(define (text-buf-append-buffer [left : TextBuf] [right : TextBuf]) : TextBuf
  (match left
    [(TextBuf left-chunks)
      (match right
        [(TextBuf right-chunks)
          (TextBuf (text-chunk-list-concat right-chunks left-chunks))])]))

(define (text-chunks-render-rev [chunks : TextChunkList] [out : String]) : String
  (match chunks
    [(TextChunkNil) out]
    [(TextChunkCons chunk rest)
      (text-chunks-render-rev rest (string-append chunk out))]))

(define (text-buf-render [buf : TextBuf]) : String
  (match buf
    [(TextBuf chunks) (text-chunks-render-rev chunks "")]))