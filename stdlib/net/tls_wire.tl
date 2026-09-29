;# Bounded TLS 1.3 (RFC 9846) wire codec: records, handshake framing,
;# extensions, handshake messages and alerts.
;#
;# This is the wire layer of the TLS client (#6975). It performs no
;# cryptography, certificate parsing, hashing, randomness, I/O or connection
;# policy; the client state machine (#6992) drives it.
;#
;# - `TlsRecordReader` splits a byte stream into records. Input may arrive in
;#   pieces of any size; each call takes bytes only up to the end of one record,
;#   so nothing is consumed twice or lost, and it checks the header before
;#   buffering the fragment.
;# - `TlsInnerPlaintext` decoding finds the real content type and padding of a
;#   decrypted record.
;# - `TlsHandshakeReader` reassembles handshake messages that span records or
;#   share one. Each message is returned as its exact encoded bytes, header
;#   included, which is what the transcript hashes. The reader reports whether
;#   the last message ended its record, which RFC 9846 requires before every key
;#   change, and rejects other records interleaved with a split message.
;# - Typed decoders and encoders cover ClientHello, ServerHello and
;#   HelloRetryRequest, EncryptedExtensions, CertificateRequest, Certificate,
;#   CertificateVerify, Finished, NewSessionTicket, KeyUpdate and
;#   EndOfEarlyData, plus the extension bodies the client needs.
;# - Extension blocks follow RFC 9846 section 4.2: no type may repeat, a
;#   recognized extension must be allowed in the message, `pre_shared_key` is
;#   last in a ClientHello, and an unrecognized one is kept (ClientHello,
;#   CertificateRequest, NewSessionTicket) or rejected as unsolicited (the
;#   server's responses).
;#
;# Every length is checked against the protocol maximum and the caller's
;# `TlsWireLimits` before anything is allocated or copied. A failure is a
;# `TlsWireError`: a stable code, the byte offset it was found at, and the alert
;# RFC 9846 prescribes. Offsets are stream offsets for the readers and offsets
;# into the decoded view (a handshake message body or extension data) for
;# decoders. Encoders trap when a value cannot be expressed on the wire, the way
;# `byte_buf` traps on a bad range.
;#
;# Usage: `(import stdlib.net.tls_wire)`
(import stdlib.byte_buf)
(import stdlib.string)

;; --- content types, versions and handshake types ------------------------------
;: `change_cipher_spec` record content type.
(define content-type-change-cipher-spec : i64
  20)

;: `alert` record content type.
(define content-type-alert : i64
  21)

;: `handshake` record content type.
(define content-type-handshake : i64
  22)

;: `application_data` record content type; the outer type of every protected
;: record.
(define content-type-application-data : i64
  23)

;: The `legacy_record_version` and `legacy_version` TLS 1.3 writes.
(define legacy-version-tls12 : i64
  0x0303)

;: The `legacy_record_version` an initial ClientHello may use instead.
(define legacy-version-tls10 : i64
  0x0301)

;: TLS 1.3 in `supported_versions`.
(define version-tls13 : i64
  0x0304)

;: `client_hello` handshake message type (RFC 9846 section 4).
(define handshake-client-hello : i64
  1)

;: `server_hello` handshake message type.
(define handshake-server-hello : i64
  2)

;: `new_session_ticket` handshake message type.
(define handshake-new-session-ticket : i64
  4)

;: `end_of_early_data` handshake message type.
(define handshake-end-of-early-data : i64
  5)

;: `encrypted_extensions` handshake message type.
(define handshake-encrypted-extensions : i64
  8)

;: `certificate` handshake message type.
(define handshake-certificate : i64
  11)

;: `certificate_request` handshake message type.
(define handshake-certificate-request : i64
  13)

;: `certificate_verify` handshake message type.
(define handshake-certificate-verify : i64
  15)

;: `finished` handshake message type.
(define handshake-finished : i64
  20)

;: `key_update` handshake message type.
(define handshake-key-update : i64
  24)

;: `message_hash` handshake message type.
(define handshake-message-hash : i64
  254)

;: `update_not_requested`, a `KeyUpdate.request_update` value.
(define key-update-not-requested : i64
  0)

;: `update_requested`: the peer must answer with its own KeyUpdate.
(define key-update-requested : i64
  1)

;; --- protocol limits ----------------------------------------------------------
;: Largest `TLSPlaintext.fragment` and `TLSInnerPlaintext.content` (2^14).
(define max-plaintext-fragment : i64
  16384)

;: Largest `TLSCiphertext.encrypted_record` (2^14 + 256).
(define max-ciphertext-fragment : i64
  16640)

;: Largest body a handshake message's 24-bit length can state.
(define max-handshake-body : i64
  16777215)

;: Record header length.
(define record-header-length : i64
  5)

;: Handshake message header length: type and 24-bit length.
(define handshake-header-length : i64
  4)

;: Largest caller bound on the entries of one extension block or list. The
;: duplicate checks compare each entry with the earlier ones, so this bounds
;: their work.
(define max-block-entries : i64
  1024)

;: Caller bounds, each positive and at most its protocol maximum:
;: record fragments, the body of one handshake message, the entries of one
;: extension block, the entries of one list inside an extension or message
;: (cipher suites, groups, key shares, protocol names, ...), and the entries
;: and per-certificate size of a Certificate message.
(defstruct TlsWireLimits
  (max-plaintext-fragment i64)
  (max-ciphertext-fragment i64)
  (max-handshake-body i64)
  (max-extensions i64)
  (max-list-entries i64)
  (max-certificates i64)
  (max-certificate-bytes i64))

;: The protocol record maxima, 256 KiB handshake messages, 64 extensions per
;: block, 1024 entries per list, and 16 certificates of at most 64 KiB each.
(define (default-limits) : TlsWireLimits
  (TlsWireLimits
    max-plaintext-fragment
    max-ciphertext-fragment
    262144
    64
    max-block-entries
    16
    65536))

;: Whether every limit is positive and within its protocol maximum.
(define (limits-valid? [limits : (& limits TlsWireLimits)]) : bool
  (and
    (> limits.max-plaintext-fragment 0)
    (<= limits.max-plaintext-fragment max-plaintext-fragment)
    (> limits.max-ciphertext-fragment 0)
    (<= limits.max-ciphertext-fragment max-ciphertext-fragment)
    (> limits.max-handshake-body 0)
    (<= limits.max-handshake-body max-handshake-body)
    (> limits.max-extensions 0)
    (<= limits.max-extensions max-block-entries)
    (> limits.max-list-entries 0)
    (<= limits.max-list-entries max-block-entries)
    (> limits.max-certificates 0)
    (> limits.max-certificate-bytes 0)
    (<= limits.max-certificate-bytes max-handshake-body)))

;: Return `limits`, trapping unless it satisfies `limits-valid?`.
(define (require-valid-limits [limits : TlsWireLimits]) : TlsWireLimits
  (begin
    (check-length
      (if (limits-valid? (& limits))
        1
        0)
      1)
    limits))

;; --- alerts ---------------------------------------------------------------------
;: `close_notify` alert description (RFC 9846 section 6).
(define alert-close-notify : i64
  0)

;: `unexpected_message` alert description.
(define alert-unexpected-message : i64
  10)

;: `bad_record_mac` alert description.
(define alert-bad-record-mac : i64
  20)

;: `record_overflow` alert description.
(define alert-record-overflow : i64
  22)

;: `handshake_failure` alert description.
(define alert-handshake-failure : i64
  40)

;: `bad_certificate` alert description.
(define alert-bad-certificate : i64
  42)

;: `unsupported_certificate` alert description.
(define alert-unsupported-certificate : i64
  43)

;: `certificate_revoked` alert description.
(define alert-certificate-revoked : i64
  44)

;: `certificate_expired` alert description.
(define alert-certificate-expired : i64
  45)

;: `certificate_unknown` alert description.
(define alert-certificate-unknown : i64
  46)

;: `illegal_parameter` alert description.
(define alert-illegal-parameter : i64
  47)

;: `unknown_ca` alert description.
(define alert-unknown-ca : i64
  48)

;: `access_denied` alert description.
(define alert-access-denied : i64
  49)

;: `decode_error` alert description.
(define alert-decode-error : i64
  50)

;: `decrypt_error` alert description.
(define alert-decrypt-error : i64
  51)

;: `protocol_version` alert description.
(define alert-protocol-version : i64
  70)

;: `insufficient_security` alert description.
(define alert-insufficient-security : i64
  71)

;: `internal_error` alert description.
(define alert-internal-error : i64
  80)

;: `inappropriate_fallback` alert description.
(define alert-inappropriate-fallback : i64
  86)

;: `user_canceled` alert description.
(define alert-user-canceled : i64
  90)

;: `missing_extension` alert description.
(define alert-missing-extension : i64
  109)

;: `unsupported_extension` alert description.
(define alert-unsupported-extension : i64
  110)

;: `unrecognized_name` alert description.
(define alert-unrecognized-name : i64
  112)

;: `bad_certificate_status_response` alert description.
(define alert-bad-certificate-status-response : i64
  113)

;: `unknown_psk_identity` alert description.
(define alert-unknown-psk-identity : i64
  115)

;: `certificate_required` alert description.
(define alert-certificate-required : i64
  116)

;: `general_error` alert description.
(define alert-general-error : i64
  117)

;: `no_application_protocol` alert description.
(define alert-no-application-protocol : i64
  120)

;: The legacy `warning` alert level. TLS 1.3 takes the severity from the
;: description, so decoding keeps the level as sent and does not act on it.
(define alert-level-warning : i64
  1)

;: The legacy `fatal` alert level.
(define alert-level-fatal : i64
  2)

;: Whether an alert with `description` ends the connection: all do except
;: `close_notify` and `user_canceled`, and unknown ones count as errors.
(define (alert-fatal? [description : i64]) : bool
  (not
    (or (= description alert-close-notify) (= description alert-user-canceled))))

;; --- errors ---------------------------------------------------------------------
;: Error: a length or vector runs past its end (`decode_error`).
(define error-truncated : i64
  1)

;: A vector length is outside its `<min..max>` or not a whole number of items
;: (`decode_error`).
(define error-length-range : i64
  2)

;: Bytes remain after a structure that must end (`decode_error`).
(define error-trailing : i64
  3)

;: A record content type that is unknown, or not allowed in this record
;: protection state (`unexpected_message`).
(define error-content-type : i64
  4)

;: A record version whose major byte is not 3 (`decode_error`).
(define error-record-version : i64
  5)

;: A record or inner plaintext over its limit (`record_overflow`).
(define error-record-overflow : i64
  6)

;: An empty handshake or alert fragment (`unexpected_message`).
(define error-empty-fragment : i64
  7)

;: An alert record that is not exactly one alert (`decode_error`).
(define error-alert-length : i64
  8)

;: A change_cipher_spec record other than the single byte 1
;: (`unexpected_message`).
(define error-change-cipher-spec : i64
  9)

;: A decrypted record with no non-zero content type byte
;: (`unexpected_message`).
(define error-missing-content-type : i64
  10)

;: A handshake message body over `max-handshake-body` (`decode_error`).
(define error-message-too-large : i64
  11)

;: Another record type between the records of a split handshake message
;: (`unexpected_message`).
(define error-interleaved : i64
  12)

;: A key change while a handshake message was not aligned with the end of a
;: record (`unexpected_message`).
(define error-key-change-unaligned : i64
  13)

;: More extensions in one block than `max-extensions` (`decode_error`).
(define error-too-many-extensions : i64
  14)

;: More list entries than `max-list-entries` (`decode_error`).
(define error-too-many-entries : i64
  15)

;: More certificates than `max-certificates` (`decode_error`).
(define error-too-many-certificates : i64
  16)

;: A certificate over `max-certificate-bytes` (`decode_error`).
(define error-certificate-too-large : i64
  17)

;: An extension type repeats in one block (`illegal_parameter`).
(define error-duplicate-extension : i64
  18)

;: A recognized extension in a message RFC 9846 does not allow it in
;: (`illegal_parameter`).
(define error-extension-context : i64
  19)

;: A response carries an extension the ClientHello did not offer
;: (`unsupported_extension`).
(define error-unsolicited-extension : i64
  20)

;: `pre_shared_key` is not the last ClientHello extension
;: (`illegal_parameter`).
(define error-psk-not-last : i64
  21)

;: A list entry repeats where it must be unique (`illegal_parameter`).
(define error-duplicate-entry : i64
  22)

;: A well-formed field holds a value the protocol forbids
;: (`illegal_parameter`).
(define error-illegal-value : i64
  23)

