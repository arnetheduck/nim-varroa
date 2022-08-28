# Varroa

`varroa` is an experimental [Nim](https://nim-lang.org/) library for accessing data on the [Swarm](https://www.ethswarm.org/) network using its native libp2p protocols.

The library is the outcome of a weekend experiment meaning it's incomplete, poorly maintained and likely out of date (swarm keeps breaking the protocol), but could be used for further experimentation and tests - patches welcome!

At the time of writing, the library was able to:

* maintain connections with other swarm nodes
* request, cache and serve chunks
* interpret manifests and download files
* expose a simple REST API to access the above functionality

Of course, being a weekend project, the library cuts a few corners:

* no accounting / incentives maintenance whatsoever - we leech from the fee tier that swarm nodes offer
* no database - chunks are stored in files and that's it
* most functionality that upstream bee client missing
* out of date (stop breaking that protocol!)

On the bright side, the code showcases how simple it is to write a Nim [libp2p](https://github.com/status-im/nim-libp2p) application that talks to a [web3](https://github.com/status-im/nim-web3/pulls) API and exposes a [REST server](https://github.com/status-im/nim-presto/) to serve swarm data.

The code shows much similarity with the upstream [bee client](https://github.com/ethersphere/bee) - the implementation was more or less reverse engineered from there (no protocol spec available at the time of writing the code).

To get an introduction to the concepts of swarm, I'd recommend [The book of Swarm](https://www.ethswarm.org/The-Book-of-Swarm.pdf).

## Development

To get started with the library, download and install the latest pre-release version of [nimble](https://github.com/nim-lang/nimble/releases/tag/latest).

```sh
# Download and extract `nimble` to current folder
curl -L https://github.com/nim-lang/nimble/releases/download/latest/nimble-linux_x64.tar.gz | tar xz

# Make nimble available in the PATH of the current shell
export PATH=$PWD:$PATH

# Clone the git repository
git clone https://github.com/arnetheduck/varroa.git

cd varroa
```

With `nimble` in your `PATH`, after cloning the repo:

```sh
# Install a local copy of `nim`
nimble install -l -y nim@1.6.14

# Setup all dependencies - skip this step if you go for the `develop` mode below
nimble setup -l
```

This above commands will install `nim` and all project dependencies in the `nimbledeps` folder.

Alternatively, to enable full development mode which instead clones all dependencies with `git` into `vendor`, run:

```sh
# Install all dependencies in the vendor folder.
./develop.sh
```

## Build and run

Once you have the dependencies set up, you can build the project with:

```sh
nimble build

bin/varroa
```

## Thanks

The hackers and dreamers of swarm remind me that there is still hope for cyberspace...
