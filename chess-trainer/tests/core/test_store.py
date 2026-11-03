"""Tests for local persistence: games, cumulative stats and bot strength.

Every test builds its own :class:`Store` on ``tmp_path``; the real
``chess-trainer/data/`` directory is never touched.  Games are constructed
from real boards with python-chess (``Game.from_board``), the same way the
controller produces them, so the PGN round-trips are honest.

Two product rules are checked explicitly:

* corrupt files degrade to defaults instead of raising (Review Focus 2);
* a zero-move game -- a practice game that was already over -- saves and
  reads back cleanly (Review Focus 5).

Resignations arrive as :data:`chess_trainer.controller.RESIGNATION`
(``chess.Termination.VARIANT_LOSS``) but the winner lives only in the PGN
``Result`` header, so the store must derive win/loss/draw from the header and
label the game as a resignation rather than counting it as anything else.
"""

from __future__ import annotations

import io
import json
import math
import re
from pathlib import Path

import chess
import chess.pgn
import pytest

from chess_trainer import store as store_module
from chess_trainer.coach import CoachVerdict
from chess_trainer.controller import RESIGNATION, FinishedGame, GameAnnotation
from chess_trainer.store import (
    DEFAULT_BOT_STRENGTH,
    MAX_BOT_STRENGTH,
    MIN_BOT_STRENGTH,
    GameRecord,
    StatsFile,
    Store,
)

START = chess.STARTING_FEN

SCHOLARS_MATE = (
    "e2e4",
    "e7e5",
    "f1c4",
    "b8c6",
    "d1h5",
    "g8f6",
    "h5f7",
)


# --- helpers --------------------------------------------------------------


def annotation(
    ply: int,
    move_uci: str,
    verdict: CoachVerdict = CoachVerdict.SILENT,
    message: str | None = None,
    *,
    is_player: bool = True,
    fen: str = START,
) -> GameAnnotation:
    """One annotation shaped exactly like the controller's."""
    return GameAnnotation(
        ply=ply,
        fen=fen,
        move_uci=move_uci,
        verdict=verdict,
        message=message,
        is_player=is_player,
    )


def finished_game(
    moves: tuple[str, ...] = ("e2e4", "e7e5"),
    *,
    player_white: bool = True,
    is_practice: bool = False,
    bot_strength: float = DEFAULT_BOT_STRENGTH,
    result: chess.Termination = chess.Termination.CHECKMATE,
    pgn_result: str | None = None,
    annotations: list[GameAnnotation] | None = None,
    attempted_blunders: int = 0,
) -> FinishedGame:
    """Build a :class:`FinishedGame` the way the controller does."""
    board = chess.Board()
    for uci in moves:
        board.push_uci(uci)
    game = chess.pgn.Game.from_board(board)
    if pgn_result is not None:
        game.headers["Result"] = pgn_result
    if annotations is None:
        annotations = [
            annotation(i + 1, uci, is_player=(i % 2 == 0))
            for i, uci in enumerate(moves)
        ]
    return FinishedGame(
        pgn=str(game),
        annotations=annotations,
        is_practice=is_practice,
        bot_strength=bot_strength,
        player_white=player_white,
        result=result,
        attempted_blunders=attempted_blunders,
    )


def read_pgn(path: Path) -> chess.pgn.Game:
    game = chess.pgn.read_game(io.StringIO(path.read_text(encoding="utf-8")))
    assert game is not None
    return game


def read_sidecar(pgn_path: Path) -> dict[str, object]:
    sidecar = pgn_path.with_suffix(".annotations.json")
    assert sidecar.is_file()
    return json.loads(sidecar.read_text(encoding="utf-8"))


# --- construction and layout ---------------------------------------------


def test_store_creates_data_directory(tmp_path: Path) -> None:
    data = tmp_path / "nested" / "data"
    Store(data)
    assert data.is_dir()


def test_default_data_dir_is_the_package_data_folder() -> None:
    # Only the path is inspected: no store is constructed, so the real data
    # directory is never created or written by the tests.
    expected = Path(store_module.__file__).resolve().parents[2] / "data"
    assert DEFAULT_BOT_STRENGTH == 1.8
    assert store_module.DEFAULT_DATA_DIR == expected
    assert store_module.DEFAULT_DATA_DIR.parent.name == "chess-trainer"
    assert store_module.DEFAULT_DATA_DIR.name == "data"


def test_save_writes_pgn_under_dated_folder(tmp_path: Path) -> None:
    store = Store(tmp_path)
    path = store.save(finished_game())

    assert path.is_file()
    assert path.suffix == ".pgn"
    assert path.parent.parent.name == "games"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", path.parent.name)


