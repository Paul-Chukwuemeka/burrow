"""Smoke checks for the chess trainer environment (Task 1)."""

import os
import shutil
import subprocess
from pathlib import Path

import chess


def test_starting_position_has_32_pieces():
    """python-chess is installed and can build the starting position."""
    board = chess.Board()
    assert board.fen() == chess.STARTING_FEN
    assert len(board.piece_map()) == 32


def test_stockfish_binary_is_available():
    """Stockfish is on PATH or vendored, is executable, and speaks UCI."""
    trainer_root = Path(__file__).resolve().parents[2]
    vendored = trainer_root / "bin" / "stockfish"

    candidates = [p for p in (shutil.which("stockfish"), str(vendored)) if p]
    binary = next((p for p in candidates if os.access(p, os.X_OK)), None)
    assert binary is not None, (
        "No executable Stockfish found on PATH or at "
        f"{vendored} (install stockfish or see chess-trainer/bin/README.md)"
    )

    handshake = subprocess.run(
        [binary],
        input="uci\nquit\n",
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert handshake.returncode == 0, handshake.stderr
    id_lines = [
        line for line in handshake.stdout.splitlines() if line.startswith("id name ")
    ]
    assert id_lines, f"Stockfish UCI handshake returned no 'id name' line: {handshake.stdout!r}"
    assert "Stockfish" in id_lines[0]
