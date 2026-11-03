"""Adaptive difficulty: the bot drifts to stay a real challenge.

The player never picks a strength; the dial quietly follows how they are
doing so that the bot stays worth beating but never unbeatable.  :func:`retune`
is called once per finished game with the recent history and the strength that
game was played at, and returns the strength to use for the next game.

The pinned window
-----------------

Only the last :data:`WINDOW` results matter.  Clean games (played with the
live coach off) are preferred; practice games fill any slots left over, so a
brand-new player whose only games are practice still moves the dial.  Games
older than the window never enter the calculation.

Two thresholds set the direction, measured as a score fraction (win 1, draw
1/2, loss 0):

* ``score >= 0.60`` -- the player is beating the bot: aim 0.8 higher;
* ``score <= 0.25`` -- the player is being beaten: aim 0.8 lower;
* anything in between -- leave the dial alone.  Two wins and three losses is
  exactly the competitive band the bot is supposed to sit in, so it must not
  move.

The "toward current +/- 0.8" target is approached, not jumped to.  Each game
in the window contributes an equal share of 0.8 (:data:`WINDOW` games, so 0.16
apiece) scaled by how convincing that game was, in ``[0.5, 1.5]`` of its
share.  A decisive, clean win counts fully; a scrappy win counts less.  A
heavy, blunder-filled loss counts more than a narrow one.  The per-game total
is capped at 0.8, so one finished game can never lurch the dial.  When the
direction is "unchanged" the current strength is returned untouched.

The ceiling
-----------

Strengths clamp to ``[0.0, 14.0]``.  Fourteen is deliberately below
Stockfish's 20: the bot must stay humanlike, and an opponent that never misses
is not a trainer.  The caller persists the returned value (the controller
writes it through ``Store.bot_strength``).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Literal

if TYPE_CHECKING:  # pragma: no cover - typing only
    from chess_trainer.store import GameRecord

#: How many recent results the dial looks at.
WINDOW = 5

#: How far the dial aims to move when the player is clearly winning or losing.
#: A single retune never moves it further than this.
MAX_SHIFT = 0.8

#: A score fraction at or above this means "the bot is too easy".
WIN_RATE = 0.60

#: A score fraction at or below this means "the bot is too hard".
LOSS_RATE = 0.25

#: The humanlike ceiling; never raw full-strength Stockfish.
MIN_STRENGTH = 0.0
MAX_STRENGTH = 14.0

#: Material balance at which a game counts as fully decisive, in pawns.
DECISIVE_MARGIN = 9.0

#: Blunders at which the player's error count is fully accounted for.
DECISIVE_BLUNDERS = 4

#: Result labels adaptation understands, practice variants included.
ResultName = Literal[
    "win",
    "loss",
    "draw",
    "practice_win",
    "practice_loss",
    "practice_draw",
]

_RESULTS = frozenset(
    {"win", "loss", "draw", "practice_win", "practice_loss", "practice_draw"}
)

#: Per-game score points: a win is a full point, a draw half, a loss none.
_SCORES = {"win": 1.0, "draw": 0.5, "loss": 0.0}


@dataclass(frozen=True)
class GameResult:
    """One finished game as adaptation sees it.

    ``margin`` is the final material balance in pawns from the player's
    perspective (negative when they are behind), and ``blunders`` is the
    number of confirmed player blunders.  ``result`` carries the practice flag
    when the game was played with the live coach on.
    """

    result: ResultName
    margin: int
    blunders: int

    def __post_init__(self) -> None:
        if self.result not in _RESULTS:
            raise ValueError(f"unknown game result: {self.result!r}")

    @property
    def is_practice(self) -> bool:
        """True when the game was played with the live coach on."""
        return self.result.startswith("practice_")

    @property
    def base(self) -> str:
        """``win``/``loss``/``draw``, with any practice prefix removed."""
        return self.result.removeprefix("practice_")

    @classmethod
    def from_record(cls, record: GameRecord) -> GameResult:
        """Adapt a stored :class:`GameRecord` for :func:`retune`.

        The store keeps the material margin as a float and the practice flag
        separately; both are folded into this module's flat shape here.  A
        non-integral margin is rounded to the nearest pawn.
        """
        result = record.result
        if record.practice:
            result = f"practice_{result}"
        return cls(
            result=result,  # type: ignore[arg-type]
            margin=round(float(record.margin)),
            blunders=int(record.blunders),
        )


def retune(current: float, results: list[GameResult]) -> float:
    """Return the strength for the next game after ``results``.

    ``current`` is the strength the just-finished game was played at;
    ``results`` is the game history oldest first.  Only the recent window is
    consulted, and an empty history leaves the dial where it is.  The result
    is always clamped to ``[0.0, 14.0]``.
    """
    window = _recent_window(results)
    if not window:
        return _clamp(current)

    score = sum(_SCORES[result.base] for result in window) / len(window)
    if score >= WIN_RATE:
        direction = 1
    elif score <= LOSS_RATE:
        direction = -1
    else:
        return _clamp(current)

    delta = sum(
        _share(result)
        for result in window
        if result.base == ("win" if direction > 0 else "loss")
    )
    delta = min(delta, MAX_SHIFT)
    return _clamp(current + direction * delta)


def _recent_window(results: list[GameResult]) -> list[GameResult]:
    """The last five results, preferring clean games over practice ones.

    When fewer than five clean games exist, the most recent practice games
    fill the remaining slots.  With no clean games at all this is simply the
    last five practice games, which is what a brand-new player has.
    """
    clean = [result for result in results if not result.is_practice]
    if len(clean) >= WINDOW:
        return clean[-WINDOW:]
    practice = [result for result in results if result.is_practice]
    missing = WINDOW - len(clean)
    return clean + practice[-missing:]


def _share(result: GameResult) -> float:
    """How far one game moves the dial: its share scaled by conviction."""
    return (MAX_SHIFT / WINDOW) * (0.5 + _conviction(result))


def _conviction(result: GameResult) -> float:
    """0-1: how strongly one game argues for its own direction.

    Material dominance is the main signal.  For a win, blunders weaken the
    evidence (a scrappy win barely proves the bot is too easy); for a loss,
    blunders strengthen it (a heavy, error-strewn loss proves the bot is too
    hard).  Draws never reach this function.
    """
    material = min(abs(result.margin), DECISIVE_MARGIN) / DECISIVE_MARGIN
    errors = min(max(result.blunders, 0), DECISIVE_BLUNDERS) / DECISIVE_BLUNDERS
    if result.base == "win":
        return 0.5 * material + 0.5 * (1.0 - errors)
    return 0.5 * material + 0.5 * errors


def _clamp(strength: float) -> float:
    """Keep the dial humanlike and stable to three decimals."""
    return round(min(max(float(strength), MIN_STRENGTH), MAX_STRENGTH), 3)
