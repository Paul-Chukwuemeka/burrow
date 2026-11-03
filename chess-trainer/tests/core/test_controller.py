"""Tests for the game controller: turns, take-back, annotations, ending games.

Every test injects a scripted, duck-typed bot (a queue of UCI replies) and a
stub coach that returns canned verdicts, so the whole file is deterministic
and never starts Stockfish.  The controller's own rules of chess come from
python-chess, so the sequences below are checked to be legal when the file is
written -- the controller is then judged on what it does with them, not on
whether the test positions are reachable.

Two corrections to the brief, both forced by the installed python-chess
1.11.2 (see the task report):

* ``board.parse_uci`` has no ``raise_on_error`` keyword; it raises
  ``ValueError`` (``InvalidMoveError`` / ``IllegalMoveError``) instead.  The
  controller catches that and rejects the move, which is the behaviour the
  brief asks for.
* The pinned castling sequence ``e2e4 d7d5 e4d5 e7e5 f1e2 e8g8`` is not legal:
  the black bishop is still on f8 and the knight on g8, so ``e8g8`` cannot
  castle.  The castling take-back test uses the closest legal sequence that
  reaches the same Black kingside castle and keeps the review focus assertion
  (rights + rook squares restored exactly).
"""

from __future__ import annotations

import io

import chess
import chess.pgn
import pytest

from chess_trainer.coach import CoachVerdict
from chess_trainer.controller import (
    RESIGNATION,
    BoardSnapshot,
    FinishedGame,
    GameAnnotation,
    GameController,
    Mode,
    PlayerMoveOutcome,
)
from chess_trainer.store import DEFAULT_BOT_STRENGTH, GameRecord, Store

START = chess.STARTING_FEN


# --- stubs ----------------------------------------------------------------


class ScriptedBot:
    """Duck-typed ``Bot``: hands out canned UCI replies and records calls.

    A real bot always returns a legal move; the queue is filled with legal
    moves by the tests.  Asking for one reply too many is a test bug, so it
    fails loudly rather than silently repeating the last move.
    """

    def __init__(self, *moves: str) -> None:
        self._moves = list(moves)
        self.calls: list[tuple[str, float]] = []

    def choose_move(
        self, board: chess.Board, strength: float, seed: int | None = None
    ) -> str:
        self.calls.append((board.fen(), strength))
        if not self._moves:
            raise AssertionError("controller asked for an unscripted bot move")
        return self._moves.pop(0)


class StubCoach:
    """Duck-typed ``Coach`` with per-move verdicts; records the call order."""

    def __init__(
        self,
        verdicts: dict[str, CoachVerdict] | None = None,
        messages: dict[str, str] | None = None,
        default: CoachVerdict = CoachVerdict.SILENT,
    ) -> None:
        self.verdicts = dict(verdicts or {})
        self.messages = dict(messages or {})
        self.default = default
        self.calls: list[tuple[str, str, str]] = []

    def verdict_for(self, uci: str) -> CoachVerdict:
        return self.verdicts.get(uci, self.default)

    def evaluate(self, board: chess.Board, played_uci: str) -> CoachVerdict:
        self.calls.append(("evaluate", board.fen(), played_uci))
        return self.verdict_for(played_uci)

    def message(self, board: chess.Board, played_uci: str) -> str:
        self.calls.append(("message", board.fen(), played_uci))
        if self.verdict_for(played_uci) is CoachVerdict.SILENT:
            return ""
        return self.messages.get(played_uci, f"stub note for {played_uci}.")


class FakeStore:
    """In-memory stand-in for the parts of ``Store`` the controller uses.

    Task 8 made the controller save, record and retune at the end of every
    game, so controller tests need a store that honours that contract without
    touching disk.  Outcomes are derived from the PGN result header exactly as
    the real store does, which is what makes resignations testable.
    """

    def __init__(self, strength: float = 6.0) -> None:
        self.saved: list[FinishedGame] = []
        self.recorded: list[FinishedGame] = []
        self.records: list[GameRecord] = []
        self._strength = strength

    def save(self, finished: FinishedGame) -> None:
        self.saved.append(finished)

    def record_to_stats(self, finished: FinishedGame) -> None:
        self.recorded.append(finished)
        self.records.append(self._record(finished))

    def load_game_records(self) -> list[GameRecord]:
        return list(self.records)

    @property
    def bot_strength(self) -> float:
        return self._strength

    @bot_strength.setter
    def bot_strength(self, value: float) -> None:
        self._strength = float(value)

    @staticmethod
    def _record(finished: FinishedGame) -> GameRecord:
        game = chess.pgn.read_game(io.StringIO(finished.pgn))
        header = game.headers.get("Result", "*") if game is not None else "*"
        if header == "1/2-1/2":
            outcome = "draw"
        elif header == "1-0":
            outcome = "win" if finished.player_white else "loss"
        elif header == "0-1":
            outcome = "loss" if finished.player_white else "win"
        else:  # pragma: no cover - the controller always writes a header
            outcome = "draw"
        if outcome == "win":
            margin = 5.0
        elif outcome == "loss":
            margin = -5.0
        else:
            margin = 0.0
        return GameRecord(
            result=outcome,
            practice=finished.is_practice,
            blunders=0,
            margin=margin,
            strength=finished.bot_strength,
            date="",
        )


