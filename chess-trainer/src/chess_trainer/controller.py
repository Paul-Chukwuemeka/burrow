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
double-record the blunder.  It is not forgotten, though: the rollback counts
one ``attempted_blunders`` on the finished game, because the spec says a move
the player blundered and took back is still recorded as made.  Annotations
store the coach's sentence next to
the move: the coach's analysis cache is single-entry and unsynchronised, so
the controller always calls ``evaluate`` immediately followed by ``message``
for the same position and persists the text rather than regenerating it.

``GameAnnotation.fen`` is the position the move was played *in* (before the
move), which lets review apply ``move_uci`` to it.  While a game is in
progress, bot moves and clean-mode player moves are recorded with
:attr:`CoachVerdict.SILENT` and no message.  At finalisation a review pass
re-evaluates every move that still lacks a non-silent note -- all plies in a
clean game, and the bot's plies in a practice game -- at the review depth and
writes the verdict and sentence into the annotation.  Player moves the live
coach already evaluated keep their sentence verbatim; the pass never
regenerates them (and never opens a new take-back offer).

Ending a game has a side effect: the first time the controller notices that
play is over, :meth:`GameController._finalize_game` runs the review pass, then
packages the PGN, saves it and its stats through the store, asks
:func:`chess_trainer.adapt.retune` for the next strength and writes that back
through :attr:`Store.bot_strength`.  The review pass, the PGN save and the
stats record are each marked done as soon as they succeed and are never
repeated for the same game; the finished record is cached as soon as the stats
record lands, before the strength is retuned.  A store failure still
propagates to the caller: a failed review, save or record is retried (only the
step that failed) on a later call, while a failed strength write leaves the
game recorded exactly once and the saved dial stale.  ``finished_game``
returns a defensive copy of the cached record, and ``new_game`` starts a
fresh one.