;: A mandatory extension is absent (`missing_extension`).
(define error-missing-extension : i64
  24)

;: A codec failure: its stable `code`, the byte `offset` it was found at, and
;: the `alert` description to send. `check-solicited` reports the index of the
;: offending extension as the offset.
(defstruct TlsWireError
  (code i64)
  (offset i64)
  (alert i64))

;: Copy an error out of a borrowed place.
(define (copy-error [error : (& error TlsWireError)]) : TlsWireError
  (TlsWireError error.code error.offset error.alert))

;: A short name for an error code, for diagnostics.
(define (error-name [code : i64]) : String
  (cond
    [(= code error-truncated) "truncated"]
    [(= code error-length-range) "length out of range"]
    [(= code error-trailing) "trailing bytes"]
    [(= code error-content-type) "unexpected content type"]
    [(= code error-record-version) "record version"]
    [(= code error-record-overflow) "record overflow"]
    [(= code error-empty-fragment) "empty fragment"]
    [(= code error-alert-length) "alert length"]
    [(= code error-change-cipher-spec) "change_cipher_spec value"]
    [(= code error-missing-content-type) "missing inner content type"]
    [(= code error-message-too-large) "handshake message too large"]
    [(= code error-interleaved) "interleaved record"]
    [(= code error-key-change-unaligned) "key change inside a record"]
    [(= code error-too-many-extensions) "too many extensions"]
    [(= code error-too-many-entries) "too many list entries"]
    [(= code error-too-many-certificates) "too many certificates"]
    [(= code error-certificate-too-large) "certificate too large"]
    [(= code error-duplicate-extension) "duplicate extension"]
    [(= code error-extension-context) "extension not allowed here"]
    [(= code error-unsolicited-extension) "unsolicited extension"]
    [(= code error-psk-not-last) "pre_shared_key not last"]
    [(= code error-duplicate-entry) "duplicate list entry"]
    [(= code error-illegal-value) "illegal value"]
    [(= code error-missing-extension) "missing extension"]
    [else "unknown error"]))

;: The outcome of a check that produces no value.
(defenum TlsWireCheck
  (TlsWireOk)
  (TlsWireErr TlsWireError))

;; --- big-endian access ------------------------------------------------------------
;: The big-endian unsigned integer of `width` bytes at `offset` of `view`. The
;: caller has checked the range.
(define (read-be [view : (& view bytes)] [offset : i64] [width : i64]) : i64
  (let
    [value : i64 0]
    [index : i64 0]
    (begin
      (while (< index width)
        (begin
          (set!
            value
            (bit-or
              (shl value 8)
              (cast (byte_buf.bytes-ref view (+ offset index)) : i64)))
          (set! index (+ index 1))))
      value)))

;: Append `value` as a big-endian unsigned integer of `width` bytes.
(define (push-be [buf : byte_buf.ByteBuf] [value : i64] [width : i64]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf buf]
    [shift : i64 (* 8 (- width 1))]
    (begin
      (while (>= shift 0)
        (begin
          (set!
            out
            (byte_buf.push out (cast (bit-and (shr value shift) 255) : u8)))
          (set! shift (- shift 8))))
      out)))

;: Trap unless `actual` equals `expected`: a caller passed a value the wire
;: cannot carry.
(define (check-length [actual : i64] [expected : i64]) : unit
  (byte_buf.check-range expected expected (- actual expected)))

;: The largest length a `width`-byte prefix states.
(define (max-for-width [width : i64]) : i64
  (- (shl 1 (* 8 width)) 1))

;: Fill the `width`-byte length prefix at `mark` with the number of bytes
;: written after it. Traps when that exceeds what the prefix can state.
(define (close-length [buf : byte_buf.ByteBuf] [mark : i64] [width : i64]) : byte_buf.ByteBuf
  (let
    [length : i64 (- (byte_buf.len (& buf)) (+ mark width))]
    [out : byte_buf.ByteBuf buf]
    [index : i64 0]
    (begin
      (byte_buf.check-range (max-for-width width) 0 length)
      (while (< index width)
        (begin
          (set!
            out
            (byte_buf.set!
              out
              (+ mark index)
              (cast (bit-and (shr length (* 8 (- (- width 1) index))) 255) : u8)))
          (set! index (+ index 1))))
      out)))

;: Append `data` with a `width`-byte length prefix.
(define (encode-opaque
  [out : byte_buf.ByteBuf]
  [data : (& data bytes)]
  [width : i64]) : byte_buf.ByteBuf
  (let
    [length : i64 (byte_buf.bytes-length data)]
    (begin
      (byte_buf.check-range (max-for-width width) 0 length)
      (byte_buf.append-bytes (push-be out length width) data))))

;; --- reader buffers ------------------------------------------------------------------
;: The readers own their buffers behind `&mut`, so they grow and fill them in
;: place: a steady stream of records allocates nothing once the buffers have
;: reached the largest record and message.
;: Grow the storage of `buf` to hold at least `capacity` bytes, at least
;: doubling it.
(define (buffer-reserve! [buf : (&mut buf byte_buf.ByteBuf)] [capacity : i64]) : unit
  (let
    [current : i64 (byte_buf.capacity buf)]
    (when
      (> capacity current)
      (set!
        (deref buf)
        (byte_buf.append-bytes
          (byte_buf.with-capacity
            (if (< capacity (* 2 current))
              (* 2 current)
              capacity))
          (byte_buf.as-bytes buf))))))

;: Append `count` bytes of `src` from `start` to `buf`.
(define (buffer-append!
  [buf : (&mut buf byte_buf.ByteBuf)]
  [src : (& src bytes)]
  [start : i64]
  [count : i64]) : unit
  (let
    [old-len : i64 buf.len]
    (begin
      (byte_buf.check-range (byte_buf.bytes-length src) start count)
      (buffer-reserve! buf (+ old-len count))
      ;; The source range was checked above and the storage now holds
      ;; `old-len + count` bytes: the same copy `byte_buf.append-bytes-range`
      ;; makes, into storage reached through `&mut`.
      (string.str-copy-bytes-into
        (unsafe
          (ptr-offset (byte_buf.bytes-data src) start))
        (unsafe
          (__tl_array-data buf.slots))
        old-len
        count)
      (set! buf.len (+ old-len count)))))

;; --- decoding cursor ----------------------------------------------------------------
;: A cursor over one borrowed view, which every call receives again. Reads
;: advance `pos` within `[pos, end)`. The first failure is kept; later reads
;: return zero values without moving, so a decoder checks `failed` once after
;: a run of reads.
(defstruct TlsDecoder
  (pos i64)
  (end i64)
  (failed bool)
  (error TlsWireError))

;: A cursor over the whole of `view`.
(define (decoder-new [view : (& view bytes)]) : TlsDecoder
  (TlsDecoder 0 (byte_buf.bytes-length view) false (TlsWireError 0 0 0)))

;: Record the first failure at `offset`; later ones are ignored.
(define (decoder-fail!
  [d : (&mut d TlsDecoder)]
  [code : i64]
  [alert : i64]
  [offset : i64]) : unit
  (when
    (not d.failed)
    (begin
      (set! d.failed true)
      (set! d.error (TlsWireError code offset alert)))))

;: Take `count` bytes and return their offset.
(define (decoder-take! [d : (&mut d TlsDecoder)] [count : i64]) : i64
  (cond
    [d.failed 0]
    [(> count (- d.end d.pos))
      (begin
        (decoder-fail! d error-truncated alert-decode-error d.pos)
        0)]
    [else
      (let
        [at : i64 d.pos]
        (begin
          (set! d.pos (+ at count))
          at))]))

;: Read a big-endian unsigned integer of `width` bytes.
(define (decoder-uint!
  [d : (&mut d TlsDecoder)]
  [view : (& view bytes)]
  [width : i64]) : i64
  (let
    [at : i64 (decoder-take! d width)]
    (if d.failed
      0
      (read-be view at width))))

;: Enter a vector with a `width`-byte length prefix whose length must be in
;: `[min, max]`: the cursor's end becomes the vector's end. Returns the outer
;: end for `decoder-close!`.
(define (decoder-open!
  [d : (&mut d TlsDecoder)]
  [view : (& view bytes)]
  [width : i64]
  [min : i64]
  [max : i64]) : i64
  (let
    [prefix-at : i64 d.pos]
    [length : i64 (decoder-uint! d view width)]
    (cond
      [d.failed d.end]
      [(or (< length min) (> length max))
        (begin
          (decoder-fail! d error-length-range alert-decode-error prefix-at)
          d.end)]
      [(> length (- d.end d.pos))
        (begin
          (decoder-fail! d error-truncated alert-decode-error prefix-at)
          d.end)]
      [else
        (let
          [outer : i64 d.end]
          (begin
            (set! d.end (+ d.pos length))
            outer))])))

;: Leave a vector entered with `decoder-open!`, which must be fully read.
(define (decoder-close! [d : (&mut d TlsDecoder)] [outer : i64]) : unit
  (begin
    (when
      (and (not d.failed) (!= d.pos d.end))
      (decoder-fail! d error-trailing alert-decode-error d.pos))
    (set! d.end outer)))

;: Require that the whole view was read.
(define (decoder-finish! [d : (&mut d TlsDecoder)]) : unit
  (when
    (and (not d.failed) (!= d.pos d.end))
    (decoder-fail! d error-trailing alert-decode-error d.pos)))

;: Copy the next `count` bytes.
(define (decoder-copy!
  [d : (&mut d TlsDecoder)]
  [view : (& view bytes)]
  [count : i64]) : byte_buf.ByteBuf
  (let
    [at : i64 (decoder-take! d count)]
    (if d.failed
      (byte_buf.with-capacity 0)
      (byte_buf.from-bytes-range view at count))))

;: Copy an opaque vector `<min..max>` with a `width`-byte prefix.
(define (decoder-opaque!
  [d : (&mut d TlsDecoder)]
  [view : (& view bytes)]
  [width : i64]
  [min : i64]
  [max : i64]) : byte_buf.ByteBuf
  (let
    [outer : i64 (decoder-open! d view width min max)]
    [data : byte_buf.ByteBuf (decoder-copy! d view (- d.end d.pos))]
    (begin
      (decoder-close! d outer)
      data)))

;: Read a vector `<min..max>` of `item-width`-byte integers (cipher suites,
;: groups, signature schemes, versions, modes) into an exact array.
(define (decoder-codes!
  [d : (&mut d TlsDecoder)]
  [view : (& view bytes)]
  [prefix-width : i64]
  [item-width : i64]
  [min : i64]
  [max : i64]
  [limit : i64]) : (__tl_dyn-array i64)
  (let
    [prefix-at : i64 d.pos]
    [outer : i64 (decoder-open! d view prefix-width min max)]
    [length : i64 (- d.end d.pos)]
    [count : i64 (/ length item-width)]
    (begin
      (cond
        [d.failed unit]
        [(!= (* count item-width) length)
          (decoder-fail! d error-length-range alert-decode-error prefix-at)]
        [(> count limit)
          (decoder-fail! d error-too-many-entries alert-decode-error prefix-at)]
        [else unit])
      (let
        [out : (__tl_dyn-array i64)
          (__tl_make-array
            i64
            (if d.failed
              0
              count))]
        [index : i64 0]
        (begin
          (while (and (not d.failed) (< index count))
            (begin
              (set! (array-ref out index) (decoder-uint! d view item-width))
              (set! index (+ index 1))))
          (decoder-close! d outer)
          out)))))

;: Count the opaque items `<min..max>` with `width`-byte prefixes from the
;: cursor to its end without moving it, failing on the first bad item or the
;: `limit`-th plus one.
(define (opaque-list-scan!
  [d : (&mut d TlsDecoder)]
  [view : (& view bytes)]
  [width : i64]
  [min : i64]
  [max : i64]
  [limit : i64]) : i64
  (let
    [cursor : i64 d.pos]
    [count : i64 0]
    (begin
      (while (and (not d.failed) (< cursor d.end))
        (cond
          [(>= count limit)
            (decoder-fail! d error-too-many-entries alert-decode-error cursor)]
          [(> (+ cursor width) d.end)
            (decoder-fail! d error-truncated alert-decode-error cursor)]
          [else
            (let
              [length : i64 (read-be view cursor width)]
              (cond
                [(or (< length min) (> length max))
                  (decoder-fail! d error-length-range alert-decode-error cursor)]
                [(> (+ (+ cursor width) length) d.end)
                  (decoder-fail! d error-truncated alert-decode-error cursor)]
                [else
                  (begin
                    (set! count (+ count 1))
                    (set! cursor (+ (+ cursor width) length)))]))]))
      count)))

