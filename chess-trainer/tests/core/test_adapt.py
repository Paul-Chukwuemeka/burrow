"""Tests for adaptive strength: pure window arithmetic, no engine.

The pinned behaviour is encoded directly: a losing streak lowers the bot
(eases up on the player), a winning streak raises it, a genuinely mixed window
leaves it alone, the humanlike ceiling and floor clamp, and practice games
keep the dial moving for a player who has no clean games yet.

Every test passes plain :class:`GameResult` values, so the file never starts
Stockfish and never touches the data directory.  The per-game scaling is this
implementation's documented choice: decisive wins and heavy, blunder-filled
losses count for more than scrappy ones, but no single game can move the dial
by more than :data:`MAX_SHIFT`.
"""

from __future__ import annotations

import pytest

from chess_trainer.adapt import (
    MAX_SHIFT,
    MAX_STRENGTH,
    MIN_STRENGTH,
    GameResult,
    retune,
)
from chess_trainer.store import DEFAULT_BOT_STRENGTH, GameRecord

START = 6.0


def game(
    result: str, margin: int = 5, blunders: int = 0
) -> GameResult:
    """One shorthand game result."""
    return GameResult(result=result, margin=margin, blunders=blunders)  # type: ignore[arg-type]


def decisive_wins(count: int) -> list[GameResult]:
    return [game("win", margin=9, blunders=0) for _ in range(count)]


def heavy_losses(count: int) -> list[GameResult]:
    return [game("loss", margin=-9, blunders=4) for _ in range(count)]


# --- the pinned behaviours --------------------------------------------------


def test_three_straight_losses_ease_the_bot_down():
    """The player keeps losing, so the bot must get easier, not harder."""
    tuned = retune(START, heavy_losses(3))

    assert tuned < START


def test_three_decisive_wins_raise_the_bot():
    tuned = retune(START, decisive_wins(3))

    assert tuned > START


def test_two_wins_and_three_losses_over_the_full_window_is_unchanged():
    mixed = [
        game("win", margin=7),
        game("loss", margin=-6),
        game("win", margin=4),
        game("loss", margin=-3),
        game("loss", margin=-9, blunders=3),
    ]

    assert retune(START, mixed) == START


def test_mixed_window_is_unchanged_even_with_lopsided_margins():
    mixed = [
        game("win", margin=15),
        game("win", margin=12),
        game("loss", margin=-1),
        game("loss", margin=-1),
        game("loss", margin=-1),
    ]

    assert retune(START, mixed) == START


def test_the_humanlike_ceiling_is_clamped():
    assert retune(MAX_STRENGTH, decisive_wins(5)) == MAX_STRENGTH


def test_the_floor_is_clamped():
    assert retune(MIN_STRENGTH, heavy_losses(5)) == MIN_STRENGTH


# --- the recent window ------------------------------------------------------


def test_practice_games_move_the_dial_for_a_new_player():
    practice_wins = [game("practice_win", margin=8) for _ in range(3)]
    practice_losses = [game("practice_loss", margin=-8) for _ in range(3)]

    assert retune(START, practice_wins) > START
    assert retune(START, practice_losses) < START


def test_clean_games_win_over_recent_practice_games():
    # Five clean losses fix the direction even though the newest games are
    # practice wins; practice results only fill a window short of clean games.
    results = heavy_losses(5) + [
        game("practice_win", margin=9) for _ in range(5)
    ]

    assert retune(START, results) < START


def test_short_clean_history_is_filled_with_recent_practice_games():
    # Two clean wins alone would raise the bot; adding three practice losses
    # makes the window 2-3, the competitive band, so nothing moves.
    results = [
        game("practice_loss", margin=-5),
        game("practice_loss", margin=-5),
        game("practice_loss", margin=-5),
        game("win", margin=5),
        game("win", margin=5),
    ]

    assert retune(START, results) == START


def test_only_the_last_five_results_count():
    old_wins = decisive_wins(5)
    recent_losses = heavy_losses(5)

    # Old wins are outside the window; the recent losses decide.
    assert retune(START, old_wins + recent_losses) < START


def test_empty_history_leaves_the_dial_alone():
    assert retune(START, []) == START


def test_draws_alone_leave_the_dial_alone():
    draws = [game("draw", margin=0) for _ in range(5)]

    assert retune(START, draws) == START


# --- how far, not just which way -------------------------------------------


def test_a_full_window_of_wins_moves_exactly_the_target_distance():
    assert retune(START, decisive_wins(5)) == pytest.approx(START + MAX_SHIFT)


def test_one_game_moves_less_than_the_target_distance():
    tuned = retune(START, decisive_wins(1))

    assert START < tuned < START + MAX_SHIFT


def test_decisive_wins_move_more_than_scrappy_wins():
    decisive = retune(START, [game("win", margin=9, blunders=0)])
    scrappy = retune(START, [game("win", margin=1, blunders=3)])

    assert decisive > scrappy > START


def test_heavy_blunder_filled_losses_move_more_than_narrow_clean_ones():
    heavy = retune(START, [game("loss", margin=-9, blunders=4)])
    narrow = retune(START, [game("loss", margin=-1, blunders=0)])

    assert heavy < narrow < START


def test_the_dial_never_leaves_its_range_over_a_long_history():
    history: list[GameResult] = []
    strength = START
    for index in range(60):
        history.append(
            game("win", margin=9) if index % 2 == 0 else game("loss", margin=-9)
        )
        strength = retune(strength, history)
        assert MIN_STRENGTH <= strength <= MAX_STRENGTH


# --- the GameResult contract ------------------------------------------------


def test_game_result_fields_are_the_pinned_interface():
    assert set(GameResult.__dataclass_fields__) == {
        "result",
        "margin",
        "blunders",
    }


def test_from_record_folds_in_the_practice_flag_and_rounds_the_margin():
    record = GameRecord(
        result="win",
        practice=True,
        blunders=2,
        margin=4.6,
        strength=6.0,
        date="2026-11-01T12:00:00+00:00",
    )

    adapted = GameResult.from_record(record)

    assert adapted == GameResult(
        result="practice_win", margin=5, blunders=2
    )
    assert adapted.is_practice is True
    assert adapted.base == "win"


def test_from_record_maps_a_clean_game_without_a_prefix():
    record = GameRecord(
        result="loss",
        practice=False,
        blunders=1,
        margin=-3.2,
        strength=6.0,
        date="",
    )

    assert GameResult.from_record(record) == GameResult(
        result="loss", margin=-3, blunders=1
    )


def test_unknown_results_are_rejected():
    with pytest.raises(ValueError):
        GameResult(result="victory", margin=1, blunders=0)  # type: ignore[arg-type]


def test_retune_does_not_mutate_the_history():
    history = decisive_wins(3)
    before = list(history)

    retune(START, history)

    assert history == before


def test_the_default_store_strength_sits_inside_the_adaptation_range():
    assert MIN_STRENGTH <= DEFAULT_BOT_STRENGTH <= MAX_STRENGTH
