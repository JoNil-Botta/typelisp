(defstruct RawChannelMessage
  (ptr (Ptr i64)))

(defstruct ChannelRawMessage
  (token i64))

(defenum ChannelRawMessageSendResult
  (ChannelRawMessageSendOk))

(define (channel-raw-message-send
  [_channel : ChannelRawMessage]
  [_message : RawChannelMessage]) : ChannelRawMessageSendResult
  (ChannelRawMessageSendOk))

(define (main) : i64
  (unsafe
    (let
      [message : RawChannelMessage
        (RawChannelMessage (int->ptr (cast 0 : u64) : (Ptr i64)))]
      (match (channel-raw-message-send (ChannelRawMessage 0) message)
        [(ChannelRawMessageSendOk) 42]))))