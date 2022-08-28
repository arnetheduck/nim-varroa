import
  chronicles,
  chronos,
  libp2p/[protocols/protocol, stream/connection],
  ./headers

logScope:
  topics = "pingpongs"

const
  pingpongCodec* = "/swarm/pingpong/1.0.0/pingpong"

type
  PingpongProto* = ref object of LPProtocol # declare a custom protocol

proc send*(p: PingpongProto, conn: Connection, messages: openArray[string]) {.async.} =
  debug "Sending", conn, messages = messages.len()
  block: # Headers
    let headers = await conn.exchangeHeaders(true)
    if headers.len > 0:
      debug "Headers", conn, headers

  for msg in messages:
    block: # Send ping
      var ping = initProtoBuffer()
      ping.write(1, msg)
      ping.finish()
      await conn.writeLp(ping.buffer)
    block: # Read pong
      let bytes = await conn.readLp(64 * 1024)
      trace "Got pong", bytes = len(bytes)

  await conn.closeWithEOF()

proc handle(p: PingpongProto, conn: Connection, proto: string) {.async.} =
  logScope: conn
  trace "Handling", proto
  block: # Headers
    let headers = await conn.exchangeHeaders(false)
    if headers.len > 0:
      debug "Headers", headers

  while true:
    try:
      let bytes = await conn.readLp(64 * 1024)
      trace "Got ping", bytes = len(bytes)
      await conn.writeLp(bytes)
    except LPStreamEOFError:
      break

proc new*(T: typedesc[PingpongProto]): T =
  # every incoming connections will be in handled in this closure

  let p = T(codecs: @[pingpongCodec])

  p.handler = proc(conn: Connection, proto: string): Future[void] =
    p.handle(conn, proto)

  p
