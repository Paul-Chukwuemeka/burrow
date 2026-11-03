"""The stats screen: results, blunder rate, trend and saved-game history.

Everything here is read from :class:`~chess_trainer.store.Store`: cumulative
counts and per-game records from ``stats.json``, and the reviewable games from
the PGN/annotation pairs on disk (via
:func:`chess_trainer.gui.review_window.list_saved_games`).  Practice games are
the ones played with the live coach on; clean games are the rest.  The split is
derived from the per-game ``practice`` flag so both views always agree.

The trend is a deliberately plain painted strip -- one bar per game, no
plotting dependency.  The history list is the entry point to review mode:
choosing a saved game emits :attr:`StatsDialog.review_requested` with a loaded
:class:`~chess_trainer.gui.review_window.ReviewGame`.
"""

from __future__ import annotations

from collections import Counter
from typing import TYPE_CHECKING

from PyQt6.QtCore import QRectF, Qt, pyqtSignal
from PyQt6.QtGui import QColor, QFont, QPainter, QPen
from PyQt6.QtWidgets import (
    QDialog,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMessageBox,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from chess_trainer.bot import Bot
from chess_trainer.gui.review_window import SavedGameRef, list_saved_games
from chess_trainer.store import StatsFile

if TYPE_CHECKING:  # pragma: no cover - typing only
    from chess_trainer.store import GameRecord, Store

_WIN = QColor("#2e7d32")
_DRAW = QColor("#f9a825")
_LOSS = QColor("#c62828")
_GRID = QColor(0, 0, 0, 45)


def _average(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def _format_average(value: float | None) -> str:
    return "\u2014" if value is None else f"{value:.1f}"


def _counts(records: list[GameRecord]) -> tuple[int, int, int]:
    """``(wins, losses, draws)`` from the player's perspective."""
    counts = Counter(record.result for record in records)
    return (
        counts.get("win", 0),
        counts.get("loss", 0),
        counts.get("draw", 0),
    )


class TrendStrip(QWidget):
    """One painted bar per game: green win, amber draw, red loss."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._labels: list[str] = []
        self._points: list[float] = []
        self.setMinimumHeight(116)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

    def set_trend(self, labels: list[str], points: list[float]) -> None:
        self._labels = list(labels)
        self._points = list(points)
        if self._points:
            first = self._labels[0] if self._labels else ""
            last = self._labels[-1] if self._labels else ""
            self.setToolTip(
                f"{len(self._points)} games \u2014 oldest {first}, newest {last}"
            )
        else:
            self.setToolTip("No games yet")
        self.update()

    @property
    def points(self) -> list[float]:
        return list(self._points)

    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        rect = self.rect()
        painter.fillRect(rect, self.palette().base())

        margin = 12
        label_height = 20
        baseline = rect.height() - label_height - 6
        plot_top = 10
        plot_height = max(1, baseline - plot_top)

        if not self._points:
            painter.setPen(QPen(QColor("#777")))
            painter.drawText(
                rect,
                Qt.AlignmentFlag.AlignCenter,
                "No games yet \u2014 finish one to start the trend.",
            )
            painter.end()
            return

        # Half-point reference line, so draws are easy to read at a glance.
        painter.setPen(QPen(_GRID, 1, Qt.PenStyle.DashLine))
        mid = baseline - plot_height * 0.5
        painter.drawLine(margin, int(mid), rect.width() - margin, int(mid))

        count = len(self._points)
        slot = (rect.width() - 2 * margin) / count
        bar_width = max(2.0, min(26.0, slot * 0.72))
        for index, point in enumerate(self._points):
            if point >= 0.75:
                color = _WIN
            elif point > 0.25:
                color = _DRAW
            else:
                color = _LOSS
            height = max(2.0, max(0.0, min(1.0, point)) * plot_height)
            x = margin + index * slot + (slot - bar_width) / 2
            painter.fillRect(QRectF(x, baseline - height, bar_width, height), color)

        painter.setPen(QPen(_GRID))
        painter.drawLine(margin, int(baseline), rect.width() - margin, int(baseline))

        font = QFont(self.font())
        font.setPointSize(max(6, font.pointSize() - 2))
        painter.setFont(font)
        first = self._labels[0] if self._labels else ""
        last = self._labels[-1] if self._labels else ""
        painter.setPen(QPen(QColor("#555")))
        painter.drawText(
            QRectF(margin, baseline + 3, rect.width() - 2 * margin, label_height),
            Qt.AlignmentFlag.AlignLeft,
            first,
        )
        if last != first:
            painter.drawText(
                QRectF(
                    margin,
                    baseline + 3,
                    rect.width() - 2 * margin,
                    label_height,
                ),
                Qt.AlignmentFlag.AlignRight,
                last,
            )
        painter.end()


class StatsDialog(QDialog):
    """Wins/losses/draws, blunders, the trend strip and saved games."""

    #: Emitted with a loaded ReviewGame when a history row is chosen.
    review_requested = pyqtSignal(object)

    def __init__(self, store: Store, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._store = store
        self._stats = StatsFile()
        self._saved: list[SavedGameRef] = []
        self._summary_labels: dict[tuple[str, str], QLabel] = {}
        self._build_ui()
        self.refresh()

    # -- construction ------------------------------------------------------

    def _build_ui(self) -> None:
        self.setWindowTitle("Your stats")
        self.resize(800, 840)

        heading = QLabel("Your games")
        font = heading.font()
        font.setPointSize(font.pointSize() + 3)
        font.setBold(True)
        heading.setFont(font)

        self._headline = QLabel("")
        self._headline.setWordWrap(True)
        self._headline.setStyleSheet("color: #555;")

        results = QGroupBox("Results")
        grid = QGridLayout(results)
        headers = ["", "Games", "Wins", "Losses", "Draws", "Avg blunders"]
        for column, text in enumerate(headers):
            label = QLabel(text)
            label.setAlignment(Qt.AlignmentFlag.AlignCenter)
            label_font = label.font()
            label_font.setBold(True)
            label.setFont(label_font)
            grid.addWidget(label, 0, column)
        for row, (key, name) in enumerate(
            (("practice", "Practice"), ("clean", "Clean"), ("all", "All games")),
            start=1,
        ):
            name_label = QLabel(name)
            name_font = name_label.font()
            name_font.setBold(True)
            name_label.setFont(name_font)
            grid.addWidget(name_label, row, 0)
            for column, field_name in enumerate(
                ("games", "wins", "losses", "draws", "blunders"),
                start=1,
            ):
                value = QLabel("\u2014")
                value.setAlignment(Qt.AlignmentFlag.AlignCenter)
                self._summary_labels[(key, field_name)] = value
                grid.addWidget(value, row, column)
        grid.setColumnStretch(0, 1)

        self._note = QLabel("")
        self._note.setWordWrap(True)
        self._note.setStyleSheet("color: #777;")

        trend_box = QGroupBox("Result trend")
        trend_layout = QVBoxLayout(trend_box)
        caption = QLabel(
            "One bar per game, oldest to newest: green win, amber draw, red loss."
        )
        caption.setWordWrap(True)
        caption.setStyleSheet("color: #666;")
        self._trend = TrendStrip()
        trend_layout.addWidget(caption)
        trend_layout.addWidget(self._trend)

        history_box = QGroupBox("Saved games")
        history_layout = QVBoxLayout(history_box)
        history_caption = QLabel(
            "Pick a game to reopen it in review mode with its saved coach notes."
        )
        history_caption.setWordWrap(True)
        history_caption.setStyleSheet("color: #666;")
        self._history = QListWidget()
        self._history.setMinimumHeight(120)
        self._history.itemDoubleClicked.connect(lambda _item: self._review_selected())
        self._history.itemSelectionChanged.connect(self._update_review_button)
        self._empty = QLabel("No saved games yet \u2014 finish a game to see it here.")
        self._empty.setStyleSheet("color: #777;")
        self._review_btn = QPushButton("Review selected")
        self._review_btn.setEnabled(False)
        self._review_btn.clicked.connect(self._review_selected)

        history_buttons = QHBoxLayout()
        history_buttons.addStretch(1)
        history_buttons.addWidget(self._review_btn)
        history_layout.addWidget(history_caption)
        history_layout.addWidget(self._empty)
        history_layout.addWidget(self._history, 1)
        history_layout.addLayout(history_buttons)

        close_row = QHBoxLayout()
        close_row.addStretch(1)
        close_button = QPushButton("Close")
        close_button.clicked.connect(self.accept)
        close_row.addWidget(close_button)

        root = QVBoxLayout(self)
        root.addWidget(heading)
        root.addWidget(self._headline)
        root.addWidget(results)
        root.addWidget(self._note)
        root.addWidget(trend_box)
        root.addWidget(history_box, 1)
        root.addLayout(close_row)

    # -- data --------------------------------------------------------------

    @property
    def stats(self) -> StatsFile:
        return self._stats

    @property
    def saved_games(self) -> list[SavedGameRef]:
        return list(self._saved)

    def refresh(self) -> None:
        """Re-read stats and saved games (called whenever the dialog opens)."""
        self._stats = self._store.load_stats()
        self._saved = list_saved_games(self._store)
        self._update_summary()
        labels, points = self._stats.trend()
        self._trend.set_trend(labels, points)
        self._populate_history()

    def _update_summary(self) -> None:
        stats = self._stats
        records = list(stats.games)
        practice = [record for record in records if record.practice]
        clean = [record for record in records if not record.practice]

        overall_average = _average([float(record.blunders) for record in records])
        if overall_average is None:
            overall_average = _average(stats.blunders_per_game)

        practice_counts = _counts(practice)
        clean_counts = _counts(clean)
        self._set_summary(
            "practice",
            games=len(practice) if records else stats.practice_total,
            wins=practice_counts[0] if records else None,
            losses=practice_counts[1] if records else None,
            draws=practice_counts[2] if records else None,
            blunders=_average([float(r.blunders) for r in practice])
            if records
            else None,
        )
        self._set_summary(
            "clean",
            games=(
                len(clean) if records else max(stats.total - stats.practice_total, 0)
            ),
            wins=clean_counts[0] if records else None,
            losses=clean_counts[1] if records else None,
            draws=clean_counts[2] if records else None,
            blunders=_average([float(r.blunders) for r in clean]) if records else None,
        )
        self._set_summary(
            "all",
            games=stats.total,
            wins=stats.wins,
            losses=stats.losses,
            draws=stats.draws,
            blunders=overall_average,
        )

        practice_total = stats.practice_total
        clean_total = max(stats.total - practice_total, 0)
        try:
            bot_now = Bot.estimate_elo(self._store.bot_strength)
        except Exception:  # noqa: BLE001 - a stats screen must not crash
            bot_now = Bot.estimate_elo(stats.strength)
        self._headline.setText(
            f"{stats.total} games  \u00b7  {practice_total} practice  "
            f"\u00b7  {clean_total} clean  \u00b7  Bot now \u2248 {bot_now}"
        )

        if not records and stats.total:
            self._note.setText(
                "This stats file predates per-game records, so the "
                "practice/clean split of wins, losses and draws is unavailable."
            )
            self._note.setVisible(True)
        elif not stats.total:
            self._note.setText(
                "No games yet. Play with the live coach on for a practice "
                "game, or switch it off for a clean one."
            )
            self._note.setVisible(True)
        else:
            self._note.setText("")
            self._note.setVisible(False)

    def _set_summary(
        self,
        mode: str,
        *,
        games: int | None,
        wins: int | None,
        losses: int | None,
        draws: int | None,
        blunders: float | None,
    ) -> None:
        values = {
            "games": "\u2014" if games is None else str(games),
            "wins": "\u2014" if wins is None else str(wins),
            "losses": "\u2014" if losses is None else str(losses),
            "draws": "\u2014" if draws is None else str(draws),
            "blunders": _format_average(blunders),
        }
        for field_name, text in values.items():
            label = self._summary_labels.get((mode, field_name))
            if label is not None:
                label.setText(text)

    def _populate_history(self) -> None:
        self._history.clear()
        for ref in self._saved:
            outcome = ref.result.capitalize() if ref.result else "\u2014"
            item = QListWidgetItem(
                f"{ref.display_date}   {outcome:<6}   {ref.mode:<8}   "
                f"blunders {ref.blunders}"
            )
            item.setData(Qt.ItemDataRole.UserRole, ref)
            item.setToolTip(
                f"{ref.path}\nBot \u2248 {Bot.estimate_elo(ref.bot_strength)}"
            )
            self._history.addItem(item)
        has_games = bool(self._saved)
        self._history.setVisible(has_games)
        self._review_btn.setVisible(has_games)
        self._empty.setVisible(not has_games)
        self._review_btn.setEnabled(False)

    # -- actions -----------------------------------------------------------

    def _selected_ref(self) -> SavedGameRef | None:
        item = self._history.currentItem()
        if item is None:
            return None
        ref = item.data(Qt.ItemDataRole.UserRole)
        return ref if isinstance(ref, SavedGameRef) else None

    def _update_review_button(self) -> None:
        self._review_btn.setEnabled(self._selected_ref() is not None)

    def _review_selected(self) -> None:
        ref = self._selected_ref()
        if ref is None:
            return
        try:
            game = ref.load()
        except (OSError, ValueError) as exc:
            QMessageBox.warning(
                self,
                "Chess Trainer",
                f"Could not open that game:\n\n{exc}",
            )
            return
        self.review_requested.emit(game)