def test_two_saves_get_distinct_paths(tmp_path: Path) -> None:
    store = Store(tmp_path)
    game = finished_game()
    first = store.save(game)
    second = store.save(game)
    assert first != second
    assert first.is_file() and second.is_file()


# --- PGN plus annotation sidecar -----------------------------------------


def test_save_round_trips_pgn(tmp_path: Path) -> None:
    store = Store(tmp_path)
    game = finished_game(SCHOLARS_MATE)
    path = store.save(game)

    saved = read_pgn(path)
    moves = [move.uci() for move in saved.mainline_moves()]
    assert tuple(moves) == SCHOLARS_MATE
    assert saved.headers["Result"] == "1-0"
    assert path.read_text(encoding="utf-8").endswith("\n")


def test_save_writes_parallel_annotation_json(tmp_path: Path) -> None:
    store = Store(tmp_path)
    game = finished_game(
        ("e2e4", "e7e5", "f1c4"),
        is_practice=True,
        bot_strength=8.5,
        player_white=False,
        pgn_result="1-0",  # white (the bot) won; the player lost
        annotations=[
            annotation(
                1,
                "e2e4",
                CoachVerdict.BLUNDER,
                "that loses your queen on d5.",
            ),
            annotation(2, "e7e5", is_player=False),
            annotation(3, "f1c4", CoachVerdict.NOTABLE, "that leaves it there."),
        ],
    )
    path = store.save(game)
    payload = read_sidecar(path)

    assert payload["practice"] is True
    assert payload["bot_strength"] == 8.5
    assert payload["player_white"] is False
    assert payload["player_color"] == "black"
    assert payload["result"] == "loss"
    assert payload["resignation"] is False
    assert payload["attempted_blunders"] == 0
    assert len(payload["annotations"]) == 3

    first = payload["annotations"][0]
    assert first["ply"] == 1
    assert first["move_uci"] == "e2e4"
    assert first["verdict"] == "blunder"
    assert first["message"] == "that loses your queen on d5."
    assert first["is_player"] is True
    assert payload["annotations"][1]["is_player"] is False
    assert payload["annotations"][1]["message"] is None


def test_zero_move_game_round_trips(tmp_path: Path) -> None:
    # A practice game that was already game over when it started: no moves,
    # a draw result header and no annotations.
    store = Store(tmp_path)
    game = finished_game(
        (),
        result=chess.Termination.INSUFFICIENT_MATERIAL,
        pgn_result="1/2-1/2",
        annotations=[],
    )

    path = store.save(game)
    assert store.load_game_records() == []

    saved = read_pgn(path)
    assert list(saved.mainline_moves()) == []
    assert saved.headers["Result"] == "1/2-1/2"

    payload = read_sidecar(path)
    assert payload["annotations"] == []
    assert payload["result"] == "draw"
    assert payload["practice"] is False


def test_save_tolerates_unreadable_pgn(tmp_path: Path) -> None:
    # Defensive: a broken PGN still saves; it simply has no derivable result.
    store = Store(tmp_path)
    game = finished_game(annotations=[])
    game.pgn = "this is not a pgn"

    path = store.save(game)
    store.record_to_stats(game)

    assert path.is_file()
    assert read_sidecar(path)["result"] == "draw"
    assert Store(tmp_path).load_stats().games[0].margin == 0.0


# --- corrupt files degrade to defaults -----------------------------------


@pytest.mark.parametrize(
    "content",
    [
        "{ this is not json",
        "",
        "[]",
        "null",
        '"stats"',
        "42",
        '{"wins": "nope"}',
    ],
)
def test_corrupt_stats_file_yields_default(
    tmp_path: Path, content: str
) -> None:
    (tmp_path / "stats.json").write_text(content, encoding="utf-8")

    stats = Store(tmp_path).load_stats()

    assert isinstance(stats, StatsFile)
    if content != '{"wins": "nope"}':
        assert stats == StatsFile()
    else:
        # A dict with one bad value degrades field by field, never raises.
        assert stats.total == 0
        assert stats.wins == 0
        assert stats.strength == DEFAULT_BOT_STRENGTH


def test_missing_stats_file_yields_default(tmp_path: Path) -> None:
    assert Store(tmp_path).load_stats() == StatsFile()


