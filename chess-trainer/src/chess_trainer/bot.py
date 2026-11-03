"""The sparring opponent: Stockfish, deliberately weakened to human level.

Stockfish's own strength floor is roughly 1320 Elo, well above the ~570 the
first user plays at, so this module weakens it in two layers:

1. **Skill-limited search.**  The engine's Skill Level is set to
   ``int(strength)`` for one 0.3 s search through
   :meth:`Engine.set_skill <chess_trainer.engine.Engine.set_skill>` and
   :meth:`Engine.play <chess_trainer.engine.Engine.play>`.  Even at high skill
   this already misses some tactics; the option is restored to full strength
   afterwards so the coach can share the same Engine.
2. **A humanlike error model.**  With probability :func:`weak_prob` the move
   from layer 1 is replaced by one of the engine's top three moves, restricted
   to choices that give up at most :func:`slack` centipawns against the best
   move and weighted towards the weaker evaluations in that set.  This is what
   makes the bot hang material and drift the way a beginner does, instead of
   playing random nonsense.

The result is always a legal move for the board it was given.
"""

from __future__ import annotations

import random
from typing import TYPE_CHECKING

import chess

if TYPE_CHECKING:  # pragma: no cover - typing only
    from chess_trainer.engine import Engine

#: Stockfish's Skill Level range.
MIN_SKILL = 0
MAX_SKILL = 20

#: Time budget for the skill-limited search behind the bot's base move.
MOVE_TIME = 0.3

#: Error-layer probability at strength 0 (weakest) and strength 20 (strongest).
MAX_WEAK_PROB = 0.85
MIN_WEAK_PROB = 0.15

#: Slack above the best move's evaluation at strength 20, in centipawns.
SLACK_BASE = 40

#: Extra slack added per skill point lost, in centipawns.
SLACK_PER_STRENGTH = 8


def _clamp_strength(strength: float) -> float:
    """Clamp the 0-20 strength dial to its supported range."""
    return max(float(MIN_SKILL), min(float(MAX_SKILL), float(strength)))


def weak_prob(strength: float) -> float:
    """Probability that the humanlike error layer overrides the base move.

    Rises linearly from ~0.15 at strength 20 to ~0.85 at strength 0.
    """
    clamped = _clamp_strength(strength)
    span = MAX_WEAK_PROB - MIN_WEAK_PROB
    return MAX_WEAK_PROB - span * clamped / MAX_SKILL


def slack(strength: float) -> int:
    """How many centipawns the error layer may give up: ``40 + 8*(20-s)``."""
    clamped = _clamp_strength(strength)
    return round(SLACK_BASE + SLACK_PER_STRENGTH * (MAX_SKILL - clamped))


class Bot:
    """A Stockfish opponent tuned down to a believable human strength."""

    def __init__(self, engine: Engine) -> None:
        self.engine = engine
        #: Used when ``choose_move`` is called without an explicit seed.  It is
        #: seeded so a fresh Bot replays the same error sequence; Stockfish's
        #: own skill-level randomness is outside our control.
        self._rng = random.Random(0)

    @staticmethod
    def estimate_elo(strength: float) -> int:
        """Approximate human rating for the strength dial.

        ``round(450 + 105 * strength)`` is a rough calibration for display
        ("Bot ≈ N"), not a measured rating; ``strength`` is expected in 0-20.
        """
        return round(450 + 105 * strength)

    def choose_move(
        self, board: chess.Board, strength: float, seed: int | None = None
    ) -> str:
        """Return a legal UCI move for ``board``, weakened by ``strength``.

        ``strength`` runs from 0 (weakest) to 20 (near-best).  Passing ``seed``
        makes the error layer reproducible, which tests rely on.
        """
        if board.is_game_over():
            raise ValueError(
                f"no legal move: the game is over ({board.result()}) in "
                f"position {board.fen()!r}"
            )
        legal = sorted(board.legal_moves, key=lambda move: move.uci())
        if not legal:  # pragma: no cover - game-over check covers this
            raise ValueError(f"no legal moves in position: {board.fen()!r}")

        rng = random.Random(seed) if seed is not None else self._rng

        best_effort = self._base_move(board, strength)
        if rng.random() < weak_prob(strength):
            weaker = self._weak_move(board, strength, rng)
            if weaker is not None:
                best_effort = weaker

        if best_effort is not None and best_effort in board.legal_moves:
            return best_effort.uci()
        # Safety net: never hand back an illegal move, even if the engine or a
        # lookalike misbehaves.
        return rng.choice(legal).uci()

    def _base_move(self, board: chess.Board, strength: float) -> chess.Move | None:
        """The skill-limited search's move, with Skill Level restored after."""
        skill = max(MIN_SKILL, min(MAX_SKILL, int(strength)))
        try:
            self.engine.set_skill(skill)
            uci = self.engine.play(board, MOVE_TIME)
        finally:
            # The coach analyses through the same Engine; leaving it crippled
            # would quietly degrade every post-game review.
            self.engine.set_skill(MAX_SKILL)
        try:
            return chess.Move.from_uci(uci)
        except ValueError:  # pragma: no cover - engine emits valid UCI
            return None

    def _weak_move(
        self, board: chess.Board, strength: float, rng: random.Random
    ) -> chess.Move | None:
        """Pick a deliberately worse (but still plausible) move, or ``None``.

        Candidates are the engine's top moves that are legal here, stay within
        :func:`slack` of the best evaluation, and are not underpromotions.
        Underpromotions are left to the engine itself so any non-queen
        promotion comes with a real reason behind it.  Weights grow with the
        centipawn deficit, so the weakest acceptable move is the likeliest.
        """
        moves = self.engine.top_moves(board.fen())
        if not moves:
            return None

        scored = [(move, move.cp) for move in moves if move.cp is not None]
        if not scored:
            return None
        best_cp = max(cp for _, cp in scored)
        limit = slack(strength)

        candidates: list[tuple[chess.Move, int]] = []
        for move, cp in scored:
            deficit = max(0, best_cp - cp)
            if deficit > limit:
                continue
            try:
                parsed = chess.Move.from_uci(move.uci)
            except ValueError:  # pragma: no cover - engine emits valid UCI
                continue
            if parsed not in board.legal_moves:
                continue
            if parsed.promotion is not None and parsed.promotion != chess.QUEEN:
                continue
            candidates.append((parsed, deficit))

        if not candidates:
            return None

        weights = [1 + deficit for _, deficit in candidates]
        return rng.choices(candidates, weights=weights, k=1)[0][0]
