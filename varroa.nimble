# Package

version       = "0.1.0"
author        = "Jacek Sieka"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["varroa"]


# Dependencies

requires "nim ~= 1.6.14",
   "libp2p",
   "protobuf_serialization",
   "presto",
   "eth",
   "json_rpc",
   "web3"
