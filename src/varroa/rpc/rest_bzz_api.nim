# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[sequtils],
  stew/results,
  chronicles,
  libp2p/[multiaddress, multicodec, peerstore],
  libp2p/protocols/pubsub/pubsubpeer

logScope: topics = "bzzapi"

type
  RestPeerInfo* = object
    peerId*: string
    addrs*: seq[string]
    protocols*: seq[string]
    protoVersion*: string
    agentVersion*: string

  RestPeerInfoTuple* = tuple
    peerId: string
    addrs: seq[string]
    protocols: seq[string]
    protoVersion: string
    agentVersion: string

  RestSimplePeer* = object
    info*: RestPeerInfo
    connectionState*: string
    score*: int

  RestFutureInfo* = object
    id*: string
    child_id*: string
    procname*: string
    filename*: string
    line*: int
    state*: string

  RestPubSubPeer* = object
    peerId*: PeerId
    score*: float64
    iWantBudget*: int
    iHaveBudget*: int
    outbound*: bool
    appScore*: float64
    behaviourPenalty*: float64
    sendConnAvail*: bool
    closed*: bool
    atEof*: bool
    address*: string
    backoff*: string
    agent*: string

  RestPeerStats* = object
    peerId*: PeerId
    null*: bool
    connected*: bool
    expire*: string
    score*: float64

  RestPeerStatus* = object
    peerId*: PeerId
    connected*: bool

proc toInfo(node: BeaconNode, peerId: PeerId): RestPeerInfo =
  RestPeerInfo(
    peerId: $peerId,
    addrs: node.network.switch.peerStore[AddressBook][peerId].mapIt($it),
    protocols: node.network.switch.peerStore[ProtoBook][peerId],
    protoVersion: node.network.switch.peerStore[ProtoVersionBook][peerId],
    agentVersion: node.network.switch.peerStore[AgentBook][peerId]
  )

proc toNode(v: PubSubPeer, backoff: Moment): RestPubSubPeer =
  RestPubSubPeer(
    peerId: v.peerId,
    score: v.score,
    iWantBudget: v.iWantBudget,
    iHaveBudget: v.iHaveBudget,
    outbound: v.outbound,
    appScore: v.appScore,
    behaviourPenalty: v.behaviourPenalty,
    sendConnAvail: v.sendConn != nil,
    closed: v.sendConn != nil and v.sendConn.closed,
    atEof: v.sendConn != nil and v.sendConn.atEof,
    address:
      if v.address.isSome():
        $v.address.get()
      else:
        "<no address>",
    backoff: $(backoff - Moment.now()),
    agent:
      when defined(libp2p_agents_metrics):
        v.shortAgent
      else:
        "unknown"
  )