;: Read a vector of opaque items (protocol names, distinguished names).
(define (decoder-opaque-list!
  [d : (&mut d TlsDecoder)]
  [view : (& view bytes)]
  [outer-width : i64]
  [outer-min : i64]
  [inner-width : i64]
  [inner-min : i64]
  [inner-max : i64]
  [limit : i64]) : (__tl_dyn-array byte_buf.ByteBuf)
  (let
    [outer : i64
      (decoder-open! d view outer-width outer-min (max-for-width outer-width))]
    [count : i64
      (opaque-list-scan! d view inner-width inner-min inner-max limit)]
    [out : (__tl_dyn-array byte_buf.ByteBuf)
      (__tl_make-array
        byte_buf.ByteBuf
        (if d.failed
          0
          count))]
    [index : i64 0]
    (begin
      (while (and (not d.failed) (< index count))
        (begin
          (set!
            (array-ref out index)
            (decoder-opaque! d view inner-width inner-min inner-max))
          (set! index (+ index 1))))
      (decoder-close! d outer)
      out)))

;; --- records ------------------------------------------------------------------------
;: A record header: outer content type, `legacy_record_version`, and fragment
;: length.
(defstruct TlsRecordHeader
  (content-type i64)
  (legacy-version i64)
  (length i64))

;: The result of `decode-record-header`.
(defenum TlsRecordHeaderResult
  (TlsRecordHeaderOk TlsRecordHeader)
  (TlsRecordHeaderErr TlsWireError))

;: Decode and check the record header at `offset` of `view`, which is at
;: `stream-offset` in the connection. `protected` is true once the peer's
;: records are encrypted: the outer type must then be `application_data` or a
;: compatibility `change_cipher_spec`, and the ciphertext bound applies. Before
;: that, `application_data` is refused. The version is otherwise ignored, as
;: RFC 9846 requires, but a major byte other than 3 means the peer does not
;: speak TLS.
(define (decode-record-header
  [view : (& view bytes)]
  [offset : i64]
  [protected : bool]
  [limits : (& limits TlsWireLimits)]
  [stream-offset : i64]) : TlsRecordHeaderResult
  (if (> (+ offset record-header-length) (byte_buf.bytes-length view))
    (TlsRecordHeaderErr
      (TlsWireError error-truncated stream-offset alert-decode-error))
    (let
      [content-type : i64 (read-be view offset 1)]
      [version : i64 (read-be view (+ offset 1) 2)]
      [length : i64 (read-be view (+ offset 3) 2)]
      [ciphertext : bool
        (and protected (= content-type content-type-application-data))]
      [bound : i64
        (if ciphertext
          limits.max-ciphertext-fragment
          limits.max-plaintext-fragment)]
      [length-at : i64 (+ stream-offset 3)]
      (cond
        [(not
            (if protected
              (or ciphertext (= content-type content-type-change-cipher-spec))
              (or
                (= content-type content-type-change-cipher-spec)
                (= content-type content-type-alert)
                (= content-type content-type-handshake))))
          (TlsRecordHeaderErr
            (TlsWireError
              error-content-type
              stream-offset
              alert-unexpected-message))]
        [(!= (shr version 8) 3)
          (TlsRecordHeaderErr
            (TlsWireError
              error-record-version
              (+ stream-offset 1)
              alert-decode-error))]
        [(> length bound)
          (TlsRecordHeaderErr
            (TlsWireError error-record-overflow length-at alert-record-overflow))]
        [(and (= length 0) (not ciphertext))
          (TlsRecordHeaderErr
            (TlsWireError
              error-empty-fragment
              length-at
              alert-unexpected-message))]
        [(and (= content-type content-type-alert) (!= length 2))
          (TlsRecordHeaderErr
            (TlsWireError error-alert-length length-at alert-decode-error))]
        [(and (= content-type content-type-change-cipher-spec) (!= length 1))
          (TlsRecordHeaderErr
            (TlsWireError
              error-change-cipher-spec
              length-at
              alert-unexpected-message))]
        [else (TlsRecordHeaderOk (TlsRecordHeader content-type version length))]))))

;: One step of `record-reader-next!`: `consumed` input bytes were taken, and a
;: record is `TlsRecordComplete` when they finished one.
(defenum TlsRecordStep
  (TlsRecordNeedMore i64)
  (TlsRecordComplete i64 TlsRecordHeader)
  (TlsRecordFailed TlsWireError))

;: Incremental record framing. The header and fragment of the current record
;: are buffered separately; a completed record's fragment stays readable
;: through `record-reader-fragment` until the next call. After a failure the
;: reader returns that failure for all further input.
(defstruct TlsRecordReader
  (limits TlsWireLimits)
  (header-bytes byte_buf.ByteBuf)
  (fragment byte_buf.ByteBuf)
  (header TlsRecordHeader)
  (header-done bool)
  (ready bool)
  (stream-offset i64)
  (failed bool)
  (error TlsWireError))

;: A reader at the start of a stream. Traps unless `limits` satisfies
;: `limits-valid?`.
(define (record-reader-new [limits : TlsWireLimits]) : TlsRecordReader
  (TlsRecordReader
    (require-valid-limits limits)
    (byte_buf.with-capacity record-header-length)
    (byte_buf.with-capacity 0)
    (TlsRecordHeader 0 0 0)
    false
    false
    0
    false
    (TlsWireError 0 0 0)))

;: Enter the failed state with `error`, returning it.
(define (record-reader-fail!
  [reader : (&mut reader TlsRecordReader)]
  [error : TlsWireError]) : TlsWireError
  (begin
    (set! reader.failed true)
    (set! reader.error (copy-error (& error)))
    error))

;: Drop the completed record so the next one can start.
(define (record-reader-release! [reader : (&mut reader TlsRecordReader)]) : unit
  (begin
    (set!
      reader.stream-offset
      (+ (+ reader.stream-offset record-header-length) reader.header.length))
    (set! reader.header-bytes.len 0)
    (set! reader.fragment.len 0)
    (set! reader.header-done false)
    (set! reader.ready false)))

;: Take bytes of `input` into the current record, stopping at its end: returns
;: `TlsRecordComplete` once the record is whole, `TlsRecordNeedMore` when
;: `input` ran out first, or `TlsRecordFailed`. `protected` selects the header
;: rules of `decode-record-header`. The caller passes the unconsumed rest of
;: `input` to the next call.
(define (record-reader-next!
  [reader : (&mut reader TlsRecordReader)]
  [input : (& input bytes)]
  [protected : bool]) : TlsRecordStep
  (begin
    (when
      reader.failed
      (return (TlsRecordFailed (copy-error (& reader.error)))))
    (when reader.ready (record-reader-release! reader))
    (let
      [available : i64 (byte_buf.bytes-length input)]
      [consumed : i64 0]
      (begin
        (when
          (not reader.header-done)
          (let
            [want : i64
              (- record-header-length (byte_buf.len (& reader.header-bytes)))]
            [take : i64
              (if (< want available)
                want
                available)]
            (begin
              (buffer-append! (&mut reader.header-bytes) input 0 take)
              (set! consumed take)
              (when
                (< (byte_buf.len (& reader.header-bytes)) record-header-length)
                (return (TlsRecordNeedMore consumed)))
              (match (decode-record-header
                (byte_buf.as-bytes (& reader.header-bytes))
                0
                protected
                (& reader.limits)
                reader.stream-offset)
                [(TlsRecordHeaderErr error)
                  (return (TlsRecordFailed (record-reader-fail! reader error)))]
                [(TlsRecordHeaderOk header)
                  (begin
                    (buffer-reserve! (&mut reader.fragment) header.length)
                    (set! reader.header header)
                    (set! reader.header-done true))]))))
        (let
          [want : i64
            (- reader.header.length (byte_buf.len (& reader.fragment)))]
          [left : i64 (- available consumed)]
          [take : i64
            (if (< want left)
              want
              left)]
          (begin
            (buffer-append! (&mut reader.fragment) input consumed take)
            (set! consumed (+ consumed take))
            (cond
              [(< (byte_buf.len (& reader.fragment)) reader.header.length)
                (TlsRecordNeedMore consumed)]
              [(and
                  (= reader.header.content-type content-type-change-cipher-spec)
                  (!= (byte_buf.ref (& reader.fragment) 0) 1))
                (TlsRecordFailed
                  (record-reader-fail!
                    reader
                    (TlsWireError
                      error-change-cipher-spec
                      (+ reader.stream-offset record-header-length)
                      alert-unexpected-message)))]
              [else
                (begin
                  (set! reader.ready true)
                  (TlsRecordComplete
                    consumed
                    (TlsRecordHeader
                      reader.header.content-type
                      reader.header.legacy-version
                      reader.header.length)))])))))))

;: The fragment of the record the last `record-reader-next!` completed.
(define (record-reader-fragment [reader : (& reader TlsRecordReader)]) : (&
    reader
    bytes)
  (byte_buf.as-bytes (& reader.fragment)))

;: The stream offset of the current record's header.
(define (record-reader-offset [reader : (& reader TlsRecordReader)]) : i64
  reader.stream-offset)

;: Whether part of a record is buffered, which at the end of the stream means
;: the peer truncated it.
(define (record-reader-mid-record? [reader : (& reader TlsRecordReader)]) : bool
  (and (not reader.ready) (> (byte_buf.len (& reader.header-bytes)) 0)))

;: Append a record header. `length` may be up to the ciphertext maximum.
(define (encode-record-header
  [out : byte_buf.ByteBuf]
  [content-type : i64]
  [legacy-version : i64]
  [length : i64]) : byte_buf.ByteBuf
  (begin
    (byte_buf.check-range max-ciphertext-fragment 0 length)
    (push-be (push-be (push-be out content-type 1) legacy-version 2) length 2)))

;: Append one record holding `fragment`.
(define (encode-record
  [out : byte_buf.ByteBuf]
  [content-type : i64]
  [legacy-version : i64]
  [fragment : (& fragment bytes)]) : byte_buf.ByteBuf
  (byte_buf.append-bytes
    (encode-record-header
      out
      content-type
      legacy-version
      (byte_buf.bytes-length fragment))
    fragment))

;: Append handshake bytes `messages` as consecutive handshake records of at
;: most `max-fragment` bytes (1 to 2^14). An empty `messages` appends nothing,
;: because TLS forbids empty handshake records.
(define (encode-handshake-records
  [out : byte_buf.ByteBuf]
  [legacy-version : i64]
  [messages : (& messages bytes)]
  [max-fragment : i64]) : byte_buf.ByteBuf
  (let
    [total : i64 (byte_buf.bytes-length messages)]
    [offset : i64 0]
    [result : byte_buf.ByteBuf out]
    (begin
      (byte_buf.check-range max-plaintext-fragment 1 (- max-fragment 1))
      (while (< offset total)
        (let
          [count : i64
            (if (< (- total offset) max-fragment)
              (- total offset)
              max-fragment)]
          (begin
            (set!
              result
              (encode-record
                result
                content-type-handshake
                legacy-version
                (byte_buf.bytes-slice-view messages offset count)))
            (set! offset (+ offset count)))))
      result)))

;: A decrypted record's real content type and the length of its content,
;: which is the prefix of the plaintext before the type byte and padding.
(defstruct TlsInnerPlaintext
  (content-type i64)
  (length i64))

;: The result of `decode-inner-plaintext`.
(defenum TlsInnerPlaintextResult
  (TlsInnerPlaintextOk TlsInnerPlaintext)
  (TlsInnerPlaintextErr TlsWireError))

