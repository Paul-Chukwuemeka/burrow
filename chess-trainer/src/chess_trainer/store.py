"""Local persistence: finished games, cumulative stats and bot strength.

Everything the player does survives a restart in three plain places under the
data directory (``chess-trainer/data/`` by default, git-ignored):

* ``games/YYYY-MM-DD/<timestamp>-<result>.pgn`` -- the game itself, plus a
  parallel ``.annotations.json`` carrying the coach's notes and the metadata
  the PGN cannot express (practice flag, bot strength, player colour,
  termination).  The annotations are stored as text, exactly as the coach
  produced them; nothing is regenerated on load.
* ``stats.json`` -- cumulative counts plus one :class:`GameRecord` per game,
  which is what Task 8's adaptation reads for its recent window.
* ``bot.json`` -- the current bot strength as a single JSON float.

Product rule: practice games count toward every total and carry a flag
(``practice_total`` and ``GameRecord.practice``); clean games are the ones
without it.  ``stats.json`` therefore stores the single totals the brief pins
and lets callers derive clean counts with ``total - practice_total``.

Resignations need special care.  python-chess has no resignation result, so
the controller records :data:`chess_trainer.controller.RESIGNATION`
(``chess.Termination.VARIANT_LOSS``) and writes the real winner only into the
PGN ``Result`` header.  The store treats that header as authoritative: the
outcome (win/loss/draw, from the player's perspective) comes from the header
combined with ``player_white``, while the sentinel only labels the game as a
resignation (``termination: "resignation"``, ``resignation: true``).

Corrupt or missing files never crash the app.  Unreadable JSON degrades to a
fresh default; values of the wrong type degrade field by field; stats and bot
writes go through a ``.tmp`` file and :func:`os.replace` so a crash mid-write
cannot leave a half-written file in place.

The data directory is resolved once, at import, from this module's location.
Tests always construct their own :class:`Store` on ``tmp_path`` and never
touch the real one.
"""

from __future__ import annotations

import io
import json
import math
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any

import chess
import chess.pgn

from chess_trainer.adapt import MAX_STRENGTH, MIN_STRENGTH
from chess_trainer.coach import CoachVerdict

if TYPE_CHECKING:  # pragma: no cover - typing only
    from chess_trainer.controller import FinishedGame

#: Starting / fallback bot strength (Stockfish skill 1.8, roughly 640 Elo).
DEFAULT_BOT_STRENGTH = 1.8

#: Stockfish ``Skill Level`` range, the scale stored in ``bot.json``.  The
#: ceiling is adaptation's humanlike limit, the single source of truth.
MIN_BOT_STRENGTH = MIN_STRENGTH
MAX_BOT_STRENGTH = MAX_STRENGTH

#: The one default location, resolved relative to the package::
#:
#:     chess-trainer/src/chess_trainer/store.py -> chess-trainer/data
DEFAULT_DATA_DIR = Path(__file__).resolve().parents[2] / "data"

#: Material values in pawn units, used for the score margin.  Kings are not
#: listed because they are never captured.
_PIECE_VALUES = {
    chess.PAWN: 1,
    chess.KNIGHT: 3,
    chess.BISHOP: 3,
    chess.ROOK: 5,
    chess.QUEEN: 9,
}

#: Outcomes as exposed to stats / adaptation.
_RESULTS = frozenset({"win", "loss", "draw"})

#: Per-game trend points: a win is a full point, a draw half, a loss none.
_SCORES = {"win": 1.0, "draw": 0.5, "loss": 0.0}

#: PGN result headers that name a winner (or a draw).
_RESULT_HEADERS = frozenset({"1-0", "0-1", "1/2-1/2"})


# --- small tolerant parsers ----------------------------------------------


def _as_int(value: object, *, default: int, minimum: int | None = None) -> int:
    """``value`` as an int, or ``default`` when it is not a sane count."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    if isinstance(value, float) and not value.is_integer():
        return default
    number = int(value)
    if minimum is not None and number < minimum:
        return default
    return number


def _as_float(value: object, *, default: float) -> float:
    """``value`` as a finite float, or ``default``."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    number = float(value)
    return number if math.isfinite(number) else default


def _as_strength(value: object, *, default: float) -> float:
    """``value`` as a strength on the Stockfish skill scale, or ``default``."""
    number = _as_float(value, default=default)
    if not MIN_BOT_STRENGTH <= number <= MAX_BOT_STRENGTH:
        return default
    return number


