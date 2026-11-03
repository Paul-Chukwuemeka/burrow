"""The main window: board, coach panel, move list, captured tray, controls.

The window owns the :class:`~chess_trainer.controller.GameController` and the
thread discipline around it.  The controller is not thread-safe, and the two
slow engine calls -- ``try_player_move``'s coach pass (live-coach mode) and
``bot_move`` -- must never run on the GUI thread.  They are therefore handed
to a single :class:`EngineWorker` (a ``QThread`` running one job at a time from
a queue), so the coach interrupt and the bot reply are strictly serialized and
the event loop keeps painting.  The GUI thread only ever reads the controller
between jobs (via ``snapshot()`` / ``board``), never while a job is in flight.

End-of-game finalisation is eager and may raise ``OSError`` when the data
directory is unwritable (Task 8).  The window catches that, shows a friendly
"couldn't save" note, and does not replay the final move.

Task 10 hooks in through :attr:`MainWindow.game_finished`, emitted with the
:class:`~chess_trainer.controller.FinishedGame` (or ``None`` if saving failed)
whenever a game ends.
"""

from __future__ import annotations

import queue
import traceback

import chess
from PyQt6.QtCore import QThread, pyqtSignal
from PyQt6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QListWidget,
    QMainWindow,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from chess_trainer.bot import Bot
from chess_trainer.controller import RESIGNATION, Mode, PlayerMoveOutcome
from chess_trainer.gui.board_widget import BoardWidget
from chess_trainer.gui.coach_panel import CoachPanel

#: Glyphs for the captured-pieces tray (independent of the board's SVG choice).
_TRAY_GLYPHS = {
    "wp": "\u2659",
    "wn": "\u2658",
    "wb": "\u2657",
    "wr": "\u2656",
    "wq": "\u2655",
    "bp": "\u265f",
    "bn": "\u265e",
    "bb": "\u265d",
    "br": "\u265c",
    "bq": "\u265b",
}


class EngineWorker(QThread):
    """Runs controller jobs one at a time, off the GUI thread.

    A single thread with a FIFO queue is the serialisation point: the coach
    pass inside ``try_player_move`` and the following ``bot_move`` can never
    overlap, and only this thread ever touches the shared Stockfish process.
    """

    # ``finished`` would shadow QThread's own signal, so the job results get
    # distinct names.
    job_done = pyqtSignal(str, object)  # (kind, result)
    job_failed = pyqtSignal(str, object)  # (kind, exception)

    def __init__(self, parent: QMainWindow | None = None):
        super().__init__(parent)
        self._queue: queue.Queue = queue.Queue()

    def run(self) -> None:
        while True:
            job = self._queue.get()
            if job is None:
                return
            kind, fn = job
            try:
                result = fn()
            except Exception as exc:  # noqa: BLE001 - report every job failure
                # An OSError here is the expected unwritable-data-dir case and
                # is reported in the window; anything else is a bug worth a
                # traceback on stderr.
                if not isinstance(exc, OSError):
                    traceback.print_exc()
                self.job_failed.emit(kind, exc)
            else:
                self.job_done.emit(kind, result)

    def submit(self, kind: str, fn) -> None:
        self._queue.put((kind, fn))

    def stop(self) -> None:
        self._queue.put(None)