;: Split a decrypted `TLSInnerPlaintext`: the content type is the last
;: non-zero byte and the zeros after it are padding. The whole plaintext may
;: not exceed 2^14 + 1 bytes nor the content `max-plaintext-fragment`; the type
;: must be handshake, alert or application data; handshake and alert content
;: may not be empty, and an alert is exactly two bytes.
(define (decode-inner-plaintext
  [plaintext : (& plaintext bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsInnerPlaintextResult
  (let
    [total : i64 (byte_buf.bytes-length plaintext)]
    [index : i64 (- total 1)]
    (begin
      (when
        (> total (+ max-plaintext-fragment 1))
        (return
          (TlsInnerPlaintextErr
            (TlsWireError error-record-overflow 0 alert-record-overflow))))
      (while (and (>= index 0) (= (byte_buf.bytes-ref plaintext index) 0))
        (set! index (- index 1)))
      (if (< index 0)
        (TlsInnerPlaintextErr
          (TlsWireError error-missing-content-type 0 alert-unexpected-message))
        (let
          [content-type : i64 (read-be plaintext index 1)]
          (cond
            [(not
                (or
                  (= content-type content-type-alert)
                  (= content-type content-type-handshake)
                  (= content-type content-type-application-data)))
              (TlsInnerPlaintextErr
                (TlsWireError error-content-type index alert-unexpected-message))]
            [(> index limits.max-plaintext-fragment)
              (TlsInnerPlaintextErr
                (TlsWireError error-record-overflow index alert-record-overflow))]
            [(and (= index 0) (!= content-type content-type-application-data))
              (TlsInnerPlaintextErr
                (TlsWireError error-empty-fragment 0 alert-unexpected-message))]
            [(and (= content-type content-type-alert) (!= index 2))
              (TlsInnerPlaintextErr
                (TlsWireError error-alert-length index alert-decode-error))]
            [else (TlsInnerPlaintextOk (TlsInnerPlaintext content-type index))]))))))

;: Append a `TLSInnerPlaintext`: `content`, its type, then `padding` zeros.
;: The whole may not exceed 2^14 + 1 bytes, and `padding` may not be negative.
(define (encode-inner-plaintext
  [out : byte_buf.ByteBuf]
  [content : (& content bytes)]
  [content-type : i64]
  [padding : i64]) : byte_buf.ByteBuf
  (let
    [length : i64 (byte_buf.bytes-length content)]
    [result : byte_buf.ByteBuf
      (push-be (byte_buf.append-bytes out content) content-type 1)]
    [index : i64 0]
    (begin
      (byte_buf.check-range (- max-plaintext-fragment length) 0 padding)
      (while (< index padding)
        (begin
          (set! result (byte_buf.push result 0))
          (set! index (+ index 1))))
      result)))

;; --- handshake reassembly ---------------------------------------------------------
;: The outcome of `handshake-reader-next!`: a complete message of `msg-type`
;: with a body of `body-length` bytes, readable through
;: `handshake-reader-message`, or a need for more records.
(defenum TlsHandshakeNext
  (TlsHandshakeReady i64 i64)
  (TlsHandshakeNeedMore)
  (TlsHandshakeFailed TlsWireError))

;: Reassembles handshake messages from the content of handshake records.
;: `pending` holds the bytes not yet released: the message returned last (its
;: `held` bytes from `start`) and anything after it. `checked` is where the
;: first message header not yet checked against the limit starts, and `base`
;: is the handshake-stream offset of `pending[0]`.
(defstruct TlsHandshakeReader
  (limits TlsWireLimits)
  (pending byte_buf.ByteBuf)
  (start i64)
  (held i64)
  (checked i64)
  (base i64)
  (failed bool)
  (error TlsWireError))

;: An empty reader. Traps unless `limits` satisfies `limits-valid?`.
(define (handshake-reader-new [limits : TlsWireLimits]) : TlsHandshakeReader
  (TlsHandshakeReader
    (require-valid-limits limits)
    (byte_buf.with-capacity 0)
    0
    0
    0
    0
    false
    (TlsWireError 0 0 0)))

;: Enter the failed state with `error`, returning it.
(define (handshake-reader-fail!
  [reader : (&mut reader TlsHandshakeReader)]
  [error : TlsWireError]) : TlsWireError
  (begin
    (set! reader.failed true)
    (set! reader.error (copy-error (& error)))
    error))

;: Release the message returned last.
(define (handshake-reader-release! [reader : (&mut reader TlsHandshakeReader)]) : unit
  (begin
    (set! reader.start (+ reader.start reader.held))
    (set! reader.held 0)
    (when
      (= reader.start (byte_buf.len (& reader.pending)))
      (begin
        (set! reader.base (+ reader.base reader.start))
        (set! reader.pending.len 0)
        (set! reader.start 0)
        (set! reader.checked 0)))))

;: Move the unreleased bytes to the front of `pending`, so it never holds more
;: than one partial message and the record being added.
(define (handshake-reader-compact! [reader : (&mut reader TlsHandshakeReader)]) : unit
  (let
    [shift : i64 reader.start]
    [live : i64 (- (byte_buf.len (& reader.pending)) shift)]
    [index : i64 0]
    (begin
      (while (< index live)
        (begin
          (set!
            (array-ref reader.pending.slots index)
            (array-ref reader.pending.slots (+ shift index)))
          (set! index (+ index 1))))
      (set! reader.pending.len live)
      (set! reader.base (+ reader.base shift))
      (set! reader.checked (- reader.checked shift))
      (set! reader.start 0))))

;: Check every complete message header not yet checked, so an oversized
;: message fails as soon as its header arrives rather than after its body.
(define (handshake-reader-check-headers!
  [reader : (&mut reader TlsHandshakeReader)]) : TlsWireCheck
  (begin
    (while (<=
      (+ reader.checked handshake-header-length)
      (byte_buf.len (& reader.pending)))
      (let
        [body : i64
          (read-be
            (byte_buf.as-bytes (& reader.pending))
            (+ reader.checked 1)
            3)]
        (begin
          (when
            (> body reader.limits.max-handshake-body)
            (return
              (TlsWireErr
                (handshake-reader-fail!
                  reader
                  (TlsWireError
                    error-message-too-large
                    (+ (+ reader.base reader.checked) 1)
                    alert-decode-error)))))
          (set!
            reader.checked
            (+ (+ reader.checked handshake-header-length) body)))))
    (TlsWireOk)))

;: Add the content of one handshake record (the fragment of a plaintext
;: record or the content of a decrypted one). This releases the message
;: returned last. Empty content is a protocol error. Call
;: `handshake-reader-next!` until it needs more before feeding again.
(define (handshake-reader-feed!
  [reader : (&mut reader TlsHandshakeReader)]
  [content : (& content bytes)]) : TlsWireCheck
  (cond
    [reader.failed (TlsWireErr (copy-error (& reader.error)))]
    [(= (byte_buf.bytes-length content) 0)
      (TlsWireErr
        (handshake-reader-fail!
          reader
          (TlsWireError
            error-empty-fragment
            (+ reader.base (byte_buf.len (& reader.pending)))
            alert-unexpected-message)))]
    [else
      (begin
        (handshake-reader-release! reader)
        (when (> reader.start 0) (handshake-reader-compact! reader))
        (buffer-append!
          (&mut reader.pending)
          content
          0
          (byte_buf.bytes-length content))
        (handshake-reader-check-headers! reader))]))

;: Return the next complete message, releasing the one returned before, or
;: `TlsHandshakeNeedMore` when the buffered bytes end inside a message.
(define (handshake-reader-next! [reader : (&mut reader TlsHandshakeReader)]) : TlsHandshakeNext
  (if reader.failed
    (TlsHandshakeFailed (copy-error (& reader.error)))
    (begin
      (handshake-reader-release! reader)
      (let
        [live : i64 (- (byte_buf.len (& reader.pending)) reader.start)]
        (if (< live handshake-header-length)
          (TlsHandshakeNeedMore)
          (let
            [msg-type : i64
              (read-be (byte_buf.as-bytes (& reader.pending)) reader.start 1)]
            [body : i64
              (read-be
                (byte_buf.as-bytes (& reader.pending))
                (+ reader.start 1)
                3)]
            [size : i64 (+ handshake-header-length body)]
            (if (< live size)
              (TlsHandshakeNeedMore)
              (begin
                (set! reader.held size)
                (TlsHandshakeReady msg-type body)))))))))

;: The exact encoding (header and body) of the message the last
;: `handshake-reader-next!` returned, readable until the next call.
(define (handshake-reader-message [reader : (& reader TlsHandshakeReader)]) : (&
    reader
    bytes)
  (byte_buf.bytes-slice-view
    (byte_buf.as-bytes (& reader.pending))
    reader.start
    reader.held))

;: The handshake-stream offset of the message returned last.
(define (handshake-reader-message-offset
  [reader : (& reader TlsHandshakeReader)]) : i64
  (+ reader.base reader.start))

;: The body of a handshake message encoding.
(define (handshake-body [message : (& message bytes)]) : (& message bytes)
  (byte_buf.bytes-slice-view
    message
    handshake-header-length
    (- (byte_buf.bytes-length message) handshake-header-length)))

;: Whether every byte fed so far belongs to a returned message, so the last one
;: ended its record.
(define (handshake-reader-at-record-boundary?
  [reader : (& reader TlsHandshakeReader)]) : bool
  (and
    (not reader.failed)
    (= (+ reader.start reader.held) (byte_buf.len (& reader.pending)))))

;: Whether part of a handshake message is buffered: the bytes after the
;: complete messages end inside a header or body. `checked` stops exactly at
;: the end of the buffer only when every buffered message is complete.
(define (handshake-reader-buffering? [reader : (& reader TlsHandshakeReader)]) : bool
  (!= reader.checked (byte_buf.len (& reader.pending))))

;: Check that a key change may happen now. RFC 9846 requires the messages
;: before a key change (ClientHello, ServerHello, EndOfEarlyData, Finished,
;: KeyUpdate) to end their record; bytes after them fail with
;: `unexpected_message`.
(define (handshake-reader-check-key-change
  [reader : (&mut reader TlsHandshakeReader)]) : TlsWireCheck
  (cond
    [reader.failed (TlsWireErr (copy-error (& reader.error)))]
    [(handshake-reader-at-record-boundary? reader) (TlsWireOk)]
    [else
      (TlsWireErr
        (handshake-reader-fail!
          reader
          (TlsWireError
            error-key-change-unaligned
            (+ (+ reader.base reader.start) reader.held)
            alert-unexpected-message)))]))

;: Record that a record of `content-type` arrived. A record other than a
;: handshake record may not arrive while a handshake message is split.
(define (handshake-reader-note-record!
  [reader : (&mut reader TlsHandshakeReader)]
  [content-type : i64]) : TlsWireCheck
  (cond
    [reader.failed (TlsWireErr (copy-error (& reader.error)))]
    [(or
        (= content-type content-type-handshake)
        (not (handshake-reader-buffering? reader)))
      (TlsWireOk)]
    [else
      (TlsWireErr
        (handshake-reader-fail!
          reader
          (TlsWireError
            error-interleaved
            (+ reader.base (byte_buf.len (& reader.pending)))
            alert-unexpected-message)))]))

;: Append a handshake message with `msg-type` and body `body`.
(define (encode-handshake
  [out : byte_buf.ByteBuf]
  [msg-type : i64]
  [body : (& body bytes)]) : byte_buf.ByteBuf
  (encode-opaque (push-be out msg-type 1) body 3))

;: The synthetic `message_hash` message that replaces the first ClientHello in
;: the transcript after a HelloRetryRequest (RFC 9846 section 4.4.1), holding
;: that ClientHello's `digest`. The codec does not hash.
(define (message-hash-frame [digest : (& digest bytes)]) : byte_buf.ByteBuf
  (encode-handshake
    (byte_buf.with-capacity
      (+ handshake-header-length (byte_buf.bytes-length digest)))
    handshake-message-hash
    digest))

;: The ServerHello `random` that marks a HelloRetryRequest, SHA-256 of
;: "HelloRetryRequest", in hexadecimal.
(define hello-retry-request-random-hex : String
  "cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c")

;: The value of a lowercase hexadecimal digit `code`.
(define (hex-digit [code : i64]) : i64
  (if (<= code 57)
    (- code 48)
    (- code 87)))

;: Byte `index` of the HelloRetryRequest random.
(define (hello-retry-request-random-byte [index : i64]) : i64
  (+
    (*
      16
      (hex-digit
        (read-be
          (byte_buf.str-as-bytes (& hello-retry-request-random-hex))
          (* 2 index)
          1)))
    (hex-digit
      (read-be
        (byte_buf.str-as-bytes (& hello-retry-request-random-hex))
        (+ (* 2 index) 1)
        1))))

;: The HelloRetryRequest random, for building one.
(define (hello-retry-request-random) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity 32)]
    [index : i64 0]
    (begin
      (while (< index 32)
        (begin
          (set! out (push-be out (hello-retry-request-random-byte index) 1))
          (set! index (+ index 1))))
      out)))

;: Whether a ServerHello `random` marks a HelloRetryRequest.
(define (hello-retry-request-random? [random : (& random bytes)]) : bool
  (let
    [same : bool (= (byte_buf.bytes-length random) 32)]
    [index : i64 0]
    (begin
      (while (and same (< index 32))
        (begin
          (when
            (!=
              (read-be random index 1)
              (hello-retry-request-random-byte index))
            (set! same false))
          (set! index (+ index 1))))
      same)))