class StrengthlessStore:
    """Minimal duck-typed store with no strength dial.

    Task 6 accepted any store-shaped object; Task 8 reads the saved strength at
    construction, so this guard keeps such a store working (it falls back to
    the shared default instead of raising ``AttributeError``).
    """

    def __init__(self) -> None:
        self.saved: list[FinishedGame] = []
        self.recorded: list[FinishedGame] = []

    def save(self, finished: FinishedGame) -> None:
        self.saved.append(finished)

    def record_to_stats(self, finished: FinishedGame) -> None:
        self.recorded.append(finished)

    def load_game_records(self) -> list[GameRecord]:
        return []


class FlakyStrengthStore(Store):
    """A real store whose first strength write fails, as on a full disk."""

    def __init__(self, data_dir) -> None:
        super().__init__(data_dir)
        self.write_attempts = 0

    @property
    def bot_strength(self) -> float:
        return Store.bot_strength.fget(self)  # type: ignore[attr-defined]

    @bot_strength.setter
    def bot_strength(self, value: float) -> None:
        self.write_attempts += 1
        if self.write_attempts == 1:
            raise OSError("disk full")
        Store.bot_strength.fset(self, value)  # type: ignore[attr-defined]


class FlakyRecordStore(Store):
    """A real store whose first stats append fails, as on a full disk."""

    def __init__(self, data_dir) -> None:
        super().__init__(data_dir)
        self.record_attempts = 0

    def record_to_stats(self, finished: FinishedGame) -> None:
        self.record_attempts += 1
        if self.record_attempts == 1:
            raise OSError("disk full")
        super().record_to_stats(finished)


# --- helpers --------------------------------------------------------------


def play_uci(*ucis: str) -> chess.Board:
    """A fresh board after ``ucis`` (used to compute expected FENs)."""
    board = chess.Board()
    for uci in ucis:
        board.push(board.parse_uci(uci))
    return board


def make_controller(
    *bot_moves: str,
    verdicts: dict[str, CoachVerdict] | None = None,
    messages: dict[str, str] | None = None,
    mode: Mode = Mode.LIVE_COACH,
    player_white: bool = True,
    store: FakeStore | None = None,
) -> tuple[GameController, ScriptedBot, StubCoach]:
    bot = ScriptedBot(*bot_moves)
    coach = StubCoach(verdicts, messages)
    controller = GameController(
        bot, coach, FakeStore() if store is None else store
    )
    controller.new_game(mode, player_white=player_white)
    return controller, bot, coach


# --- starting a game ------------------------------------------------------


def test_new_game_starts_a_clean_game_at_the_starting_position():
    controller, _, coach = make_controller(mode=Mode.CLEAN)

    assert controller.snapshot() == BoardSnapshot(
        ply=0, fen=START, turn_white=True, result=None
    )
    assert controller.is_practice is False
    assert controller.mode is Mode.CLEAN
    assert controller.awaiting_retry is False
    assert controller.annotations == []
    assert controller.finished_game() is None
    assert coach.calls == []


def test_live_coach_game_is_practice():
    controller, _, _ = make_controller()

    assert controller.mode is Mode.LIVE_COACH
    assert controller.is_practice is True


def test_new_game_resets_the_board_and_pending_state():
    controller, _, _ = make_controller(
        verdicts={"e2e4": CoachVerdict.BLUNDER}
    )
    controller.try_player_move("e2e4")
    assert controller.awaiting_retry is True

    controller.new_game(Mode.CLEAN)

    assert controller.snapshot().fen == START
    assert controller.snapshot().ply == 0
    assert controller.annotations == []
    assert controller.awaiting_retry is False
    assert controller.is_practice is False
    assert controller.finished_game() is None


def test_default_bot_strength_is_the_store_default():
    controller, _, _ = make_controller(mode=Mode.CLEAN)

    assert controller.bot_strength == 6.0


def test_the_saved_strength_is_loaded_on_construction(tmp_path):
    store = Store(tmp_path)
    store.bot_strength = 9.5

    controller = GameController(ScriptedBot(), StubCoach(), store)

    assert controller.bot_strength == 9.5


def test_a_duck_typed_store_without_a_strength_dial_still_constructs():
    # Task 6 accepted any store-shaped object.  Loading the saved dial must
    # degrade to the shared default rather than reject such a store.
    controller = GameController(ScriptedBot(), StubCoach(), StrengthlessStore())

    assert controller.bot_strength == DEFAULT_BOT_STRENGTH

    # Ordinary play stays store-free until the game actually ends.
    controller.new_game(Mode.CLEAN)
    assert controller.try_player_move("e2e4").accepted is True