def test_stats_with_bad_values_are_repaired_field_by_field(
    tmp_path: Path,
) -> None:
    (tmp_path / "stats.json").write_text(
        json.dumps(
            {
                "total": 4,
                "practice_total": "two",
                "losses": 1,
                "wins": -3,
                "draws": 0,
                "blunders_per_game": [2, "x", -1, 3.5],
                "strength": 99,
                "games": [
                    {
                        "result": "win",
                        "practice": False,
                        "blunders": 2,
                        "margin": 1.0,
                        "strength": 18.0,
                        "date": "2026-11-01",
                    },
                    {"result": "nonsense"},
                    "not a record",
                ],
            }
        ),
        encoding="utf-8",
    )

    stats = Store(tmp_path).load_stats()

    assert stats.total == 4
    assert stats.practice_total == 0
    assert stats.losses == 1
    assert stats.wins == 0  # negative counts are treated as corrupt
    assert stats.draws == 0
    assert stats.blunders_per_game == [2.0, 3.5]
    assert stats.strength == MAX_BOT_STRENGTH  # legacy 99 clamps to the ceiling
    assert len(stats.games) == 1
    assert stats.games[0].result == "win"
    assert stats.games[0].strength == MAX_BOT_STRENGTH  # 18 clamps as well


def test_load_game_records_degrades_to_empty(tmp_path: Path) -> None:
    (tmp_path / "stats.json").write_text("not json", encoding="utf-8")
    assert Store(tmp_path).load_game_records() == []


# --- recording games into cumulative stats -------------------------------


def test_record_to_stats_counts_practice_win(tmp_path: Path) -> None:
    store = Store(tmp_path)
    game = finished_game(
        SCHOLARS_MATE,
        is_practice=True,
        bot_strength=7.0,
        annotations=[
            annotation(1, "e2e4", CoachVerdict.BLUNDER, "lost a piece."),
            annotation(2, "e7e5", CoachVerdict.BLUNDER, is_player=False),
        ],
    )

    store.record_to_stats(game)
    stats = store.load_stats()

    assert stats.total == 1
    assert stats.practice_total == 1
    assert stats.wins == 1
    assert stats.losses == 0
    assert stats.draws == 0
    assert stats.blunders_per_game == [1.0]  # bot blunders do not count
    assert stats.strength == 7.0

    record = stats.games[0]
    assert record.result == "win"
    assert record.practice is True
    assert record.blunders == 1
    assert math.isfinite(record.margin)
    assert record.margin > 0
    assert record.strength == 7.0
    assert record.date


def test_attempted_blunders_count_in_stats_and_the_sidecar(
    tmp_path: Path,
) -> None:
    # The move was taken back, so the annotations contain no blunder; the
    # carried counter must still make the game count once.
    store = Store(tmp_path)
    game = finished_game(
        ("d2d4", "e7e5"),
        annotations=[
            annotation(1, "d2d4"),
            annotation(2, "e7e5", is_player=False),
        ],
        attempted_blunders=1,
    )

    path = store.save(game)
    store.record_to_stats(game)

    payload = read_sidecar(path)
    assert payload["attempted_blunders"] == 1
    assert payload["blunders"] == 1
    stats = store.load_stats()
    assert stats.games[0].blunders == 1
    assert stats.blunders_per_game == [1.0]


def test_record_to_stats_appends_across_store_instances(
    tmp_path: Path,
) -> None:
    Store(tmp_path).record_to_stats(
        finished_game(is_practice=True, pgn_result="1-0")
    )
    Store(tmp_path).record_to_stats(
        finished_game(SCHOLARS_MATE, result=chess.Termination.CHECKMATE)
    )

    stats = Store(tmp_path).load_stats()
    assert stats.total == 2
    assert stats.practice_total == 1
    assert stats.wins == 2
    assert [record.practice for record in stats.games] == [True, False]
    assert len(stats.blunders_per_game) == stats.total

    records = Store(tmp_path).load_game_records()
    assert len(records) == 2
    assert [record.result for record in records] == ["win", "win"]


def test_record_to_stats_counts_draw(tmp_path: Path) -> None:
    store = Store(tmp_path)
    store.record_to_stats(
        finished_game(
            (),
            result=chess.Termination.INSUFFICIENT_MATERIAL,
            pgn_result="1/2-1/2",
            annotations=[],
        )
    )

    stats = store.load_stats()
    assert stats.total == 1
    assert stats.draws == 1
    assert stats.wins == stats.losses == 0
    assert stats.games[0].result == "draw"
    assert stats.games[0].margin == 0.0
    assert stats.blunders_per_game == [0.0]


@pytest.mark.parametrize(
    ("player_white", "pgn_result"),
    [
        (True, "0-1"),  # white player resigned
        (False, "1-0"),  # black player resigned
    ],
)
def test_resignation_counts_as_loss_from_result_header(
    tmp_path: Path, player_white: bool, pgn_result: str
) -> None:
    store = Store(tmp_path)
    game = finished_game(
        ("e2e4",),
        player_white=player_white,
        result=RESIGNATION,
        pgn_result=pgn_result,
    )

    path = store.save(game)
    store.record_to_stats(game)

    payload = read_sidecar(path)
    assert payload["resignation"] is True
    assert payload["termination"] == "resignation"
    assert payload["result"] == "loss"

    stats = store.load_stats()
    assert stats.total == 1
    assert stats.losses == 1
    assert stats.wins == stats.draws == 0
    assert stats.games[0].result == "loss"
    assert stats.games[0].margin < 0


