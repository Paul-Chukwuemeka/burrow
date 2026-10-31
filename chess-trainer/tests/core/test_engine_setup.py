"""Smoke checks for the chess trainer environment (Task 1)."""

import shutil
from pathlib import Path

import chess


def test_starting_position_has_32_pieces():
    """python-chess is installed and can build the starting position."""
    board = chess.Board()
    assert board.fen() == chess.STARTING_FEN
    assert len(board.piece_map()) == 32


def test_stockfish_binary_is_available():
    """Stockfish is either on PATH or vendored under chess-trainer/bin/."""
    trainer_root = Path(__file__).resolve().parents[2]
    vendored = trainer_root / "bin" / "stockfish"

    on_path = shutil.which("stockfish")
    assert on_path is not None or vendored.is_file(), (
        "Stockfish not found on PATH and not vendored at "
        f"{vendored}"
    )