def test_new_game_keeps_the_adapted_bot_strength():
    controller, _, _ = make_controller(mode=Mode.CLEAN)
    controller.bot_strength = 9.5

    controller.new_game(Mode.CLEAN, player_white=False)

    assert controller.bot_strength == 9.5


# --- player moves ---------------------------------------------------------


def test_silent_player_move_is_accepted_and_annotated():
    fen_after = play_uci("e2e4").fen()
    controller, bot, coach = make_controller("e7e5")

    outcome = controller.try_player_move("e2e4")

    assert outcome == PlayerMoveOutcome(
        accepted=True,
        verdict=CoachVerdict.SILENT,
        message=None,
        can_undo=False,
    )
    assert controller.awaiting_retry is False
    assert controller.snapshot() == BoardSnapshot(
        ply=1, fen=fen_after, turn_white=False, result=None
    )
    assert controller.annotations == [
        GameAnnotation(
            ply=1,
            fen=START,
            move_uci="e2e4",
            verdict=CoachVerdict.SILENT,
            message=None,
            is_player=True,
        )
    ]
    # The cheap evaluate -> message pair, same position, in that order.
    assert coach.calls == [
        ("evaluate", START, "e2e4"),
        ("message", START, "e2e4"),
    ]
    # No bot reply until the GUI asks for one.
    assert bot.calls == []


def test_bot_reply_is_appended_and_annotated():
    controller, bot, coach = make_controller("e7e5")
    controller.try_player_move("e2e4")
    calls_before = len(coach.calls)

    assert controller.bot_move() == "e7e5"

    assert controller.snapshot().ply == 2
    assert controller.snapshot().turn_white is True
    assert [a.is_player for a in controller.annotations] == [True, False]
    bot_annotation = controller.annotations[1]
    assert bot_annotation.ply == 2
    assert bot_annotation.fen == play_uci("e2e4").fen()
    assert bot_annotation.move_uci == "e7e5"
    assert bot_annotation.verdict is CoachVerdict.SILENT
    assert bot_annotation.message is None
    assert bot.calls == [(play_uci("e2e4").fen(), 6.0)]
    # The coach only looks at the player's moves.
    assert len(coach.calls) == calls_before


def test_bot_strength_is_passed_to_the_bot():
    controller, bot, _ = make_controller("e7e5", mode=Mode.CLEAN)
    controller.bot_strength = 12.0
    controller.try_player_move("e2e4")

    controller.bot_move()

    assert bot.calls == [(play_uci("e2e4").fen(), 12.0)]


def test_clean_mode_never_asks_the_coach():
    controller, _, coach = make_controller("e7e5", mode=Mode.CLEAN)

    outcome = controller.try_player_move("e2e4")

    assert outcome == PlayerMoveOutcome(
        accepted=True, verdict=None, message=None, can_undo=False
    )
    # The move is still recorded for review, with nothing to say about it.
    assert controller.annotations[0].verdict is CoachVerdict.SILENT
    assert controller.annotations[0].message is None
    controller.bot_move()
    assert coach.calls == []


@pytest.mark.parametrize("uci", ["e2e5", "zzzz", "e2e4e5", "", "0000"])
def test_illegal_or_malformed_move_is_rejected_without_side_effects(uci):
    controller, bot, coach = make_controller("e7e5")

    outcome = controller.try_player_move(uci)

    assert outcome == PlayerMoveOutcome(
        accepted=False, verdict=None, message=None, can_undo=False
    )
    assert controller.snapshot().fen == START
    assert controller.annotations == []
    assert controller.awaiting_retry is False
    assert coach.calls == []
    assert bot.calls == []


def test_move_for_the_bot_side_is_rejected_even_when_legal():
    controller, bot, _ = make_controller("e2e4", mode=Mode.CLEAN, player_white=False)

    # e2e4 is legal, but White is the bot in this game.
    outcome = controller.try_player_move("e2e4")

    assert outcome.accepted is False
    assert controller.snapshot().fen == START
    assert controller.annotations == []
    assert bot.calls == []
    # The bot's own turn still works.
    assert controller.bot_move() == "e2e4"
    assert controller.try_player_move("d7d5").accepted is True


# --- live-coach interruption ------------------------------------------------


@pytest.mark.parametrize(
    "verdict", [CoachVerdict.NOTABLE, CoachVerdict.BLUNDER]
)
def test_actionable_verdict_blocks_the_bot_and_offers_take_back(verdict):
    message = "that lets your opponent back into the game."
    controller, bot, coach = make_controller(
        "e7e5",
        verdicts={"e2e4": verdict},
        messages={"e2e4": message},
    )

    outcome = controller.try_player_move("e2e4")

    assert outcome == PlayerMoveOutcome(
        accepted=True, verdict=verdict, message=message, can_undo=True
    )
    assert controller.awaiting_retry is True
    assert controller.annotations[0].verdict is verdict
    assert controller.annotations[0].message == message
    # Interrupt before the bot replies.
    assert bot.calls == []
    with pytest.raises(RuntimeError):
        controller.bot_move()
    assert bot.calls == []
    assert len(coach.calls) == 2


