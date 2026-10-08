;; git_pkt_line_core.tl - Incremental Git pkt-line framing and sideband
;; demultiplexing (#7074).
;;
;; All String values here are byte strings. This layer performs no process,
;; network, compression, hashing or filesystem operation. Errors are
;; payload-free so no peer-controlled byte reaches a diagnostic; untrusted remote
;; text leaves only through `git-pkt-sanitize-text`.
(import stdlib.byte_buf_core as byte_buf)
(import stdlib.string)

;: The largest pkt-line, its four-byte length header included.
(define git-pkt-max-length : i64
  65520)

;: The largest pkt-line payload.
(define git-pkt-max-payload : i64
  65516)

(defenum GitProtocolError
  ;; pkt-line framing
  (InvalidLengthHex)
  (ReservedLength)
  (EmptyPacket)
  (OversizedPacket)
  (TruncatedPacket)
  (TrailingBytes)
  ;; sideband
  (InvalidSideband)
  ;; advertisements
  (MissingAdvertisement)
  (MalformedAdvertisement)
  (UnsupportedVersion)
  (MalformedCapability)
  (DuplicateCapability)
  (CapabilityLimit)
  (ConflictingObjectFormat)
  (UnsupportedObjectFormat)
  (MissingCapability)
  (MalformedRef)
  (DuplicateRef)
  (RefLimit)
  (InvalidObjectId)
  ;; requests
  (InvalidRefPrefix)
  (InvalidWant)
  (DuplicateWant)
  (WantNotAdvertised)
  (UnsupportedLegacyCapability)
  ;; responses
  (UnexpectedPacket)
  (MalformedSection)
  (UnexpectedSection)
  (OutOfOrderSection)
  (MissingShallowInfo)
  (MalformedShallow)
  (UnexpectedUnshallow)
  (DuplicateShallow)
  (MalformedAcknowledgment)
  (TruncatedResponse))

;: A copy of `error`, for a holder that keeps reporting it.
(define (git-pkt-error-copy [error : (& error GitProtocolError)]) : GitProtocolError
  (match error
    [(InvalidLengthHex) (InvalidLengthHex)]
    [(ReservedLength) (ReservedLength)]
    [(EmptyPacket) (EmptyPacket)]
    [(OversizedPacket) (OversizedPacket)]
    [(TruncatedPacket) (TruncatedPacket)]
    [(TrailingBytes) (TrailingBytes)]
    [(InvalidSideband) (InvalidSideband)]
    [(MissingAdvertisement) (MissingAdvertisement)]
    [(MalformedAdvertisement) (MalformedAdvertisement)]
    [(UnsupportedVersion) (UnsupportedVersion)]
    [(MalformedCapability) (MalformedCapability)]
    [(DuplicateCapability) (DuplicateCapability)]
    [(CapabilityLimit) (CapabilityLimit)]
    [(ConflictingObjectFormat) (ConflictingObjectFormat)]
    [(UnsupportedObjectFormat) (UnsupportedObjectFormat)]
    [(MissingCapability) (MissingCapability)]
    [(MalformedRef) (MalformedRef)]
    [(DuplicateRef) (DuplicateRef)]
    [(RefLimit) (RefLimit)]
    [(InvalidObjectId) (InvalidObjectId)]
    [(InvalidRefPrefix) (InvalidRefPrefix)]
    [(InvalidWant) (InvalidWant)]
    [(DuplicateWant) (DuplicateWant)]
    [(WantNotAdvertised) (WantNotAdvertised)]
    [(UnsupportedLegacyCapability) (UnsupportedLegacyCapability)]
    [(UnexpectedPacket) (UnexpectedPacket)]
    [(MalformedSection) (MalformedSection)]
    [(UnexpectedSection) (UnexpectedSection)]
    [(OutOfOrderSection) (OutOfOrderSection)]
    [(MissingShallowInfo) (MissingShallowInfo)]
    [(MalformedShallow) (MalformedShallow)]
    [(UnexpectedUnshallow) (UnexpectedUnshallow)]
    [(DuplicateShallow) (DuplicateShallow)]
    [(MalformedAcknowledgment) (MalformedAcknowledgment)]
    [(TruncatedResponse) (TruncatedResponse)]))

(defenum GitPkt
  (Data String)
  (Flush)
  (Delim)
  (ResponseEnd))

(defenum GitPktNext
  (Packet GitPkt)
  (NeedMore)
  (Err GitProtocolError))

(defenum ResultGitPktUnit
  (Ok)
  (Err GitProtocolError))

(defenum ResultGitPktBytes
  (Ok String)
  (Err GitProtocolError))

;: Unconsumed input starts at `offset` of `pending`. Once `terminal`, the
;: stream has ended and any further byte is `TrailingBytes`.
(defstruct GitPktReader
  (pending String)
  (offset i64)
  (terminal bool))

(define (git-pkt-reader-new) : GitPktReader
  (GitPktReader "" 0 false))

(define (git-pkt-byte [bytes : (& bytes str)] [index : i64]) : i64
  (cast (string.string-ref bytes index) : i64))

(define (git-pkt-hex-value [byte : i64]) : i64
  (cond
    [(and (>= byte 48) (<= byte 57)) (- byte 48)]
    [(and (>= byte 97) (<= byte 102)) (+ 10 (- byte 97))]
    [(and (>= byte 65) (<= byte 70)) (+ 10 (- byte 65))]
    [else -1]))

;: Unconsumed bytes buffered in `reader`.
(define (git-pkt-reader-available [reader : (& reader GitPktReader)]) : i64
  (- (string.string-length (& reader.pending)) reader.offset))

;: Append `chunk` to the unconsumed input. Input after the terminal packet is
;: refused.
(define (git-pkt-reader-feed!
  [reader : (&mut reader GitPktReader)]
  [chunk : (& chunk str)]) : ResultGitPktUnit
  (let
    [count : i64 (string.string-length chunk)]
    [available : i64 (git-pkt-reader-available (& reader))]
    (cond
      [(= count 0) (Ok)]
      [reader.terminal (Err TrailingBytes)]
      [else
        (let
          [out : byte_buf.ByteBufBuilder
            (byte_buf.byte-buf-builder-with-capacity (+ available count))]
          (byte_buf.byte-buf-builder-append-string-range
            (&mut out)
            (string.substring (& reader.pending) reader.offset available)
            0
            available)
          (byte_buf.byte-buf-builder-append-string-range
            (&mut out)
            (string.substring chunk 0 count)
            0
            count)
          (set!
            reader.pending
            (byte_buf.byte-buf-builder-finish-string (& out)))
          (set! reader.offset 0)
          (Ok))])))

;: The next complete packet, `NeedMore` when the buffered input ends inside
;: one, or the framing error at the current position.
(define (git-pkt-reader-next! [reader : (&mut reader GitPktReader)]) : GitPktNext
  (let
    [available : i64 (git-pkt-reader-available (& reader))]
    [length : i64 0]
    [index : i64 0]
    (when (< available 4) (return (NeedMore)))
    (while (< index 4)
      (let
        [digit : i64
          (git-pkt-hex-value
            (git-pkt-byte (& reader.pending) (+ reader.offset index)))]
        (when (< digit 0) (return (Err InvalidLengthHex)))
        (set! length (+ (* length 16) digit))
        (set! index (+ index 1))))
    (cond
      [(= length 0)
        (set! reader.offset (+ reader.offset 4))
        (Packet (Flush))]
      [(= length 1)
        (set! reader.offset (+ reader.offset 4))
        (Packet (Delim))]
      [(= length 2)
        (set! reader.offset (+ reader.offset 4))
        (Packet (ResponseEnd))]
      [(= length 3) (Err ReservedLength)]
      [(= length 4) (Err EmptyPacket)]
      [(> length git-pkt-max-length) (Err OversizedPacket)]
      [(< available length) (NeedMore)]
      [else
        (let
          [payload : String
            (string.substring
              (& reader.pending)
              (+ reader.offset 4)
              (- length 4))]
          (set! reader.offset (+ reader.offset length))
          (Packet (Data payload)))])))

;: The input has ended: any buffered byte belongs to a truncated packet.
(define (git-pkt-reader-end [reader : (& reader GitPktReader)]) : ResultGitPktUnit
  (if (> (git-pkt-reader-available reader) 0)
    (Err TruncatedPacket)
    (Ok)))

;: The stream's terminal packet has been read: any buffered or later byte is
;: trailing input.
(define (git-pkt-reader-terminate! [reader : (&mut reader GitPktReader)]) : ResultGitPktUnit
  (set! reader.terminal true)
  (if (> (git-pkt-reader-available (& reader)) 0)
    (Err TrailingBytes)
    (Ok)))

(define (git-pkt-push-hex4
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [value : i64]) : unit
  (let
    [shift : i64 12]
    (while (>= shift 0)
      (let
        [digit : i64 (bit-and (shr value shift) 15)]
        (byte_buf.byte-buf-builder-push
          out
          (cast
            (if (< digit 10)
              (+ 48 digit)
              (+ 87 digit))
            : u8)))
      (set! shift (- shift 4)))))

;: One data pkt-line carrying `payload` exactly.
(define (git-pkt-encode-data [payload : (& payload str)]) : ResultGitPktBytes
  (let
    [count : i64 (string.string-length payload)]
    (cond
      [(= count 0) (Err EmptyPacket)]
      [(> count git-pkt-max-payload) (Err OversizedPacket)]
      [else
        (let
          [out : byte_buf.ByteBufBuilder
            (byte_buf.byte-buf-builder-with-capacity (+ count 4))]
          (git-pkt-push-hex4 (&mut out) (+ count 4))
          (byte_buf.byte-buf-builder-append-string-range
            (&mut out)
            (string.substring payload 0 count)
            0
            count)
          (Ok (byte_buf.byte-buf-builder-finish-string (& out))))])))

(define (git-pkt-flush) : String
  "0000")

(define (git-pkt-delim) : String
  "0001")

(define (git-pkt-response-end) : String
  "0002")

;: A text payload without its optional final LF. Senders should end text
;: packets with LF, and receivers must not require it.
(define (git-pkt-text [payload : (& payload str)]) : String
  (let
    [count : i64 (string.string-length payload)]
    (if (and (> count 0) (= (git-pkt-byte payload (- count 1)) 10))
      (string.substring payload 0 (- count 1))
      (string.substring payload 0 count))))

;: Untrusted remote text for display: printable ASCII kept, tab, CR and LF
;: become spaces, every other byte `?`; trailing spaces trimmed; at most
;: `max-bytes` bytes. Nothing in it can act as a terminal control sequence.
(define (git-pkt-sanitize-text [text : (& text str)] [max-bytes : i64]) : String
  (let
    [count : i64 (string.string-length text)]
    [out : byte_buf.ByteBufBuilder
      (byte_buf.byte-buf-builder-with-capacity (+ count 1))]
    [index : i64 0]
    [kept : i64 0]
    (while (and
      (< index count)
      (< (byte_buf.byte-buf-builder-len (& out)) max-bytes))
      (let
        [byte : i64 (git-pkt-byte text index)]
        [mapped : i64
          (cond
            [(or (= byte 9) (= byte 10) (= byte 13)) 32]
            [(and (>= byte 32) (<= byte 126)) byte]
            [else 63])]
        (byte_buf.byte-buf-builder-push (&mut out) (cast mapped : u8))
        (unless
          (= mapped 32)
          (set! kept (byte_buf.byte-buf-builder-len (& out))))
        (set! index (+ index 1))))
    (let
      [all : String (byte_buf.byte-buf-builder-finish-string (& out))]
      (string.substring (& all) 0 kept))))

(defenum GitSideband
  (Pack String)
  (Progress String)
  (Fatal String))

(defenum ResultGitSideband
  (Ok GitSideband)
  (Err GitProtocolError))

;: Demultiplex one sideband data packet. Channel 1 is pack bytes, exactly;
;: channels 2 (progress) and 3 (fatal error) are untrusted text, sanitized and
;: limited to `max-text` bytes.
(define (git-pkt-sideband [payload : (& payload str)] [max-text : i64]) : ResultGitSideband
  (let
    [count : i64 (string.string-length payload)]
    (if (= count 0)
      (Err InvalidSideband)
      (let
        [channel : i64 (git-pkt-byte payload 0)]
        [body : String (string.substring payload 1 (- count 1))]
        (cond
          [(= channel 1) (Ok (Pack body))]
          [(= channel 2)
            (Ok (Progress (git-pkt-sanitize-text (& body) max-text)))]
          [(= channel 3) (Ok (Fatal (git-pkt-sanitize-text (& body) max-text)))]
          [else (Err InvalidSideband)])))))