def _verdict_value(verdict: object) -> str:
    """Serialise a coach verdict whether it is an enum or a plain string."""
    if isinstance(verdict, CoachVerdict):
        return verdict.value
    return str(verdict)


def _annotation_payload(annotation: Any) -> dict[str, object]:
    """One :class:`GameAnnotation` as JSON-safe data."""
    return {
        "ply": int(annotation.ply),
        "fen": annotation.fen,
        "move_uci": annotation.move_uci,
        "verdict": _verdict_value(annotation.verdict),
        "message": annotation.message,
        "is_player": bool(annotation.is_player),
    }


# --- schema ---------------------------------------------------------------


@dataclass
class GameRecord:
    """One finished game as the stats file and adaptation need it.

    ``result`` is from the player's perspective (``"win"``/``"loss"``/
    ``"draw"``).  ``margin`` is the final material balance in pawns, signed
    from the player's perspective and nudged so a win is always positive and
    a loss always negative (a resignation while ahead is still a loss).
    ``date`` is an ISO 8601 timestamp.
    """

    result: str
    practice: bool
    blunders: int
    margin: float
    strength: float
    date: str

    def to_dict(self) -> dict[str, object]:
        return {
            "result": self.result,
            "practice": self.practice,
            "blunders": self.blunders,
            "margin": self.margin,
            "strength": self.strength,
            "date": self.date,
        }

    @classmethod
    def from_dict(cls, raw: object) -> GameRecord | None:
        """Parse one record, or ``None`` when it is not usable."""
        if not isinstance(raw, dict):
            return None
        result = raw.get("result")
        if result not in _RESULTS:
            return None
        date = raw.get("date")
        return cls(
            result=result,
            practice=raw.get("practice") is True,
            blunders=_as_int(raw.get("blunders"), default=0, minimum=0),
            margin=_as_float(raw.get("margin"), default=0.0),
            strength=_as_strength(
                raw.get("strength"), default=DEFAULT_BOT_STRENGTH
            ),
            date=date if isinstance(date, str) else "",
        )


@dataclass
class StatsFile:
    """The cumulative stats document.

    ``total`` includes practice games; ``practice_total`` is the subset that
    was played with the live coach on.  ``blunders_per_game`` holds one entry
    per game (the player's confirmed blunders).  ``strength`` is the strength
    of the most recently recorded game; the live value lives in ``bot.json``.
    """

    total: int = 0
    practice_total: int = 0
    losses: int = 0
    wins: int = 0
    draws: int = 0
    blunders_per_game: list[float] = field(default_factory=list)
    strength: float = DEFAULT_BOT_STRENGTH
    games: list[GameRecord] = field(default_factory=list)

    def trend(self) -> tuple[list[str], list[float]]:
        """Per-game labels and score points for the stats screen (Task 10).

        Labels are the games' dates, falling back to their 1-based position;
        points are 1.0 for a win, 0.5 for a draw, 0.0 for a loss.
        """
        labels: list[str] = []
        points: list[float] = []
        for index, record in enumerate(self.games, start=1):
            label = record.date[:10] if len(record.date) >= 10 else ""
            labels.append(label or f"game {index}")
            points.append(_SCORES.get(record.result, 0.0))
        return labels, points

    def to_dict(self) -> dict[str, object]:
        return {
            "total": self.total,
            "practice_total": self.practice_total,
            "losses": self.losses,
            "wins": self.wins,
            "draws": self.draws,
            "blunders_per_game": list(self.blunders_per_game),
            "strength": self.strength,
            "games": [record.to_dict() for record in self.games],
        }

    @classmethod
    def from_dict(cls, raw: object) -> StatsFile:
        """Build stats from untrusted JSON, repairing each field separately."""
        if not isinstance(raw, dict):
            return cls()

        games: list[GameRecord] = []
        games_raw = raw.get("games")
        if isinstance(games_raw, list):
            for item in games_raw:
                record = GameRecord.from_dict(item)
                if record is not None:
                    games.append(record)

        blunders: list[float] = []
        blunders_raw = raw.get("blunders_per_game")
        if isinstance(blunders_raw, list):
            for item in blunders_raw:
                if isinstance(item, bool) or not isinstance(item, (int, float)):
                    continue
                number = float(item)
                if math.isfinite(number) and number >= 0:
                    blunders.append(number)

        strength = _as_strength(
            raw.get("strength"), default=DEFAULT_BOT_STRENGTH
        )
        return cls(
            total=_as_int(raw.get("total"), default=0, minimum=0),
            practice_total=_as_int(
                raw.get("practice_total"), default=0, minimum=0
            ),
            losses=_as_int(raw.get("losses"), default=0, minimum=0),
            wins=_as_int(raw.get("wins"), default=0, minimum=0),
            draws=_as_int(raw.get("draws"), default=0, minimum=0),
            blunders_per_game=blunders,
            strength=strength,
            games=games,
        )


