# Chess Trainer

A small desktop chess trainer. Play against a Stockfish opponent tuned to your
level, get plain-language coaching as you move, then review what went wrong and
watch your blunder rate change over time.

## Setup

PyQt6 and `python-chess` are already installed here. The Stockfish binary is
vendored at `bin/stockfish` (git-ignored, present locally); if it is missing,
install Stockfish ≥ 15 on `PATH`, or follow `bin/README.md` to restore the
vendored build.

The real Cburnett SVG piece set is optional. It needs QtSvg:

```sh
sudo apt install python3-pyqt6.qtsvg
```

Without QtSvg the board falls back to Unicode chess glyphs; everything else
works identically.

## Run

From this directory:

```sh
env PYTHONPATH=src python3 -m chess_trainer
```

To add it to the application menu:

```sh
install -Dm644 launcher.desktop ~/.local/share/applications/chess-trainer.desktop
```

`launcher.desktop` holds absolute paths for this machine. If the repository
moves, update its `Exec=` and `Path=` lines (the space in the path is quoted).

## Data location

Everything is local, under `data/` next to this README (git-ignored):

- `data/games/YYYY-MM-DD/<timestamp>-<result>.pgn` — the game
- the matching `<same>.annotations.json` — coach notes and game metadata
- `data/stats.json` — cumulative results and per-game records
- `data/bot.json` — the current bot strength

Delete `data/` to start with a clean history.

## How training works

With **Live coach** on (the default) every game is a **Practice** game: after
each of your moves the coach checks it, and a notable move or blunder pauses
play so you can take it back or keep it. Switch the coach off for a **Clean**
game — no hints while you play, but still fully reviewable afterwards.

When a game ends, review opens automatically. Use the ‹ and › buttons (or the
arrow keys) to step through the saved positions; at each turning point the
window shows the move you played and the coach's saved plain-language reason,
including brief notes on the bot's own slips. The **Stats** button shows
wins/losses/draws split into practice and clean, blunders per game, a simple
one-bar-per-game result trend, and the list of saved games — pick one to reopen
it in review. The bot adjusts its strength from your recent results.
