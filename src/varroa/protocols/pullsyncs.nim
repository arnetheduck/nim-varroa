import
  chronicles,
  chronos,
  libp2p/[protocols/protocol, stream/connection],
  ./headers,
  protobuf_serialization

logScope:
  topics = "pullsyncs"

const
  pullSyncCodec* = "/swarm/pullsync/1.1.0/pullsync"
  pullSyncCursorsCodec* = "/swarm/pullsync/1.1.0/cursors"
  pullSyncCancelCodec* = "/swarm/pullsync/1.1.0/cancel"

type
  PullSyncProto* = ref object of LPProtocol # declare a custom protocol

  SynMsg {.proto3.} = object

  AckMsg {.proto3.} = object
    cursors {.fieldNumber: 1.}: seq[uint64]

  RuidMsg {.proto3.} = object
    ruid {.fieldNumber: 1.}: uint32

  CancelMsg {.proto3.} = object
    ruid {.fieldNumber: 1.}: uint32

  GetRangeMsg {.proto3.} = object
    bin {.fieldNumber: 1, pint.}: int32
    frm {.fieldNumber: 2.}: uint64
    to {.fieldNumber: 3.}: uint64

  OfferMsg {.proto3.} = object
    topmost {.fieldNumber: 1.}: uint64
    hashes {.fieldNumber: 2.}: seq[byte]

  WantMsg {.proto3.} = object
    bitVector {.fieldNumber: 1.}: seq[byte]

  DeliveryMsg {.proto3.} = object
    address {.fieldNumber: 1.}: seq[byte]
    data {.fieldNumber: 1.}: seq[byte]
    stamp {.fieldNumber: 1.}: seq[byte]

proc send*(p: PullSyncProto, conn: Connection) {.async.} =
  debug "Sending", conn
  block: # Headers
    let headers = await conn.exchangeHeaders(true)
    if headers.len > 0:
      debug "Headers", conn, headers

  await conn.closeWithEOF()

proc handle(p: PullSyncProto, conn: Connection, proto: string) {.async.} =
  logScope: conn
  debug "Handling", proto
  block: # Headers
    let headers = await conn.exchangeHeaders(false)
    if headers.len > 0:
      debug "Headers", headers

    # TODO

  await conn.closeWithEOF()

proc new*(T: typedesc[PullSyncProto]): T =
  # every incoming connections will be in handled in this closure
  let p = T(
    codecs: @[pullSyncCodec, pullSyncCursorsCodec, pullSyncCursorsCodec])

  p.handler = proc(conn: Connection, proto: string): Future[void] =
    p.handle(conn, proto)

  p
