"""The coach: classify a move, then explain in plain words what it lost.

Engine scores decide *whether* a move is worth mentioning, but never *what the
coach says*.  Sentences are built from board facts: which of the player's
pieces the opponent can now take, which free capture was left on the table,
whether a mate in one became available.  This is deliberate product policy --
the coach explains, the player does the chess, and eval numbers stay out of
the user-facing copy.

Verdicts are pinned by the spec:

* :attr:`CoachVerdict.BLUNDER` -- the move gives up at least
  :data:`BLUNDER_LOSS_CP` centipawns, or it allows a mate in one that the
  engine's choice would have prevented;
* :attr:`CoachVerdict.NOTABLE` -- a loss from :data:`NOTABLE_LOSS_CP` up to
  just below the blunder threshold;
* :attr:`CoachVerdict.SILENT` -- anything smaller.  The coach says nothing at
  all, which is what keeps it from becoming noise.

The only place a sentence may echo a move is the free-material phrase ("the
queen on d5 was yours, Qxd5 wins it"): it names the capture that was already
on the board, not a move the player should find instead.  The
:meth:`Coach.never_names_the_move` property enforces that rule.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING

import chess

from chess_trainer.engine import DEFAULT_DEPTH, MoveAnalysis

if TYPE_CHECKING:  # pragma: no cover - typing only
    from chess_trainer.engine import Engine

#: Loss at or above this many centipawns is a blunder.
BLUNDER_LOSS_CP = 250

#: Loss at or above this many centipawns is worth mentioning.
NOTABLE_LOSS_CP = 100

#: Material values used to judge captures (king high so a king always counts
#: as a defender that cannot be won; kings are never capture victims).
_PIECE_VALUES = {
    chess.PAWN: 1,
    chess.KNIGHT: 3,
    chess.BISHOP: 3,
    chess.ROOK: 5,
    chess.QUEEN: 9,
    chess.KING: 100,
}

_PIECE_NAMES = {
    chess.PAWN: "pawn",
    chess.KNIGHT: "knight",
    chess.BISHOP: "bishop",
    chess.ROOK: "rook",
    chess.QUEEN: "queen",
    chess.KING: "king",
}


class CoachVerdict(StrEnum):
    """How strongly the coach reacts to a move."""

    SILENT = "silent"
    NOTABLE = "notable"
    BLUNDER = "blunder"


class CoachKind(StrEnum):
    """The board fact behind a coach message.

    Review mode (Task 10) reuses these together with :data:`PHRASES`.
    """

    MATE_THREAT = "mate_threat"
    HANGING_PIECE = "hanging_piece"
    MISSED_CAPTURE = "missed_capture"
    POSITION = "position"


#: Sentence templates keyed by ``(kind, verdict)``.  Placeholders are filled
#: from board facts only.  The missed-capture template is the one accepted
#: shape that may echo a move; see the module docstring.
PHRASES: dict[tuple[CoachKind, CoachVerdict], str] = {
    (CoachKind.MATE_THREAT, CoachVerdict.BLUNDER): (
        "that lets your opponent mate you next move."
    ),
    (CoachKind.HANGING_PIECE, CoachVerdict.BLUNDER): (
        "that loses your {piece} on {square}."
    ),
    (CoachKind.HANGING_PIECE, CoachVerdict.NOTABLE): (
        "that leaves your {piece} on {square} where it can be taken."
    ),
    (CoachKind.MISSED_CAPTURE, CoachVerdict.NOTABLE): (
        "the {piece} on {square} was yours, {san} wins it."
    ),
    (CoachKind.MISSED_CAPTURE, CoachVerdict.BLUNDER): (
        "the {piece} on {square} was yours, {san} wins it."
    ),
    (CoachKind.POSITION, CoachVerdict.NOTABLE): (
        "that lets your opponent back into the game."
    ),
    (CoachKind.POSITION, CoachVerdict.BLUNDER): (
        "that hands the initiative to your opponent."
    ),
}

#: SAN-shaped tokens in a message.  Bare pawn pushes are matched too, but a
#: square preceded by "on" is treated as a board reference ("the queen on
#: d5") rather than a suggestion.
_SAN_CANDIDATE = re.compile(
    r"(?<![A-Za-z0-9])"
    r"(?:"
    r"O-O(?:-O)?"
    r"|[KQRBN][a-h]?[1-8]?x?[a-h][1-8](?:=[QRBN])?"
    r"|[a-h]x[a-h][1-8](?:=[QRBN])?"
    r"|[a-h][1-8](?:=[QRBN])?"
    r")"
    r"[+#]?"
    r"(?![A-Za-z0-9])"
)

_BARE_SQUARE = re.compile(r"[a-h][1-8]")


@dataclass(frozen=True)
class _FreeCapture:
    """A legal capture that wins material, with what it wins."""

    move: chess.Move
    victim_square: chess.Square
    victim: chess.Piece
    gain: int


def _parse_move(board: chess.Board, played_uci: str) -> chess.Move:
    """Parse a UCI move for ``board``, raising ValueError if it is not legal."""
    try:
        move = board.parse_uci(played_uci)
    except ValueError as exc:  # chess.InvalidMoveError is a ValueError
        raise ValueError(
            f"invalid move {played_uci!r} for FEN {board.fen()!r}"
        ) from exc
    if move not in board.legal_moves:
        raise ValueError(f"illegal move {played_uci!r} for FEN {board.fen()!r}")
    return move


def _after(board: chess.Board, move: chess.Move) -> chess.Board:
    """Return the position after ``move`` (the input board is untouched)."""
    result = board.copy()
    result.push(move)
    return result


def _allows_mate_in_one(board: chess.Board) -> bool:
    """True if the side to move has a legal checkmating move.

    This is a board fact (python-chess rules), not an engine guess.
    """
    if board.is_game_over():
        return False
    probe = board.copy()
    for move in board.legal_moves:
        probe.push(move)
        mate = probe.is_checkmate()
        probe.pop()
        if mate:
            return True
    return False


def _captured_piece(
    board: chess.Board, move: chess.Move
) -> tuple[chess.Square, chess.Piece | None]:
    """Return the square and piece a capture removes (handles en passant)."""
    if board.is_en_passant(move):
        square = chess.square(
            chess.square_file(move.to_square),
            chess.square_rank(move.from_square),
        )
        return square, board.piece_at(square)
    return move.to_square, board.piece_at(move.to_square)


def _capture_gain(board: chess.Board, move: chess.Move) -> int:
    """Material the side to move wins with ``move``, in pawns (0 if not a win).

    The approximation is deliberately simple: a capture is worth the victim
    unless the victim is defended, in which case the attacker is traded for
    it.  It is used for phrasing only -- the verdict already comes from the
    engine.
    """
    if not board.is_capture(move):
        return 0
    _victim_square, victim = _captured_piece(board, move)
    attacker = board.piece_at(move.from_square)
    if victim is None or attacker is None:  # pragma: no cover - defensive
        return 0
    victim_value = _PIECE_VALUES[victim.piece_type]
    attacker_value = _PIECE_VALUES[attacker.piece_type]
    # Defenders of the destination square can recapture the attacker.
    if board.attackers(not board.turn, move.to_square):
        return max(0, victim_value - attacker_value)
    return victim_value


def _best_free_capture(board: chess.Board) -> _FreeCapture | None:
    """The most material the side to move can win with one capture, if any."""
    best: _FreeCapture | None = None
    for move in board.legal_moves:
        gain = _capture_gain(board, move)
        if gain <= 0:
            continue
        victim_square, victim = _captured_piece(board, move)
        if victim is None:  # pragma: no cover - non-capture already excluded
            continue
        candidate = _FreeCapture(move, victim_square, victim, gain)
        if best is None or candidate.gain > best.gain:
            best = candidate
    return best


class Coach:
    """Classifies the player's moves and phrases what went wrong.

    One coach can be reused for a whole game.  It keeps a one-entry analysis
    cache so calling :meth:`message` straight after :meth:`evaluate` for the
    same position and move costs a single engine search; the cache is not
    synchronised, so a Coach belongs to one worker at a time.
    """

    def __init__(self, engine: Engine, depth: int = DEFAULT_DEPTH) -> None:
        self.engine = engine
        self.depth = depth
        self._last_key: tuple[str, str] | None = None
        self._last_analysis: MoveAnalysis | None = None

    def evaluate(self, board_before: chess.Board, played_uci: str) -> CoachVerdict:
        """Classify ``played_uci`` played on ``board_before``.

        ``BLUNDER`` at 250 cp or more of loss (or an avoidable mate in one),
        ``NOTABLE`` from 100 to 249 cp, otherwise ``SILENT``.
        """
        move = _parse_move(board_before, played_uci)
        return self._classify(board_before, move, self._analysis(board_before, move))

    def message(self, board_before: chess.Board, played_uci: str) -> str:
        """A plain-language reason for the move, or ``""`` when silent.

        The sentence is chosen from board facts, never from the score, so the
        same mistake is described the same way whether it cost 100 or 900
        centipawns.  See :data:`PHRASES`.
        """
        move = _parse_move(board_before, played_uci)
        analysis = self._analysis(board_before, move)
        verdict = self._classify(board_before, move, analysis)
        if verdict is CoachVerdict.SILENT:
            return ""
        kind, details = self._diagnose(board_before, move, analysis)
        return PHRASES[(kind, verdict)].format(**details)

    @staticmethod
    def never_names_the_move(message: str, board_before: chess.Board) -> bool:
        """True when ``message`` suggests no move the player could have made.

        The free-material phrase is the accepted exception: a SAN that is a
        legal capture winning material is describing what was already there.
        A square preceded by "on" ("the queen on d5") is a board reference,
        not a pawn-push suggestion.  Only the free-material phrase may echo a
        capture, so a SAN is accepted only when the message uses that shape.
        """
        free_material_phrase = "was yours" in message.lower()
        for match in _SAN_CANDIDATE.finditer(message):
            token = match.group()
            san = token.rstrip("+#!?")
            before = message[: match.start()].lower()
            if _BARE_SQUARE.fullmatch(san) and before.endswith("on "):
                continue
            try:
                move = board_before.parse_san(san)
            except ValueError:
                continue
            if (
                free_material_phrase
                and move in board_before.legal_moves
                and _capture_gain(board_before, move) > 0
            ):
                continue
            return False
        return True

    # -- internals ---------------------------------------------------------

    def _analysis(
        self, board_before: chess.Board, move: chess.Move
    ) -> MoveAnalysis:
        """Analyse one position/move pair, reusing the previous result."""
        key = (board_before.fen(), move.uci())
        if key != self._last_key or self._last_analysis is None:
            self._last_analysis = self.engine.analyse(
                board_before.fen(), move.uci(), depth=self.depth
            )
            self._last_key = key
        return self._last_analysis

    def _classify(
        self,
        board_before: chess.Board,
        move: chess.Move,
        analysis: MoveAnalysis,
    ) -> CoachVerdict:
        loss = analysis.loss_cp
        if loss >= BLUNDER_LOSS_CP:
            return CoachVerdict.BLUNDER
        if _allows_mate_in_one(_after(board_before, move)) and self._best_avoids(
            board_before, analysis
        ):
            return CoachVerdict.BLUNDER
        if loss >= NOTABLE_LOSS_CP:
            return CoachVerdict.NOTABLE
        return CoachVerdict.SILENT

    @staticmethod
    def _best_avoids(board_before: chess.Board, analysis: MoveAnalysis) -> bool:
        """True when the engine's choice does not allow mate in one."""
        try:
            best = board_before.parse_uci(analysis.best_uci)
        except ValueError:  # pragma: no cover - engine emits legal UCI
            return False
        if best not in board_before.legal_moves:  # pragma: no cover - defensive
            return False
        return not _allows_mate_in_one(_after(board_before, best))

    def _diagnose(
        self,
        board_before: chess.Board,
        move: chess.Move,
        analysis: MoveAnalysis,
    ) -> tuple[CoachKind, dict[str, str]]:
        """Pick the board fact that best explains the mistake."""
        after = _after(board_before, move)

        if _allows_mate_in_one(after) and self._best_avoids(board_before, analysis):
            return CoachKind.MATE_THREAT, {}

        threat = _best_free_capture(after)
        if threat is not None:
            return CoachKind.HANGING_PIECE, {
                "piece": _PIECE_NAMES[threat.victim.piece_type],
                "square": chess.square_name(threat.victim_square),
            }

        missed = _best_free_capture(board_before)
        if missed is not None and _capture_gain(board_before, move) < missed.gain:
            return CoachKind.MISSED_CAPTURE, {
                "piece": _PIECE_NAMES[missed.victim.piece_type],
                "square": chess.square_name(missed.victim_square),
                "san": board_before.san(missed.move),
            }

        return CoachKind.POSITION, {}