class MainWindow(QMainWindow):
    """The single window the player runs."""

    #: Emitted when a game ends, with the FinishedGame (or None on save failure).
    game_finished = pyqtSignal(object)

    def __init__(
        self,
        controller,
        store,
        engine=None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self._controller = controller
        self._store = store
        self._engine = engine
        self._busy = False
        self._awaiting_retry = False
        self._game_over = False

        self._worker = EngineWorker(self)
        self._worker.job_done.connect(self._on_job_done)
        self._worker.job_failed.connect(self._on_job_failed)
        self._worker.start()

        self._build_ui()

        # Default: live coach ON, player is White.
        self._controller.new_game(self._mode())
        self._refresh_all()

    # -- UI construction ---------------------------------------------------

    def _build_ui(self) -> None:
        self.setWindowTitle("Chess Trainer")

        self._board_widget = BoardWidget()
        self._board_widget.setMinimumSize(420, 420)
        self._board_widget.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding
        )
        self._board_widget.move_requested.connect(self._on_player_move)

        self._captured_label = QLabel("")
        self._captured_label.setTextInteractionFlags(
            self._captured_label.textInteractionFlags()
        )

        self._elo_label = QLabel("")
        elo_font = self._elo_label.font()
        elo_font.setBold(True)
        self._elo_label.setFont(elo_font)

        self._coach_panel = CoachPanel()
        self._coach_panel.live_coach_toggled.connect(self._on_live_coach_toggled)
        self._coach_panel.take_back_requested.connect(self._on_take_back)
        self._coach_panel.keep_move_requested.connect(self._on_keep_move)

        self._move_list = QListWidget()
        self._move_list.setFixedWidth(180)

        self._status = QLabel("")
        self._status.setWordWrap(True)

        self._resign_btn = QPushButton("Resign")
        self._new_game_btn = QPushButton("New Game")
        self._resign_btn.clicked.connect(self._on_resign)
        self._new_game_btn.clicked.connect(self._on_new_game)

        buttons = QHBoxLayout()
        buttons.addWidget(self._resign_btn)
        buttons.addWidget(self._new_game_btn)

        left = QVBoxLayout()
        left.addWidget(self._board_widget, 1)
        left.addWidget(self._captured_label)

        right = QVBoxLayout()
        right.addWidget(self._elo_label)
        right.addWidget(self._coach_panel)
        right.addWidget(QLabel("Moves"))
        right.addWidget(self._move_list, 1)
        right.addWidget(self._status)
        right.addLayout(buttons)

        central = QWidget()
        root = QHBoxLayout(central)
        root.addLayout(left, 1)
        root.addLayout(right)
        self.setCentralWidget(central)
        self.resize(1000, 740)

    # -- mode / helpers ----------------------------------------------------

    def _mode(self) -> Mode:
        return Mode.LIVE_COACH if self._coach_panel.is_live_coach() else Mode.CLEAN

    def _player_color(self) -> chess.Color:
        return chess.WHITE if self._controller.player_white else chess.BLACK

    def _refresh_strength(self) -> None:
        elo = Bot.estimate_elo(self._controller.bot_strength)
        self._elo_label.setText(f"Bot \u2248 {elo}")

    def _refresh_board(self) -> None:
        snapshot = self._controller.snapshot()
        board = self._controller.board
        last_move = board.peek() if board.move_stack else None
        enabled = (
            not self._game_over
            and not self._awaiting_retry
            and not self._busy
            and snapshot.result is None
            and board.turn == self._player_color()
        )
        self._board_widget.set_position(
            board,
            player_color=self._player_color(),
            last_move=last_move,
            enabled=enabled,
        )

    def _show_preview(self, uci: str) -> None:
        """Paint the player's move at once while the worker confirms it.

        This is presentation only: the controller's board stays authoritative
        and the next :meth:`_refresh_board` replaces the preview with the real
        position (or reverts it if the move was rejected).
        """
        try:
            move = chess.Move.from_uci(uci)
        except ValueError:
            self._refresh_board()
            return
        preview = self._controller.board.copy()
        if move not in preview.legal_moves:
            self._refresh_board()
            return
        preview.push(move)
        self._board_widget.set_position(
            preview,
            player_color=self._player_color(),
            last_move=move,
            enabled=False,
        )

    def _apply_mode_if_idle(self) -> None:
        """Copy the panel's live-coach choice onto the controller between jobs.

        Mutating the controller while a worker job is in flight would race the
        coach pass it is running, so a toggle made mid-move takes effect as
        soon as the job finishes.
        """
        if self._busy:
            return
        mode = self._mode()
        if self._controller.mode is not mode:
            self._controller.mode = mode

    def _refresh_move_list(self) -> None:
        board = self._controller.board
        replay = chess.Board()
        items: list[str] = []
        for ply, move in enumerate(board.move_stack, start=1):
            san = replay.san(move)
            replay.push(move)
            fullmove = (ply + 1) // 2
            prefix = f"{fullmove}." if ply % 2 == 1 else f"{fullmove}\u2026"
            items.append(f"{prefix} {san}")
        self._move_list.clear()
        for item in items:
            self._move_list.addItem(item)
        self._move_list.scrollToBottom()

    def _refresh_captured(self) -> None:
        board = self._controller.board
        white_captured: list[chess.Piece] = []
        black_captured: list[chess.Piece] = []
        replay = chess.Board()
        for move in board.move_stack:
            if replay.is_capture(move):
                victim_square = move.to_square
                if replay.is_en_passant(move):
                    victim_square = chess.square(
                        chess.square_file(move.to_square),
                        chess.square_rank(move.from_square),
                    )
                victim = replay.piece_at(victim_square)
                if victim is not None:
                    target = (
                        white_captured if replay.turn == chess.WHITE else black_captured
                    )
                    target.append(victim)
            replay.push(move)

        def glyphs(pieces: list[chess.Piece]) -> str:
            letters = {
                chess.PAWN: "p",
                chess.KNIGHT: "n",
                chess.BISHOP: "b",
                chess.ROOK: "r",
                chess.QUEEN: "q",
            }
            return "".join(
                _TRAY_GLYPHS[
                    f"{'w' if piece.color else 'b'}{letters[piece.piece_type]}"
                ]
                for piece in pieces
            )

        if self._controller.player_white:
            mine, theirs = white_captured, black_captured
        else:
            mine, theirs = black_captured, white_captured
        if mine or theirs:
            self._captured_label.setText(
                f"You: {glyphs(mine)}\u2003 Bot: {glyphs(theirs)}"
            )
        else:
            self._captured_label.setText("")

    def _refresh_all(self) -> None:
        self._refresh_strength()
        self._refresh_board()
        self._refresh_move_list()
        self._refresh_captured()

    def _set_status(self, text: str) -> None:
        self._status.setText(text)

    def _result_text(self, snapshot) -> str:
        if snapshot.result is None:
            return ""
        if snapshot.result == RESIGNATION:
            return "You resigned \u2014 bot wins."
        outcome = self._controller.board.outcome()
        if outcome is None:
            return "Game over."
        if outcome.winner is None:
            return "Draw."
        return "You won!" if outcome.winner == self._player_color() else "Bot wins."

    # -- input handlers ----------------------------------------------------

    def _on_player_move(self, uci: str) -> None:
        if self._busy or self._awaiting_retry or self._game_over:
            return
        self._apply_mode_if_idle()
        self._busy = True
        # A SILENT verdict leaves the coach panel untouched (see
        # _on_player_move_done), so the message is not cleared here either.
        self._show_preview(uci)
        self._worker.submit(
            "player_move", lambda: self._controller.try_player_move(uci)
        )

    def _on_take_back(self) -> None:
        if self._busy or not self._awaiting_retry:
            return
        self._controller.undo_player_move()
        self._awaiting_retry = False
        self._coach_panel.clear_message()
        self._coach_panel.show_take_back(False)
        self._refresh_all()

    def _on_keep_move(self) -> None:
        if self._busy or not self._awaiting_retry:
            return
        self._awaiting_retry = False
        self._coach_panel.clear_message()
        self._coach_panel.show_take_back(False)
        self._busy = True
        self._refresh_board()
        self._worker.submit("confirm", self._controller.confirm_move)

    def _on_resign(self) -> None:
        if self._busy or self._game_over:
            return
        self._apply_mode_if_idle()
        self._busy = True
        self._worker.submit("resign", self._controller.resign)

    def _on_new_game(self) -> None:
        if self._busy:
            return
        self._controller.new_game(self._mode())
        self._game_over = False
        self._awaiting_retry = False
        self._busy = False
        self._coach_panel.clear_message()
        self._coach_panel.show_take_back(False)
        self._set_status("")
        self._refresh_all()

    def _on_live_coach_toggled(self, enabled: bool) -> None:
        # Applies to the current game from the next move onward, and to any
        # new game.  If a move is being evaluated right now, the change waits
        # for the worker to go idle so it cannot race the coach pass.
        self._apply_mode_if_idle()

    # -- worker results ----------------------------------------------------

    def _on_job_done(self, kind: str, result) -> None:
        self._busy = False
        self._apply_mode_if_idle()
        if kind == "player_move":
            self._on_player_move_done(result)
        elif kind == "bot_move":
            self._on_bot_move_done(result)
        elif kind == "confirm":
            self._on_confirm_done()
        elif kind == "resign":
            self._on_resign_done()
        else:  # pragma: no cover - unknown kinds are a bug
            self._refresh_all()

    def _on_player_move_done(self, outcome: PlayerMoveOutcome) -> None:
        if not outcome.accepted:
            self._refresh_all()
            return
        # Verbatim coach text, and only when there is one: a SILENT verdict
        # leaves the panel exactly as it was.
        if outcome.message:
            self._coach_panel.show_coach_message(outcome.message)
        if outcome.can_undo:
            self._awaiting_retry = True
            self._coach_panel.show_take_back(True)
            self._refresh_all()
            return
        self._refresh_all()
        self._maybe_bot_move()

    def _on_bot_move_done(self, _uci: str) -> None:
        self._refresh_all()
        self._maybe_finish_or_release()

    def _on_confirm_done(self) -> None:
        self._refresh_all()
        self._maybe_bot_move()

    def _on_resign_done(self) -> None:
        self._coach_panel.show_take_back(False)
        self._coach_panel.clear_message()
        self._finish_game()

    def _on_job_failed(self, kind: str, exc) -> None:
        self._busy = False
        self._apply_mode_if_idle()
        if isinstance(exc, OSError):
            # Eager finalisation could not write; the move is already on the
            # board and the game is over.  Do not replay the final move.
            self._coach_panel.show_take_back(False)
            self._coach_panel.clear_message()
            self._finish_game()
        else:  # pragma: no cover - defensive
            self._set_status(f"Something went wrong: {exc}")
            self._refresh_all()

    # -- flow helpers ------------------------------------------------------

    def _maybe_bot_move(self) -> None:
        snapshot = self._controller.snapshot()
        if snapshot.result is not None:
            self._finish_game()
            return
        if self._controller.board.turn == self._player_color():
            self._refresh_all()  # not the bot's turn (defensive)
            return
        self._busy = True
        self._refresh_board()
        self._worker.submit("bot_move", self._controller.bot_move)

    def _maybe_finish_or_release(self) -> None:
        snapshot = self._controller.snapshot()
        if snapshot.result is not None:
            self._finish_game()
        else:
            self._refresh_all()  # back to the player

    def _finish_game(self) -> None:
        snapshot = self._controller.snapshot()
        if snapshot.result is None:
            self._refresh_all()
            return
        if self._game_over:
            return
        self._game_over = True
        self._awaiting_retry = False
        self._busy = False
        self._coach_panel.show_take_back(False)
        self._coach_panel.clear_message()
        self._refresh_board()
        self._refresh_move_list()
        self._refresh_captured()
        status = self._result_text(snapshot)
        finished = None
        try:
            finished = self._controller.finished_game()
        except OSError:
            # Eager finalisation could not write (read-only data directory).
            # The move is already on the board; never replay it.
            status += " Couldn't save this game."
        # The retune happens inside finished_game, so read the dial afterwards.
        self._refresh_strength()
        self._set_status(status)
        # Task 10's review window hangs off this signal.
        self.game_finished.emit(finished)

    # -- shutdown ----------------------------------------------------------

    def closeEvent(self, event) -> None:
        self._worker.stop()
        self._worker.wait()
        if self._engine is not None:
            self._engine.close()
        super().closeEvent(event)