;; --- extensions ------------------------------------------------------------------------
;: `server_name` extension type. The extension types are those of RFC 9846
;: table 1 plus `max_fragment_length` and `signed_certificate_timestamp`, which
;: the IANA registry still lists for TLS 1.3 with the contexts of RFC 8446.
(define extension-server-name : i64
  0)

;: `max_fragment_length` extension type.
(define extension-max-fragment-length : i64
  1)

;: `status_request` extension type.
(define extension-status-request : i64
  5)

;: `supported_groups` extension type.
(define extension-supported-groups : i64
  10)

;: `signature_algorithms` extension type.
(define extension-signature-algorithms : i64
  13)

;: `use_srtp` extension type.
(define extension-use-srtp : i64
  14)

;: `heartbeat` extension type.
(define extension-heartbeat : i64
  15)

;: `application_layer_protocol_negotiation` extension type.
(define extension-application-layer-protocol-negotiation : i64
  16)

;: `signed_certificate_timestamp` extension type.
(define extension-signed-certificate-timestamp : i64
  18)

;: `client_certificate_type` extension type.
(define extension-client-certificate-type : i64
  19)

;: `server_certificate_type` extension type.
(define extension-server-certificate-type : i64
  20)

;: `padding` extension type.
(define extension-padding : i64
  21)

;: `compress_certificate` extension type.
(define extension-compress-certificate : i64
  27)

;: `record_size_limit` extension type.
(define extension-record-size-limit : i64
  28)

;: `delegated_credential` extension type.
(define extension-delegated-credential : i64
  34)

;: `supported_ekt_ciphers` extension type.
(define extension-supported-ekt-ciphers : i64
  39)

;: `pre_shared_key` extension type.
(define extension-pre-shared-key : i64
  41)

;: `early_data` extension type.
(define extension-early-data : i64
  42)

;: `supported_versions` extension type.
(define extension-supported-versions : i64
  43)

;: `cookie` extension type.
(define extension-cookie : i64
  44)

;: `psk_key_exchange_modes` extension type.
(define extension-psk-key-exchange-modes : i64
  45)

;: `certificate_authorities` extension type.
(define extension-certificate-authorities : i64
  47)

;: `oid_filters` extension type.
(define extension-oid-filters : i64
  48)

;: `post_handshake_auth` extension type.
(define extension-post-handshake-auth : i64
  49)

;: `signature_algorithms_cert` extension type.
(define extension-signature-algorithms-cert : i64
  50)

;: `key_share` extension type.
(define extension-key-share : i64
  51)

;: `transparency_info` extension type.
(define extension-transparency-info : i64
  52)

;: `external_id_hash` extension type.
(define extension-external-id-hash : i64
  55)

;: `external_session_id` extension type.
(define extension-external-session-id : i64
  56)

;: `quic_transport_parameters` extension type.
(define extension-quic-transport-parameters : i64
  57)

;: `ticket_request` extension type.
(define extension-ticket-request : i64
  58)

;: `ech_outer_extensions` extension type.
(define extension-ech-outer-extensions : i64
  0xfd00)

;: `encrypted_client_hello` extension type.
(define extension-encrypted-client-hello : i64
  0xfe0d)

;: The block of a ClientHello. The context of an extension block names the
;: message that carries it: a HelloRetryRequest is a ServerHello with the
;: HelloRetryRequest random, and a Certificate entry's block has its own.
(define context-client-hello : i64
  1)

;: The block of a ServerHello.
(define context-server-hello : i64
  2)

;: The block of a NewSessionTicket.
(define context-new-session-ticket : i64
  4)

;: The block of a HelloRetryRequest.
(define context-hello-retry-request : i64
  6)

;: The block of EncryptedExtensions.
(define context-encrypted-extensions : i64
  8)

;: The block of a Certificate entry.
(define context-certificate : i64
  11)

;: The block of a CertificateRequest.
(define context-certificate-request : i64
  13)

;: ClientHello bit of `extension-contexts`.
(define context-bit-ch : i64
  1)

;: ServerHello bit.
(define context-bit-sh : i64
  2)

;: HelloRetryRequest bit.
(define context-bit-hrr : i64
  4)

;: EncryptedExtensions bit.
(define context-bit-ee : i64
  8)

;: Certificate bit.
(define context-bit-ct : i64
  16)

;: CertificateRequest bit.
(define context-bit-cr : i64
  32)

;: NewSessionTicket bit.
(define context-bit-nst : i64
  64)

;: The bit of `context`, or 0 for an unknown context.
(define (context-bit [context : i64]) : i64
  (cond
    [(= context context-client-hello) context-bit-ch]
    [(= context context-server-hello) context-bit-sh]
    [(= context context-hello-retry-request) context-bit-hrr]
    [(= context context-encrypted-extensions) context-bit-ee]
    [(= context context-certificate) context-bit-ct]
    [(= context context-certificate-request) context-bit-cr]
    [(= context context-new-session-ticket) context-bit-nst]
    [else 0]))

;: The messages a recognized extension may appear in, as context bits
;: (RFC 9846 table 1), or 0 for an unrecognized type.
(define (extension-contexts [ext-type : i64]) : i64
  (let
    [ch-ee : i64 (bit-or context-bit-ch context-bit-ee)]
    [ch-cr : i64 (bit-or context-bit-ch context-bit-cr)]
    [ch-cr-ct : i64 (bit-or ch-cr context-bit-ct)]
    [hellos : i64
      (bit-or (bit-or context-bit-ch context-bit-sh) context-bit-hrr)]
    (cond
      [(= ext-type extension-server-name) (bit-or ch-ee context-bit-cr)]
      [(= ext-type extension-max-fragment-length) ch-ee]
      [(= ext-type extension-status-request) ch-cr-ct]
      [(= ext-type extension-supported-groups) ch-ee]
      [(= ext-type extension-signature-algorithms) ch-cr]
      [(= ext-type extension-use-srtp) ch-ee]
      [(= ext-type extension-heartbeat) ch-ee]
      [(= ext-type extension-application-layer-protocol-negotiation) ch-ee]
      [(= ext-type extension-signed-certificate-timestamp) ch-cr-ct]
      [(= ext-type extension-client-certificate-type) ch-ee]
      [(= ext-type extension-server-certificate-type) ch-ee]
      [(= ext-type extension-padding) context-bit-ch]
      [(= ext-type extension-compress-certificate) ch-cr]
      [(= ext-type extension-record-size-limit) ch-ee]
      [(= ext-type extension-delegated-credential) ch-cr-ct]
      [(= ext-type extension-supported-ekt-ciphers) ch-ee]
      [(= ext-type extension-pre-shared-key)
        (bit-or context-bit-ch context-bit-sh)]
      [(= ext-type extension-early-data) (bit-or ch-ee context-bit-nst)]
      [(= ext-type extension-supported-versions) hellos]
      [(= ext-type extension-cookie) (bit-or context-bit-ch context-bit-hrr)]
      [(= ext-type extension-psk-key-exchange-modes) context-bit-ch]
      [(= ext-type extension-certificate-authorities) ch-cr]
      [(= ext-type extension-oid-filters) context-bit-cr]
      [(= ext-type extension-post-handshake-auth) context-bit-ch]
      [(= ext-type extension-signature-algorithms-cert) ch-cr]
      [(= ext-type extension-key-share) hellos]
      [(= ext-type extension-transparency-info) ch-cr-ct]
      [(= ext-type extension-external-id-hash) ch-ee]
      [(= ext-type extension-external-session-id) ch-ee]
      [(= ext-type extension-quic-transport-parameters) ch-ee]
      [(= ext-type extension-ticket-request) ch-ee]
      [(= ext-type extension-ech-outer-extensions) context-bit-ch]
      [(= ext-type extension-encrypted-client-hello)
        (bit-or (bit-or context-bit-ch context-bit-hrr) context-bit-ee)]
      [else 0])))

;: Whether this module recognizes `ext-type`.
(define (extension-recognized? [ext-type : i64]) : bool
  (!= (extension-contexts ext-type) 0))

;: Whether a block in `context` answers the ClientHello, so that an
;: extension the client did not send is an error.
(define (response-context? [context : i64]) : bool
  (or
    (= context context-server-hello)
    (= context context-hello-retry-request)
    (= context context-encrypted-extensions)
    (= context context-certificate)))

;: One extension: its type and its `extension_data`.
(defstruct TlsExtension
  (ext-type i64)
  (data byte_buf.ByteBuf))

;: A decoded extension block, or its failure.
(defenum TlsExtensionsResult
  (TlsExtensionsOk (__tl_dyn-array TlsExtension))
  (TlsExtensionsErr TlsWireError))

;: Whether an extension of `ext-type` appears in the block entries between
;: `first` and `stop`.
(define (extension-type-before?
  [view : (& view bytes)]
  [first : i64]
  [stop : i64]
  [ext-type : i64]) : bool
  (let
    [cursor : i64 first]
    [found : bool false]
    (begin
      (while (and (not found) (< cursor stop))
        (begin
          (when (= (read-be view cursor 2) ext-type) (set! found true))
          (set! cursor (+ (+ cursor 4) (read-be view (+ cursor 2) 2)))))
      found)))

;: Check the entries of the extension block the cursor is inside, without
;: moving it, and count them.
(define (extension-block-scan!
  [d : (&mut d TlsDecoder)]
  [view : (& view bytes)]
  [context : i64]
  [limits : (& limits TlsWireLimits)]) : i64
  (let
    [first : i64 d.pos]
    [cursor : i64 d.pos]
    [count : i64 0]
    [bit : i64 (context-bit context)]
    (begin
      (while (and (not d.failed) (< cursor d.end))
        (cond
          [(>= count limits.max-extensions)
            (decoder-fail!
              d
              error-too-many-extensions
              alert-decode-error
              cursor)]
          [(> (+ cursor 4) d.end)
            (decoder-fail! d error-truncated alert-decode-error cursor)]
          [else
            (let
              [ext-type : i64 (read-be view cursor 2)]
              [next : i64 (+ (+ cursor 4) (read-be view (+ cursor 2) 2))]
              [allowed : i64 (extension-contexts ext-type)]
              (cond
                [(> next d.end)
                  (decoder-fail!
                    d
                    error-truncated
                    alert-decode-error
                    (+ cursor 2))]
                [(extension-type-before? view first cursor ext-type)
                  (decoder-fail!
                    d
                    error-duplicate-extension
                    alert-illegal-parameter
                    cursor)]
                [(and (= allowed 0) (response-context? context))
                  (decoder-fail!
                    d
                    error-unsolicited-extension
                    alert-unsupported-extension
                    cursor)]
                [(and (!= allowed 0) (= (bit-and allowed bit) 0))
                  (decoder-fail!
                    d
                    error-extension-context
                    alert-illegal-parameter
                    cursor)]
                [(and
                    (= context context-client-hello)
                    (= ext-type extension-pre-shared-key)
                    (!= next d.end))
                  (decoder-fail!
                    d
                    error-psk-not-last
                    alert-illegal-parameter
                    cursor)]
                [else
                  (begin
                    (set! count (+ count 1))
                    (set! cursor next))]))]))
      count)))

;: Read an extension block `<min..max>` of a message in `context`.
(define (decoder-extensions!
  [d : (&mut d TlsDecoder)]
  [view : (& view bytes)]
  [min : i64]
  [max : i64]
  [context : i64]
  [limits : (& limits TlsWireLimits)]) : (__tl_dyn-array TlsExtension)
  (let
    [outer : i64 (decoder-open! d view 2 min max)]
    [count : i64 (extension-block-scan! d view context limits)]
    [out : (__tl_dyn-array TlsExtension)
      (__tl_make-array
        TlsExtension
        (if d.failed
          0
          count))]
    [index : i64 0]
    (begin
      (while (and (not d.failed) (< index count))
        (let
          [ext-type : i64 (decoder-uint! d view 2)]
          [data : byte_buf.ByteBuf (decoder-opaque! d view 2 0 65535)]
          (begin
            (set! (array-ref out index) (TlsExtension ext-type data))
            (set! index (+ index 1)))))
      (decoder-close! d outer)
      out)))

;: Decode a standalone extension block (2-byte length and entries) of a
;: message in `context`.
(define (decode-extension-block
  [view : (& view bytes)]
  [context : i64]
  [limits : (& limits TlsWireLimits)]) : TlsExtensionsResult
  (let
    [d : TlsDecoder (decoder-new view)]
    [extensions : (__tl_dyn-array TlsExtension)
      (decoder-extensions! (&mut d) view 0 65535 context limits)]
    (begin
      (decoder-finish! (&mut d))
      (if d.failed
        (TlsExtensionsErr d.error)
        (TlsExtensionsOk extensions)))))