@dataclass(frozen=True)
class _Summary:
    """What save and record both need to know about one finished game."""

    pgn_result: str | None
    outcome: str
    resignation: bool
    margin: float
    blunders: int


# --- reading a finished game ---------------------------------------------


def _read_game(pgn: str) -> chess.pgn.Game | None:
    """Parse a PGN string, returning ``None`` for anything unreadable."""
    try:
        return chess.pgn.read_game(io.StringIO(pgn))
    except (ValueError, KeyError, IndexError):
        # Corrupt game files must never crash the app.
        return None


def _is_resignation(finished: FinishedGame) -> bool:
    """True for the controller's resignation sentinel (no RESIGN in chess)."""
    return finished.result == chess.Termination.VARIANT_LOSS


def _pgn_result(pgn: str) -> str | None:
    """The real result header, re-derived from the final board if needed."""
    game = _read_game(pgn)
    if game is None:
        return None
    header = game.headers.get("Result", "*")
    if header in _RESULT_HEADERS:
        return header
    # Older / truncated PGNs may still have a terminal final position.
    outcome = game.end().board().outcome()
    if outcome is None:
        return None
    if outcome.winner is None:
        return "1/2-1/2"
    return "1-0" if outcome.winner == chess.WHITE else "0-1"


def _outcome(pgn_result: str | None, player_white: bool) -> str:
    """Win/loss/draw from the player's perspective."""
    if pgn_result == "1/2-1/2":
        return "draw"
    if pgn_result == "1-0":
        return "win" if player_white else "loss"
    if pgn_result == "0-1":
        return "loss" if player_white else "win"
    # No trustworthy result: count it neutrally rather than invent a winner.
    return "draw"


def _material_margin(pgn: str, player_white: bool) -> float:
    """Final material balance in pawns, positive when the player is ahead."""
    game = _read_game(pgn)
    if game is None:
        return 0.0
    player_color = chess.WHITE if player_white else chess.BLACK
    balance = 0
    for piece in game.end().board().piece_map().values():
        value = _PIECE_VALUES.get(piece.piece_type, 0)
        balance += value if piece.color == player_color else -value
    return float(balance)


def _margin(outcome: str, material: float) -> float:
    """Signed score margin: a win is at least +1, a loss at most -1."""
    if outcome == "win":
        return max(material, 1.0)
    if outcome == "loss":
        return min(material, -1.0)
    return material


def _player_blunders(finished: FinishedGame) -> int:
    """Confirmed player blunders; a taken-back move never reaches here."""
    return sum(
        1
        for annotation in finished.annotations
        if annotation.is_player and annotation.verdict == CoachVerdict.BLUNDER
    )


def _summarise(finished: FinishedGame) -> _Summary:
    """Derive every stored fact once, from the PGN and annotations."""
    pgn_result = _pgn_result(finished.pgn)
    outcome = _outcome(pgn_result, finished.player_white)
    material = _material_margin(finished.pgn, finished.player_white)
    return _Summary(
        pgn_result=pgn_result,
        outcome=outcome,
        resignation=_is_resignation(finished),
        margin=_margin(outcome, material),
        blunders=_player_blunders(finished),
    )


# --- files ----------------------------------------------------------------