def test_resignation_sentinel_does_not_override_a_winning_header(
    tmp_path: Path,
) -> None:
    # The PGN Result header is authoritative; the sentinel only says "this was
    # a resignation", not who won.
    store = Store(tmp_path)
    game = finished_game(
        ("e2e4", "e7e5"),
        player_white=True,
        result=RESIGNATION,
        pgn_result="1-0",
    )

    store.record_to_stats(game)

    stats = store.load_stats()
    assert stats.wins == 1
    assert stats.games[0].result == "win"
    assert stats.games[0].margin > 0


def test_record_to_stats_writes_stats_atomically(tmp_path: Path) -> None:
    store = Store(tmp_path)
    store.record_to_stats(finished_game())

    stats_path = tmp_path / "stats.json"
    assert stats_path.is_file()
    assert list(tmp_path.glob("*.tmp")) == []
    payload = json.loads(stats_path.read_text(encoding="utf-8"))
    assert payload["total"] == 1


def test_stats_json_shape_matches_schema(tmp_path: Path) -> None:
    store = Store(tmp_path)
    store.record_to_stats(finished_game())

    payload = json.loads(
        (tmp_path / "stats.json").read_text(encoding="utf-8")
    )
    for key in (
        "total",
        "practice_total",
        "losses",
        "wins",
        "draws",
        "blunders_per_game",
        "strength",
        "games",
    ):
        assert key in payload
    assert isinstance(payload["blunders_per_game"], list)
    assert isinstance(payload["games"], list)


# --- bot strength ---------------------------------------------------------


def test_bot_strength_defaults_to_the_shared_default(tmp_path: Path) -> None:
    store = Store(tmp_path)
    assert store.bot_strength == 1.8
    assert store.bot_strength == DEFAULT_BOT_STRENGTH


def test_bot_strength_persists_across_instances(tmp_path: Path) -> None:
    Store(tmp_path).bot_strength = 8.25

    assert (tmp_path / "bot.json").is_file()
    assert Store(tmp_path).bot_strength == 8.25
    assert list(tmp_path.glob("*.tmp")) == []


@pytest.mark.parametrize(
    "content",
    [
        "not json",
        "",
        '"high"',
        "[]",
        "null",
        "NaN",
    ],
)
def test_corrupt_bot_file_yields_default(
    tmp_path: Path, content: str
) -> None:
    (tmp_path / "bot.json").write_text(content, encoding="utf-8")
    assert Store(tmp_path).bot_strength == DEFAULT_BOT_STRENGTH


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        ("42", MAX_BOT_STRENGTH),
        ("21", MAX_BOT_STRENGTH),
        ("-3", MIN_BOT_STRENGTH),
        ('{"strength": 18}', MAX_BOT_STRENGTH),
    ],
)
def test_out_of_range_bot_strength_is_clamped(
    tmp_path: Path, content: str, expected: float
) -> None:
    # A legacy file may hold a value from the old 20-point ceiling.  It is
    # clamped, not accepted: the bot must never play above the humanlike limit.
    (tmp_path / "bot.json").write_text(content, encoding="utf-8")
    assert Store(tmp_path).bot_strength == expected


def test_store_ceiling_matches_adaptation() -> None:
    from chess_trainer.adapt import MAX_STRENGTH, MIN_STRENGTH

    assert MAX_BOT_STRENGTH == MAX_STRENGTH == 14.0
    assert MIN_BOT_STRENGTH == MIN_STRENGTH == 0.0


# --- trend view for the stats screen -------------------------------------


def test_trend_returns_labels_and_per_game_points() -> None:
    stats = StatsFile(
        total=3,
        practice_total=1,
        losses=1,
        wins=1,
        draws=1,
        blunders_per_game=[1.0, 0.0, 3.0],
        strength=6.0,
        games=[
            GameRecord("win", False, 1, 2.0, 6.0, "2026-11-01"),
            GameRecord("draw", True, 0, 0.0, 6.0, "2026-11-01"),
            GameRecord("loss", False, 3, -2.0, 6.0, "2026-11-01"),
        ],
    )

    labels, points = stats.trend()

    assert len(labels) == len(points) == 3
    assert points == [1.0, 0.5, 0.0]
    assert all(isinstance(label, str) and label for label in labels)


def test_trend_is_empty_without_games() -> None:
    assert StatsFile().trend() == ([], [])