def test_coach_message_is_persisted_not_regenerated_at_save_time():
    message = "that hands the initiative to your opponent."
    controller, _, coach = make_controller(
        verdicts={"e2e4": CoachVerdict.NOTABLE},
        messages={"e2e4": message},
    )
    outcome = controller.try_player_move("e2e4")
    assert outcome.message == message
    assert controller.annotations[0].message == message

    controller.resign()  # ending the game must not re-ask the coach
    finished = controller.finished_game()

    assert finished is not None
    assert finished.annotations[0].message == message
    assert len(coach.calls) == 2, "evaluate+message only, no regeneration"


def test_a_second_move_while_awaiting_retry_is_rejected():
    controller, _, _ = make_controller(
        "e7e5", verdicts={"e2e4": CoachVerdict.BLUNDER}
    )
    controller.try_player_move("e2e4")

    outcome = controller.try_player_move("d2d4")

    assert outcome.accepted is False
    assert outcome.can_undo is True, "take-back is still available"
    assert controller.snapshot().ply == 1
    assert [a.move_uci for a in controller.annotations] == ["e2e4"]
    assert controller.awaiting_retry is True


# --- take-back --------------------------------------------------------------


def test_undo_reverts_the_blunder_and_allows_a_new_attempt():
    controller, bot, _ = make_controller(
        "e7e5", verdicts={"e2e4": CoachVerdict.BLUNDER}
    )
    controller.try_player_move("e2e4")

    assert controller.undo_player_move() is True

    assert controller.snapshot().fen == START
    assert controller.snapshot().ply == 0
    assert controller.annotations == []
    assert controller.awaiting_retry is False
    # Never pops twice: a second call must be a no-op, even though the board
    # still has a previous move on its stack from the bot.
    assert controller.undo_player_move() is False
    assert controller.snapshot().fen == START

    assert controller.try_player_move("d2d4").accepted is True
    assert [a.move_uci for a in controller.annotations] == ["d2d4"]
    assert controller.bot_move() == "e7e5"


def test_undo_is_only_available_while_awaiting_retry():
    controller, _, _ = make_controller("e7e5")
    assert controller.undo_player_move() is False

    controller.try_player_move("e2e4")  # silent, no take-back offered
    assert controller.awaiting_retry is False
    assert controller.undo_player_move() is False
    assert controller.snapshot().ply == 1
    assert [a.move_uci for a in controller.annotations] == ["e2e4"]


def test_confirm_keeps_the_move_and_lets_the_bot_reply():
    controller, bot, _ = make_controller(
        "e7e5", verdicts={"e2e4": CoachVerdict.BLUNDER}
    )
    controller.try_player_move("e2e4")

    controller.confirm_move()

    assert controller.awaiting_retry is False
    assert controller.snapshot().ply == 1
    assert [a.move_uci for a in controller.annotations] == ["e2e4"]
    assert controller.bot_move() == "e7e5"
    assert controller.snapshot().ply == 2


def test_confirm_move_without_a_pending_retry_is_a_noop():
    controller, _, _ = make_controller(mode=Mode.CLEAN)

    controller.confirm_move()

    assert controller.awaiting_retry is False
    assert controller.snapshot().fen == START


def test_annotations_property_is_a_read_only_view():
    controller, _, _ = make_controller("e7e5", mode=Mode.CLEAN)
    controller.try_player_move("e2e4")

    view = controller.annotations
    view.clear()

    assert [a.move_uci for a in controller.annotations] == ["e2e4"]


# --- bot guards -------------------------------------------------------------


def test_bot_move_rejects_the_wrong_turn():
    controller, bot, _ = make_controller("e7e5", mode=Mode.CLEAN)

    with pytest.raises(RuntimeError):
        controller.bot_move()

    assert bot.calls == []
    assert controller.snapshot().fen == START


def test_bot_move_rejects_an_illegal_reply_without_corrupting_the_board():
    controller, _, _ = make_controller("e2e4", mode=Mode.CLEAN)
    controller.try_player_move("e2e4")

    with pytest.raises(ValueError):
        controller.bot_move()

    assert controller.snapshot().fen == play_uci("e2e4").fen()
    assert [a.is_player for a in controller.annotations] == [True]


def test_bot_move_rejects_a_finished_game():
    controller, _, _ = make_controller(mode=Mode.CLEAN)

    controller.resign()

    with pytest.raises(RuntimeError):
        controller.bot_move()


# --- ending a game ----------------------------------------------------------


def test_resign_finishes_a_practice_game_as_a_player_loss():
    controller, _, _ = make_controller(
        verdicts={"e2e4": CoachVerdict.BLUNDER}
    )
    controller.try_player_move("e2e4")
    controller.confirm_move()

    controller.resign()

    finished = controller.finished_game()
    assert finished is not None
    assert finished.result is RESIGNATION
    assert finished.is_practice is True
    assert finished.player_white is True
    assert finished.bot_strength == 6.0
    assert [a.move_uci for a in finished.annotations] == ["e2e4"]
    assert '[Result "0-1"]' in finished.pgn
    assert "1. e4" in finished.pgn
    assert controller.snapshot().result is RESIGNATION
    assert controller.awaiting_retry is False


