"""Tests for the pure square <-> pixel mapping (no Qt, no display)."""

import chess
import pytest

from chess_trainer.gui.geometry import BOARD_SIZE, square_to_xy, xy_to_square


def test_a1_is_bottom_left_when_white_is_bottom():
    assert square_to_xy(chess.A1, 100, white_bottom=True) == (0, 700)


def test_h8_is_top_right_when_white_is_bottom():
    assert square_to_xy(chess.H8, 100, white_bottom=True) == (700, 0)


def test_e4_maps_to_the_middle_files_and_ranks():
    x, y = square_to_xy(chess.E4, 80, white_bottom=True)
    assert (x, y) == (4 * 80, 4 * 80)


def test_round_trip_every_square():
    for square in range(64):
        x, y = square_to_xy(square, 50, white_bottom=True)
        assert xy_to_square(x, y, 50, white_bottom=True) == square
        x, y = square_to_xy(square, 50, white_bottom=False)
        assert xy_to_square(x, y, 50, white_bottom=False) == square


def test_white_bottom_flips_ranks_not_files():
    x_top, y_top = square_to_xy(chess.A8, 100, white_bottom=True)
    x_bottom, y_bottom = square_to_xy(chess.A8, 100, white_bottom=False)
    assert x_top == x_bottom == 0  # file unchanged
    assert y_top == 0 and y_bottom == 700  # rank flips


@pytest.mark.parametrize("x,y", [(-1, 0), (800, 0), (0, -1), (0, 800)])
def test_off_board_pixels_return_none(x, y):
    assert xy_to_square(x, y, 100, white_bottom=True) is None


def test_board_size_constant_is_eight():
    assert BOARD_SIZE == 8