def _dump(payload: object) -> str:
    """Pretty, stable JSON with a trailing newline."""
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def _atomic_write_text(path: Path, text: str) -> None:
    """Write via ``.tmp`` + rename so readers never see a partial file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


# --- the store ------------------------------------------------------------


class Store:
    """Reads and writes the app's data folder.

    Construct it once with the data directory (the GUI uses the default):

    >>> store = Store()                      # chess-trainer/data/
    >>> store = Store(Path("/tmp/test"))     # tests and throwaways
    """

    def __init__(self, data_dir: Path | None = None) -> None:
        self.data_dir = (
            Path(data_dir) if data_dir is not None else DEFAULT_DATA_DIR
        )
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self._games_dir = self.data_dir / "games"
        self._stats_path = self.data_dir / "stats.json"
        self._bot_path = self.data_dir / "bot.json"

    # -- games -------------------------------------------------------------

    def save(self, finished: FinishedGame) -> Path:
        """Write the PGN and its annotation sidecar; return the PGN path.

        Zero-move games are valid: the PGN simply has no movetext, and the
        sidecar's ``annotations`` list is empty.
        """
        now = datetime.now().astimezone()
        summary = _summarise(finished)

        directory = self._games_dir / now.strftime("%Y-%m-%d")
        directory.mkdir(parents=True, exist_ok=True)
        stem = f"{now.strftime('%Y%m%dT%H%M%S%f')}-{summary.outcome}"
        path = directory / f"{stem}.pgn"
        suffix = 2
        while path.exists():
            # Two quick saves can share a microsecond; never overwrite.
            path = directory / f"{stem}-{suffix}.pgn"
            suffix += 1

        pgn = finished.pgn
        if not pgn.endswith("\n"):
            pgn += "\n"
        _atomic_write_text(path, pgn)

        payload: dict[str, object] = {
            "date": now.isoformat(timespec="seconds"),
            "result": summary.outcome,
            "pgn_result": summary.pgn_result,
            "termination": (
                "resignation"
                if summary.resignation
                else getattr(finished.result, "name", str(finished.result)).lower()
            ),
            "resignation": summary.resignation,
            "practice": bool(finished.is_practice),
            "bot_strength": _as_strength(
                finished.bot_strength, default=DEFAULT_BOT_STRENGTH
            ),
            "player_white": bool(finished.player_white),
            "player_color": "white" if finished.player_white else "black",
            "blunders": summary.blunders,
            "margin": summary.margin,
            "annotations": [
                _annotation_payload(annotation)
                for annotation in finished.annotations
            ],
        }
        _atomic_write_text(path.with_suffix(".annotations.json"), _dump(payload))
        return path

    # -- stats -------------------------------------------------------------

    def load_stats(self) -> StatsFile:
        """Read ``stats.json``; missing or corrupt files yield defaults."""
        try:
            raw = json.loads(self._stats_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return StatsFile()
        return StatsFile.from_dict(raw)

    def load_game_records(self) -> list[GameRecord]:
        """The per-game history adaptation (Task 8) reads."""
        return list(self.load_stats().games)

    def record_to_stats(self, finished: FinishedGame) -> None:
        """Append one game to the cumulative file.

        Practice and clean games both count; the record keeps the flag so
        callers can separate them without a second set of totals.
        """
        stats = self.load_stats()
        summary = _summarise(finished)
        strength = _as_strength(
            finished.bot_strength, default=DEFAULT_BOT_STRENGTH
        )
        record = GameRecord(
            result=summary.outcome,
            practice=bool(finished.is_practice),
            blunders=summary.blunders,
            margin=summary.margin,
            strength=strength,
            date=datetime.now().astimezone().isoformat(timespec="seconds"),
        )

        stats.games.append(record)
        stats.total += 1
        if record.practice:
            stats.practice_total += 1
        if record.result == "win":
            stats.wins += 1
        elif record.result == "loss":
            stats.losses += 1
        else:
            stats.draws += 1
        stats.blunders_per_game.append(float(record.blunders))
        stats.strength = strength

        _atomic_write_text(self._stats_path, _dump(stats.to_dict()))

    # -- bot strength ------------------------------------------------------

    @property
    def bot_strength(self) -> float:
        """The saved strength, clamped to the humanlike range.

        An unreadable or non-numeric file falls back to the 640-Elo default.
        A finite number -- including a legacy file written under the old
        20-point ceiling -- is clamped into ``[0.0, 14.0]`` instead of being
        rejected, so a corrupt or stale ``bot.json`` cannot field an
        above-ceiling bot for one game.
        """
        try:
            raw = json.loads(self._bot_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return DEFAULT_BOT_STRENGTH
        if isinstance(raw, dict):
            # Tolerate a future ``{"strength": ...}`` shape.
            raw = raw.get("strength")
        number = _as_float(raw, default=DEFAULT_BOT_STRENGTH)
        return min(max(number, MIN_BOT_STRENGTH), MAX_BOT_STRENGTH)

    @bot_strength.setter
    def bot_strength(self, value: float) -> None:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise TypeError("bot strength must be a number")
        number = float(value)
        if not math.isfinite(number):
            raise ValueError("bot strength must be finite")
        number = min(max(number, MIN_BOT_STRENGTH), MAX_BOT_STRENGTH)
        _atomic_write_text(self._bot_path, _dump(number))