def test_resign_before_any_move_finishes_a_zero_move_game():
    controller, _, _ = make_controller(mode=Mode.CLEAN, player_white=False)

    controller.resign()

    finished = controller.finished_game()
    assert finished is not None
    assert finished.annotations == []
    assert finished.is_practice is False
    assert finished.player_white is False
    assert finished.result is RESIGNATION
    assert '[Result "1-0"]' in finished.pgn
    assert controller.snapshot().ply == 0
    assert controller.snapshot().result is RESIGNATION


def test_resign_while_awaiting_retry_keeps_the_move_and_ends_the_game():
    controller, _, _ = make_controller(
        verdicts={"e2e4": CoachVerdict.BLUNDER}
    )
    controller.try_player_move("e2e4")

    controller.resign()

    assert controller.awaiting_retry is False
    assert [a.move_uci for a in controller.annotations] == ["e2e4"]
    assert controller.finished_game().result is RESIGNATION  # type: ignore[union-attr]


def test_resign_does_not_override_a_checkmate():
    # Player is Black and delivers Fool's mate.
    controller, bot, _ = make_controller(
        "f2f3", "g2g4", mode=Mode.CLEAN, player_white=False
    )
    assert controller.bot_move() == "f2f3"
    assert controller.try_player_move("e7e5").accepted is True
    assert controller.bot_move() == "g2g4"
    assert controller.try_player_move("d8h4").accepted is True
    assert controller.snapshot().result is chess.Termination.CHECKMATE

    controller.resign()

    finished = controller.finished_game()
    assert finished is not None
    assert finished.result is chess.Termination.CHECKMATE
    assert '[Result "0-1"]' in finished.pgn


def test_player_move_can_end_the_game():
    # Player is White and mates with Qh5.
    controller, bot, coach = make_controller("f7f6", "g7g5", mode=Mode.CLEAN)
    assert controller.try_player_move("e2e4").accepted is True
    assert controller.bot_move() == "f7f6"
    assert controller.try_player_move("d2d4").accepted is True
    assert controller.bot_move() == "g7g5"

    outcome = controller.try_player_move("d1h5")

    assert outcome.accepted is True
    assert controller.awaiting_retry is False
    assert controller.snapshot().result is chess.Termination.CHECKMATE
    finished = controller.finished_game()
    assert finished is not None
    assert finished.result is chess.Termination.CHECKMATE
    assert '[Result "1-0"]' in finished.pgn
    assert "Qh5#" in finished.pgn
    assert [a.ply for a in finished.annotations] == [1, 2, 3, 4, 5]
    # The end-of-game review pass is the only coach work a clean game sees,
    # and every move here is genuinely silent.
    assert len(coach.calls) == 2 * 5
    assert {a.verdict for a in finished.annotations} == {CoachVerdict.SILENT}
    # Nothing can be played now.
    assert controller.try_player_move("a7a6").accepted is False
    with pytest.raises(RuntimeError):
        controller.bot_move()


def test_bot_move_can_end_the_game():
    controller, _, _ = make_controller("e7e5", "d8h4", mode=Mode.CLEAN)
    assert controller.try_player_move("f2f3").accepted is True
    assert controller.bot_move() == "e7e5"
    assert controller.try_player_move("g2g4").accepted is True

    assert controller.bot_move() == "d8h4"

    assert controller.snapshot().result is chess.Termination.CHECKMATE
    finished = controller.finished_game()
    assert finished is not None
    assert finished.result is chess.Termination.CHECKMATE
    assert finished.annotations[-1].is_player is False
    assert finished.annotations[-1].move_uci == "d8h4"
    assert '[Result "0-1"]' in finished.pgn


def test_finished_game_is_a_snapshot_copy():
    controller, _, _ = make_controller("e7e5", mode=Mode.CLEAN)
    controller.try_player_move("e2e4")
    controller.bot_move()
    controller.resign()

    first = controller.finished_game()
    second = controller.finished_game()

    assert first is not None and second is not None
    assert first == second
    assert first.annotations is not second.annotations


# --- the end-of-game store hookup ------------------------------------------


def test_a_non_terminal_move_writes_nothing(tmp_path):
    store = Store(tmp_path)
    store.bot_strength = 7.25
    controller = GameController(ScriptedBot("e7e5"), StubCoach(), store)
    controller.new_game(Mode.CLEAN)

    assert controller.try_player_move("e2e4").accepted is True
    assert controller.bot_move() == "e7e5"

    assert store.load_stats().total == 0
    assert list((tmp_path / "games").rglob("*.pgn")) == []
    assert store.bot_strength == 7.25


