"""Entry point: ``python -m chess_trainer``.

Run it from the trainer root with ``PYTHONPATH=src python -m chess_trainer``
(or with the package installed).  It builds the engine, bot, coach and store,
wraps them in a :class:`~chess_trainer.controller.GameController`, and shows
the main window.
Importing this module is side-effect free (``main`` creates the ``QApplication``
and window only when called), so a headless smoke check can do
``from chess_trainer.__main__ import main`` without starting Qt.
"""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    try:
        from PyQt6.QtWidgets import QApplication, QMessageBox
    except ImportError as exc:  # Qt is a runtime dependency, kept out of core
        print(
            f"Chess Trainer needs PyQt6 to open its window: {exc}\n"
            "Install it with:  pip install PyQt6",
            file=sys.stderr,
        )
        return 1

    from chess_trainer.bot import Bot
    from chess_trainer.coach import Coach
    from chess_trainer.controller import GameController
    from chess_trainer.engine import Engine
    from chess_trainer.gui.main_window import MainWindow
    from chess_trainer.store import Store

    app = QApplication(argv if argv is not None else sys.argv)
    app.setApplicationName("Chess Trainer")

    try:
        engine = Engine()
        bot = Bot(engine)
        coach = Coach(engine)
        store = Store()
        controller = GameController(bot, coach, store)
    except (FileNotFoundError, OSError) as exc:
        QMessageBox.critical(
            None,
            "Chess Trainer",
            f"Could not start Chess Trainer:\n\n{exc}",
        )
        return 1

    window = MainWindow(controller, store, engine=engine)
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
