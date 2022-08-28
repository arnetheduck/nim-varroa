import
  chronicles,
  chronos,
  libp2p/[protocols/protocol, stream/connection],
  ./headers,
  protobuf_serialization

logScope:
  topics = "pushsyncs"

const
  pushSyncCodec* = "/swarm/pushsync/1.1.0/pushsync"

type
  PushSyncProto* = ref object of LPProtocol # declare a custom protocol

  DeliveryMsg {.proto3.} = object
    amount {.fieldNumber: 1.}: seq[byte]
    data {.fieldNumber: 2.}: seq[byte]
    stamp {.fieldNumber: 3.}: seq[byte]

  ReceiptMsg {.proto3.} = object
    address {.fieldNumber: 1.}: seq[byte]
    signature {.fieldNumber: 2, pint.} : int64
    blockHash {.fieldNumber: 3, pint.} : int64

proc send*(p: PushSyncProto, conn: Connection) {.async.} =
  debug "Sending", conn
  block: # Headers
    let headers = await conn.exchangeHeaders(true)
    if headers.len > 0:
      debug "Headers", conn, headers

  await conn.closeWithEOF()

proc handle(p: PushSyncProto, conn: Connection, proto: string) {.async.} =
  logScope: conn
  debug "Handling", proto
  block: # Headers
    let headers = await conn.exchangeHeaders(false)
    if headers.len > 0:
      debug "Headers", headers

  block:
    let
      bytes = await conn.readLp(16*1024)
      delivery = Protobuf.decode(bytes, DeliveryMsg)

    notice "TODO delivery", delivery

  await conn.closeWithEOF()

proc new*(T: typedesc[PushSyncProto]): T =
  # every incoming connections will be in handled in this closure
  let p = T(
    codecs: @[pushSyncCodec])

  p.handler = proc(conn: Connection, proto: string): Future[void] =
    p.handle(conn, proto)

  p