The controller is not thread-safe; the slow engine calls
(``try_player_move``'s coach pass and ``bot_move``) belong on the GUI's worker
thread, one call at a time.

python-chess has no "resignation" termination.  Resignations are recorded as
:data:`RESIGNATION` (:attr:`chess.Termination.VARIANT_LOSS`), the closest
legal ``chess.Termination`` value; a standard game can only reach it here by
resigning.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, replace
from enum import StrEnum
from typing import TYPE_CHECKING

import chess
import chess.pgn

from chess_trainer import adapt
from chess_trainer.coach import CoachVerdict
from chess_trainer.store import DEFAULT_BOT_STRENGTH

if TYPE_CHECKING:  # pragma: no cover - typing only
    from chess_trainer.bot import Bot
    from chess_trainer.coach import Coach
    from chess_trainer.store import Store

#: Termination recorded for a resignation (python-chess has no RESIGN member).
RESIGNATION: chess.Termination = chess.Termination.VARIANT_LOSS

#: Verdicts that make the live coach interrupt and offer a take-back.
_ACTIONABLE = frozenset({CoachVerdict.NOTABLE, CoachVerdict.BLUNDER})

#: Depth used by the post-game review pass.  Live moves already had the
#: coach's full depth; the review is a cheaper sweep over the moves that did
#: not get one (bot replies, and every move in a clean game).
REVIEW_DEPTH = 8


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
    is the position the move was played in (before it was made).  During play
    ``verdict`` is ``SILENT`` for bot moves and for clean-mode player moves;
    the end-of-game review pass may replace that with a coach note.
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
    """A completed game, ready for the store.

    ``attempted_blunders`` counts actionable mistakes the player took back.
    They have no annotation (the move was rewound) but still count once in
    the game's stats.  It is last with a default so records built by older
    callers keep working.
    """

    pgn: str
    annotations: list[GameAnnotation]
    is_practice: bool
    bot_strength: float
    player_white: bool
    result: chess.Termination
    attempted_blunders: int = 0


class GameController:
    """Owns the board and the rules of a single game against the bot."""

    def __init__(
        self,
        bot: Bot,
        coach: Coach,
        store: Store,
        on_review: Callable[[], None] | None = None,
    ) -> None:
        self.bot = bot
        self.coach = coach
        #: Persistence for the end-of-game save and the adapted strength.
        self._store = store
        #: Called (on the caller's thread) just before the review pass starts,
        #: so the GUI can explain why the board stays locked.  Optional: core
        #: users and tests do not need it.
        self.on_review = on_review
        #: Loaded from the store so the dial survives a restart, then adapted
        #: after each game; ``new_game`` must not reset it.  Callers may still
        #: override it before the first game starts.  Duck-typed stores that do
        #: not track a dial fall back to the shared default rather than failing
        #: at construction.
        self.bot_strength = getattr(
            self._store, "bot_strength", DEFAULT_BOT_STRENGTH
        )
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
        #: Actionable mistakes the player took back.  The move is gone from
        #: the annotations, but it still counts once in this game's stats.
        self._attempted_blunders = 0
        self._finished: FinishedGame | None = None
        #: Persistence and analysis steps already completed for this game.
        #: They are set only after the step returns, so a retry resumes at the
        #: step that failed instead of repeating work or writing the game
        #: twice.  The review pass is idempotent too, but the flag keeps a
        #: retried save/record from re-running the engine sweep.
        self._reviewed = False
        self._saved = False
        self._recorded = False

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
        self._finalize_game()
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
        self._finalize_game()
        return played

    def undo_player_move(self) -> bool:
        """Take back the pending player move, exactly one ply.

        Only available while :attr:`awaiting_retry`; the pending annotation is
        dropped with the move so a confirmed retry is recorded only once.  If
        that move was an actionable mistake, it is counted as an attempted
        blunder before it disappears: taking a blunder back must not erase it
        from the game's record.
        """
        if not self.awaiting_retry or not self._board.move_stack:
            return False
        last = self._annotations[-1] if self._annotations else None
        popped = self._board.pop()
        self.awaiting_retry = False
        if (
            last is not None
            and last.is_player
            and last.move_uci == popped.uci()
        ):
            if last.verdict in _ACTIONABLE:
                self._attempted_blunders += 1
            self._annotations.pop()
        return True

    def confirm_move(self) -> None:
        """Keep the move currently on offer; the bot replies on the next tick."""
        self.awaiting_retry = False
        # A confirmed move may have ended the game (the interruption held the
        # board back from reporting it), so this is a possible finish point.
        self._finalize_game()

    def resign(self) -> None:
        """End the game as a player loss (a no-op once the game is over)."""
        if self._resigned:
            return
        if self._board.outcome() is not None and not self.awaiting_retry:
            return
        self._resigned = True
        self.awaiting_retry = False
        self._finalize_game()

    # -- game over ---------------------------------------------------------

    def finished_game(self) -> FinishedGame | None:
        """The completed game, or ``None`` while play (or a retry) is pending.

        The review pass, save and strength adaptation run on the first call
        (or earlier, at the move that ended play).  Each call returns a fresh
        copy, so callers cannot mutate the record the store already saw.
        """
        finished = self._finalize_game()
        if finished is None:
            return None
        return replace(finished, annotations=list(finished.annotations))

    # -- internals ---------------------------------------------------------

    def _finalize_game(self) -> FinishedGame | None:
        """Review, save, record and retune once; ``None`` while play is pending.

        The review pass runs first so the game that is saved and counted is
        the fully annotated one.  The record is built before the strength
        changes, so its ``bot_strength`` is the strength the game was actually
        played at.  The review, save and record steps are each skipped once
        they have succeeded, so a failure in one is retried on a later call
        without repeating the others.  The record is cached as soon as the
        stats record lands, before the strength is read or written: if
        adapting or writing fails, the game still stays recorded exactly once
        and the saved dial is simply left unchanged.
        """
        if self._finished is not None:
            return self._finished
        result = self._termination()
        if result is None:
            return None

        if not self._reviewed:
            if self.on_review is not None and self._annotations:
                self.on_review()
            self._review_annotations()

        game = chess.pgn.Game.from_board(self._board)
        if self._resigned:
            # The board itself has no outcome; from_board would write "*".
            game.headers["Result"] = "0-1" if self.player_white else "1-0"
        finished = FinishedGame(
            pgn=str(game),
            annotations=list(self._annotations),
            is_practice=self.is_practice,
            bot_strength=self.bot_strength,
            player_white=self.player_white,
            result=result,
            attempted_blunders=self._attempted_blunders,
        )

        if not self._saved:
            self._store.save(finished)
            self._saved = True
        if not self._recorded:
            self._store.record_to_stats(finished)
            self._recorded = True

        # The game now exists on disk exactly once.  Cache it before adapting
        # so a failed strength write cannot make a later call record it again;
        # the saved dial stays stale until a future game retunes from it.
        self._finished = finished
        results = [
            adapt.GameResult.from_record(record)
            for record in self._store.load_game_records()
        ]
        next_strength = adapt.retune(self.bot_strength, results)
        self._store.bot_strength = next_strength
        self.bot_strength = next_strength
        return finished

    def _review_annotations(self) -> None:
        """Fill in the notes the live pass did not produce.

        Every ply without a non-silent note is analysed at
        :data:`REVIEW_DEPTH`: all of them in a clean game, and the bot's moves
        in a practice game.  Player moves the live coach already evaluated
        keep their saved sentence verbatim -- re-running them would be slower,
        shallower and could change the text the player saw.  Review never
        opens a take-back offer.
        """
        previous_depth = getattr(self.coach, "depth", None)
        if isinstance(previous_depth, int):
            self.coach.depth = REVIEW_DEPTH
        try:
            reviewed: list[GameAnnotation] = []
            for annotation in self._annotations:
                if not self._needs_review(annotation):
                    reviewed.append(annotation)
                    continue
                reviewed.append(self._review_annotation(annotation))
            self._annotations = reviewed
        finally:
            if isinstance(previous_depth, int):
                self.coach.depth = previous_depth
        self._reviewed = True

    def _needs_review(self, annotation: GameAnnotation) -> bool:
        """True when this ply still lacks a post-game coach note."""
        if annotation.verdict is not CoachVerdict.SILENT:
            return False
        # Live player moves were already evaluated at the coach's full depth;
        # even a silent verdict is their recorded answer.
        if self.mode is Mode.LIVE_COACH and annotation.is_player:
            return False
        return True

    def _review_annotation(self, annotation: GameAnnotation) -> GameAnnotation:
        """Analyse one stored ply and return the annotated replacement."""
        try:
            before = chess.Board(annotation.fen)
        except ValueError:  # pragma: no cover - stored FENs are valid
            return annotation
        # Keep the evaluate/message pair adjacent: the coach reuses its
        # one-entry analysis cache for the second call.
        verdict = self.coach.evaluate(before, annotation.move_uci)
        text = self.coach.message(before, annotation.move_uci)
        message = None if verdict is CoachVerdict.SILENT else (text or None)
        return replace(annotation, verdict=verdict, message=message)

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
