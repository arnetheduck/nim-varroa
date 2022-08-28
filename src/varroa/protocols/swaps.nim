import
  stew/[byteutils],
  chronicles,
  chronos,
  libp2p/[protocols/protocol, stream/connection],
  eth/keys,
  ../types,
  ./headers,
  protobuf_serialization

logScope:
  topics = "swaps"

const
  swapCodec* = "/swarm/swap/1.0.0/swap"

type
  SwapProto* = ref object of LPProtocol # declare a custom protocol

  EmitChequeMsg {.proto3.} = object
    cheque {.fieldNumber: 1.}: seq[byte]

  HandshakeMsg {.proto3.} = object
    beneficiary {.fieldNumber: 1.}: seq[byte]

proc send*(p: SwapProto, conn: Connection) {.async.} =
  block: # Headers
    let headers = await conn.exchangeHeaders(true)
    if headers.len > 0:
      debug "Headers", conn, headers

  await conn.closeWithEOF()

proc handle(p: SwapProto, conn: Connection, proto: string) {.async.} =
  logScope: conn
  debug "Handling", proto
  block: # Headers
    let headers = await conn.exchangeHeaders(false)
    if headers.len > 0:
      debug "Headers", headers

  block: # EmitCheque
    let
      bytes = await conn.readLp(16 * 1024)
      msg = Protobuf.decode(bytes, EmitChequeMsg)
    debug "Got cheque emit", msg = byteutils.toHex(msg.cheque)

  await conn.closeWithEOF()

proc new*(
    T: typedesc[SwapProto]): T =
  # every incoming connections will be in handled in this closure
  let p = T(
    codecs: @[swapCodec])

  p.handler = proc(conn: Connection, proto: string): Future[void] =
    p.handle(conn, proto)

  p
