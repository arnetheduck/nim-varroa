import
  std/[json, tables],
  stew/[arrayops, byteutils, endians2, objects],
  ./types

{.push raises: [].}

const
  nodeTypeValue             = uint8(2)
  nodeTypeEdge              = uint8(4)
  nodeTypeWithPathSeparator = uint8(8)
  nodeTypeWithMetadata      = uint8(16)
  rootPath* = "/"
  WebsiteIndexDocumentSuffixKey* = "website-index-document"
  EntryMetadataContentTypeKey*   = "Content-Type"
  EntryMetadataFilenameKey*      = "Filename"

  version02Hash = hexToByteArray[31]("5768b3b6a7db56d21d1abff40d41cebfc83448fed8d7e9b06ec0d3b073f28f7b")

type
  NodeRef* = ref object
    nodeType*: uint8
    obfuscationKey*: array[32, byte]
    refs*: SwarmAddress
    entry*: SwarmAddress
    metadata*: Table[string, string]
    forks*: Table[char, Fork]
    loaded*: bool

  Fork* = object
    prefix*: string
    node*: NodeRef

proc common(a, b: openArray[char]): int =
  var i = 0
  while i < a.len and i < b.len and a[i] == b[i]:
    i += 1
  i

proc lookupNode*(n: NodeRef, path: openArray[char]): NodeRef =
  if path.len == 0:
    return n

  if path[0] in n.forks:
    let fork = try: n.forks[path[0]] except KeyError: raiseAssert ""
    let c = common(fork.prefix, path)
    if c == len(fork.prefix):
      return fork.node.lookupNode(path.toOpenArray(c, path.high()))

proc lookupMetadata*(n: NodeRef, path: string, metadataKey: string): string =
  let metaNode = n.lookupNode(path)
  if metaNode == nil:
    ""
  else:
    metaNode.metadata.getOrDefault(metadataKey, "")

proc lookupEntry*(n: NodeRef, path: string): NodeRef =
  let tmp = n.lookupNode(path)
  if ((tmp.nodeType and nodeTypeValue) == 0) and (path.len > 0):
    nil
  else:
    tmp

template checkBytes(data, pos, needed) =
  if pos + needed > data.len:
    return err("not enough data")

proc readMantaray*(n: NodeRef, data: openArray[byte]): Result[void, cstring] =
  var
    pos: int

  checkBytes(data, pos, 8)
  let size = uint64.fromBytesLE(data)
  pos += 8

  checkBytes(data, pos, 32)
  n.obfuscationKey[0..31] = data.toOpenArray(pos, pos + 32 - 1)

  var bytes = newSeqUninitialized[byte](data.len - 8 - 32)

  for i in 0..<bytes.len:
    bytes[i] = data[i + 8 + 32] xor n.obfuscationKey[i mod n.obfuscationKey.len]

  pos = 0

  checkBytes(bytes, pos, 32)
  let version = toArray(31, bytes.toOpenArray(pos, pos + 31 - 1))
  pos += 31

  if version != version02Hash:
    debugEcho "not hash ", toHex(version)
    return

  let refsize = int(bytes[pos])
  pos += 1

  if refsize != sizeof(SwarmAddress):
    return err("Unsupported reference size")

  checkBytes(bytes, pos, refsize)
  n.entry = SwarmAddress.init(bytes.toOpenArray(pos, pos + refsize - 1)).expect("checked")
  pos += refsize

  checkBytes(bytes, pos, 32)
  let index = toArray(32, bytes.toOpenArray(pos, pos + 32 - 1))
  pos += 32

  for i in 0..255:
    if ((index[i div 8] shr (i mod 8)) and 1'u8) > 0:
      n.nodeType = n.nodeType or nodeTypeEdge
      checkBytes(bytes, pos, 32 + refsize)
      let
        nodeType = bytes[pos]
        prefixLen = int(bytes[pos + 1])
      # TODO deal with long prefixes
      var fork = Fork(
        prefix: string.fromBytes(bytes[pos + 2..pos + 2 + prefixLen - 1]),
        node: NodeRef(
          nodeType: nodeType,
          refs: SwarmAddress.init(bytes.toOpenArray(pos + 32, pos + 32 + refsize - 1)).expect("checked")
        ))

      pos += 32 + refsize

      # TODO length checks
      if (nodeType and nodeTypeWithMetadata) == nodeTypeWithMetadata:
        let metaLen =
          int(uint16.fromBytesBE(bytes.toOpenArray(pos, pos + 2 - 1)))
        pos += 2

        if metaLen > 0:
          let meta =
            try: parseJson(string.fromBytes(bytes.toOpenArray(pos, pos + metaLen - 1)))
            except Exception: JsonNode()
          pos += metaLen

          if meta.kind == JObject:
            for key, value in meta:
              fork.node[].metadata[key] = value.getStr()

      n.forks[char(i)] = fork
  n.loaded = true
  ok()

iterator walk*(n: NodeRef): (string, NodeRef) =
  var stack: seq[(string, NodeRef)]
  stack.add(("", n))
  while stack.len > 0:
    let x = stack.pop()
    yield x

    for _, v in x[1].forks:
      stack.add((v.prefix, v.node))

when isMainModule:
  import os

  let node = NodeRef(refs: SwarmAddress.fromHex("031b7294e90af0bc67778ef1eb9444d681a29383a16b346e21b5b0675924fefc"))

  for prefix, n in node.walk:
    if n.loaded: continue
    let name = "/data/varroa/chunks/" & $n.refs
    if fileExists(name):
      let data = readFile(name).toBytes()
      readMantaray(n, data).expect("Worked")
      debugEcho "prefix: ", prefix, " node: ", n.refs, " entry ", n.entry

    else:
      debugEcho "want ", $n.refs

  let idx = node.lookupMetadata(rootPath, WebsiteIndexDocumentSuffixKey)

  debugEcho idx
  debugEcho $node.lookupEntry(idx)[].entry
