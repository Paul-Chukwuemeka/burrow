# Vendored Stockfish binary

The local fallback binary is `bin/stockfish`, Stockfish **19** (Linux x86-64 universal build), from
<https://github.com/official-stockfish/Stockfish/releases/download/sf_19/stockfish-linux-x86-64-universal.tar.gz>.

Reproduce from the repo root:

```sh
mkdir -p ~/.cache/chess-trainer && curl -L -C - -o ~/.cache/chess-trainer/sf.tar.gz https://github.com/official-stockfish/Stockfish/releases/download/sf_19/stockfish-linux-x86-64-universal.tar.gz && tar xzf ~/.cache/chess-trainer/sf.tar.gz -C ~/.cache/chess-trainer stockfish/stockfish-linux-x86-64-universal && install -m 755 ~/.cache/chess-trainer/stockfish/stockfish-linux-x86-64-universal chess-trainer/bin/stockfish
```

Alternatively install Stockfish >= 15 from your package manager so it is on `PATH`; the test accepts either.
