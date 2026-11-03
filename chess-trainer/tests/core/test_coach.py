"""Tests for the coach: verdicts and plain-language messages.

Engine-backed cases run at depth 8 (verified against the vendored Stockfish 19
at depths 8 and 10) so the file stays quick to iterate on.  Threshold
boundaries and the mate-in-one override are tested with a stub engine, which
makes them exact and free.
"""

import chess
import pytest

from chess_trainer.coach import Coach, CoachKind, CoachVerdict
from chess_trainer.engine import Engine, MoveAnalysis

# --- fixtures -------------------------------------------------------------

# A normal developing move; nothing is lost.
QUIET_FEN = chess.STARTING_FEN

# White to move.  The f3 knight is undefended and the black queen on d5
# attacks it; h2h3 ignores it, so Qxf3 wins the knight.
HANGING_KNIGHT_FEN = "6k1/ppp2ppp/8/3q4/8/5N2/PPP2P1P/1Q4K1 w - - 0 1"

# White's d4 pawn can take the undefended e5 pawn.  h2h3 misses it and the
# engine scores the omission as a notable (100-249 cp) loss.
FREE_PAWN_FEN = "6k1/ppp2ppp/8/4p3/3P4/2P5/PPP2PPP/6K1 w - - 0 1"

# White's bishop steps off the back rank and ...Re1# follows.  Kf1 avoids it.
BACK_RANK_FEN = "4r1k1/5ppp/8/8/8/8/5PPP/2B3K1 w - - 0 1"

# Verified replacement for the plan's invalid free-queen FEN (there is no
# legal queen capture in that one; see tests/core/test_engine.py).  Black's
# queen on d5 is undefended; c1f4 ignores it.
FREE_QUEEN_FEN = "rnb1kbnr/ppp1pppp/8/3q4/8/8/PPP2PPP/RNBQKB1R w KQkq - 0 1"

# White's only two pawn moves both allow ...Re1# (verified in test_engine.py).
MATED_IN_TWO_FEN = "4r2k/8/8/8/8/3n3q/P7/6K1 w - - 0 1"

DEPTH = 8

FIXTURES = {
    "quiet": (QUIET_FEN, "e2e4"),
    "hanging_knight": (HANGING_KNIGHT_FEN, "h2h3"),
    "free_pawn": (FREE_PAWN_FEN, "h2h3"),
    "mate_in_one": (BACK_RANK_FEN, "c1f4"),
    "free_queen": (FREE_QUEEN_FEN, "c1f4"),
}


class StubEngine:
    """Duck-typed stand-in for Engine.analyse (the only method Coach uses)."""

    def __init__(self, analysis: MoveAnalysis) -> None:
        self.analysis = analysis
        self.calls: list[tuple[str, str, int]] = []

    def analyse(
        self, fen_before: str, played_uci: str, depth: int = 12
    ) -> MoveAnalysis:
        self.calls.append((fen_before, played_uci, depth))
        return self.analysis


def _analysis(
    best_uci: str,
    played_uci: str,
    best_cp: int,
    played_cp: int,
) -> MoveAnalysis:
    return MoveAnalysis(
        played_uci=played_uci,
        best_uci=best_uci,
        played_cp=played_cp,
        best_cp=best_cp,
        mate_against=False,
    )


@pytest.fixture(scope="module")
def engine():
    eng = Engine()
    try:
        yield eng
    finally:
        eng.close()


@pytest.fixture(scope="module")
def coach(engine):
    return Coach(engine, depth=DEPTH)


@pytest.fixture(scope="module")
def observed(coach):
    """Evaluate every real fixture once; tests below share the results."""
    results = {}
    for name, (fen, uci) in FIXTURES.items():
        board = chess.Board(fen)
        verdict = coach.evaluate(board, uci)
        results[name] = (verdict, coach.message(board, uci))
    return results


# --- verdicts and messages (real engine) ----------------------------------


def test_quiet_move_is_silent(observed):
    verdict, message = observed["quiet"]
    assert verdict is CoachVerdict.SILENT
    assert message == "", "a quiet move must produce no visible message"


def test_hanging_piece_is_blunder_with_plain_message(observed, coach):
    verdict, message = observed["hanging_knight"]
    assert verdict is CoachVerdict.BLUNDER
    assert "knight" in message, message
    assert "f3" in message, message
    assert coach.never_names_the_move(message, chess.Board(HANGING_KNIGHT_FEN))


def test_missed_free_capture_is_notable(observed, coach):
    verdict, message = observed["free_pawn"]
    assert verdict is CoachVerdict.NOTABLE
    assert "pawn" in message, message
    assert "e5" in message, message
    assert coach.never_names_the_move(message, chess.Board(FREE_PAWN_FEN))


def test_missed_free_queen_is_blunder_and_echoes_the_capture(observed, coach):
    verdict, message = observed["free_queen"]
    assert verdict is CoachVerdict.BLUNDER
    assert "queen" in message, message
    assert "d5" in message, message
    assert "Qxd5" in message, "the free-material phrase may name the capture"
    assert coach.never_names_the_move(message, chess.Board(FREE_QUEEN_FEN))


def test_allows_mate_in_one_is_blunder(observed, coach):
    verdict, message = observed["mate_in_one"]
    assert verdict is CoachVerdict.BLUNDER
    assert "mate" in message, message
    assert coach.never_names_the_move(message, chess.Board(BACK_RANK_FEN))


