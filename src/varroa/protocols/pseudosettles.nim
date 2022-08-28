import
  std/times,
  chronicles,
  chronos,
  stint,
  libp2p/[protocols/protocol, stream/connection],
  ./headers,
  protobuf_serialization,
  ../types

logScope:
  topics = "pseudosettles"

const
  pseudoSettleCodec* = "/swarm/pseudosettle/1.0.0/pseudosettle"

type
  PseudoSettleProto* = ref object of LPProtocol # declare a custom protocol

  PaymentMsg {.proto3.} = object
    amount {.fieldNumber: 1.}: seq[byte]

  PaymentAckMsg {.proto3.} = object
    amount {.fieldNumber: 1.}: seq[byte]
    timestamp {.fieldNumber: 2, pint.} : int64

proc peerAllowance(peer: var Peer, fullNode: bool): Opt[(Int256, int64)] =
  let
    currentTime = getTime().toUnix()

  if currentTime - peer.pseudoSettle.timestamp < 1:
    return Opt.none((Int256, int64))

  let
    refreshRateUsed = if fullnode: refreshRate else: lightRefreshRate
    maxAllowance = i256(currentTime - peer.pseudoSettle.timestamp) * refreshRateUsed
    debt = peer.debt()

  if debt >= maxAllowance:
    ok((maxAllowance, currentTime))
  else:
    ok((debt, currentTime))

proc send*(p: PseudoSettleProto, conn: Connection) {.async.} =
  debug "Sending", conn
  block: # Headers
    let headers = await conn.exchangeHeaders(true)
    debug "Headers", headers

  await conn.closeWithEOF()

proc handle(
    p: PseudoSettleProto, conn: Connection, proto: string, peer: ref Peer) {.async.} =
  logScope: conn
  debug "Handling", proto
  block: # Headers
    let headers = await conn.exchangeHeaders(false)
    if headers.len > 0:
      debug "Headers", headers

  block:
    let
      bytes = await conn.readLp(16*1024)
      req = Protobuf.decode(bytes, PaymentMsg)
      attemptedAmount = max(i256(0), stint(UInt256.fromBytesBE(req.amount), 256))
      (allowance, timestamp) = peer[].peerAllowance(false).tryGet()
      paymentAmount =
        if allowance < attemptedAmount: allowance else: attemptedAmount

    await conn.writeLp(Protobuf.encode(
      PaymentAckMsg(
        amount: @(stuint(paymentAmount, 256).toBytesBE()),
        timestamp: timestamp)))

    peer.pseudoSettle.total += paymentAmount
    peer.pseudoSettle.timestamp = timestamp

  await conn.closeWithEOF()

proc new*(T: typedesc[PseudoSettleProto], lookupPeer: LookupPeer): T =
  # every incoming connections will be in handled in this closure
  let p = T(
    codecs: @[pseudoSettleCodec])

  p.handler = proc(conn: Connection, proto: string): Future[void] =
    let peer = lookupPeer(conn.peerId)
    if peer == nil:
      debug "Unkown peer", peerId = conn.peerId
      return

    p.handle(conn, proto, peer)

  p
