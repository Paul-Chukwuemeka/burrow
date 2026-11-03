"""The chess board widget: squares, pieces, and player input.

The widget is a pure view: it never touches the controller.  It is handed a
board plus the side-to-move colour, it filters candidate moves against the
legal moves for that side, and it emits :attr:`BoardWidget.move_requested` with
a UCI string for a legal move.  Anything illegal (wrong turn, off-board, a
piece that cannot reach the target) is ignored silently, per the spec.

Interaction is both click-to-move and drag-and-drop, unified through
press/move/release:

* click a friendly piece to select it (legal targets get a dot);
* click a target square to complete the move (click-to-move);
* press a friendly piece, drag, and release on a target to complete the move
  (drag-and-drop).  A pawn promotion defaults to a queen.

Pieces are drawn from the Task 1 SVG assets via ``PyQt6.QtSvg`` when it is
available; a missing asset file, or a Qt build without QtSvg, falls back to
Unicode chess glyphs so the board always renders something.
"""

from __future__ import annotations

from pathlib import Path

import chess
from PyQt6.QtCore import QPointF, QRectF, Qt, pyqtSignal
from PyQt6.QtGui import QColor, QFont, QPainter, QPen
from PyQt6.QtWidgets import QWidget

from chess_trainer.gui.geometry import square_to_xy, xy_to_square

try:  # QtSvg is optional; Unicode glyphs are the fallback.
    from PyQt6.QtSvg import QSvgRenderer
except ImportError:  # pragma: no cover - depends on the Qt build
    QSvgRenderer = None

#: Piece type -> asset/colour letter (standard chess filename scheme).
_LETTER = {
    chess.PAWN: "p",
    chess.KNIGHT: "n",
    chess.BISHOP: "b",
    chess.ROOK: "r",
    chess.QUEEN: "q",
    chess.KING: "k",
}

#: Unicode chess glyphs keyed by ``"<colour>_<letter>"`` (fallback renderer).
_GLYPHS = {
    "w_k": "\u2654",
    "w_q": "\u2655",
    "w_r": "\u2656",
    "w_b": "\u2657",
    "w_n": "\u2658",
    "w_p": "\u2659",
    "b_k": "\u265a",
    "b_q": "\u265b",
    "b_r": "\u265c",
    "b_b": "\u265d",
    "b_n": "\u265e",
    "b_p": "\u265f",
}

#: The ``chess-trainer/assets/pieces`` directory, resolved like ``store.py``.
_ASSETS_DIR = Path(__file__).resolve().parents[3] / "assets" / "pieces"

_LIGHT = QColor("#F0D9B5")
_DARK = QColor("#B58863")
_SELECT = QColor(255, 230, 60, 120)
_LAST_MOVE = QColor(255, 255, 90, 110)
_HINT = QColor(0, 0, 0, 70)

#: A click must move this many pixels before it counts as a drag.
_DRAG_THRESHOLD = 8