# --- never_names_the_move -------------------------------------------------


@pytest.mark.parametrize("name", sorted(FIXTURES))
def test_never_names_the_move_over_the_fixture_set(name, observed, coach):
    fen, _ = FIXTURES[name]
    _, message = observed[name]
    assert coach.never_names_the_move(message, chess.Board(fen))


def test_never_names_the_move_rejects_a_suggested_move(coach):
    board = chess.Board(QUIET_FEN)
    assert not coach.never_names_the_move("instead of that, Nf3 was better.", board)
    assert not coach.never_names_the_move("a better try was Nc3.", board)
    assert not coach.never_names_the_move("e4 was stronger.", board)

    castling = chess.Board("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
    assert not coach.never_names_the_move(
        "you should have castled with O-O.", castling
    )

    # Legal in this position, but it is not a capture at all.
    assert not coach.never_names_the_move(
        "the bishop could go Bg5.", chess.Board(FREE_QUEEN_FEN)
    )


def test_never_names_the_move_accepts_square_references(coach):
    board = chess.Board(QUIET_FEN)
    # e4 is a legal pawn push here, but "on e4" names a square, not a move.
    assert coach.never_names_the_move("the weak square on e4 matters.", board)


def test_never_names_the_move_allows_only_a_free_material_capture(coach):
    board = chess.Board(FREE_QUEEN_FEN)
    assert coach.never_names_the_move(
        "the queen on d5 was yours, Qxd5 wins it.", board
    )
    # Phrased as advice rather than as a description of what was there, the
    # same capture is no longer allowed.
    assert not coach.never_names_the_move("you should play Qxd5.", board)

    # A capture that is merely a trade is still a suggestion of the better move.
    defended_pawn = chess.Board("4k3/8/4p3/3p4/4P3/8/8/4K3 w - - 0 1")
    assert not coach.never_names_the_move(
        "the pawn should take with exd5.", defended_pawn
    )


def test_never_names_the_move_accepts_silence(coach):
    assert coach.never_names_the_move("", chess.Board(QUIET_FEN))


# --- thresholds (stub engine) ---------------------------------------------


@pytest.mark.parametrize(
    ("best_cp", "played_cp", "expected"),
    [
        (50, -49, CoachVerdict.SILENT),  # loss 99
        (50, -50, CoachVerdict.NOTABLE),  # loss 100
        (50, -199, CoachVerdict.NOTABLE),  # loss 249
        (50, -200, CoachVerdict.BLUNDER),  # loss 250
    ],
)
def test_verdict_thresholds(best_cp, played_cp, expected):
    stub = StubEngine(_analysis("d2d4", "e2e4", best_cp, played_cp))
    coach = Coach(stub, depth=DEPTH)
    assert coach.evaluate(chess.Board(), "e2e4") is expected


def test_mate_in_one_overrides_a_small_loss():
    board = chess.Board(BACK_RANK_FEN)
    # Loss is only 10 cp, but c1f4 allows ...Re1# and Kf1 does not.
    stub = StubEngine(_analysis("g1f1", "c1f4", best_cp=-980, played_cp=-990))
    coach = Coach(stub, depth=DEPTH)
    assert coach.evaluate(board, "c1f4") is CoachVerdict.BLUNDER
    assert "mate" in coach.message(board, "c1f4")


def test_unavoidable_mate_in_one_is_not_a_blunder():
    board = chess.Board(MATED_IN_TWO_FEN)
    # Both a2a3 (the engine's choice) and a2a4 allow ...Re1#.
    stub = StubEngine(_analysis("a2a3", "a2a4", best_cp=-980, played_cp=-990))
    coach = Coach(stub, depth=DEPTH)
    assert coach.evaluate(board, "a2a4") is CoachVerdict.SILENT
    assert coach.message(board, "a2a4") == ""


# --- phrasing is board-driven, not score-driven ---------------------------


def test_message_uses_board_facts_when_the_score_is_only_notable():
    board = chess.Board(HANGING_KNIGHT_FEN)
    stub = StubEngine(_analysis("f3h4", "h2h3", best_cp=0, played_cp=-100))
    coach = Coach(stub, depth=DEPTH)
    assert coach.evaluate(board, "h2h3") is CoachVerdict.NOTABLE
    message = coach.message(board, "h2h3")
    assert "knight" in message and "f3" in message
    assert coach.never_names_the_move(message, board)


def test_evaluate_then_message_reuses_one_analysis():
    stub = StubEngine(_analysis("d2d4", "e2e4", best_cp=30, played_cp=30))
    coach = Coach(stub, depth=DEPTH)
    board = chess.Board()
    coach.evaluate(board, "e2e4")
    coach.message(board, "e2e4")
    assert len(stub.calls) == 1


def test_kind_is_exposed_for_review_mode():
    assert CoachKind.MISSED_CAPTURE.value == "missed_capture"
    assert CoachVerdict.BLUNDER.value == "blunder"


# --- invalid input --------------------------------------------------------


@pytest.mark.parametrize("played_uci", ["e2e5", "not-a-move", "e1e2"])
def test_invalid_move_raises_value_error(played_uci):
    stub = StubEngine(_analysis("d2d4", "e2e4", best_cp=0, played_cp=0))
    coach = Coach(stub, depth=DEPTH)
    with pytest.raises(ValueError):
        coach.evaluate(chess.Board(), played_uci)
