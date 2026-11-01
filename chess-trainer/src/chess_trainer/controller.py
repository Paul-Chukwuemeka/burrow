"""The game controller: the multiplayer brain behind the board.

The controller owns the one authoritative :class:`chess.Board` and turns
requests from the UI into moves, coach verdicts, annotations and a finished
game record.  Everything else -- the GUI, persistence, adaptation -- is a
client of this module, so the state machine here is the contract:

* ``new_game`` resets the board, mode, color and pending take-back;
* ``try_player_move`` accepts one player move (legality from python-chess),
  records it, and in live-coach mode asks the coach.  A ``NOTABLE`` or
  ``BLUNDER`` verdict interrupts *before* the bot replies and offers a
  one-ply take-back;
* ``undo_player_move`` is only legal while that offer is pending and pops
  exactly one ply, so castling rights, en passant squares and promotions come
  back exactly as python-chess recorded them;
* ``confirm_move`` keeps the flawed move and lets the bot reply on the UI's
  next tick;
* ``bot_move`` computes the reply; ``resign`` ends the game as a player loss;
* ``finished_game`` packages the PGN plus annotations for the store.

A taken-back move leaves no annotation behind, so confirming a retry cannot
double-record the blunder.  Annotations store the coach's sentence next to
the move: the coach's analysis cache is single-entry and unsynchronised, so
the controller always calls ``evaluate`` immediately followed by ``message``
for the same position and persists the text rather than regenerating it.

``GameAnnotation.fen`` is the position the move was played *in* (before the
move), which lets review apply ``move_uci`` to it.  Bot moves and clean-mode
player moves are recorded with :attr:`CoachVerdict.SILENT` and no message.

The store is accepted in the constructor but deliberately untouched here:
Task 8 wires the end-of-game save/retune hook, and until then no method may
dereference it.  The controller is not thread-safe; the slow engine calls
(``try_player_move``'s coach pass and ``bot_move``) belong on the GUI's worker
thread, one call at a time.

python-chess has no "resignation" termination.  Resignations are recorded as
:data:`RESIGNATION` (:attr:`chess.Termination.VARIANT_LOSS`), the closest
legal ``chess.Termination`` value; a standard game can only reach it here by
resigning.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING

import chess
import chess.pgn

from chess_trainer.coach import CoachVerdict

if TYPE_CHECKING:  # pragma: no cover - typing only
    from chess_trainer.bot import Bot
    from chess_trainer.coach import Coach

#: Starting strength when the caller has not loaded a saved value yet.  It is
#: the same default the store uses (Stockfish skill 6.0, roughly 640 Elo).
DEFAULT_BOT_STRENGTH = 6.0

#: Termination recorded for a resignation (python-chess has no RESIGN member).
RESIGNATION: chess.Termination = chess.Termination.VARIANT_LOSS

#: Verdicts that make the live coach interrupt and offer a take-back.
_ACTIONABLE = frozenset({CoachVerdict.NOTABLE, CoachVerdict.BLUNDER})


class Mode(StrEnum):
    """Whether the live coach watches this game."""

    LIVE_COACH = "live_coach"
    CLEAN = "clean"


@dataclass
class PlayerMoveOutcome:
    """What the GUI needs to know after a player's move attempt.

    ``verdict``/``message`` are ``None`` in clean mode and on rejected moves.
    ``can_undo`` is true exactly when a take-back is on offer.
    """

    accepted: bool
    verdict: CoachVerdict | None
    message: str | None
    can_undo: bool


@dataclass
class GameAnnotation:
    """One move plus the coach's note about it.

    ``ply`` is the 1-based ply number of ``move_uci`` in the game, and ``fen``
    is the position the move was played in (before it was made).  ``verdict``
    is ``SILENT`` for bot moves and for clean-mode player moves.
    """

    ply: int
    fen: str
    move_uci: str
    verdict: CoachVerdict
    message: str | None
    is_player: bool


@dataclass
class BoardSnapshot:
    """Everything the GUI needs to paint the board."""

    ply: int
    fen: str
    turn_white: bool
    result: chess.Termination | None


@dataclass
class FinishedGame:
    """A completed game, ready for the store."""

    pgn: str
    annotations: list[GameAnnotation]
    is_practice: bool
    bot_strength: float
    player_white: bool
    result: chess.Termination


class GameController:
    """Owns the board and the rules of a single game against the bot."""

    def __init__(self, bot: Bot, coach: Coach, store: object) -> None:
        # Duck-typed in tests and not used until Task 8; do not dereference it.
        self.bot = bot
        self.coach = coach
        self._store = store
        #: Adapted by Task 8; ``new_game`` must not reset it.
        self.bot_strength = DEFAULT_BOT_STRENGTH
        self.new_game(Mode.CLEAN)

    # -- lifecycle ---------------------------------------------------------

    def new_game(self, mode: Mode, player_white: bool = True) -> None:
        """Start a fresh game from the initial position."""
        self.mode = mode
        self.player_white = player_white
        self._board = chess.Board()
        self._annotations: list[GameAnnotation] = []
        self._resigned = False
        self.awaiting_retry = False

    # -- views -------------------------------------------------------------

    @property
    def board(self) -> chess.Board:
        """The live board.  Callers must treat it as read-only."""
        return self._board

    @property
    def annotations(self) -> list[GameAnnotation]:
        """A copy of the annotations recorded so far."""
        return list(self._annotations)

    @property
    def is_practice(self) -> bool:
        """Practice games are played with the live coach on."""
        return self.mode is Mode.LIVE_COACH

    def snapshot(self) -> BoardSnapshot:
        """The current position as the GUI should render it."""
        return BoardSnapshot(
            ply=len(self._board.move_stack),
            fen=self._board.fen(),
            turn_white=self._board.turn == chess.WHITE,
            result=self._termination(),
        )

    # -- moves -------------------------------------------------------------

    def try_player_move(self, uci: str) -> PlayerMoveOutcome:
        """Play one move for the human, if it is legal and it is their turn.

        Rejected attempts never touch the board, the annotations or the
        coach.  A notable/blunder verdict in live-coach mode sets
        :attr:`awaiting_retry` and leaves the bot's reply to a later tick.
        """
        if self.awaiting_retry:
            # The GUI should have disabled input; keep the pending offer alive.
            return PlayerMoveOutcome(False, None, None, True)
        if self._termination() is not None:
            return PlayerMoveOutcome(False, None, None, False)
        if self._board.turn != self._player_color:
            return PlayerMoveOutcome(False, None, None, False)

        # python-chess 1.11 raises ValueError (InvalidMoveError/IllegalMoveError)
        # rather than taking the plan's invented raise_on_error keyword.
        try:
            move = self._board.parse_uci(uci)
        except ValueError:
            return PlayerMoveOutcome(False, None, None, False)
        if not move or move not in self._board.legal_moves:
            return PlayerMoveOutcome(False, None, None, False)

        before = self._board.copy()
        played = move.uci()
        self._board.push(move)

        verdict: CoachVerdict | None = None
        message: str | None = None
        if self.mode is Mode.LIVE_COACH:
            # The coach caches one analysis; keep the pair adjacent and on the
            # same position.  The message is persisted, never regenerated.
            verdict = self.coach.evaluate(before, played)
            text = self.coach.message(before, played)
            if verdict is CoachVerdict.SILENT:
                message = None
            else:
                message = text or None
                if verdict in _ACTIONABLE:
                    self.awaiting_retry = True

        self._annotations.append(
            GameAnnotation(
                ply=len(self._board.move_stack),
                fen=before.fen(),
                move_uci=played,
                verdict=CoachVerdict.SILENT if verdict is None else verdict,
                message=message,
                is_player=True,
            )
        )
        return PlayerMoveOutcome(
            accepted=True,
            verdict=verdict,
            message=message,
            can_undo=self.awaiting_retry,
        )

    def bot_move(self) -> str:
        """Ask the bot for its reply and append it to the game.

        Raises ``RuntimeError`` when it is not a legal moment for a bot move
        and ``ValueError`` if the bot ever returns an illegal move (the board
        is left untouched in that case).
        """
        if self.awaiting_retry:
            raise RuntimeError(
                "the player's move is awaiting confirm or take-back"
            )
        if self._termination() is not None:
            raise RuntimeError("the game is over")
        if self._board.turn == self._player_color:
            raise RuntimeError("it is the player's turn, not the bot's")

        before = self._board.copy()
        uci = self.bot.choose_move(before, self.bot_strength)
        try:
            move = self._board.parse_uci(uci)
        except ValueError as exc:
            raise ValueError(
                f"bot returned illegal move {uci!r} in {before.fen()!r}"
            ) from exc
        if move not in self._board.legal_moves:
            raise ValueError(
                f"bot returned illegal move {uci!r} in {before.fen()!r}"
            )

        played = move.uci()
        self._board.push(move)
        self._annotations.append(
            GameAnnotation(
                ply=len(self._board.move_stack),
                fen=before.fen(),
                move_uci=played,
                verdict=CoachVerdict.SILENT,
                message=None,
                is_player=False,
            )
        )
        return played

    def undo_player_move(self) -> bool:
        """Take back the pending player move, exactly one ply.

        Only available while :attr:`awaiting_retry`; the pending annotation is
        dropped with the move so a confirmed retry is recorded only once.
        """
        if not self.awaiting_retry or not self._board.move_stack:
            return False
        popped = self._board.pop()
        self.awaiting_retry = False
        last = self._annotations[-1] if self._annotations else None
        if (
            last is not None
            and last.is_player
            and last.move_uci == popped.uci()
        ):
            self._annotations.pop()
        return True

    def confirm_move(self) -> None:
        """Keep the move currently on offer; the bot replies on the next tick."""
        self.awaiting_retry = False

    def resign(self) -> None:
        """End the game as a player loss (a no-op once the game is over)."""
        if self._resigned:
            return
        if self._board.outcome() is not None and not self.awaiting_retry:
            return
        self._resigned = True
        self.awaiting_retry = False

    # -- game over ---------------------------------------------------------

    def finished_game(self) -> FinishedGame | None:
        """The completed game, or ``None`` while play (or a retry) is pending."""
        result = self._termination()
        if result is None:
            return None

        game = chess.pgn.Game.from_board(self._board)
        if self._resigned:
            # The board itself has no outcome; from_board would write "*".
            game.headers["Result"] = "0-1" if self.player_white else "1-0"
        return FinishedGame(
            pgn=str(game),
            annotations=list(self._annotations),
            is_practice=self.is_practice,
            bot_strength=self.bot_strength,
            player_white=self.player_white,
            result=result,
        )

    # -- internals ---------------------------------------------------------

    @property
    def _player_color(self) -> chess.Color:
        return chess.WHITE if self.player_white else chess.BLACK

    def _termination(self) -> chess.Termination | None:
        """The final result, or ``None`` while a take-back could still change it."""
        if self._resigned:
            return RESIGNATION
        if self.awaiting_retry:
            return None
        outcome = self._board.outcome()
        return None if outcome is None else outcome.termination