class BoardWidget(QWidget):
    """Renders a position and turns clicks/drags into ``move_requested``."""

    move_requested = pyqtSignal(str)  # a legal UCI move chosen by the player

    def __init__(self, parent: QWidget | None = None, *, white_bottom: bool = True):
        super().__init__(parent)
        self._white_bottom = white_bottom
        self._board = chess.Board()
        self._player_color = chess.WHITE
        self._legal_moves: set[chess.Move] = set()
        self._last_move: chess.Move | None = None
        self._selected: int | None = None
        self._press_square: int | None = None
        self._press_pos: QPointF | None = None
        self._drag_pos: QPointF | None = None
        self._drag_square: int | None = None
        self._dragging = False
        self._enabled = False
        self._svg: dict[tuple[str, str], object] = {}
        self._load_svg()
        self.setMouseTracking(True)
        self.setMinimumSize(320, 320)

    # -- configuration -----------------------------------------------------

    def set_position(
        self,
        board: chess.Board,
        *,
        player_color: chess.Color = chess.WHITE,
        last_move: chess.Move | None = None,
        enabled: bool = False,
    ) -> None:
        """Hand the widget a fresh position to render and interact with."""
        self._board = board.copy()
        self._player_color = player_color
        self._legal_moves = set(self._board.legal_moves)
        self._last_move = last_move
        self._enabled = enabled
        self._selected = None
        self._press_square = None
        self._drag_square = None
        self._dragging = False
        self.update()

    def set_input_enabled(self, enabled: bool) -> None:
        """Enable or disable player input (selection and moves)."""
        self._enabled = enabled
        if not enabled:
            self._selected = None
            self._dragging = False
            self._drag_square = None
        self.update()

    # -- internals ---------------------------------------------------------

    def _load_svg(self) -> None:
        if QSvgRenderer is None or not _ASSETS_DIR.is_dir():
            return
        for color in ("w", "b"):
            for letter in "kqrbnp":
                path = _ASSETS_DIR / f"{color}_{letter}.svg"
                if not path.is_file():
                    continue
                try:
                    self._svg[(color, letter)] = QSvgRenderer(str(path))
                except Exception:  # noqa: BLE001 - one bad asset must not break paint
                    self._svg[(color, letter)] = None

    def _board_metrics(self) -> tuple[int, int, int]:
        size = min(self.width(), self.height())
        sq = size // 8
        ox = (self.width() - sq * 8) // 2
        oy = (self.height() - sq * 8) // 2
        return sq, ox, oy

    def _square_rect(self, square: int, sq: int, ox: int, oy: int) -> QRectF:
        x, y = square_to_xy(square, sq, white_bottom=self._white_bottom)
        return QRectF(ox + x, oy + y, sq, sq)

    def _promotion_move(self, frm: int, to: int) -> chess.Move | None:
        """The legal move ``frm -> to``, preferring a queen on promotion."""
        for promotion in (None, chess.QUEEN, chess.ROOK, chess.BISHOP, chess.KNIGHT):
            move = chess.Move(frm, to, promotion=promotion)
            if move in self._legal_moves:
                return move
        return None

    def _try_move(self, frm: int, to: int) -> None:
        if not self._enabled or frm == to:
            self._selected = None
            self.update()
            return
        move = self._promotion_move(frm, to)
        if move is None:
            # Illegal attempt: ignore silently.
            self._selected = None
            self.update()
            return
        self._selected = None
        self.update()
        self.move_requested.emit(move.uci())

    # -- painting ----------------------------------------------------------

    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        sq, ox, oy = self._board_metrics()
        if sq <= 0:
            painter.end()
            return
        self._draw_squares(painter, sq, ox, oy)
        self._draw_highlights(painter, sq, ox, oy)
        self._draw_pieces(painter, sq, ox, oy)
        if (
            self._dragging
            and self._drag_square is not None
            and self._drag_pos is not None
        ):
            piece = self._board.piece_at(self._drag_square)
            if piece is not None:
                self._draw_piece(
                    painter,
                    piece,
                    self._drag_pos.x() - sq / 2,
                    self._drag_pos.y() - sq / 2,
                    sq,
                )
        painter.end()

    def _draw_squares(self, painter: QPainter, sq: int, ox: int, oy: int) -> None:
        for square in range(64):
            file = chess.square_file(square)
            rank = chess.square_rank(square)
            color = _LIGHT if (file + rank) % 2 == 0 else _DARK
            painter.fillRect(self._square_rect(square, sq, ox, oy), color)

    def _draw_highlights(self, painter: QPainter, sq: int, ox: int, oy: int) -> None:
        if self._last_move is not None:
            for square in (self._last_move.from_square, self._last_move.to_square):
                painter.fillRect(self._square_rect(square, sq, ox, oy), _LAST_MOVE)
        if self._selected is None:
            return
        painter.fillRect(self._square_rect(self._selected, sq, ox, oy), _SELECT)
        for move in self._legal_moves:
            if move.from_square != self._selected:
                continue
            center = self._square_rect(move.to_square, sq, ox, oy).center()
            radius = sq * 0.16
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(_HINT)
            painter.drawEllipse(center, radius, radius)

    def _draw_pieces(self, painter: QPainter, sq: int, ox: int, oy: int) -> None:
        for square, piece in self._board.piece_map().items():
            if self._dragging and square == self._drag_square:
                continue  # the dragged piece follows the cursor
            x, y = square_to_xy(square, sq, white_bottom=self._white_bottom)
            self._draw_piece(painter, piece, ox + x, oy + y, sq)

    def _draw_piece(
        self, painter: QPainter, piece: chess.Piece, x: float, y: float, sq: int
    ) -> None:
        color = "w" if piece.color else "b"
        letter = _LETTER[piece.piece_type]
        renderer = self._svg.get((color, letter))
        if renderer is not None:
            renderer.render(painter, QRectF(x, y, sq, sq))
            return
        # Unicode fallback (also used when QtSvg is absent).
        painter.save()
        font = QFont()
        font.setPixelSize(max(1, int(sq * 0.72)))
        painter.setFont(font)
        painter.setPen(QPen(QColor("#1b1b1b")))
        painter.drawText(
            QRectF(x, y, sq, sq),
            Qt.AlignmentFlag.AlignCenter,
            _GLYPHS[f"{color}_{letter}"],
        )
        painter.restore()

    # -- mouse input -------------------------------------------------------

    def mousePressEvent(self, event) -> None:
        if event.button() != Qt.MouseButton.LeftButton:
            return
        sq, ox, oy = self._board_metrics()
        pos = event.position()
        square = (
            xy_to_square(
                int(pos.x() - ox),
                int(pos.y() - oy),
                sq,
                white_bottom=self._white_bottom,
            )
            if sq > 0
            else None
        )
        self._press_square = square
        self._press_pos = pos
        self._drag_pos = pos
        self._drag_square = None
        self._dragging = False
        # Selection is resolved on release, not here: a press may turn into a
        # drag, and a click that selects a piece must keep the selection alive
        # until the following click chooses its destination.
        self.update()

    def mouseMoveEvent(self, event) -> None:
        if (
            not (event.buttons() & Qt.MouseButton.LeftButton)
            or self._press_square is None
        ):
            return
        self._drag_pos = event.position()
        if not self._dragging and self._press_pos is not None:
            delta = self._drag_pos - self._press_pos
            if delta.manhattanLength() > _DRAG_THRESHOLD:
                piece = self._board.piece_at(self._press_square)
                if (
                    self._enabled
                    and piece is not None
                    and piece.color == self._player_color
                ):
                    self._dragging = True
                    self._drag_square = self._press_square
                    # A drag replaces any half-finished click-to-move.
                    self._selected = None
        self.update()

    def mouseReleaseEvent(self, event) -> None:
        if event.button() != Qt.MouseButton.LeftButton:
            return
        press = self._press_square
        was_dragging = self._dragging
        self._dragging = False
        self._drag_square = None
        self._press_square = None
        self._press_pos = None

        sq, ox, oy = self._board_metrics()
        pos = event.position()
        release = (
            xy_to_square(
                int(pos.x() - ox),
                int(pos.y() - oy),
                sq,
                white_bottom=self._white_bottom,
            )
            if sq > 0
            else None
        )

        if press is None:
            self.update()
            return

        if was_dragging:
            if release is not None and release != press:
                self._try_move(press, release)
            else:
                self.update()
            return

        if not self._enabled or release != press:
            self._selected = None
            self.update()
            return

        piece = self._board.piece_at(press)
        if piece is not None and piece.color == self._player_color:
            # Clicked a friendly piece: toggle selection.
            self._selected = None if self._selected == press else press
        elif self._selected is not None and self._selected != press:
            # Clicked a destination square for the selected piece.
            self._try_move(self._selected, press)
        else:
            self._selected = None
        self.update()
