import
  stew/[byteutils],
  chronicles,
  chronos,
  libp2p/[protocols/protocol, stream/connection],
  ./headers,
  ".."/[types],
  protobuf_serialization

logScope:
  topics = "retrievals"

const
  retrievalCodec* = "/swarm/retrieval/1.2.0/retrieval"

type
  RetrievalProto* = ref object of LPProtocol # declare a custom protocol
    lookupAndSendChunk*: LookupAndSendChunk

  RequestMsg* {.proto3.} = object
    chunk* {.fieldNumber: 1.}: seq[byte]

  DeliveryMsg* {.proto3.} = object
    data* {.fieldNumber: 1.}: seq[byte]
    stamp* {.fieldNumber: 2.}: seq[byte]

proc send*(
    p: RetrievalProto, conn: Connection, chunkAddr: SwarmAddress):
    Future[Chunk] {.async.} =
  debug "Sending", conn, chunkAddr
  block: # Headers
    let headers = await conn.exchangeHeaders(true)
    debug "Headers", headers

  block: # Request
    debug "Sending request", conn, chunkAddr
    let req = RequestMsg(chunk: @(chunkAddr.data))
    await conn.writeLp(Protobuf.encode(req))

  let delivery = block:
    let bytes = await conn.readLp(16 * 1024)
    Protobuf.decode(bytes, DeliveryMsg)

  debug "Got delivery",
    conn, chunkAddr, data = delivery.data.len(),
    stamp = byteutils.toHex(delivery.stamp)

  await conn.closeWithEOF()

  return Chunk(data: delivery.data, stamp: delivery.stamp)

proc handle(p: RetrievalProto, conn: Connection, proto: string, peer: ref Peer) {.async.} =
  logScope: conn
  debug "Handling", proto
  block: # Headers
    let headers = await conn.exchangeHeaders(false)
    if headers.len > 0:
      debug "Headers", headers

  proc respond(chunk: Chunk): Future[void] {.async.} =
    let
      resp = DeliveryMsg(
        data: chunk.data,
        stamp: chunk.stamp
      )
    await conn.writeLp(Protobuf.encode(resp))

  try:
    let
      bytes = await conn.readLp(1024)
      req = Protobuf.decode(bytes, RequestMsg)

      refs = SwarmAddress.init(req.chunk).valueOr:
        debug "Invalid retrieval request", refs = byteutils.toHex(req.chunk)
        return
    await p.lookupAndSendChunk(peer, refs, respond)
  except CatchableError as exc:
    debug "Cannot respond", error = exc.msg

  await conn.closeWithEOF()

proc new*(T: typedesc[RetrievalProto], lookupPeer: LookupPeer): T =
  # every incoming connections will be in handled in this closure
  let p = T(
    codecs: @[retrievalCodec])

  p.handler = proc(conn: Connection, proto: string): Future[void] {.raises: [], gcsafe.} =
    let peer = lookupPeer(conn.peerId)
    if peer == nil:
      debug "Unkown peer", peerId = conn.peerId
      return

    p.handle(conn, proto, peer)

  p
