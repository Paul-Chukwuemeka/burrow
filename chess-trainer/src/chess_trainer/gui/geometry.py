"""Pure board geometry: square <-> pixel mapping.

This module deliberately imports nothing from Qt so the mapping can be unit
tested headlessly (no display, no PyQt6).  Squares are python-chess square
indices (0 = a1 .. 63 = h8); pixels are measured from the top-left of the
board, one square edge long.
"""

from __future__ import annotations

import chess

BOARD_SIZE = 8


def square_to_xy(
    square: int, square_size: int, *, white_bottom: bool = True
) -> tuple[int, int]:
    """Top-left pixel of ``square`` for a board ``square_size`` px wide.

    With ``white_bottom`` (the default) rank 8 is drawn at the top and rank 1
    at the bottom, so a1 (file 0, rank 0) maps to the bottom-left corner.
    """
    file = chess.square_file(square)
    rank = chess.square_rank(square)
    x = file * square_size
    y = (BOARD_SIZE - 1 - rank) * square_size if white_bottom else rank * square_size
    return x, y


def xy_to_square(
    x: int, y: int, square_size: int, *, white_bottom: bool = True
) -> int | None:
    """The square under pixel ``(x, y)``, or ``None`` when off the board.

    The inverse of :func:`square_to_xy`, including its orientation handling.
    """
    file = x // square_size
    rank = y // square_size
    if not (0 <= file < BOARD_SIZE and 0 <= rank < BOARD_SIZE):
        return None
    rank = (BOARD_SIZE - 1 - rank) if white_bottom else rank
    return chess.square(file, rank)
