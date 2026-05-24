;; lsp_frame.tl - First selfhost LSP stdio framing slice (#592).

;;

;; This driver owns only JSON-RPC/LSP Content-Length framing over stdin/stdout.

;; It intentionally does not parse JSON-RPC, track documents, or publish

;; diagnostics yet.

(defenum LspFrameRead
  (LspFrameOk String)
  (LspFrameEof)
  (LspFrameErr String))

(defenum LspLengthParse
  (LspLengthIgnore)
  (LspLengthOk i64)
  (LspLengthErr String))

(define (lsp-frame-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (lsp-frame-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string-append a (string-append b (string-append c (string-append d e)))))

(define (lsp-frame-char-code-at [text : String] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

(define (lsp-frame-space-code? [code : i64]) : bool
  (or (= code 32) (= code 9)))

(define (lsp-frame-trim-right-space-cr [text : String]) : String
  (let ([i : i64 (string-length text)]
    [end : i64 (string-length text)]
    [done : bool false])
    (begin
      (while (> i 0)
        (if done
          (set! i 0)
          (let ([code : i64 (lsp-frame-char-code-at text (- i 1))])
            (if (or (lsp-frame-space-code? code) (= code 13))
              (begin
                (set! end (- i 1))
                (set! i (- i 1)))
              (set! done true)))))
      (substring text 0 end))))

(define (lsp-frame-trim-left-space [text : String]) : String
  (let ([n : i64 (string-length text)]
    [i : i64 0]
    [start : i64 0]
    [done : bool false])
    (begin
      (while (< i n)
        (if done
          (set! i n)
          (if (lsp-frame-space-code? (lsp-frame-char-code-at text i))
            (begin
              (set! start (+ i 1))
              (set! i (+ i 1)))
            (set! done true))))
      (substring text start (- n start)))))

(define (lsp-frame-trim-header-value [text : String]) : String
  (lsp-frame-trim-left-space (lsp-frame-trim-right-space-cr text)))

(define (lsp-frame-starts-with? [text : String] [prefix : String]) : bool
  (let ([text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    [i : i64 0]
    [ok : bool true])
    (if (< text-len prefix-len)
      false
      (begin
        (while (< i prefix-len)
          (if ok
            (if (=
              (lsp-frame-char-code-at text i)
              (lsp-frame-char-code-at prefix i))
              (set! i (+ i 1))
              (begin
                (set! ok false)
                (set! i prefix-len)))
            (set! i prefix-len)))
        ok))))

(define (lsp-frame-digit-code? [code : i64]) : bool
  (and (>= code 48) (<= code 57)))

(define (lsp-frame-decimal? [text : String]) : bool
  (let ([n : i64 (string-length text)] [i : i64 0] [ok : bool true])
    (if (= n 0)
      false
      (begin
        (while (< i n)
          (if ok
            (if (lsp-frame-digit-code? (lsp-frame-char-code-at text i))
              (set! i (+ i 1))
              (begin
                (set! ok false)
                (set! i n)))
            (set! i n)))
        ok))))

(define (lsp-frame-parse-content-length [line : String]) : LspLengthParse
  (if (lsp-frame-starts-with? line "Content-Length:")
    (let ([value
        :
        String
        (lsp-frame-trim-header-value
          (substring line 15 (- (string-length line) 15)))])
      (if (lsp-frame-decimal? value)
        (let ([n : i64 (string->int value)])
          (if (< n 0)
            (LspLengthErr "lsp: invalid Content-Length")
            (LspLengthOk n)))
        (LspLengthErr "lsp: invalid Content-Length")))
    LspLengthIgnore))

(define (lsp-frame-read-message) : LspFrameRead
  (let ([content-length : i64 -1]
    [saw-header : bool false]
    [done : bool false]
    [clean-eof : bool false]
    [err : String ""])
    (begin
      (while (not done)
        (if (string-eq err "")
          (let ([line
              :
              String
              (lsp-frame-trim-right-space-cr (read-stdin-line))])
            (if (stdin-eof?)
              (if (= (string-length line) 0)
                (if saw-header
                  (begin
                    (set! err "lsp: EOF before header terminator")
                    (set! done true))
                  (begin
                    (set! clean-eof true)
                    (set! done true)))
                (begin
                  (set! saw-header true)
                  (match (lsp-frame-parse-content-length line)
                    [(LspLengthIgnore) unit]
                    [(LspLengthOk n) (set! content-length n)]
                    [(LspLengthErr message)
                      (begin
                        (set! err message)
                        (set! done true))])))
              (if (string-eq line "")
                (set! done true)
                (begin
                  (set! saw-header true)
                  (match (lsp-frame-parse-content-length line)
                    [(LspLengthIgnore) unit]
                    [(LspLengthOk n) (set! content-length n)]
                    [(LspLengthErr message)
                      (begin
                        (set! err message)
                        (set! done true))])))))
          (set! done true)))
      (if clean-eof
        LspFrameEof
        (if (not (string-eq err ""))
          (LspFrameErr err)
          (if (< content-length 0)
            (LspFrameErr "lsp: missing Content-Length")
            (let ([payload : String (read-stdin-bytes content-length)])
              (if (and (stdin-eof?) (< (string-length payload) content-length))
                (LspFrameErr "lsp: truncated payload")
                (LspFrameOk payload)))))))))

(define (lsp-frame-write-body [body : String]) : unit
  (begin
    (print-string
      (lsp-frame-cat5
        "Content-Length: "
        (int->string (string-length body))
        "\r\n\r\n"
        body
        ""))
    (flush-stdout)))

(define (lsp-frame-ok-body) : String
  "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":null}")

(define (lsp-frame-error-body [message : String]) : String
  (lsp-frame-cat3
    "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\""
    message
    "\"}}"))

(define (lsp-frame-run) : i64
  (let ([done : bool false] [status : i64 0])
    (begin
      (while (not done)
        (match (lsp-frame-read-message)
          [(LspFrameOk payload)
            (begin
              (string-length payload)
              (lsp-frame-write-body (lsp-frame-ok-body)))]
          [(LspFrameEof) (set! done true)]
          [(LspFrameErr message)
            (begin
              (lsp-frame-write-body (lsp-frame-error-body message))
              (print-error message)
              (set! status 1)
              (set! done true))]))
      status)))

(define (main) : i64
  (lsp-frame-run))