;: The index of the extension of `ext-type`, or -1.
(define (find-extension
  [extensions : (& extensions (__tl_dyn-array TlsExtension))]
  [ext-type : i64]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index (array-length extensions)))
        (begin
          (when
            (= (array-ref extensions index).ext-type ext-type)
            (set! found index))
          (set! index (+ index 1))))
      found)))

;: The data of `extensions[index]`.
(define (extension-data
  [extensions : (& source (__tl_dyn-array TlsExtension))]
  [index : i64]) : (& source bytes)
  (byte_buf.as-bytes (& (array-ref extensions index).data)))

;: Check a response block (`context` ServerHello, HelloRetryRequest,
;: EncryptedExtensions or Certificate) against the extension types the
;: ClientHello `offered`: RFC 9846 fails any other with
;: `unsupported_extension`, except `cookie` in a HelloRetryRequest. The error
;: offset is the extension's index.
(define (check-solicited
  [extensions : (& extensions (__tl_dyn-array TlsExtension))]
  [offered : (& offered (__tl_dyn-array i64))]
  [context : i64]) : TlsWireCheck
  (let
    [index : i64 0]
    (begin
      (while (< index (array-length extensions))
        (let
          [ext-type : i64 (array-ref extensions index).ext-type]
          [search : i64 0]
          [found : bool
            (and
              (= context context-hello-retry-request)
              (= ext-type extension-cookie))]
          (begin
            (while (and (not found) (< search (array-length offered)))
              (begin
                (when (= (array-ref offered search) ext-type) (set! found true))
                (set! search (+ search 1))))
            (when
              (not found)
              (return
                (TlsWireErr
                  (TlsWireError
                    error-unsolicited-extension
                    index
                    alert-unsupported-extension))))
            (set! index (+ index 1)))))
      (TlsWireOk))))

;: Append an extension block with its 2-byte length.
(define (encode-extensions
  [out : byte_buf.ByteBuf]
  [extensions : (& extensions (__tl_dyn-array TlsExtension))]) : byte_buf.ByteBuf
  (let
    [mark : i64 (byte_buf.len (& out))]
    [result : byte_buf.ByteBuf (push-be out 0 2)]
    [index : i64 0]
    (begin
      (while (< index (array-length extensions))
        (begin
          (set!
            result
            (encode-opaque
              (push-be result (array-ref extensions index).ext-type 2)
              (extension-data extensions index)
              2))
          (set! index (+ index 1))))
      (close-length result mark 2))))

;; --- extension bodies -------------------------------------------------------------------
;: A decoded integer field, or its failure.
(defenum TlsCodeResult
  (TlsCodeOk i64)
  (TlsCodeErr TlsWireError))

;: A decoded list of integer codes, or its failure.
(defenum TlsCodesResult
  (TlsCodesOk (__tl_dyn-array i64))
  (TlsCodesErr TlsWireError))

;: A decoded opaque field, or its failure.
(defenum TlsBytesResult
  (TlsBytesOk byte_buf.ByteBuf)
  (TlsBytesErr TlsWireError))

;: A decoded list of opaque items, or its failure.
(defenum TlsBytesListResult
  (TlsBytesListOk (__tl_dyn-array byte_buf.ByteBuf))
  (TlsBytesListErr TlsWireError))

;: The codes, or the cursor's failure.
(define (codes-result [d : (& d TlsDecoder)] [codes : (__tl_dyn-array i64)]) : TlsCodesResult
  (if d.failed
    (TlsCodesErr (copy-error (& d.error)))
    (TlsCodesOk codes)))

;: The code, or the cursor's failure.
(define (code-result [d : (& d TlsDecoder)] [code : i64]) : TlsCodeResult
  (if d.failed
    (TlsCodeErr (copy-error (& d.error)))
    (TlsCodeOk code)))

;: The bytes, or the cursor's failure.
(define (bytes-result [d : (& d TlsDecoder)] [data : byte_buf.ByteBuf]) : TlsBytesResult
  (if d.failed
    (TlsBytesErr (copy-error (& d.error)))
    (TlsBytesOk data)))

;: The items, or the cursor's failure.
(define (bytes-list-result
  [d : (& d TlsDecoder)]
  [items : (__tl_dyn-array byte_buf.ByteBuf)]) : TlsBytesListResult
  (if d.failed
    (TlsBytesListErr (copy-error (& d.error)))
    (TlsBytesListOk items)))

;: Decode a list of `item-width`-byte codes with a `prefix-width`-byte
;: length in `<min..max>` that fills `data`.
(define (decode-code-list
  [data : (& data bytes)]
  [prefix-width : i64]
  [item-width : i64]
  [min : i64]
  [max : i64]
  [limits : (& limits TlsWireLimits)]) : TlsCodesResult
  (let
    [d : TlsDecoder (decoder-new data)]
    [codes : (__tl_dyn-array i64)
      (decoder-codes!
        (&mut d)
        data
        prefix-width
        item-width
        min
        max
        limits.max-list-entries)]
    (begin
      (decoder-finish! (&mut d))
      (codes-result (& d) codes))))

;: Decode a single `width`-byte code that fills `data`.
(define (decode-code [data : (& data bytes)] [width : i64]) : TlsCodeResult
  (let
    [d : TlsDecoder (decoder-new data)]
    [code : i64 (decoder-uint! (&mut d) data width)]
    (begin
      (decoder-finish! (&mut d))
      (code-result (& d) code))))