def test_resign_saves_records_and_retunes_the_strength(tmp_path):
    store = Store(tmp_path)
    controller = GameController(ScriptedBot(), StubCoach(), store)
    controller.new_game(Mode.CLEAN, player_white=True)

    controller.resign()
    finished = controller.finished_game()

    assert finished is not None
    stats = store.load_stats()
    assert stats.total == 1
    assert stats.losses == 1
    assert stats.practice_total == 0
    # The record carries the strength the game was played at; the live dial
    # has already moved down after the loss.
    assert finished.bot_strength == 6.0
    assert controller.bot_strength < 6.0
    assert store.bot_strength == controller.bot_strength
    assert len(list((tmp_path / "games").rglob("*.pgn"))) == 1


def test_the_game_is_recorded_when_the_player_is_checkmated(tmp_path):
    # Player is White and gets mated by the scripted bot, so the save happens
    # from the move path, not from resign().
    store = Store(tmp_path)
    controller = GameController(
        ScriptedBot("e7e5", "d8h4"), StubCoach(), store
    )
    controller.new_game(Mode.CLEAN, player_white=True)
    assert controller.try_player_move("f2f3").accepted is True
    assert controller.bot_move() == "e7e5"
    assert controller.try_player_move("g2g4").accepted is True
    assert controller.bot_move() == "d8h4"

    stats = store.load_stats()
    assert stats.total == 1
    assert stats.losses == 1
    assert store.bot_strength < 6.0


def test_the_game_is_recorded_when_the_player_wins(tmp_path):
    # Player is Black and delivers Fool's mate through try_player_move.
    store = Store(tmp_path)
    controller = GameController(
        ScriptedBot("f2f3", "g2g4"), StubCoach(), store
    )
    controller.new_game(Mode.CLEAN, player_white=False)
    assert controller.bot_move() == "f2f3"
    assert controller.try_player_move("e7e5").accepted is True
    assert controller.bot_move() == "g2g4"
    assert controller.try_player_move("d8h4").accepted is True

    stats = store.load_stats()
    assert stats.total == 1
    assert stats.wins == 1
    assert store.bot_strength > 6.0


def test_finished_game_finalises_only_once(tmp_path):
    store = Store(tmp_path)
    controller = GameController(ScriptedBot(), StubCoach(), store)
    controller.new_game(Mode.CLEAN)

    controller.resign()
    first = controller.finished_game()
    second = controller.finished_game()

    assert first == second
    assert first is not None and second is not None
    assert first.annotations is not second.annotations
    assert store.load_stats().total == 1
    assert len(list((tmp_path / "games").rglob("*.pgn"))) == 1
    # Repeating the query must not retune a second time.
    assert controller.bot_strength == store.bot_strength


def test_the_adapted_strength_survives_a_controller_restart(tmp_path):
    store = Store(tmp_path)
    first = GameController(ScriptedBot(), StubCoach(), store)
    first.new_game(Mode.CLEAN)
    first.resign()
    adapted = first.bot_strength

    restarted = GameController(ScriptedBot(), StubCoach(), store)

    assert adapted < 6.0
    assert restarted.bot_strength == adapted


def test_a_failed_strength_write_does_not_duplicate_the_game(tmp_path):
    store = FlakyStrengthStore(tmp_path)
    controller = GameController(ScriptedBot(), StubCoach(), store)
    controller.new_game(Mode.CLEAN)

    # resign() finalises immediately, so the write failure surfaces there.
    with pytest.raises(OSError):
        controller.resign()

    assert store.load_stats().total == 1
    assert len(list((tmp_path / "games").rglob("*.pgn"))) == 1
    assert store.write_attempts == 1
    # The dial stays stale on both sides rather than adapting twice.
    assert store.bot_strength == DEFAULT_BOT_STRENGTH
    assert controller.bot_strength == DEFAULT_BOT_STRENGTH

    # The record is cached: asking again must not save, record, or retry the
    # strength write.
    finished = controller.finished_game()

    assert finished is not None
    assert store.load_stats().total == 1
    assert len(list((tmp_path / "games").rglob("*.pgn"))) == 1
    assert store.write_attempts == 1
    assert store.bot_strength == DEFAULT_BOT_STRENGTH


def test_a_failed_record_is_retried_without_saving_the_pgn_twice(tmp_path):
    store = FlakyRecordStore(tmp_path)
    controller = GameController(ScriptedBot(), StubCoach(), store)
    controller.new_game(Mode.CLEAN)

    with pytest.raises(OSError):
        controller.resign()

    assert store.record_attempts == 1
    assert store.load_stats().total == 0
    # The PGN from the first attempt is kept and not written again.
    assert len(list((tmp_path / "games").rglob("*.pgn"))) == 1

    finished = controller.finished_game()

    assert finished is not None
    assert store.record_attempts == 2
    assert store.load_stats().total == 1
    assert len(list((tmp_path / "games").rglob("*.pgn"))) == 1
    assert controller.bot_strength == store.bot_strength


