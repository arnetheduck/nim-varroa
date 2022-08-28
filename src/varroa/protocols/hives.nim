import
  stew/[byteutils, endians2],
  chronicles,
  chronos,
  libp2p/[protocols/protocol, stream/connection],
  ./headers,
  ../types,
  protobuf_serialization

logScope:
  topics = "hives"

const
  hiveCodec* = "/swarm/hive/1.0.0/peers"

type
  PeerHandler* = proc(adds: BzzAddress) {.raises: [], gcsafe.}

  HiveProto* = ref object of LPProtocol # declare a custom protocol
    onPeer*: PeerHandler
    overlay: SwarmAddress

  PeersMsg {.proto3.} = object
    peers {.fieldNumber: 1.}: seq[BzzAddressMsg]

  BzzAddressMsg {.proto3.} = object
    underlay {.fieldNumber: 1.}: seq[byte]
    signature {.fieldNumber: 2.} : seq[byte]
    overlay {.fieldNumber: 3.}: seq[byte]
    transaction {.fieldNumber: 4.} : seq[byte]

proc send*(p: HiveProto, conn: Connection) {.async.} =
  logScope: conn
  debug "Sending"
  block: # Headers
    let headers = await conn.exchangeHeaders(true)
    if headers.len > 0:
      debug "Headers", headers

  await conn.writeLp([])
  await conn.closeWithEOF()

proc handle(p: HiveProto, conn: Connection, proto: string) {.async.} =
  logScope: conn
  trace "Handling", proto
  block: # Headers
    let headers = await conn.exchangeHeaders(false)
    if headers.len > 0:
      debug "Headers", headers

  block:
    let
      bytes = await conn.readLp(16*1024)
      peers = Protobuf.decode(bytes, PeersMsg)

    debug "Got peers", msg = peers.peers.len
    for peer in peers.peers:
      let
        underlay = MultiAddress.init(peer.underlay).valueOr:
          debug "Peer with invalid underlay",
            underlay = byteutils.toHex(peer.underlay)
          continue
        overlay = SwarmAddress.init(peer.overlay).valueOr:
          debug "Peer with invalid overlay",
            overlay = byteutils.toHex(peer.overlay)
          continue
      debug "Peer",
        underlay = underlay,
        overlay = overlay,
        proximity = proximity(p.overlay.data, overlay.data),
        transaction = byteutils.toHex(peer.transaction)
      p.onPeer(BzzAddress(overlay: overlay, underlay: underlay))

  await conn.closeWithEOF()

proc new*(T: typedesc[HiveProto], overlay: SwarmAddress): T =
  # every incoming connections will be in handled in this closure
  let p = T(
    overlay: overlay,
    codecs: @[hiveCodec])

  p.handler = proc(conn: Connection, proto: string): Future[void] =
    p.handle(conn, proto)

  p