;: ClientHello `supported_versions`: `ProtocolVersion versions<2..254>`.
(define (decode-supported-versions
  [data : (& data bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsCodesResult
  (decode-code-list data 1 2 2 254 limits))

;: ServerHello and HelloRetryRequest `supported_versions`: the selected
;: version.
(define (decode-selected-version [data : (& data bytes)]) : TlsCodeResult
  (decode-code data 2))

;: `supported_groups`: `NamedGroup named_group_list<2..2^16-1>`.
(define (decode-supported-groups
  [data : (& data bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsCodesResult
  (decode-code-list data 2 2 2 65535 limits))

;: `signature_algorithms` and `signature_algorithms_cert`:
;: `SignatureScheme supported_signature_algorithms<2..2^16-2>`.
(define (decode-signature-schemes
  [data : (& data bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsCodesResult
  (decode-code-list data 2 2 2 65534 limits))

;: `psk_key_exchange_modes`: `PskKeyExchangeMode ke_modes<1..255>`.
(define (decode-psk-key-exchange-modes
  [data : (& data bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsCodesResult
  (decode-code-list data 1 1 1 255 limits))

;: HelloRetryRequest `key_share`: the selected group.
(define (decode-key-share-hello-retry [data : (& data bytes)]) : TlsCodeResult
  (decode-code data 2))

;: NewSessionTicket `early_data`: `max_early_data_size`.
(define (decode-early-data-ticket [data : (& data bytes)]) : TlsCodeResult
  (decode-code data 4))

;: An extension whose data must be empty: `early_data` in ClientHello and
;: EncryptedExtensions, `post_handshake_auth`, and the `server_name`
;: acknowledgement.
(define (decode-empty-extension [data : (& data bytes)]) : TlsWireCheck
  (if (= (byte_buf.bytes-length data) 0)
    (TlsWireOk)
    (TlsWireErr (TlsWireError error-trailing 0 alert-decode-error))))

;: `cookie`: `opaque cookie<1..2^16-1>`.
(define (decode-cookie [data : (& data bytes)]) : TlsBytesResult
  (let
    [d : TlsDecoder (decoder-new data)]
    [cookie : byte_buf.ByteBuf (decoder-opaque! (&mut d) data 2 1 65535)]
    (begin
      (decoder-finish! (&mut d))
      (bytes-result (& d) cookie))))

;: `application_layer_protocol_negotiation` in a ClientHello:
;: `ProtocolName protocol_name_list<2..2^16-1>`, names `<1..2^8-1>`.
(define (decode-alpn-list
  [data : (& data bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsBytesListResult
  (let
    [d : TlsDecoder (decoder-new data)]
    [names : (__tl_dyn-array byte_buf.ByteBuf)
      (decoder-opaque-list! (&mut d) data 2 2 1 1 255 limits.max-list-entries)]
    (begin
      (decoder-finish! (&mut d))
      (bytes-list-result (& d) names))))

;: `application_layer_protocol_negotiation` in EncryptedExtensions: a list
;: of exactly one name (RFC 7301 section 3.1).
(define (decode-alpn-selected [data : (& data bytes)]) : TlsBytesResult
  (let
    [d : TlsDecoder (decoder-new data)]
    [outer : i64 (decoder-open! (&mut d) data 2 2 65535)]
    [name : byte_buf.ByteBuf (decoder-opaque! (&mut d) data 1 1 255)]
    (begin
      (when
        (and (not d.failed) (!= d.pos d.end))
        (decoder-fail!
          (&mut d)
          error-illegal-value
          alert-illegal-parameter
          d.pos))
      (decoder-close! (&mut d) outer)
      (decoder-finish! (&mut d))
      (bytes-result (& d) name))))

;: `server_name` in a ClientHello: a `ServerNameList` holding one `host_name`
;: (RFC 6066 section 3), whose bytes are returned without DNS validation.
;: Another name type or a second `host_name` is illegal.
(define (decode-server-name [data : (& data bytes)]) : TlsBytesResult
  (let
    [d : TlsDecoder (decoder-new data)]
    [outer : i64 (decoder-open! (&mut d) data 2 1 65535)]
    [type-at : i64 d.pos]
    [name-type : i64 (decoder-uint! (&mut d) data 1)]
    [host : byte_buf.ByteBuf (decoder-opaque! (&mut d) data 2 1 65535)]
    (begin
      (cond
        [d.failed unit]
        [(!= name-type 0)
          (decoder-fail!
            (&mut d)
            error-illegal-value
            alert-illegal-parameter
            type-at)]
        [(and (< d.pos d.end) (= (read-be data d.pos 1) 0))
          (decoder-fail!
            (&mut d)
            error-duplicate-entry
            alert-illegal-parameter
            d.pos)]
        [(< d.pos d.end)
          (decoder-fail!
            (&mut d)
            error-illegal-value
            alert-illegal-parameter
            d.pos)]
        [else unit])
      (decoder-close! (&mut d) outer)
      (decoder-finish! (&mut d))
      (bytes-result (& d) host))))

;: `certificate_authorities`: `DistinguishedName authorities<3..2^16-1>`, each
;: `opaque DistinguishedName<1..2^16-1>` kept as DER bytes.
(define (decode-certificate-authorities
  [data : (& data bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsBytesListResult
  (let
    [d : TlsDecoder (decoder-new data)]
    [names : (__tl_dyn-array byte_buf.ByteBuf)
      (decoder-opaque-list! (&mut d) data 2 3 2 1 65535 limits.max-list-entries)]
    (begin
      (decoder-finish! (&mut d))
      (bytes-list-result (& d) names))))

;: One `KeyShareEntry`: a group and its `key_exchange` bytes.
(defstruct TlsKeyShareEntry
  (group i64)
  (key-exchange byte_buf.ByteBuf))

;: The result of `decode-key-share-client-hello`.
(defenum TlsKeySharesResult
  (TlsKeySharesOk (__tl_dyn-array TlsKeyShareEntry))
  (TlsKeySharesErr TlsWireError))

;: The result of `decode-key-share-server-hello`.
(defenum TlsKeyShareResult
  (TlsKeyShareOk TlsKeyShareEntry)
  (TlsKeyShareErr TlsWireError))

;: Read one `KeyShareEntry`.
(define (decoder-key-share! [d : (&mut d TlsDecoder)] [view : (& view bytes)]) : TlsKeyShareEntry
  (let
    [group : i64 (decoder-uint! d view 2)]
    [key-exchange : byte_buf.ByteBuf (decoder-opaque! d view 2 1 65535)]
    (TlsKeyShareEntry group key-exchange)))

;: ClientHello `key_share`: `KeyShareEntry client_shares<0..2^16-1>`. A group
;: may not repeat.
(define (decode-key-share-client-hello
  [data : (& data bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsKeySharesResult
  (let
    [d : TlsDecoder (decoder-new data)]
    [outer : i64 (decoder-open! (&mut d) data 2 0 65535)]
    [first : i64 d.pos]
    [cursor : i64 d.pos]
    [count : i64 0]
    (begin
      (while (and (not d.failed) (< cursor d.end))
        (cond
          [(>= count limits.max-list-entries)
            (decoder-fail!
              (&mut d)
              error-too-many-entries
              alert-decode-error
              cursor)]
          [(> (+ cursor 4) d.end)
            (decoder-fail! (&mut d) error-truncated alert-decode-error cursor)]
          [else
            (let
              [length : i64 (read-be data (+ cursor 2) 2)]
              [next : i64 (+ (+ cursor 4) length)]
              (cond
                [(= length 0)
                  (decoder-fail!
                    (&mut d)
                    error-length-range
                    alert-decode-error
                    (+ cursor 2))]
                [(> next d.end)
                  (decoder-fail!
                    (&mut d)
                    error-truncated
                    alert-decode-error
                    (+ cursor 2))]
                [(extension-type-before?
                    data
                    first
                    cursor
                    (read-be data cursor 2))
                  (decoder-fail!
                    (&mut d)
                    error-duplicate-entry
                    alert-illegal-parameter
                    cursor)]
                [else
                  (begin
                    (set! count (+ count 1))
                    (set! cursor next))]))]))
      (let
        [shares : (__tl_dyn-array TlsKeyShareEntry)
          (__tl_make-array
            TlsKeyShareEntry
            (if d.failed
              0
              count))]
        [index : i64 0]
        (begin
          (while (and (not d.failed) (< index count))
            (begin
              (set! (array-ref shares index) (decoder-key-share! (&mut d) data))
              (set! index (+ index 1))))
          (decoder-close! (&mut d) outer)
          (decoder-finish! (&mut d))
          (if d.failed
            (TlsKeySharesErr d.error)
            (TlsKeySharesOk shares)))))))

;: ServerHello `key_share`: one `KeyShareEntry`.
(define (decode-key-share-server-hello [data : (& data bytes)]) : TlsKeyShareResult
  (let
    [d : TlsDecoder (decoder-new data)]
    [share : TlsKeyShareEntry (decoder-key-share! (&mut d) data)]
    (begin
      (decoder-finish! (&mut d))
      (if d.failed
        (TlsKeyShareErr d.error)
        (TlsKeyShareOk share)))))

;: Append a list of `item-width`-byte codes with a `prefix-width`-byte length.
(define (encode-code-list
  [out : byte_buf.ByteBuf]
  [codes : (& codes (__tl_dyn-array i64))]
  [prefix-width : i64]
  [item-width : i64]) : byte_buf.ByteBuf
  (let
    [mark : i64 (byte_buf.len (& out))]
    [result : byte_buf.ByteBuf (push-be out 0 prefix-width)]
    [index : i64 0]
    (begin
      (while (< index (array-length codes))
        (begin
          (set! result (push-be result (array-ref codes index) item-width))
          (set! index (+ index 1))))
      (close-length result mark prefix-width))))

;: Append a list of opaque items with `inner-width`-byte lengths inside an
;: `outer-width`-byte length: ALPN names (2, 1) or distinguished names (2, 2).
(define (encode-opaque-list
  [out : byte_buf.ByteBuf]
  [items : (& items (__tl_dyn-array byte_buf.ByteBuf))]
  [outer-width : i64]
  [inner-width : i64]) : byte_buf.ByteBuf
  (let
    [mark : i64 (byte_buf.len (& out))]
    [result : byte_buf.ByteBuf (push-be out 0 outer-width)]
    [index : i64 0]
    (begin
      (while (< index (array-length items))
        (begin
          (set!
            result
            (encode-opaque
              result
              (byte_buf.as-bytes (& (array-ref items index)))
              inner-width))
          (set! index (+ index 1))))
      (close-length result mark outer-width))))

;: Append one `KeyShareEntry` (the ServerHello `key_share` data).
(define (encode-key-share
  [out : byte_buf.ByteBuf]
  [share : (& share TlsKeyShareEntry)]) : byte_buf.ByteBuf
  (encode-opaque
    (push-be out share.group 2)
    (byte_buf.as-bytes (& share.key-exchange))
    2))

;: Append the ClientHello `key_share` data: the entries with a 2-byte length.
(define (encode-key-share-client-hello
  [out : byte_buf.ByteBuf]
  [shares : (& shares (__tl_dyn-array TlsKeyShareEntry))]) : byte_buf.ByteBuf
  (let
    [mark : i64 (byte_buf.len (& out))]
    [result : byte_buf.ByteBuf (push-be out 0 2)]
    [index : i64 0]
    (begin
      (while (< index (array-length shares))
        (begin
          (set! result (encode-key-share result (& (array-ref shares index))))
          (set! index (+ index 1))))
      (close-length result mark 2))))

;: Append the ClientHello `server_name` data for one `host_name`.
(define (encode-server-name [out : byte_buf.ByteBuf] [host : (& host bytes)]) : byte_buf.ByteBuf
  (let
    [mark : i64 (byte_buf.len (& out))]
    (close-length (encode-opaque (push-be (push-be out 0 2) 0 1) host 2) mark 2)))

;; --- handshake messages -------------------------------------------------------------------
;: A ClientHello. `random` is 32 bytes.
(defstruct TlsClientHello
  (legacy-version i64)
  (random byte_buf.ByteBuf)
  (legacy-session-id byte_buf.ByteBuf)
  (cipher-suites (__tl_dyn-array i64))
  (legacy-compression-methods byte_buf.ByteBuf)
  (extensions (__tl_dyn-array TlsExtension)))

;: The result of `decode-client-hello`.
(defenum TlsClientHelloResult
  (TlsClientHelloOk TlsClientHello)
  (TlsClientHelloErr TlsWireError))

;: Decode a ClientHello body. RFC 9846 requires the single compression method
;: 0 (`illegal_parameter` otherwise) and at least 8 bytes of extensions.
(define (decode-client-hello
  [body : (& body bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsClientHelloResult
  (let
    [d : TlsDecoder (decoder-new body)]
    [legacy-version : i64 (decoder-uint! (&mut d) body 2)]
    [random : byte_buf.ByteBuf (decoder-copy! (&mut d) body 32)]
    [session-id : byte_buf.ByteBuf (decoder-opaque! (&mut d) body 1 0 32)]
    [suites : (__tl_dyn-array i64)
      (decoder-codes! (&mut d) body 2 2 2 65534 limits.max-list-entries)]
    [compression-at : i64 d.pos]
    [compression : byte_buf.ByteBuf (decoder-opaque! (&mut d) body 1 1 255)]
    (begin
      (when
        (and
          (not d.failed)
          (not
            (and
              (= (byte_buf.len (& compression)) 1)
              (= (byte_buf.ref (& compression) 0) 0))))
        (decoder-fail!
          (&mut d)
          error-illegal-value
          alert-illegal-parameter
          compression-at))
      (let
        [extensions : (__tl_dyn-array TlsExtension)
          (decoder-extensions!
            (&mut d)
            body
            8
            65535
            context-client-hello
            limits)]
        (begin
          (decoder-finish! (&mut d))
          (if d.failed
            (TlsClientHelloErr d.error)
            (TlsClientHelloOk
              (TlsClientHello
                legacy-version
                random
                session-id
                suites
                compression
                extensions))))))))

;: Append a ClientHello message.
(define (encode-client-hello
  [out : byte_buf.ByteBuf]
  [hello : (& hello TlsClientHello)]) : byte_buf.ByteBuf
  (let
    [mark : i64 (+ (byte_buf.len (& out)) 1)]
    [result : byte_buf.ByteBuf
      (push-be (push-be out handshake-client-hello 1) 0 3)]
    (begin
      (check-length (byte_buf.len (& hello.random)) 32)
      (set! result (push-be result hello.legacy-version 2))
      (set!
        result
        (byte_buf.append-bytes result (byte_buf.as-bytes (& hello.random))))
      (set!
        result
        (encode-opaque result (byte_buf.as-bytes (& hello.legacy-session-id)) 1))
      (set! result (encode-code-list result (& hello.cipher-suites) 2 2))
      (set!
        result
        (encode-opaque
          result
          (byte_buf.as-bytes (& hello.legacy-compression-methods))
          1))
      (set! result (encode-extensions result (& hello.extensions)))
      (close-length result mark 3))))

;: A ServerHello or HelloRetryRequest; `server-hello-retry?` tells them apart.
(defstruct TlsServerHello
  (legacy-version i64)
  (random byte_buf.ByteBuf)
  (legacy-session-id-echo byte_buf.ByteBuf)
  (cipher-suite i64)
  (extensions (__tl_dyn-array TlsExtension)))

;: The result of `decode-server-hello`.
(defenum TlsServerHelloResult
  (TlsServerHelloOk TlsServerHello)
  (TlsServerHelloErr TlsWireError))

;: Whether `hello` is a HelloRetryRequest.
(define (server-hello-retry? [hello : (& hello TlsServerHello)]) : bool
  (hello-retry-request-random? (byte_buf.as-bytes (& hello.random))))

;: Decode a ServerHello body. Its extensions are checked in the
;: HelloRetryRequest context when `random` marks one. The compression method
;: must be 0.
(define (decode-server-hello
  [body : (& body bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsServerHelloResult
  (let
    [d : TlsDecoder (decoder-new body)]
    [legacy-version : i64 (decoder-uint! (&mut d) body 2)]
    [random : byte_buf.ByteBuf (decoder-copy! (&mut d) body 32)]
    [session-id : byte_buf.ByteBuf (decoder-opaque! (&mut d) body 1 0 32)]
    [cipher-suite : i64 (decoder-uint! (&mut d) body 2)]
    [compression-at : i64 d.pos]
    [compression : i64 (decoder-uint! (&mut d) body 1)]
    [context : i64
      (if (hello-retry-request-random? (byte_buf.as-bytes (& random)))
        context-hello-retry-request
        context-server-hello)]
    (begin
      (when
        (and (not d.failed) (!= compression 0))
        (decoder-fail!
          (&mut d)
          error-illegal-value
          alert-illegal-parameter
          compression-at))
      (let
        [extensions : (__tl_dyn-array TlsExtension)
          (decoder-extensions! (&mut d) body 6 65535 context limits)]
        (begin
          (decoder-finish! (&mut d))
          (if d.failed
            (TlsServerHelloErr d.error)
            (TlsServerHelloOk
              (TlsServerHello
                legacy-version
                random
                session-id
                cipher-suite
                extensions))))))))

;: Append a ServerHello (or, with the HelloRetryRequest random, a
;: HelloRetryRequest) message.
(define (encode-server-hello
  [out : byte_buf.ByteBuf]
  [hello : (& hello TlsServerHello)]) : byte_buf.ByteBuf
  (let
    [mark : i64 (+ (byte_buf.len (& out)) 1)]
    [result : byte_buf.ByteBuf
      (push-be (push-be out handshake-server-hello 1) 0 3)]
    (begin
      (check-length (byte_buf.len (& hello.random)) 32)
      (set! result (push-be result hello.legacy-version 2))
      (set!
        result
        (byte_buf.append-bytes result (byte_buf.as-bytes (& hello.random))))
      (set!
        result
        (encode-opaque
          result
          (byte_buf.as-bytes (& hello.legacy-session-id-echo))
          1))
      (set! result (push-be (push-be result hello.cipher-suite 2) 0 1))
      (set! result (encode-extensions result (& hello.extensions)))
      (close-length result mark 3))))

;: Decode an EncryptedExtensions body.
(define (decode-encrypted-extensions
  [body : (& body bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsExtensionsResult
  (let
    [d : TlsDecoder (decoder-new body)]
    [extensions : (__tl_dyn-array TlsExtension)
      (decoder-extensions!
        (&mut d)
        body
        0
        65535
        context-encrypted-extensions
        limits)]
    (begin
      (decoder-finish! (&mut d))
      (if d.failed
        (TlsExtensionsErr d.error)
        (TlsExtensionsOk extensions)))))

;: Append an EncryptedExtensions message.
(define (encode-encrypted-extensions
  [out : byte_buf.ByteBuf]
  [extensions : (& extensions (__tl_dyn-array TlsExtension))]) : byte_buf.ByteBuf
  (let
    [mark : i64 (+ (byte_buf.len (& out)) 1)]
    (close-length
      (encode-extensions
        (push-be (push-be out handshake-encrypted-extensions 1) 0 3)
        extensions)
      mark
      3)))

;: A CertificateRequest.
(defstruct TlsCertificateRequest
  (context byte_buf.ByteBuf)
  (extensions (__tl_dyn-array TlsExtension)))

;: The result of `decode-certificate-request`.
(defenum TlsCertificateRequestResult
  (TlsCertificateRequestOk TlsCertificateRequest)
  (TlsCertificateRequestErr TlsWireError))

;: Decode a CertificateRequest body, which must carry
;: `signature_algorithms`.
(define (decode-certificate-request
  [body : (& body bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsCertificateRequestResult
  (let
    [d : TlsDecoder (decoder-new body)]
    [context : byte_buf.ByteBuf (decoder-opaque! (&mut d) body 1 0 255)]
    [extensions-at : i64 d.pos]
    [extensions : (__tl_dyn-array TlsExtension)
      (decoder-extensions!
        (&mut d)
        body
        2
        65535
        context-certificate-request
        limits)]
    (begin
      (decoder-finish! (&mut d))
      (when
        (and
          (not d.failed)
          (< (find-extension (& extensions) extension-signature-algorithms) 0))
        (decoder-fail!
          (&mut d)
          error-missing-extension
          alert-missing-extension
          extensions-at))
      (if d.failed
        (TlsCertificateRequestErr d.error)
        (TlsCertificateRequestOk (TlsCertificateRequest context extensions))))))

;: Append a CertificateRequest message.
(define (encode-certificate-request
  [out : byte_buf.ByteBuf]
  [request : (& request TlsCertificateRequest)]) : byte_buf.ByteBuf
  (let
    [mark : i64 (+ (byte_buf.len (& out)) 1)]
    (close-length
      (encode-extensions
        (encode-opaque
          (push-be (push-be out handshake-certificate-request 1) 0 3)
          (byte_buf.as-bytes (& request.context))
          1)
        (& request.extensions))
      mark
      3)))

;: One `CertificateEntry`: the certificate (or raw public key) bytes and the
;: entry's extensions.
(defstruct TlsCertificateEntry
  (data byte_buf.ByteBuf)
  (extensions (__tl_dyn-array TlsExtension)))

;: A Certificate message. A client without a certificate sends an empty
;: `entries` list.
(defstruct TlsCertificate
  (context byte_buf.ByteBuf)
  (entries (__tl_dyn-array TlsCertificateEntry)))

;: The result of `decode-certificate`.
(defenum TlsCertificateResult
  (TlsCertificateOk TlsCertificate)
  (TlsCertificateErr TlsWireError))

;: Count the certificate entries from the cursor to its end without moving it,
;: checking each entry's framing and the certificate limits.
(define (certificate-list-scan!
  [d : (&mut d TlsDecoder)]
  [view : (& view bytes)]
  [limits : (& limits TlsWireLimits)]) : i64
  (let
    [cursor : i64 d.pos]
    [count : i64 0]
    (begin
      (while (and (not d.failed) (< cursor d.end))
        (cond
          [(>= count limits.max-certificates)
            (decoder-fail!
              d
              error-too-many-certificates
              alert-decode-error
              cursor)]
          [(> (+ cursor 3) d.end)
            (decoder-fail! d error-truncated alert-decode-error cursor)]
          [else
            (let
              [length : i64 (read-be view cursor 3)]
              [extensions-at : i64 (+ (+ cursor 3) length)]
              (cond
                [(= length 0)
                  (decoder-fail! d error-length-range alert-decode-error cursor)]
                [(> length limits.max-certificate-bytes)
                  (decoder-fail!
                    d
                    error-certificate-too-large
                    alert-decode-error
                    cursor)]
                [(> (+ extensions-at 2) d.end)
                  (decoder-fail! d error-truncated alert-decode-error cursor)]
                [(>
                    (+ (+ extensions-at 2) (read-be view extensions-at 2))
                    d.end)
                  (decoder-fail!
                    d
                    error-truncated
                    alert-decode-error
                    extensions-at)]
                [else
                  (begin
                    (set! count (+ count 1))
                    (set!
                      cursor
                      (+ (+ extensions-at 2) (read-be view extensions-at 2))))]))]))
      count)))

;: Decode a Certificate body.
(define (decode-certificate
  [body : (& body bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsCertificateResult
  (let
    [d : TlsDecoder (decoder-new body)]
    [context : byte_buf.ByteBuf (decoder-opaque! (&mut d) body 1 0 255)]
    [outer : i64 (decoder-open! (&mut d) body 3 0 max-handshake-body)]
    [count : i64 (certificate-list-scan! (&mut d) body limits)]
    [entries : (__tl_dyn-array TlsCertificateEntry)
      (__tl_make-array
        TlsCertificateEntry
        (if d.failed
          0
          count))]
    [index : i64 0]
    (begin
      (while (and (not d.failed) (< index count))
        (let
          [data : byte_buf.ByteBuf
            (decoder-opaque! (&mut d) body 3 1 max-handshake-body)]
          [extensions : (__tl_dyn-array TlsExtension)
            (decoder-extensions!
              (&mut d)
              body
              0
              65535
              context-certificate
              limits)]
          (begin
            (set!
              (array-ref entries index)
              (TlsCertificateEntry data extensions))
            (set! index (+ index 1)))))
      (decoder-close! (&mut d) outer)
      (decoder-finish! (&mut d))
      (if d.failed
        (TlsCertificateErr d.error)
        (TlsCertificateOk (TlsCertificate context entries))))))

;: Append a Certificate message.
(define (encode-certificate
  [out : byte_buf.ByteBuf]
  [certificate : (& certificate TlsCertificate)]) : byte_buf.ByteBuf
  (let
    [mark : i64 (+ (byte_buf.len (& out)) 1)]
    [result : byte_buf.ByteBuf
      (encode-opaque
        (push-be (push-be out handshake-certificate 1) 0 3)
        (byte_buf.as-bytes (& certificate.context))
        1)]
    [list-mark : i64 (byte_buf.len (& result))]
    [index : i64 0]
    (begin
      (set! result (push-be result 0 3))
      (while (< index (array-length certificate.entries))
        (let
          [entry : (& certificate TlsCertificateEntry)
            (& (array-ref certificate.entries index))]
          (begin
            (set!
              result
              (encode-extensions
                (encode-opaque result (byte_buf.as-bytes (& entry.data)) 3)
                (& entry.extensions)))
            (set! index (+ index 1)))))
      (close-length (close-length result list-mark 3) mark 3))))

;: A CertificateVerify.
(defstruct TlsCertificateVerify
  (algorithm i64)
  (signature byte_buf.ByteBuf))

;: The result of `decode-certificate-verify`.
(defenum TlsCertificateVerifyResult
  (TlsCertificateVerifyOk TlsCertificateVerify)
  (TlsCertificateVerifyErr TlsWireError))

;: Decode a CertificateVerify body.
(define (decode-certificate-verify [body : (& body bytes)]) : TlsCertificateVerifyResult
  (let
    [d : TlsDecoder (decoder-new body)]
    [algorithm : i64 (decoder-uint! (&mut d) body 2)]
    [signature : byte_buf.ByteBuf (decoder-opaque! (&mut d) body 2 0 65535)]
    (begin
      (decoder-finish! (&mut d))
      (if d.failed
        (TlsCertificateVerifyErr d.error)
        (TlsCertificateVerifyOk (TlsCertificateVerify algorithm signature))))))

;: Append a CertificateVerify message.
(define (encode-certificate-verify
  [out : byte_buf.ByteBuf]
  [verify : (& verify TlsCertificateVerify)]) : byte_buf.ByteBuf
  (let
    [mark : i64 (+ (byte_buf.len (& out)) 1)]
    (close-length
      (encode-opaque
        (push-be
          (push-be (push-be out handshake-certificate-verify 1) 0 3)
          verify.algorithm
          2)
        (byte_buf.as-bytes (& verify.signature))
        2)
      mark
      3)))

;: Decode a Finished body, whose `verify_data` is exactly `hash-length`
;: bytes (32 for SHA-256).
(define (decode-finished [body : (& body bytes)] [hash-length : i64]) : TlsBytesResult
  (let
    [d : TlsDecoder (decoder-new body)]
    [verify-data : byte_buf.ByteBuf (decoder-copy! (&mut d) body hash-length)]
    (begin
      (decoder-finish! (&mut d))
      (bytes-result (& d) verify-data))))

;: Append a Finished message.
(define (encode-finished
  [out : byte_buf.ByteBuf]
  [verify-data : (& verify-data bytes)]) : byte_buf.ByteBuf
  (encode-handshake out handshake-finished verify-data))

;: A NewSessionTicket.
(defstruct TlsNewSessionTicket
  (lifetime i64)
  (age-add i64)
  (nonce byte_buf.ByteBuf)
  (ticket byte_buf.ByteBuf)
  (extensions (__tl_dyn-array TlsExtension)))

;: The result of `decode-new-session-ticket`.
(defenum TlsNewSessionTicketResult
  (TlsNewSessionTicketOk TlsNewSessionTicket)
  (TlsNewSessionTicketErr TlsWireError))

;: Decode a NewSessionTicket body.
(define (decode-new-session-ticket
  [body : (& body bytes)]
  [limits : (& limits TlsWireLimits)]) : TlsNewSessionTicketResult
  (let
    [d : TlsDecoder (decoder-new body)]
    [lifetime : i64 (decoder-uint! (&mut d) body 4)]
    [age-add : i64 (decoder-uint! (&mut d) body 4)]
    [nonce : byte_buf.ByteBuf (decoder-opaque! (&mut d) body 1 0 255)]
    [ticket : byte_buf.ByteBuf (decoder-opaque! (&mut d) body 2 1 65535)]
    [extensions : (__tl_dyn-array TlsExtension)
      (decoder-extensions!
        (&mut d)
        body
        0
        65534
        context-new-session-ticket
        limits)]
    (begin
      (decoder-finish! (&mut d))
      (if d.failed
        (TlsNewSessionTicketErr d.error)
        (TlsNewSessionTicketOk
          (TlsNewSessionTicket lifetime age-add nonce ticket extensions))))))

;: Append a NewSessionTicket message.
(define (encode-new-session-ticket
  [out : byte_buf.ByteBuf]
  [ticket : (& ticket TlsNewSessionTicket)]) : byte_buf.ByteBuf
  (let
    [mark : i64 (+ (byte_buf.len (& out)) 1)]
    (close-length
      (encode-extensions
        (encode-opaque
          (encode-opaque
            (push-be
              (push-be
                (push-be (push-be out handshake-new-session-ticket 1) 0 3)
                ticket.lifetime
                4)
              ticket.age-add
              4)
            (byte_buf.as-bytes (& ticket.nonce))
            1)
          (byte_buf.as-bytes (& ticket.ticket))
          2)
        (& ticket.extensions))
      mark
      3)))

;: Decode a KeyUpdate body: `request_update` must be 0 or 1.
(define (decode-key-update [body : (& body bytes)]) : TlsCodeResult
  (let
    [d : TlsDecoder (decoder-new body)]
    [request : i64 (decoder-uint! (&mut d) body 1)]
    (begin
      (decoder-finish! (&mut d))
      (when
        (and
          (not d.failed)
          (!= request key-update-not-requested)
          (!= request key-update-requested))
        (decoder-fail! (&mut d) error-illegal-value alert-illegal-parameter 0))
      (code-result (& d) request))))

;: Append a KeyUpdate message.
(define (encode-key-update [out : byte_buf.ByteBuf] [request : i64]) : byte_buf.ByteBuf
  (push-be (push-be (push-be out handshake-key-update 1) 1 3) request 1))

;: Decode an EndOfEarlyData body, which is empty.
(define (decode-end-of-early-data [body : (& body bytes)]) : TlsWireCheck
  (decode-empty-extension body))

;: Append an EndOfEarlyData message.
(define (encode-end-of-early-data [out : byte_buf.ByteBuf]) : byte_buf.ByteBuf
  (push-be (push-be out handshake-end-of-early-data 1) 0 3))

;; --- alert messages ---------------------------------------------------------------------
;: A decoded alert: its legacy level and its description.
(defstruct TlsAlert
  (level i64)
  (description i64))

;: The result of `decode-alert`.
(defenum TlsAlertResult
  (TlsAlertOk TlsAlert)
  (TlsAlertErr TlsWireError))

;: Decode the content of an alert record: exactly two bytes. Any level and
;: description decode; `alert-fatal?` classifies the description.
(define (decode-alert [content : (& content bytes)]) : TlsAlertResult
  (if (!= (byte_buf.bytes-length content) 2)
    (TlsAlertErr (TlsWireError error-alert-length 0 alert-decode-error))
    (TlsAlertOk (TlsAlert (read-be content 0 1) (read-be content 1 1)))))

;: Append alert content: level, description.
(define (encode-alert
  [out : byte_buf.ByteBuf]
  [level : i64]
  [description : i64]) : byte_buf.ByteBuf
  (push-be (push-be out level 1) description 1))