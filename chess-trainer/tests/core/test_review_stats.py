"""Headless tests for the review window, stats screen and saved-game history.

Qt runs with the ``offscreen`` platform plugin, so the tests need no display.
The games are built exactly like the controller builds them: one annotation
per ply, with the FEN the move was played in.  The castling test is the one
that matters most -- review must restore the position from stored FENs rather
than guess from SAN.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import chess
import chess.pgn
import pytest

pytest.importorskip("PyQt6")

from PyQt6.QtWidgets import QApplication

from chess_trainer.coach import CoachVerdict
from chess_trainer.controller import (
    RESIGNATION,
    BoardSnapshot,
    FinishedGame,
    GameAnnotation,
    Mode,
)
from chess_trainer.gui.review_window import (
    ReviewGame,
    ReviewWindow,
    SavedGameRef,
    build_steps,
    list_saved_games,
    load_saved_game,
    review_from_finished,
)
from chess_trainer.gui.stats_dialog import StatsDialog
from chess_trainer.store import Store

START = chess.STARTING_FEN


@pytest.fixture(scope="session")
def qapp():
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    return app


# --- helpers --------------------------------------------------------------


def make_finished(
    moves: tuple[str, ...],
    *,
    practice: bool = False,
    player_white: bool = True,
    pgn_result: str | None = None,
    result: chess.Termination = chess.Termination.CHECKMATE,
    notes: dict[int, tuple[CoachVerdict, str | None]] | None = None,
    bot_notes: dict[int, tuple[CoachVerdict, str | None]] | None = None,
) -> FinishedGame:
    """A game with one annotation per ply, FENs taken before each move."""
    board = chess.Board()
    annotations: list[GameAnnotation] = []
    notes = notes or {}
    bot_notes = bot_notes or {}
    for ply, uci in enumerate(moves, start=1):
        fen = board.fen()
        board.push_uci(uci)
        is_player = (ply % 2 == 1) == player_white
        source = notes if is_player else bot_notes
        verdict, message = source.get(ply, (CoachVerdict.SILENT, None))
        annotations.append(
            GameAnnotation(
                ply=ply,
                fen=fen,
                move_uci=uci,
                verdict=verdict,
                message=message,
                is_player=is_player,
            )
        )
    game = chess.pgn.Game.from_board(board)
    if pgn_result is not None:
        game.headers["Result"] = pgn_result
    return FinishedGame(
        pgn=str(game),
        annotations=annotations,
        is_practice=practice,
        bot_strength=6.0,
        player_white=player_white,
        result=result,
    )


CASTLING_MOVES = (
    "e2e4",
    "e7e5",
    "g1f3",
    "b8c6",
    "f1c4",
    "g8f6",
    "e1g1",
    "f8c5",
)


def save_and_record(store: Store, game: FinishedGame) -> Path:
    path = store.save(game)
    store.record_to_stats(game)
    return path


# --- saved-game discovery -------------------------------------------------


def test_list_saved_games_reads_pgn_sidecar_pairs(tmp_path: Path, qapp) -> None:
    store = Store(tmp_path)
    game = make_finished(
        CASTLING_MOVES,
        practice=True,
        pgn_result="0-1",
        notes={
            3: (CoachVerdict.BLUNDER, "that loses your queen on d5."),
        },
    )
    save_and_record(store, game)

    refs = list_saved_games(store)

    assert len(refs) == 1
    ref = refs[0]
    assert ref.practice is True
    assert ref.mode == "Practice"
    assert ref.result == "loss"
    assert ref.blunders == 1
    assert ref.bot_strength == 6.0
    assert ref.player_white is True
    assert ref.path.suffix == ".pgn"
    assert ref.path.with_name(ref.path.stem + ".annotations.json").is_file()


def test_load_saved_game_preserves_annotations_verbatim(tmp_path: Path, qapp) -> None:
    store = Store(tmp_path)
    message = "that loses your queen on d5."
    game = make_finished(
        CASTLING_MOVES,
        practice=True,
        pgn_result="0-1",
        notes={3: (CoachVerdict.BLUNDER, message)},
    )
    save_and_record(store, game)

    loaded = list_saved_games(store)[0].load()

    assert loaded.practice is True
    assert loaded.result == "loss"
    assert len(loaded.annotations) == len(CASTLING_MOVES)
    assert loaded.annotations[2].message == message
    assert loaded.annotations[2].verdict is CoachVerdict.BLUNDER
    assert loaded.path is not None


def test_corrupt_sidecar_is_skipped(tmp_path: Path, qapp) -> None:
    store = Store(tmp_path)
    path = store.save(make_finished(("e2e4", "e7e5")))
    path.with_name(path.stem + ".annotations.json").write_text(
        "not json", encoding="utf-8"
    )

    assert list_saved_games(store) == []


def test_non_utf8_pgn_is_skipped_and_stats_still_opens(tmp_path: Path, qapp) -> None:
    store = Store(tmp_path)
    good_path = store.save(make_finished(("e2e4", "e7e5")))

    # A valid JSON sidecar with no usable result, next to a PGN whose bytes
    # are not UTF-8.  Reading the PGN used to raise UnicodeDecodeError out of
    # list_saved_games() and crash StatsDialog.refresh().
    games_dir = tmp_path / "games" / "2026-11-03"
    games_dir.mkdir(parents=True, exist_ok=True)
    broken_path = games_dir / "20261103T235959000000-broken.pgn"
    broken_path.write_bytes(b"\xff\xfe\x00not a UTF-8 PGN")
    broken_path.with_name(broken_path.stem + ".annotations.json").write_text(
        json.dumps(
            {
                "date": "2026-11-03T23:59:59+00:00",
                "practice": False,
                "annotations": [],
            }
        ),
        encoding="utf-8",
    )

    refs = list_saved_games(store)
    assert [ref.path for ref in refs] == [good_path]

    dialog = StatsDialog(store)
    try:
        assert dialog._history.count() == 1
        assert dialog.saved_games[0].path == good_path
    finally:
        dialog.close()

    # Opening the corrupt pair directly also degrades instead of raising; the
    # saved annotations still render and the PGN fallback is simply absent.
    broken_ref = SavedGameRef(
        path=broken_path,
        date="2026-11-03T23:59:59+00:00",
        result="",
        practice=False,
        blunders=0,
        bot_strength=6.0,
        player_white=True,
        resignation=False,
    )
    loaded = load_saved_game(broken_ref)
    assert loaded.pgn is None
    assert loaded.annotations == []


def test_missing_annotation_list_falls_back_to_pgn(tmp_path: Path, qapp) -> None:
    store = Store(tmp_path)
    path = store.save(make_finished(CASTLING_MOVES))
    sidecar = path.with_name(path.stem + ".annotations.json")
    payload = json.loads(sidecar.read_text(encoding="utf-8"))
    payload["annotations"] = []
    sidecar.write_text(json.dumps(payload), encoding="utf-8")

    loaded = list_saved_games(store)[0].load()
    steps = build_steps(loaded)

    replay = chess.Board()
    for uci in CASTLING_MOVES[:7]:
        replay.push_uci(uci)

    assert len(steps) == len(CASTLING_MOVES) + 1
    assert steps[7].san == "O-O"
    assert steps[7].fen == replay.fen()


# --- replay ---------------------------------------------------------------


def test_build_steps_restores_castling_position_exactly(qapp) -> None:
    game = make_finished(CASTLING_MOVES)
    review = review_from_finished(game)
    steps = build_steps(review)

    replay = chess.Board()
    for uci in CASTLING_MOVES:
        replay.push_uci(uci)

    assert len(steps) == len(CASTLING_MOVES) + 1
    assert steps[0].fen == START
    assert steps[-1].fen == replay.fen()
    assert steps[7].san == "O-O"
    assert steps[7].last_move is not None
    assert steps[7].last_move.uci() == "e1g1"
    king = chess.Board(steps[7].fen).piece_at(chess.G1)
    rook = chess.Board(steps[7].fen).piece_at(chess.F1)
    assert king is not None and king.piece_type == chess.KING
    assert rook is not None and rook.piece_type == chess.ROOK


def test_build_steps_returns_start_for_zero_move_game(qapp) -> None:
    game = make_finished((), pgn_result="1/2-1/2")
    steps = build_steps(review_from_finished(game))

    assert len(steps) == 1
    assert steps[0].fen == START


# --- review window --------------------------------------------------------


def test_review_window_shows_practice_and_verbatim_coach_note(qapp) -> None:
    message = "that loses your queen on d5."
    game = make_finished(
        CASTLING_MOVES,
        practice=True,
        pgn_result="0-1",
        notes={3: (CoachVerdict.BLUNDER, message)},
    )
    window = ReviewWindow(review_from_finished(game))
    try:
        assert "Practice" in window.windowTitle()
        window.show_ply(3)
        assert window.current_ply == 3
        assert window._reason.text() == message
        assert window._verdict.text() == "Blunder"
        assert "Nf3" in window._move_label.text()
        assert window._board_widget._board.fen() == window.steps[3].fen
    finally:
        window.close()


def test_review_window_restores_castled_board_when_stepping(qapp) -> None:
    window = ReviewWindow(review_from_finished(make_finished(CASTLING_MOVES)))
    try:
        window.show_ply(7)
        board = window._board_widget._board
        assert board.fen() == window.steps[7].fen
        assert board.piece_at(chess.G1).piece_type == chess.KING
        assert board.piece_at(chess.F1).piece_type == chess.ROOK
        window.show_ply(6)
        assert window._board_widget._board.piece_at(chess.E1).piece_type == chess.KING
    finally:
        window.close()


def test_bot_notes_are_brief(qapp) -> None:
    game = make_finished(
        CASTLING_MOVES,
        practice=True,
        bot_notes={4: (CoachVerdict.NOTABLE, "that leaves a pawn loose.")},
    )
    window = ReviewWindow(review_from_finished(game))
    try:
        window.show_ply(4)
        assert window._reason.text() == "Coach: that leaves a pawn loose."
        assert "8pt" in window._reason.styleSheet()
    finally:
        window.close()


def test_review_from_resignation_labels_the_result(qapp) -> None:
    game = make_finished(
        ("e2e4",), practice=False, pgn_result="0-1", result=RESIGNATION
    )
    review = review_from_finished(game)

    assert review.result == "loss"
    assert review.resignation is True
    assert review.title == "Game review \u2014 Clean \u2014 You resigned"


# --- stats dialog ---------------------------------------------------------


def _seed_stats(store: Store) -> None:
    save_and_record(
        store,
        make_finished(
            ("e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6"),
            practice=True,
            pgn_result="1-0",
            notes={3: (CoachVerdict.BLUNDER, "that loses your queen on d5.")},
            bot_notes={4: (CoachVerdict.BLUNDER, "a pawn was hanging.")},
        ),
    )
    save_and_record(
        store,
        make_finished(
            ("e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6"),
            practice=True,
            pgn_result="0-1",
        ),
    )
    save_and_record(
        store,
        make_finished(
            ("e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6"),
            practice=False,
            pgn_result="1-0",
            notes={
                1: (CoachVerdict.BLUNDER, "that drops a pawn."),
                3: (CoachVerdict.BLUNDER, "that loses your queen on d5."),
            },
        ),
    )
    save_and_record(
        store,
        make_finished(
            ("e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6"),
            practice=False,
            pgn_result="1/2-1/2",
        ),
    )


def test_stats_dialog_separates_practice_and_clean(tmp_path: Path, qapp) -> None:
    store = Store(tmp_path)
    _seed_stats(store)

    dialog = StatsDialog(store)
    try:
        labels = dialog._summary_labels
        assert labels[("practice", "games")].text() == "2"
        assert labels[("clean", "games")].text() == "2"
        assert labels[("all", "games")].text() == "4"
        assert labels[("practice", "wins")].text() == "1"
        assert labels[("practice", "losses")].text() == "1"
        assert labels[("clean", "wins")].text() == "1"
        assert labels[("clean", "draws")].text() == "1"
        assert labels[("all", "wins")].text() == "2"
        assert labels[("all", "losses")].text() == "1"
        assert labels[("all", "draws")].text() == "1"
        assert labels[("practice", "blunders")].text() == "0.5"
        assert labels[("clean", "blunders")].text() == "1.0"
        assert labels[("all", "blunders")].text() == "0.8"
    finally:
        dialog.close()


def test_stats_dialog_trend_and_history_open_review(tmp_path: Path, qapp) -> None:
    store = Store(tmp_path)
    _seed_stats(store)
    dialog = StatsDialog(store)
    received: list[ReviewGame] = []
    dialog.review_requested.connect(received.append)
    try:
        assert dialog._trend.points == [1.0, 0.0, 1.0, 0.5]
        assert len(dialog.saved_games) == 4
        assert dialog._history.count() == 4
        assert "blunders" in dialog._history.item(0).text()

        dialog._history.setCurrentRow(0)
        dialog._review_selected()
        assert len(received) == 1
        assert received[0].path is not None
        assert received[0].annotations
    finally:
        dialog.close()


def test_stats_dialog_handles_no_games(tmp_path: Path, qapp) -> None:
    dialog = StatsDialog(Store(tmp_path))
    try:
        assert dialog._summary_labels[("all", "games")].text() == "0"
        assert dialog._summary_labels[("all", "blunders")].text() == "\u2014"
        assert dialog._trend.points == []
        assert dialog._history.count() == 0
        assert dialog._empty.isVisibleTo(dialog)
    finally:
        dialog.close()


# --- main-window hook -----------------------------------------------------


class _StubController:
    """Just enough controller for MainWindow's constructor."""

    def __init__(self) -> None:
        self.board = chess.Board()
        self.player_white = True
        self.bot_strength = 6.0
        self.mode = Mode.LIVE_COACH

    def new_game(self, mode: Mode) -> None:
        self.mode = mode
        self.board = chess.Board()

    def snapshot(self) -> BoardSnapshot:
        return BoardSnapshot(ply=0, fen=self.board.fen(), turn_white=True, result=None)


def test_main_window_opens_review_on_game_finished(tmp_path: Path, qapp) -> None:
    from chess_trainer.gui.main_window import MainWindow

    window = MainWindow(_StubController(), Store(tmp_path))
    try:
        game = make_finished(("e2e4", "e7e5"), practice=True)
        window.game_finished.emit(game)
        assert len(window._review_windows) == 1
        assert "Practice" in window._review_windows[0].windowTitle()
    finally:
        window.close()


def test_main_window_explains_the_review_pass(tmp_path: Path, qapp) -> None:
    from chess_trainer.gui.main_window import MainWindow

    window = MainWindow(_StubController(), Store(tmp_path))
    try:
        # The controller calls this hook on the worker thread; the window
        # wires it to a queued signal that sets the status line.
        window._controller.on_review()
        assert window._status.text() == "Reviewing your game\u2026"
    finally:
        window.close()