def test_practice_games_are_saved_with_the_practice_flag(tmp_path):
    store = Store(tmp_path)
    controller = GameController(
        ScriptedBot(), StubCoach(verdicts={"e2e4": CoachVerdict.BLUNDER}), store
    )
    controller.new_game(Mode.LIVE_COACH)
    controller.try_player_move("e2e4")
    controller.confirm_move()

    controller.resign()
    finished = controller.finished_game()

    assert finished is not None
    stats = store.load_stats()
    assert stats.total == 1
    assert stats.practice_total == 1
    assert store.load_game_records()[0].practice is True
    sidecars = list((tmp_path / "games").rglob("*.annotations.json"))
    assert len(sidecars) == 1


# --- the post-game review pass (C1 / I3) -----------------------------------


def test_clean_game_review_pass_annotates_moves_and_counts_blunders(tmp_path):
    # A clean game records no live notes; finalisation must review every ply
    # so the saved game and its stats carry the player's mistakes.
    store = Store(tmp_path)
    message = "that loses your queen on d5."
    coach = StubCoach(
        verdicts={"e2e4": CoachVerdict.BLUNDER},
        messages={"e2e4": message},
    )
    controller = GameController(ScriptedBot("e7e5"), coach, store)
    controller.new_game(Mode.CLEAN)
    assert controller.try_player_move("e2e4").accepted is True
    assert controller.bot_move() == "e7e5"

    controller.resign()
    finished = controller.finished_game()

    assert finished is not None
    assert [a.move_uci for a in finished.annotations] == ["e2e4", "e7e5"]
    player_note = finished.annotations[0]
    assert player_note.is_player is True
    assert player_note.verdict is CoachVerdict.BLUNDER
    assert player_note.message == message
    stats = store.load_stats()
    assert stats.games[0].blunders == 1
    assert stats.blunders_per_game == [1.0]


def test_live_game_review_pass_annotates_a_bot_slip(tmp_path):
    # The live coach never watched the bot; the review pass adds the one-line
    # note, and a bot slip never counts as the player's blunder.
    store = Store(tmp_path)
    message = "that leaves your knight on f6 where it can be taken."
    coach = StubCoach(
        verdicts={"e7e5": CoachVerdict.BLUNDER},
        messages={"e7e5": message},
    )
    controller = GameController(ScriptedBot("e7e5"), coach, store)
    controller.new_game(Mode.LIVE_COACH)
    assert controller.try_player_move("e2e4").accepted is True
    assert controller.bot_move() == "e7e5"

    controller.resign()
    finished = controller.finished_game()

    assert finished is not None
    bot_note = finished.annotations[1]
    assert bot_note.is_player is False
    assert bot_note.verdict is CoachVerdict.BLUNDER
    assert bot_note.message == message
    assert controller.awaiting_retry is False, "review never offers a take-back"
    assert store.load_stats().games[0].blunders == 0


def test_live_annotations_are_preserved_verbatim_by_the_review_pass(tmp_path):
    store = Store(tmp_path)
    message = "that hands the initiative to your opponent."
    coach = StubCoach(
        verdicts={"e2e4": CoachVerdict.BLUNDER},
        messages={"e2e4": message},
    )
    controller = GameController(ScriptedBot("e7e5"), coach, store)
    controller.new_game(Mode.LIVE_COACH)
    outcome = controller.try_player_move("e2e4")
    assert outcome.message == message
    live_calls = list(coach.calls)

    controller.confirm_move()
    controller.bot_move()
    controller.resign()
    finished = controller.finished_game()

    assert finished is not None
    assert finished.annotations[0].verdict is CoachVerdict.BLUNDER
    assert finished.annotations[0].message == message
    # The live sentence was not regenerated: the review only looked at the
    # bot's reply.
    assert coach.calls[: len(live_calls)] == live_calls
    assert [call for call in coach.calls if call[2] == "e2e4"] == live_calls


# --- take-back restores special moves exactly ------------------------------


