"""The coach panel: live-coach toggle, the coach's latest message, take-back.

The toggle defaults to ON and, within a running session, keeps whatever state
the player last chose (new games do not reset it).  The panel only ever shows
text the controller handed over -- never invented engine copy -- and a SILENT
verdict changes nothing visible: the message area is simply left empty.

The Take-Back / Keep-Move buttons live here because they are the coach's
interruption affordances: they appear only while a take-back is on offer and
disappear as soon as it is resolved.
"""

from __future__ import annotations

from PyQt6.QtCore import Qt, pyqtSignal
from PyQt6.QtWidgets import (
    QCheckBox,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QVBoxLayout,
    QWidget,
)


class CoachPanel(QWidget):
    """Shows the coach's latest message and hosts the live-coach controls."""

    live_coach_toggled = pyqtSignal(bool)
    take_back_requested = pyqtSignal()
    keep_move_requested = pyqtSignal()

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)

        self._toggle = QCheckBox("Live coach")
        self._toggle.setChecked(True)  # default ON
        self._toggle.toggled.connect(self.live_coach_toggled)

        self._heading = QLabel("Coach")
        font = self._heading.font()
        font.setBold(True)
        self._heading.setFont(font)

        self._message = QLabel("")
        self._message.setWordWrap(True)
        self._message.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse
        )

        self._take_back_btn = QPushButton("Take Back")
        self._keep_btn = QPushButton("Keep Move")
        self._take_back_btn.clicked.connect(self.take_back_requested)
        self._keep_btn.clicked.connect(self.keep_move_requested)
        self._take_back_btn.setVisible(False)
        self._keep_btn.setVisible(False)

        buttons = QHBoxLayout()
        buttons.addWidget(self._take_back_btn)
        buttons.addWidget(self._keep_btn)
        buttons.addStretch(1)

        layout = QVBoxLayout(self)
        layout.addWidget(self._toggle)
        layout.addWidget(self._heading)
        layout.addWidget(self._message)
        layout.addLayout(buttons)
        layout.addStretch(1)

    # -- state -------------------------------------------------------------

    def is_live_coach(self) -> bool:
        return self._toggle.isChecked()

    def set_live_coach(self, enabled: bool) -> None:
        """Set the toggle programmatically (emits ``live_coach_toggled``)."""
        self._toggle.setChecked(enabled)

    # -- coach message -----------------------------------------------------

    def show_coach_message(self, text: str | None) -> None:
        """Display the coach's message verbatim (``None``/empty clears)."""
        self._message.setText(text or "")

    def clear_message(self) -> None:
        self._message.setText("")

    # -- take-back affordances --------------------------------------------

    def show_take_back(self, visible: bool) -> None:
        """Show or hide the Take-Back / Keep-Move buttons."""
        self._take_back_btn.setVisible(visible)
        self._keep_btn.setVisible(visible)
