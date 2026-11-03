"""Tests for the deliberately weakened bot opponent."""

from __future__ import annotations

import random
from pathlib import Path

import chess
import pytest

from chess_trainer.bot import Bot, slack, weak_prob
from chess_trainer.engine import Engine, EngineMove
from chess_trainer.store import DEFAULT_BOT_STRENGTH

#: At strength 20 the bot must stay close to the engine's first choice.
HIGH_STRENGTH_SLACK = 45

#: White queen on d1 and a black queen hanging on d5: d1d5 is the only top-3
#: move inside even a generous slack, so a near-best player must find it.
FREE_QUEEN_FEN = "rnb1kbnr/ppp1pppp/8/3q4/8/8/PPP2PPP/RNBQKB1R w KQkq - 0 1"

#: Fool's mate: White is checkmated, so there is no legal move to choose.
CHECKMATED_FEN = "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3"

#: White pawn on a7 can promote; used to check the weak layer's promotion rule.
PROMOTION_FEN = "8/P6k/8/8/8/8/6K1/8 w - - 0 1"


def _walk_fens(count: int = 40) -> list[str]:
    """Build deterministic positions with three random plies from the start.

    One fixed seed per position keeps the sample stable across runs while the
    walks still reach a variety of pawn structures and piece placements.
    """
    fens: list[str] = []
    for seed in range(count):
        board = chess.Board(chess.STARTING_FEN)
        rng = random.Random(seed)
        for _ in range(3):
            board.push(rng.choice(sorted(board.legal_moves, key=lambda m: m.uci())))
        fens.append(board.fen())
    return fens


FEN_SAMPLES = _walk_fens()


class StubEngine:
    """Duck-typed ``Engine``: canned moves, no Stockfish process."""

    def __init__(self, play_uci: str | None, top_moves: list[EngineMove]) -> None:
        self.play_uci = play_uci
        self.skill_levels: list[int] = []
        self.play_calls = 0
        self.top_moves_calls = 0
        self._top_moves = list(top_moves)

    def set_skill(self, level: int) -> None:
        self.skill_levels.append(level)

    def play(self, board: chess.Board, time_s: float = 0.3) -> str | None:
        self.play_calls += 1
        return self.play_uci

    def top_moves(self, fen: str, depth: int = 12) -> list[EngineMove]:
        self.top_moves_calls += 1
        return list(self._top_moves)


def test_fen_samples_count():
    assert len(FEN_SAMPLES) == 40
    assert len(set(FEN_SAMPLES)) > 30, "the random walk should not repeat positions"


def test_estimate_elo_range():
    bot = Bot(StubEngine("e2e4", []))
    assert bot.estimate_elo(0) == 450
    assert bot.estimate_elo(6) == 1080
    assert bot.estimate_elo(20) == 2550


def test_estimate_elo_tracks_strength():
    bot = Bot(StubEngine("e2e4", []))
    ratings = [bot.estimate_elo(strength) for strength in range(21)]
    assert ratings == sorted(ratings)
    assert ratings[10] == 1500


def test_default_strength_lands_in_the_spec_band():
    # Spec: starts near rapid ~570-700, displayed as "Bot ≈ 640".
    assert DEFAULT_BOT_STRENGTH == 1.8
    elo = Bot.estimate_elo(DEFAULT_BOT_STRENGTH)
    assert elo == 639
    assert 570 <= elo <= 700


def test_weak_prob_climbs_as_strength_falls():
    assert weak_prob(20) == pytest.approx(0.15, abs=1e-9)
    assert weak_prob(0) == pytest.approx(0.85, abs=1e-9)
    assert weak_prob(0) > weak_prob(6) > weak_prob(12) > weak_prob(20)
    # Out-of-range dial values are clamped to the supported 0-20 range.
    assert weak_prob(-5) == pytest.approx(weak_prob(0))
    assert weak_prob(40) == pytest.approx(weak_prob(20))


def test_slack_widens_as_strength_falls():
    assert slack(20) == 40
    assert slack(10) == 120
    assert slack(0) == 200
    assert slack(0) > slack(10) > slack(20)


def test_bot_moves_are_legal():
    engine = Engine()
    bot = Bot(engine)
    try:
        for seed, fen in enumerate(FEN_SAMPLES):
            board = chess.Board(fen)
            uci = bot.choose_move(board, strength=18, seed=seed)
            assert uci in [m.uci() for m in board.legal_moves]
    finally:
        engine.close()


