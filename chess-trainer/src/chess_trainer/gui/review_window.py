"""Post-game review: step through a saved game, coach notes included.

A finished game is replayed from the FENs the controller stored with each
annotation, never by re-parsing SAN.  Every annotation records the position
*the move was played in* (``GameAnnotation.fen``) plus the move in UCI, so a
step is exact: build the board from that FEN, push the UCI move, and the
position -- castling rights, en passant square, promotion -- is the same one
the player saw.  Stepping backwards simply rebuilds an earlier step.

The coach's sentences are shown **verbatim**: they are the notes that were
saved with the game, not a fresh analysis.  Player blunders and notable moves
get a prominent note; bot notes are deliberately brief.  Practice games carry
``Practice`` in the title bar.

This module also owns the small amount of filesystem discovery needed by the
stats screen (:func:`list_saved_games`) so :class:`~chess_trainer.store.Store`
keeps its narrow public interface.  It reads ``<data>/games/<date>/*.pgn`` and
the parallel ``.annotations.json`` sidecar written by the store.  Corrupt
files are skipped rather than crashing the review screen.
"""

from __future__ import annotations

import io
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

import chess
import chess.pgn
from PyQt6.QtCore import Qt
from PyQt6.QtGui import QColor, QKeySequence, QShortcut
from PyQt6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from chess_trainer.bot import Bot
from chess_trainer.coach import CoachVerdict
from chess_trainer.controller import RESIGNATION, FinishedGame, GameAnnotation
from chess_trainer.gui.board_widget import BoardWidget
from chess_trainer.store import DEFAULT_BOT_STRENGTH

if TYPE_CHECKING:  # pragma: no cover - typing only
    from chess_trainer.store import Store

_START_FEN = chess.STARTING_FEN
_RESULTS = frozenset({"win", "loss", "draw"})

_BLUNDER_COLOR = QColor("#b71c1c")
_NOTABLE_COLOR = QColor("#e65100")
_BOT_NOTE_COLOR = QColor("#5c3d8f")


# --- saved-game discovery -------------------------------------------------


@dataclass(frozen=True)
class SavedGameRef:
    """One PGN + annotation-sidecar pair found on disk."""

    path: Path
    date: str
    result: str
    practice: bool
    blunders: int
    bot_strength: float
    player_white: bool
    resignation: bool

    @property
    def mode(self) -> str:
        return "Practice" if self.practice else "Clean"

    @property
    def display_date(self) -> str:
        if len(self.date) >= 16:
            return self.date[:16].replace("T", " ")
        return self.date or self.path.parent.name

    def load(self) -> ReviewGame:
        """Read this game back, including its saved coach annotations."""
        return load_saved_game(self)


@dataclass
class ReviewGame:
    """Everything the review window needs, from a fresh game or from disk."""

    annotations: list[GameAnnotation] = field(default_factory=list)
    practice: bool = False
    player_white: bool = True
    result: str = ""
    date: str = ""
    bot_strength: float = DEFAULT_BOT_STRENGTH
    resignation: bool = False
    pgn: str | None = None
    path: Path | None = None

    @property
    def mode(self) -> str:
        return "Practice" if self.practice else "Clean"

    @property
    def result_text(self) -> str:
        if self.result == "win":
            return "You won by resignation" if self.resignation else "You won"
        if self.result == "loss":
            return "You resigned" if self.resignation else "You lost"
        if self.result == "draw":
            return "Draw"
        return ""

    @property
    def title(self) -> str:
        parts = ["Game review", self.mode]
        if self.result_text:
            parts.append(self.result_text)
        return " \u2014 ".join(parts)


@dataclass(frozen=True)
class ReviewStep:
    """One position in the game; ``annotation`` is the move leading here."""

    index: int
    fen: str
    move_uci: str | None
    san: str | None
    annotation: GameAnnotation | None

    @property
    def last_move(self) -> chess.Move | None:
        if not self.move_uci:
            return None
        try:
            return chess.Move.from_uci(self.move_uci)
        except ValueError:
            return None


