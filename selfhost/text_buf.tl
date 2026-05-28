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

(define (text-chunk-list-count [chunks : TextChunkList]) : i64
  (match chunks
    [(TextChunkNil) 0]
    [(TextChunkCons _ rest) (+ 1 (text-chunk-list-count rest))]))

(define (text-chunks-fill-array-rev
  [chunks : TextChunkList]
  [items : (Array String)]
  [index : i64]) : unit
  (match chunks
    [(TextChunkNil) unit]
    [(TextChunkCons chunk rest)
      (begin
        (array-set! items index chunk)
        (text-chunks-fill-array-rev rest items (- index 1)))]))

(define (text-chunks-render-array-range
  [items : (Array String)]
  [lo : i64]
  [hi : i64]) : String
  (if (>= lo hi)
    ""
    (if (= (+ lo 1) hi)
      (array-ref items lo)
      (let
        [mid : i64 (/ (+ lo hi) 2)]
        (string-append
          (text-chunks-render-array-range items lo mid)
          (text-chunks-render-array-range items mid hi))))))

(define (text-chunks-render-balanced [chunks : TextChunkList] [count : i64]) : String
  (let
    [items : (Array String) (make-array String count)]
    (begin
      (text-chunks-fill-array-rev chunks items (- count 1))
      (text-chunks-render-array-range items 0 count))))

(define (text-buf-render [buf : TextBuf]) : String
  (match buf
    [(TextBuf chunks)
      (let
        [count : i64 (text-chunk-list-count chunks)]
        (if (> count 32)
          (text-chunks-render-balanced chunks count)
          (text-chunks-render-rev chunks "")))]))