def test_high_strength_plays_near_best_move():
    with Engine() as engine:
        top = engine.top_moves(FREE_QUEEN_FEN, depth=10)
        assert top[0].uci == "d1d5"
        assert top[0].cp is not None and top[1].cp is not None
        assert top[0].cp - top[1].cp > HIGH_STRENGTH_SLACK, (
            "fixture must have one clearly best move so near-best play is "
            "unambiguous"
        )

        bot = Bot(engine)
        for seed in range(5):
            uci = bot.choose_move(chess.Board(FREE_QUEEN_FEN), strength=20, seed=seed)
            assert uci == top[0].uci


def test_weak_layer_respects_slack():
    # A second move 100cp down is outside a strength-20 slack of 40, so the
    # error layer must never pick it; at strength 0 the slack is 200.
    top = [EngineMove("g1f3", 100, None), EngineMove("b1a3", 0, None)]
    bot = Bot(StubEngine("g1f3", top))

    strong = [bot.choose_move(chess.Board(), 20, seed=s) for s in range(100)]
    assert strong == ["g1f3"] * 100

    weak = [bot.choose_move(chess.Board(), 0, seed=s) for s in range(100)]
    assert "b1a3" in weak, "slack at strength 0 must admit the 100cp-down move"


def test_low_strength_errs_more_often_than_high_strength():
    # Both moves are inside the strength-20 slack of 40, so the difference is
    # the error probability, not the candidate set.
    top = [EngineMove("g1f3", 100, None), EngineMove("b1a3", 60, None)]
    bot = Bot(StubEngine("g1f3", top))

    def errs(strength: float) -> int:
        moves = [bot.choose_move(chess.Board(), strength, seed=s) for s in range(200)]
        return moves.count("b1a3")

    strong_errs = errs(20)
    weak_errs = errs(0)
    assert strong_errs > 0, "the error layer must fire at strength 20 sometimes"
    assert weak_errs > strong_errs * 3
    # Weighting favours the weaker eval inside the candidate set.
    assert weak_errs > 100


def test_weak_layer_never_underpromotes():
    # Even if the engine's top list offers only underpromotions, the random
    # weakening layer must fall back to the engine's legal move (a queen
    # promotion here) instead of choosing an underpromotion for free.
    top = [EngineMove("a7a8n", 990, 1), EngineMove("a7a8b", 900, None)]
    bot = Bot(StubEngine("a7a8q", top))
    board = chess.Board(PROMOTION_FEN)

    for seed in range(20):
        assert bot.choose_move(board, 0, seed=seed) == "a7a8q"


def test_choose_move_sets_and_restores_skill_level():
    bot = Bot(StubEngine("g1f3", [EngineMove("g1f3", 100, None)]))
    bot.choose_move(chess.Board(), 7.9, seed=0)
    # int(7.9) == 7 while playing, and full strength is restored afterwards so
    # the coach can keep using the same Engine instance.
    assert bot.engine.skill_levels == [7, 20]


def test_choose_move_restores_skill_level_after_engine_error():
    engine = StubEngine("g1f3", [])

    def boom(board: chess.Board, time_s: float = 0.3) -> str:
        raise RuntimeError("engine exploded")

    engine.play = boom  # type: ignore[method-assign]
    bot = Bot(engine)

    with pytest.raises(RuntimeError, match="exploded"):
        bot.choose_move(chess.Board(), 5, seed=0)
    assert engine.skill_levels == [5, 20]


def test_bot_uses_only_public_engine_surface():
    source = (
        Path(__file__).resolve().parents[2] / "src" / "chess_trainer" / "bot.py"
    ).read_text(encoding="utf-8")
    assert "_engine" not in source, "Bot must not reach into Engine internals"
    assert "set_skill(" in source
    assert ".play(" in source


def test_choose_move_seed_is_reproducible():
    top = [EngineMove("g1f3", 100, None), EngineMove("b1a3", 60, None)]
    bot = Bot(StubEngine("g1f3", top))
    first = bot.choose_move(chess.Board(), 10, seed=3)
    second = bot.choose_move(chess.Board(), 10, seed=3)
    assert first == second


def test_choose_move_raises_when_no_legal_moves():
    bot = Bot(StubEngine("g1f3", []))
    board = chess.Board(CHECKMATED_FEN)
    assert board.is_game_over()
    with pytest.raises(ValueError, match="legal"):
        bot.choose_move(board, 10, seed=0)
