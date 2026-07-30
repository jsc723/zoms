# Zoms

In progress.

A version-controlled key-value store. This project is essentially a rewrite of [noms](https://github.com/attic-labs/noms) in Zig. It does not aim for compatibility with the original Noms—meaning the data format and type system will differ—but the high-level architecture and structure will remain similar.

Currently, a single-file journal chunk store is mostly finished. The next step is to add some compression to the chunk data, and then I will start to implement the type system and the Prolly Tree.  

## Roadmap
- [x] Hash
- [x] Chunk
- [x] Size Cache
- [x] Chunk Store
- [x] Compression
- [ ] Types
- [ ] Diff
- [ ] Merge
- [ ] Database
- [ ] Spec
- [ ] CLI
