"""Tests for the Stockfish wrapper used by the coach and the GUI."""

import chess
import pytest

from chess_trainer.engine import DEFAULT_DEPTH, Engine, MoveAnalysis

# White queen on d1, black queen hanging on d5, d-file open for Qxd5.
# Verified with the vendored Stockfish 19 (depth 10): d1d5 ~ +823, while the
# quiet c1f4 hands Black the queen and evaluates ~ -822 for White.  The brief's
# suggested FEN (white queen on e2) has no legal queen capture at all.
FREE_QUEEN_FEN = "rnb1kbnr/ppp1pppp/8/3q4/8/8/PPP2PPP/RNBQKB1R w KQkq - 0 1"

# White plays Ra8# immediately.
MATE_IN_ONE_FEN = "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1"

# White has only a-pawn moves; whatever White does, ...Re1# follows.
MATED_IN_TWO_FEN = "4r2k/8/8/8/8/3n3q/P7/6K1 w - - 0 1"


def test_top_moves_prefers_free_capture():
    with Engine() as e:
        moves = e.top_moves(FREE_QUEEN_FEN, depth=10)

    ucis = [m.uci.lower() for m in moves]
    assert "d1d5" in ucis, f"Qxd5 missing from engine top moves: {ucis}"
    assert ucis[0] == "d1d5", f"Qxd5 should be the engine's first choice, got {ucis}"
    assert 1 <= len(moves) <= 3, "MultiPV=3 should return at most three moves"

    cps = [m.cp for m in moves]
    assert cps == sorted(cps, reverse=True), "top_moves must be best-first"
    assert moves[0].cp is not None and moves[0].cp > 0
    assert moves[0].mate is None


def test_analyse_flags_hanging_queen():
    # Bf4 ignores the free queen on d5 and hangs White's own queen instead.
    with Engine() as e:
        analysis = e.analyse(FREE_QUEEN_FEN, "c1f4")

    assert isinstance(analysis, MoveAnalysis)
    assert analysis.played_uci == "c1f4"
    assert analysis.best_uci == "d1d5"
    assert analysis.loss_cp >= 100
    assert analysis.best_cp > analysis.played_cp
    assert analysis.mate_against is False


def test_loss_cp_is_never_negative():
    # Taking the queen narrowly beats a quiet move; loss clamps at zero.
    with Engine() as e:
        analysis = e.analyse(FREE_QUEEN_FEN, "d1d5")

    assert analysis.loss_cp >= 0
    assert analysis.loss_cp == max(0, analysis.best_cp - analysis.played_cp)


def test_best_returns_engine_first_choice():
    with Engine() as e:
        best = e.best(FREE_QUEEN_FEN, depth=10)

    assert best.uci == "d1d5"
    assert best.cp is not None and best.cp > 0
    assert best.mate is None


def test_mate_scores_are_normalised_and_clipped():
    with Engine() as e:
        moves = e.top_moves(MATE_IN_ONE_FEN, depth=10)

    top = moves[0]
    assert top.uci == "a1a8"
    assert top.mate == 1
    assert top.cp == 990  # 1000 - 10 * |mate|


def test_analyse_detects_mate_against():
    # a2a3 hands Black a forced mate in one.
    with Engine() as e:
        analysis = e.analyse(MATED_IN_TWO_FEN, "a2a3")

    assert analysis.played_uci == "a2a3"
    assert analysis.mate_against is True
    assert analysis.played_cp == -990
    assert analysis.best_cp == -990, "both pawn moves allow ...Re1#"
    assert analysis.loss_cp == 0


def test_analyse_of_mating_move_reports_a_win():
    with Engine() as e:
        analysis = e.analyse(MATE_IN_ONE_FEN, "a1a8")

    assert analysis.played_cp == 1000
    assert analysis.best_cp == 990
    assert analysis.mate_against is False


def test_analyse_rejects_illegal_move():
    with Engine() as e, pytest.raises(ValueError):
        e.analyse(FREE_QUEEN_FEN, "e2e4")


def test_engine_rejects_missing_explicit_path(tmp_path):
    with pytest.raises(FileNotFoundError):
        Engine(path=str(tmp_path / "stockfish-does-not-exist"))


def test_engine_discovers_vendored_binary():
    # No system Stockfish is on PATH in this environment; resolution must fall
    # back to chess-trainer/bin/stockfish.
    with Engine() as e:
        assert e.path


def test_default_depth_is_twelve():
    assert DEFAULT_DEPTH == 12


def test_close_is_idempotent():
    e = Engine()
    e.close()
    e.close()


def test_context_manager_closes_engine():
    with Engine() as e:
        assert e.path


def test_set_skill_and_play_round_trip():
    engine = Engine()
    try:
        with pytest.raises(ValueError):
            engine.set_skill(21)

        engine.set_skill(5)
        engine.set_skill(5)  # idempotent: same level is a no-op
        board = chess.Board()
        uci = engine.play(board, time_s=0.5)
        assert uci in [move.uci() for move in board.legal_moves]

        # 20 is Stockfish's default: restoring it must leave the engine usable.
        engine.set_skill(20)
        engine.set_skill(20)
        assert engine.best(chess.STARTING_FEN, depth=8).uci in [
            move.uci() for move in board.legal_moves
        ]
        assert engine.play(board, time_s=0.5) in [
            move.uci() for move in board.legal_moves
        ]
    finally:
        engine.close()

    # Both new methods share close()'s lifecycle guard.
    with pytest.raises(RuntimeError):
        engine.set_skill(5)
    with pytest.raises(RuntimeError):
        engine.play(chess.Board())
