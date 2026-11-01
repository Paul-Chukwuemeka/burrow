"""Thin wrapper around Stockfish.

All scores exposed by this module are from the perspective of the player whose
turn it is in the position being analysed (the "mover").  Engine scores are
normalised so the rest of the app never needs to reason about raw centipawn
values:

* centipawn scores are clipped to ``[-MATE_SCORE, +MATE_SCORE]``;
* forced mates become ``+/- (MATE_SCORE - 10 * |mate|)``, so "mate in 1" is
  ``990`` and a lost-but-not-mated position can never read as ``-32767``.

Stockfish itself is resolved in this order: an explicit ``path`` argument, then
``stockfish`` on ``PATH``, then the vendored ``chess-trainer/bin/stockfish``.
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Self

import chess
import chess.engine

#: Score assigned to a position that is already mate; mate-in-N scores sit
#: just below it at ``MATE_SCORE - 10 * N``.
MATE_SCORE = 1000

#: Default search depth for every public method.
DEFAULT_DEPTH = 12

#: Number of principal variations requested from the engine.
MULTIPV = 3

_STOCKFISH_ENV_HINT = (
    "Install Stockfish and put it on PATH, pass an explicit path to Engine(), "
    "or see chess-trainer/bin/README.md for the vendored binary."
)


def _clip_cp(cp: int) -> int:
    """Clip a centipawn score to the legal evaluation range."""
    return max(-MATE_SCORE, min(MATE_SCORE, cp))


def _mate_cp(mate: int) -> int:
    """Normalise a mate distance to a clipped centipawn score.

    Positive ``mate`` means the mover delivers mate, negative means the mover
    is mated.  ``mate == 0`` (already mated) maps to ``-MATE_SCORE``.
    """
    if mate == 0:
        return -MATE_SCORE
    return (MATE_SCORE - 10 * abs(mate)) * (1 if mate > 0 else -1)


def _score_pair(score: chess.engine.PovScore, color: chess.Color) -> tuple[int, int | None]:
    """Return ``(cp, mate)`` for ``color``, clipped/normalised per module rules."""
    pov = score.pov(color)
    mate = pov.mate()
    if mate is not None:
        return _mate_cp(mate), mate
    return _clip_cp(pov.score() or 0), None


def _find_stockfish(path: str | None = None) -> str:
    """Resolve the Stockfish executable (argument, PATH, vendored binary)."""
    if path is not None:
        candidate = Path(path)
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
        raise FileNotFoundError(
            f"Stockfish executable not found or not executable at {path!r}. "
            f"{_STOCKFISH_ENV_HINT}"
        )

    found = shutil.which("stockfish")
    if found:
        return found

    # engine.py lives at chess-trainer/src/chess_trainer/engine.py, so the
    # trainer root (which owns bin/stockfish) is three levels up.
    vendored = Path(__file__).resolve().parents[2] / "bin" / "stockfish"
    if vendored.is_file() and os.access(vendored, os.X_OK):
        return str(vendored)

    raise FileNotFoundError(f"No Stockfish found. {_STOCKFISH_ENV_HINT}")


@dataclass
class EngineMove:
    """A single engine choice.

    ``cp`` and ``mate`` are from the perspective of the side to move.  For mate
    lines ``cp`` is the normalised score and ``mate`` keeps the raw distance
    (positive = the mover mates, negative = the mover is mated).
    """

    uci: str
    cp: int | None
    mate: int | None


@dataclass
class MoveAnalysis:
    """Evaluation of a played move against the engine's best move.

    All scores are from the player's (mover's) perspective.  ``mate_against``
    is true when the played move allows the opponent a forced mate.
    """

    played_uci: str
    best_uci: str
    played_cp: int
    best_cp: int
    mate_against: bool

    @property
    def loss_cp(self) -> int:
        """How much the played move gave up, clamped to be non-negative."""
        return max(0, self.best_cp - self.played_cp)


class Engine:
    """A Stockfish process bound to one position at a time."""

    def __init__(self, path: str | None = None) -> None:
        self.path = _find_stockfish(path)
        self._engine = chess.engine.SimpleEngine.popen_uci(self.path)
        self._closed = False

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def close(self) -> None:
        """Shut the engine down; safe to call more than once."""
        if not self._closed:
            self._closed = True
            self._engine.quit()

    def top_moves(self, fen: str, depth: int = DEFAULT_DEPTH) -> list[EngineMove]:
        """Return up to three best moves for ``fen``, best first.

        Mate scores are normalised to ``+/- (MATE_SCORE - 10 * |mate|)`` and
        centipawn scores are clipped to ``+/- MATE_SCORE``.
        """
        board = _board(fen)
        if board.is_game_over():
            return []

        infos = self._engine.analyse(
            board, chess.engine.Limit(depth=depth), multipv=MULTIPV
        )
        moves: list[EngineMove] = []
        for info in infos:
            pv = info.get("pv") or []
            if not pv:
                continue
            cp, mate = _score_pair(info["score"], board.turn)
            moves.append(EngineMove(uci=pv[0].uci(), cp=cp, mate=mate))

        moves.sort(
            key=lambda move: move.cp if move.cp is not None else -MATE_SCORE,
            reverse=True,
        )
        return moves

    def best(self, fen: str, depth: int = DEFAULT_DEPTH) -> EngineMove:
        """Return the engine's first choice for ``fen``."""
        moves = self.top_moves(fen, depth)
        if not moves:
            raise ValueError(f"no legal moves in position: {fen!r}")
        return moves[0]

    def analyse(
        self,
        fen_before: str,
        played_uci: str,
        depth: int = DEFAULT_DEPTH,
    ) -> MoveAnalysis:
        """Compare ``played_uci`` with the engine's top choice in ``fen_before``.

        ``played_cp`` is the evaluation after the played move, ``best_cp`` the
        evaluation of the engine's preferred move, both from the player's
        perspective and clipped/normalised like :meth:`top_moves`.
        """
        board = _board(fen_before)
        try:
            move = board.parse_uci(played_uci)
        except ValueError as exc:  # chess.InvalidMoveError is a ValueError
            raise ValueError(
                f"invalid move {played_uci!r} for FEN {fen_before!r}"
            ) from exc
        if move not in board.legal_moves:
            raise ValueError(f"illegal move {played_uci!r} for FEN {fen_before!r}")

        best_move = self.best(fen_before, depth)

        board_after = board.copy()
        board_after.push(move)

        if board_after.is_checkmate():
            played_cp: int = MATE_SCORE
            mate_against = False
        elif board_after.is_game_over():
            played_cp = 0
            mate_against = False
        else:
            info = self._engine.analyse(
                board_after, chess.engine.Limit(depth=depth)
            )
            # The side to move after the played move is the opponent, so negate.
            opponent_cp, opponent_mate = _score_pair(info["score"], board_after.turn)
            if opponent_mate is not None:
                player_mate = -opponent_mate
                played_cp = _mate_cp(player_mate)
                mate_against = player_mate < 0
            else:
                played_cp = _clip_cp(-opponent_cp)
                mate_against = False

        best_cp = best_move.cp if best_move.cp is not None else 0
        return MoveAnalysis(
            played_uci=move.uci(),
            best_uci=best_move.uci,
            played_cp=played_cp,
            best_cp=best_cp,
            mate_against=mate_against,
        )


def _board(fen: str) -> chess.Board:
    """Build a board, converting python-chess's FEN errors into ValueError."""
    try:
        return chess.Board(fen)
    except ValueError as exc:
        raise ValueError(f"invalid FEN: {fen!r}") from exc