def _as_int(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        return 0
    return max(0, value)


def _as_strength(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return DEFAULT_BOT_STRENGTH
    number = float(value)
    if not math.isfinite(number):
        return DEFAULT_BOT_STRENGTH
    return min(max(number, 0.0), 20.0)


def _result_from_header(header: str, player_white: bool) -> str:
    if header == "1/2-1/2":
        return "draw"
    if header == "1-0":
        return "win" if player_white else "loss"
    if header == "0-1":
        return "loss" if player_white else "win"
    return ""


def _result_from_pgn(pgn: str, player_white: bool) -> str:
    try:
        game = chess.pgn.read_game(io.StringIO(pgn))
    except (ValueError, KeyError, IndexError):
        return ""
    if game is None:
        return ""
    return _result_from_header(game.headers.get("Result", "*"), player_white)


def _verdict_from_payload(value: object) -> CoachVerdict:
    try:
        return CoachVerdict(value)
    except (TypeError, ValueError):
        return CoachVerdict.SILENT


def _annotation_from_payload(raw: object) -> GameAnnotation | None:
    """Parse one stored annotation, or ``None`` when it is unusable."""
    if not isinstance(raw, dict):
        return None
    ply = raw.get("ply")
    fen = raw.get("fen")
    move_uci = raw.get("move_uci")
    if (
        isinstance(ply, bool)
        or not isinstance(ply, int)
        or ply < 1
        or not isinstance(fen, str)
        or not fen
        or not isinstance(move_uci, str)
        or not move_uci
    ):
        return None
    message = raw.get("message")
    return GameAnnotation(
        ply=ply,
        fen=fen,
        move_uci=move_uci,
        verdict=_verdict_from_payload(raw.get("verdict")),
        message=message if isinstance(message, str) and message else None,
        is_player=raw.get("is_player") is True,
    )


def _annotations_from_payload(payload: object) -> list[GameAnnotation]:
    if not isinstance(payload, dict):
        return []
    raw_annotations = payload.get("annotations")
    if not isinstance(raw_annotations, list):
        return []
    by_ply: dict[int, GameAnnotation] = {}
    for raw in raw_annotations:
        annotation = _annotation_from_payload(raw)
        if annotation is not None:
            by_ply[annotation.ply] = annotation
    return [by_ply[ply] for ply in sorted(by_ply)]


def _read_payload(path: Path) -> dict[str, object] | None:
    sidecar = path.with_name(path.stem + ".annotations.json")
    try:
        payload = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def _ref_from_payload(path: Path, payload: dict[str, object]) -> SavedGameRef | None:
    # Read the PGN up front: unreadable bytes (including UnicodeDecodeError,
    # a ValueError) mean this is not a usable PGN/sidecar pair.  Skipping it
    # keeps a corrupt file from breaking the whole history list.
    try:
        pgn = path.read_text(encoding="utf-8")
    except (OSError, ValueError):
        return None
    player_white = payload.get("player_white") is not False
    result = payload.get("result")
    if result not in _RESULTS:
        result = _result_from_pgn(pgn, player_white)
    date = payload.get("date")
    if not isinstance(date, str) or not date:
        date = path.parent.name
    return SavedGameRef(
        path=path,
        date=date,
        result=result if result in _RESULTS else "",
        practice=payload.get("practice") is True,
        blunders=_as_int(payload.get("blunders")),
        bot_strength=_as_strength(payload.get("bot_strength")),
        player_white=player_white,
        resignation=payload.get("resignation") is True,
    )


def list_saved_games(store: Store) -> list[SavedGameRef]:
    """Every saved PGN with a readable annotation sidecar, newest first.

    The store's public surface stays unchanged; ``Store.data_dir`` is public,
    so the games live under ``<data_dir>/games``.  Unreadable sidecars are
    skipped: a game without its coach notes cannot be reviewed faithfully.
    """
    data_dir = getattr(store, "data_dir", None)
    if data_dir is None:
        return []
    games_dir = Path(data_dir) / "games"
    if not games_dir.is_dir():
        return []
    try:
        paths = [path for path in games_dir.rglob("*.pgn") if path.is_file()]
    except OSError:
        return []
    refs: list[SavedGameRef] = []
    for path in paths:
        payload = _read_payload(path)
        if payload is None:
            continue
        ref = _ref_from_payload(path, payload)
        if ref is None:
            continue
        refs.append(ref)
    refs.sort(key=lambda ref: (ref.date, str(ref.path)), reverse=True)
    return refs


def load_saved_game(ref: SavedGameRef) -> ReviewGame:
    """Load a saved pair back into a :class:`ReviewGame`."""
    payload = _read_payload(ref.path)
    annotations = _annotations_from_payload(payload)
    try:
        pgn = ref.path.read_text(encoding="utf-8")
    except (OSError, ValueError):
        # Same tolerance as listing: an unreadable/corrupt PGN still opens
        # with its saved annotations, just without the PGN fallback.
        pgn = None
    return ReviewGame(
        annotations=annotations,
        practice=ref.practice,
        player_white=ref.player_white,
        result=ref.result,
        date=ref.date,
        bot_strength=ref.bot_strength,
        resignation=ref.resignation,
        pgn=pgn,
        path=ref.path,
    )


def review_from_finished(finished: FinishedGame) -> ReviewGame:
    """Build a review game from the controller's end-of-game record."""
    return ReviewGame(
        annotations=list(finished.annotations),
        practice=finished.is_practice,
        player_white=finished.player_white,
        result=_result_from_pgn(finished.pgn, finished.player_white),
        bot_strength=finished.bot_strength,
        resignation=finished.result == RESIGNATION,
        pgn=finished.pgn,
    )


# --- position replay ------------------------------------------------------


def _safe_board(fen: str) -> chess.Board | None:
    try:
        return chess.Board(fen)
    except ValueError:
        return None


def _is_contiguous(annotations: list[GameAnnotation]) -> bool:
    return bool(annotations) and [a.ply for a in annotations] == list(
        range(1, len(annotations) + 1)
    )


def _move_text(step: ReviewStep) -> str:
    ply = step.annotation.ply if step.annotation is not None else step.index
    fullmove = (ply + 1) // 2
    prefix = f"{fullmove}." if ply % 2 == 1 else f"{fullmove}\u2026"
    return f"{prefix} {step.san or step.move_uci or '?'}"


def _steps_from_annotations(annotations: list[GameAnnotation]) -> list[ReviewStep]:
    """Replay every stored FEN exactly, one annotation per ply."""
    start = _safe_board(annotations[0].fen)
    steps = [
        ReviewStep(
            index=0,
            fen=(start.fen() if start is not None else _START_FEN),
            move_uci=None,
            san=None,
            annotation=None,
        )
    ]
    for annotation in annotations:
        before = _safe_board(annotation.fen)
        if before is None:
            before = chess.Board(steps[-1].fen)
        san: str | None = None
        move: chess.Move | None = None
        try:
            move = chess.Move.from_uci(annotation.move_uci)
            san = before.san(move)
        except ValueError:
            move = None
        if move is not None:
            after = before.copy()
            try:
                after.push(move)
            except ValueError:
                pass
            else:
                before = after
        steps.append(
            ReviewStep(
                index=len(steps),
                fen=before.fen(),
                move_uci=annotation.move_uci,
                san=san,
                annotation=annotation,
            )
        )
    return steps


def _steps_from_pgn(
    pgn: str, annotations: list[GameAnnotation] = ()
) -> list[ReviewStep]:
    """Fallback for old/partial sidecars: replay the PGN's mainline moves."""
    try:
        game = chess.pgn.read_game(io.StringIO(pgn))
    except (ValueError, KeyError, IndexError):
        return []
    if game is None:
        return []
    by_ply = {annotation.ply: annotation for annotation in annotations}
    board = game.board()
    steps = [
        ReviewStep(
            index=0,
            fen=board.fen(),
            move_uci=None,
            san=None,
            annotation=None,
        )
    ]
    for ply, move in enumerate(game.mainline_moves(), start=1):
        try:
            san = board.san(move)
        except ValueError:
            san = move.uci()
        board.push(move)
        annotation = by_ply.get(ply)
        if annotation is not None and annotation.move_uci != move.uci():
            annotation = None
        steps.append(
            ReviewStep(
                index=ply,
                fen=board.fen(),
                move_uci=move.uci(),
                san=san,
                annotation=annotation,
            )
        )
    return steps


def build_steps(game: ReviewGame) -> list[ReviewStep]:
    """The full step list, starting at the initial position.

    Stored annotations are authoritative.  The PGN is only a fallback for a
    sidecar that is missing moves (for example a game saved by an older
    build), so normal reviews never re-derive positions from SAN.
    """
    annotations = sorted(game.annotations, key=lambda annotation: annotation.ply)
    if _is_contiguous(annotations):
        return _steps_from_annotations(annotations)
    if game.pgn:
        steps = _steps_from_pgn(game.pgn, annotations)
        if steps:
            return steps
    start = annotations[0].fen if annotations else _START_FEN
    board = _safe_board(start)
    return [
        ReviewStep(
            index=0,
            fen=board.fen() if board is not None else _START_FEN,
            move_uci=None,
            san=None,
            annotation=None,
        )
    ]


# --- the window -----------------------------------------------------------


class ReviewWindow(QMainWindow):
    """A read-only board plus the game's saved coach story."""

    def __init__(self, game: ReviewGame, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._game = game
        self._steps = build_steps(game)
        self._index = max(0, len(self._steps) - 1)
        self._shortcuts: list[QShortcut] = []
        self._build_ui()
        self._populate_moves()
        self.show_ply(self._index)

    # -- construction ------------------------------------------------------

    def _build_ui(self) -> None:
        self.setWindowTitle(self._game.title)
        self.resize(1060, 800)

        self._title = QLabel(self._game.title)
        title_font = self._title.font()
        title_font.setPointSize(title_font.pointSize() + 3)
        title_font.setBold(True)
        self._title.setFont(title_font)
        self._title.setWordWrap(True)

        subtitle_bits: list[str] = []
        if self._game.date:
            subtitle_bits.append(self._game.date[:16].replace("T", " "))
        subtitle_bits.append(f"Bot \u2248 {Bot.estimate_elo(self._game.bot_strength)}")
        self._subtitle = QLabel("  \u00b7  ".join(subtitle_bits))
        self._subtitle.setStyleSheet("color: #555;")

        self._board_widget = BoardWidget()
        self._board_widget.setMinimumSize(460, 460)
        self._board_widget.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding
        )
        orientation = chess.WHITE if self._game.player_white else chess.BLACK
        self._board_widget.set_position(
            chess.Board(), player_color=orientation, enabled=False
        )

        self._start_btn = QPushButton("Start")
        self._prev_btn = QPushButton("\u2039")
        self._next_btn = QPushButton("\u203a")
        self._end_btn = QPushButton("End")
        self._ply_label = QLabel("")
        self._ply_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._start_btn.clicked.connect(self._first)
        self._prev_btn.clicked.connect(self._previous)
        self._next_btn.clicked.connect(self._next)
        self._end_btn.clicked.connect(self._last)

        nav = QHBoxLayout()
        nav.addWidget(self._start_btn)
        nav.addWidget(self._prev_btn)
        nav.addWidget(self._ply_label, 1)
        nav.addWidget(self._next_btn)
        nav.addWidget(self._end_btn)

        left = QVBoxLayout()
        left.addWidget(self._title)
        left.addWidget(self._subtitle)
        left.addWidget(self._board_widget, 1)
        left.addLayout(nav)

        self._verdict = QLabel("")
        verdict_font = self._verdict.font()
        verdict_font.setBold(True)
        self._verdict.setFont(verdict_font)
        self._move_label = QLabel("")
        self._move_label.setWordWrap(True)
        move_font = self._move_label.font()
        move_font.setBold(True)
        self._move_label.setFont(move_font)
        self._reason = QLabel("")
        self._reason.setWordWrap(True)
        self._reason.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse
        )

        self._move_list = QListWidget()
        self._move_list.setMinimumWidth(250)
        self._move_list.setMaximumWidth(320)
        self._move_list.itemClicked.connect(self._on_move_clicked)
        self._move_list.itemActivated.connect(self._on_move_clicked)

        moves_heading = QLabel("Moves")
        moves_font = moves_heading.font()
        moves_font.setBold(True)
        moves_heading.setFont(moves_font)

        right = QVBoxLayout()
        right.addWidget(self._verdict)
        right.addWidget(self._move_label)
        right.addWidget(self._reason)
        right.addSpacing(12)
        right.addWidget(moves_heading)
        right.addWidget(self._move_list, 1)

        central = QWidget()
        root = QHBoxLayout(central)
        root.addLayout(left, 1)
        root.addLayout(right)
        self.setCentralWidget(central)

        for key, handler in (
            ("Left", self._previous),
            ("Right", self._next),
            ("Home", self._first),
            ("End", self._last),
        ):
            shortcut = QShortcut(QKeySequence(key), self)
            shortcut.activated.connect(handler)
            self._shortcuts.append(shortcut)

    def _populate_moves(self) -> None:
        self._move_list.clear()
        for step in self._steps[1:]:
            label = _move_text(step)
            annotation = step.annotation
            item = QListWidgetItem(label)
            item.setData(Qt.ItemDataRole.UserRole, step.index)
            if annotation is not None and not annotation.is_player:
                # Bot notes are deliberately briefer than the player's story.
                if annotation.verdict is not CoachVerdict.SILENT or annotation.message:
                    label += (
                        "   bot blunder"
                        if annotation.verdict is CoachVerdict.BLUNDER
                        else "   bot note"
                    )
                    item.setText(label)
                    item.setForeground(_BOT_NOTE_COLOR)
            elif annotation is not None:
                if annotation.verdict is CoachVerdict.BLUNDER:
                    item.setText(label + "   blunder")
                    item.setForeground(_BLUNDER_COLOR)
                elif annotation.verdict is CoachVerdict.NOTABLE:
                    item.setText(label + "   notable")
                    item.setForeground(_NOTABLE_COLOR)
            self._move_list.addItem(item)

    # -- navigation --------------------------------------------------------

    @property
    def current_ply(self) -> int:
        """The 0-based ply currently painted (0 is the initial position)."""
        return self._index

    @property
    def steps(self) -> list[ReviewStep]:
        return list(self._steps)

    def show_ply(self, index: int) -> None:
        """Paint the position at ``index`` and show its saved coach note."""
        if not self._steps:
            return
        index = max(0, min(index, len(self._steps) - 1))
        self._index = index
        step = self._steps[index]
        board = _safe_board(step.fen)
        if board is None:  # pragma: no cover - defensive; stored FENs are valid
            board = chess.Board()
        orientation = chess.WHITE if self._game.player_white else chess.BLACK
        self._board_widget.set_position(
            board,
            player_color=orientation,
            last_move=step.last_move,
            enabled=False,
        )

        total = len(self._steps) - 1
        self._ply_label.setText(f"Ply {index} of {total}")
        self._start_btn.setEnabled(index > 0)
        self._prev_btn.setEnabled(index > 0)
        self._next_btn.setEnabled(index < total)
        self._end_btn.setEnabled(index < total)

        self._update_note(step)
        self._sync_move_selection()

    def _update_note(self, step: ReviewStep) -> None:
        annotation = step.annotation
        if annotation is None:
            if step.index == 0:
                self._verdict.setText("")
                self._verdict.setVisible(False)
                self._move_label.setText("Starting position")
                self._reason.setStyleSheet("color: #555;")
                self._reason.setText(
                    "Use \u2039 and \u203a (or the arrow keys) to step through "
                    "the game. Coach notes are the ones saved at the time."
                )
            else:
                self._verdict.setText("")
                self._verdict.setVisible(False)
                self._move_label.setText(f"Move {step.index}: {step.san or ''}")
                self._reason.setStyleSheet("color: #555;")
                self._reason.setText("No saved coach note for this move.")
            return

        san = step.san or annotation.move_uci
        if annotation.is_player:
            self._move_label.setText(f"You played {san}.")
        else:
            self._move_label.setText(f"Bot played {san}.")

        if annotation.is_player:
            if annotation.verdict is CoachVerdict.BLUNDER:
                self._verdict.setText("Blunder")
                self._verdict.setStyleSheet("color: #b71c1c;")
                self._verdict.setVisible(True)
            elif annotation.verdict is CoachVerdict.NOTABLE:
                self._verdict.setText("Notable")
                self._verdict.setStyleSheet("color: #b26a00;")
                self._verdict.setVisible(True)
            else:
                self._verdict.setText("")
                self._verdict.setVisible(False)
        else:
            if annotation.verdict is CoachVerdict.BLUNDER:
                self._verdict.setText("Bot slip")
                self._verdict.setStyleSheet("color: #5c3d8f;")
                self._verdict.setVisible(True)
            elif annotation.verdict is CoachVerdict.NOTABLE:
                self._verdict.setText("Bot note")
                self._verdict.setStyleSheet("color: #5c3d8f;")
                self._verdict.setVisible(True)
            else:
                self._verdict.setText("")
                self._verdict.setVisible(False)

        if annotation.message:
            if annotation.is_player:
                # Verbatim: exactly the sentence the coach saved with the game.
                self._reason.setStyleSheet("")
                self._reason.setText(annotation.message)
            else:
                # Bot notes stay brief and visually secondary.
                self._reason.setStyleSheet("color: #5c3d8f; font-size: 8pt;")
                self._reason.setText(f"Coach: {annotation.message}")
        else:
            self._reason.setStyleSheet("color: #555;")
            self._reason.setText("No coach note for this move.")

    def _sync_move_selection(self) -> None:
        self._move_list.blockSignals(True)
        if self._index == 0:
            self._move_list.clearSelection()
            self._move_list.setCurrentRow(-1)
        else:
            self._move_list.setCurrentRow(self._index - 1)
            item = self._move_list.currentItem()
            if item is not None:
                self._move_list.scrollToItem(item)
        self._move_list.blockSignals(False)

    def _on_move_clicked(self, item: QListWidgetItem) -> None:
        index = item.data(Qt.ItemDataRole.UserRole)
        if isinstance(index, int):
            self.show_ply(index)

    def _previous(self) -> None:
        self.show_ply(self._index - 1)

    def _next(self) -> None:
        self.show_ply(self._index + 1)

    def _first(self) -> None:
        self.show_ply(0)

    def _last(self) -> None:
        self.show_ply(len(self._steps) - 1)