def test_undo_after_castling_restores_rights():
    """Review Focus 1: undoing O-O puts king, rook and rights back exactly.

    The brief's sequence (e2e4 d7d5 e4d5 e7e5 f1e2 e8g8) cannot castle with
    the bishop still on f8, so this is the closest legal Black kingside
    castle: e2e4 d7d5 e4d5 Ng8f6 Be2 e7e5 Nf3 Be7 Nc3 O-O.
    """
    controller, bot, _ = make_controller(
        "e2e4",
        "e4d5",
        "f1e2",
        "g1f3",
        "b1c3",
        verdicts={"e8g8": CoachVerdict.BLUNDER},
        messages={"e8g8": "that hands the initiative to your opponent."},
        player_white=False,
    )

    assert controller.bot_move() == "e2e4"
    assert controller.try_player_move("d7d5").accepted is True
    assert controller.bot_move() == "e4d5"
    assert controller.try_player_move("g8f6").accepted is True
    assert controller.bot_move() == "f1e2"
    assert controller.try_player_move("e7e5").accepted is True
    assert controller.bot_move() == "g1f3"
    assert controller.try_player_move("f8e7").accepted is True
    assert controller.bot_move() == "b1c3"

    before = controller.snapshot().fen
    assert controller.board.has_kingside_castling_rights(chess.BLACK)

    outcome = controller.try_player_move("e8g8")

    assert outcome.accepted is True and outcome.can_undo is True
    assert controller.awaiting_retry is True
    assert controller.board.piece_at(chess.G8) == chess.Piece(
        chess.KING, chess.BLACK
    )
    assert controller.board.piece_at(chess.F8) == chess.Piece(
        chess.ROOK, chess.BLACK
    )
    assert not controller.board.has_kingside_castling_rights(chess.BLACK)

    assert controller.undo_player_move() is True

    board = controller.board
    assert board.fen() == before
    assert board.piece_at(chess.E8) == chess.Piece(chess.KING, chess.BLACK)
    assert board.piece_at(chess.H8) == chess.Piece(chess.ROOK, chess.BLACK)
    assert board.piece_at(chess.F8) is None
    assert board.piece_at(chess.G8) is None
    assert board.has_kingside_castling_rights(chess.BLACK)
    assert controller.awaiting_retry is False
    # The pending castling annotation is gone; the last one is the bot's Nc3.
    assert controller.annotations[-1].move_uci == "b1c3"
    assert controller.annotations[-1].is_player is False


def test_undo_after_en_passant_restores_the_captured_pawn_and_ep_square():
    controller, _, _ = make_controller(
        "a7a6",
        "d7d5",
        verdicts={"e5d6": CoachVerdict.BLUNDER},
        player_white=True,
    )
    assert controller.try_player_move("e2e4").accepted is True
    assert controller.bot_move() == "a7a6"
    assert controller.try_player_move("e4e5").accepted is True

    assert controller.bot_move() == "d7d5"
    before = controller.snapshot().fen
    assert controller.board.ep_square == chess.D6

    outcome = controller.try_player_move("e5d6")

    assert outcome.accepted is True and outcome.can_undo is True
    assert controller.board.piece_at(chess.D6) == chess.Piece(
        chess.PAWN, chess.WHITE
    )
    assert controller.board.piece_at(chess.D5) is None, "captured en passant"

    assert controller.undo_player_move() is True

    board = controller.board
    assert board.fen() == before
    assert board.piece_at(chess.D5) == chess.Piece(chess.PAWN, chess.BLACK)
    assert board.piece_at(chess.E5) == chess.Piece(chess.PAWN, chess.WHITE)
    assert board.piece_at(chess.D6) is None
    assert board.ep_square == chess.D6
    assert board.turn is chess.WHITE


def test_undo_after_promotion_restores_the_pawn_and_the_captured_rook():
    controller, _, _ = make_controller(
        "h7h5",
        "h5h4",
        "h4h3",
        "h3g2",
        verdicts={"b7a8q": CoachVerdict.BLUNDER},
        player_white=True,
    )
    for move, reply in (
        ("a2a4", "h7h5"),
        ("a4a5", "h5h4"),
        ("a5a6", "h4h3"),
        ("a6b7", "h3g2"),
    ):
        assert controller.try_player_move(move).accepted is True
        assert controller.bot_move() == reply

    before = controller.snapshot().fen
    assert controller.board.piece_at(chess.A8) == chess.Piece(
        chess.ROOK, chess.BLACK
    )
    assert controller.board.piece_at(chess.B7) == chess.Piece(
        chess.PAWN, chess.WHITE
    )

    outcome = controller.try_player_move("b7a8q")

    assert outcome.accepted is True and outcome.can_undo is True
    assert controller.board.piece_at(chess.A8) == chess.Piece(
        chess.QUEEN, chess.WHITE
    )
    assert controller.board.piece_at(chess.B7) is None

    assert controller.undo_player_move() is True

    board = controller.board
    assert board.fen() == before
    assert board.piece_at(chess.A8) == chess.Piece(chess.ROOK, chess.BLACK)
    assert board.piece_at(chess.B7) == chess.Piece(chess.PAWN, chess.WHITE)
    assert board.piece_at(chess.G2) == chess.Piece(chess.PAWN, chess.BLACK)


def test_finished_game_fields_are_the_pinned_interface():
    controller, _, _ = make_controller(mode=Mode.CLEAN)
    controller.resign()

    finished = controller.finished_game()
    assert isinstance(finished, FinishedGame)
    assert set(finished.__dataclass_fields__) == {
        "pgn",
        "annotations",
        "is_practice",
        "bot_strength",
        "player_white",
        "result",
    }
    assert set(PlayerMoveOutcome.__dataclass_fields__) == {
        "accepted",
        "verdict",
        "message",
        "can_undo",
    }
    assert set(GameAnnotation.__dataclass_fields__) == {
        "ply",
        "fen",
        "move_uci",
        "verdict",
        "message",
        "is_player",
    }
    assert set(BoardSnapshot.__dataclass_fields__) == {
        "ply",
        "fen",
        "turn_white",
        "result",
    }
