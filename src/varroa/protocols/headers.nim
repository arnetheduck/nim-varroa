import
  chronos,
  libp2p/stream/connection,
  protobuf_serialization

type
  HeadersMsg {.proto3.} = object
    headers {.fieldNumber: 1.}: seq[HeaderMsg]

  HeaderMsg {.proto3.} = object
    key {.fieldNumber: 1.}: string
    value {.fieldNumber: 2.}: seq[byte]

proc exchangeHeaders*(conn: Connection, writeFirst: bool): Future[seq[(string, seq[byte])]] {.async.} =
  if writeFirst: await conn.writeLp([]) # Write some empty Headers
  let
    bytes = await conn.readLp(64 * 1024)
    headers = Protobuf.decode(bytes, HeadersMsg)

  if not writeFirst: await conn.writeLp([])

  var res: seq[(string, seq[byte])]
  for header in headers.headers:
    if header.key == "tracing-span-context" and header.value.len == 0:
      continue
    res.add((header.key, header.value))
  return res
