"""A module for rendering the texture helper window."""

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Optional

from loguru import logger
from PySide6.QtCore import QPoint, Qt, Signal, Slot
from PySide6.QtGui import QColor, QFont, QIcon, QKeyEvent
from PySide6.QtWidgets import (
    QApplication,
    QDialog,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMenu,
    QProgressBar,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from app.utils.app_info import AppInfo
from app.utils.generic import platform_specific_open
from app.utils.ordered_set import OrderedSet


class TextureHelperDialog(QDialog):
    """dialog for displaying textures and their mods that are being replaced from the sort order."""


    # signals for search events
    search_started = Signal(str, str, dict)  # search_text, algorithm, options
    search_stopped = Signal()
    result_found = Signal(str, str, str)  # mod_name, file_name, path

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Texture Helper")
        self.setWindowFlags(Qt.WindowType.Window)
        self.resize(900, 700)  # Set a reasonable default size
        self._recent_searches: list[str] = []
        self._max_recent_searches: int = 10

        # Added a placeholder for search_worker to resolve attribute access issues
        self.search_worker = None

        # Load recent searches
        self._load_recent_searches()

        # Create main layout
        main_layout = QVBoxLayout()
        main_layout.setSpacing(10)
        main_layout.setContentsMargins(10, 10, 10, 10)
        self.setLayout(main_layout)

        # ===== SEARCH QUERY SECTION =====
        # Top section with search input and buttons
        top_section = QWidget()
        top_layout = QVBoxLayout(top_section)
        top_layout.setContentsMargins(0, 0, 0, 0)
        top_layout.setSpacing(10)

        # Search and Stop buttons
        buttons_layout = QHBoxLayout()
        buttons_layout.setSpacing(10)

        self.search_button = QPushButton("Search")
        self.search_button.setMinimumWidth(100)
        self.search_button.setEnabled(True)
        self.search_button.setStyleSheet("font-weight: bold; background-color: green;")

        self.stop_button = QPushButton("Stop")
        self.stop_button.setMinimumWidth(100)
        self.stop_button.setEnabled(False)
        self.stop_button.setStyleSheet("font-weight: bold; background-color: transparent;")

        buttons_layout.addWidget(self.search_button)
        buttons_layout.addWidget(self.stop_button)

        top_layout.addLayout(buttons_layout)

        # Add top section to main layout
        main_layout.addWidget(top_section)

        # Add a horizontal separator line
        separator = QWidget()
        separator.setFixedHeight(1)
        main_layout.addWidget(separator)

        # ===== PROGRESS AND RESULTS SECTION =====
        results_section = QWidget()
        results_layout = QVBoxLayout(results_section)
        results_layout.setContentsMargins(0, 5, 0, 0)
        results_layout.setSpacing(10)

        # Progress section with improved layout and visual feedback
        progress_group = QWidget()
        progress_group.setObjectName("progressGroup")  # For potential styling
        progress_layout = QVBoxLayout(progress_group)
        progress_layout.setContentsMargins(0, 0, 0, 0)
        progress_layout.setSpacing(8)

        self.progress_bar = QProgressBar()
        self.progress_bar.setObjectName("default")
        progress_layout.addWidget(self.progress_bar)

        # Status and stats in a horizontal layout
        status_row = QHBoxLayout()
        status_row.setSpacing(10)

        # Statistics
        self.stats_label = QLabel("Ready to search")
        self.stats_label.setAlignment(
            Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter
        )
        status_row.addWidget(self.stats_label)

        progress_layout.addLayout(status_row)

        results_layout.addWidget(progress_group)

        # Results filter with icon
        filter_group = QWidget()
        filter_layout = QHBoxLayout(filter_group)
        filter_layout.setContentsMargins(0, 0, 0, 0)
        filter_layout.setSpacing(10)

        filter_label = QLabel("Filter results:")
        filter_label.setFixedWidth(80)
        filter_layout.addWidget(filter_label)

        self.filter_input = QLineEdit()
        self.filter_input.setPlaceholderText(
            "Filter results by mod name, file name, or path"
        )
        filter_layout.addWidget(self.filter_input)

        self.recent_searches_button = QPushButton("▼")
        self.recent_searches_button.setFixedWidth(25)
        self.recent_searches_button.setToolTip("Recent Searches")
        self.recent_searches_button.clicked.connect(self._show_recent_searches)
        filter_layout.addWidget(self.recent_searches_button)

        results_layout.addWidget(filter_group)

        # Results table with header
        results_table_group = QWidget()
        results_table_layout = QVBoxLayout(results_table_group)
        results_table_layout.setContentsMargins(0, 0, 0, 0)
        results_table_layout.setSpacing(5)

        results_header = QHBoxLayout()
        results_label = QLabel("Search Results:")
        results_label.setStyleSheet("font-weight: bold;")
        results_header.addWidget(results_label)

        # Add a right-aligned label with instructions
        results_help = QLabel("Double-click a result to open the file")
        results_help.setAlignment(Qt.AlignmentFlag.AlignRight)
        results_header.addWidget(results_help)

        results_table_layout.addLayout(results_header)

        self.results_table = QTableWidget()
        self.results_table.setColumnCount(5)
        self.results_table.setHorizontalHeaderLabels(
            ["Status", "Mod Name", "File Name", "Path", "Preview"]
        )

        # Set table properties for better appearance
        self.results_table.setAlternatingRowColors(True)
        self.results_table.setSelectionBehavior(
            QTableWidget.SelectionBehavior.SelectRows
        )
        self.results_table.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self.results_table.setSortingEnabled(True)
        self.results_table.verticalHeader().setVisible(False)

        # Set a minimum height for the results table
        self.results_table.setMinimumHeight(300)

        # Configure column stretching
        header = self.results_table.horizontalHeader()
        header.setSectionResizeMode(
            0, QHeaderView.ResizeMode.ResizeToContents
        )  # Mod name
        header.setSectionResizeMode(
            1, QHeaderView.ResizeMode.ResizeToContents
        )  # File name
        header.setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)  # Path
        header.setSectionResizeMode(
            3, QHeaderView.ResizeMode.Stretch
        )  # Preview (stretch to fill remaining space)

        # Enable context menu
        self.results_table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.results_table.customContextMenuRequested.connect(self._show_context_menu)

        # Connect double-click to open file
        self.results_table.cellDoubleClicked.connect(self._on_cell_double_clicked)

        # Add table to results layout
        results_table_layout.addWidget(self.results_table)

        # Add the results table group to the results layout
        results_layout.addWidget(results_table_group)

        # Add results section to main layout with stretch factor
        main_layout.addWidget(
            results_section, 1
        )  # Give it a stretch factor of 1 to take available space

        # Connect filter input to filter method
        self.filter_input.textChanged.connect(self._on_filter_changed)

        # Connect search button to start search timer
        self.search_button.clicked.connect(self._on_search_start)

        # Connect stop button to cancel search
        self.stop_button.clicked.connect(self.search_stopped.emit)

    def _show_context_menu(self, pos: QPoint) -> None:
        """
        Show context menu for results table.

        Args:
            pos: Position where the context menu is requested.
        """
        menu = QMenu()

        # get selected item
        item = self.results_table.itemAt(pos)
        if item is None:
            return

        row = item.row()
        path_item = self.results_table.item(row, 2)
        if path_item is None:
            return

        path = path_item.text()

        # Create actions with keyboard shortcuts
        open_file = menu.addAction("Open File (Enter)")
        open_file.setShortcut("Return")

        open_folder = menu.addAction("Open Containing Folder (Ctrl+O)")
        open_folder.setShortcut("Ctrl+O")

        copy_path = menu.addAction("Copy Path (Ctrl+C)")
        copy_path.setShortcut("Ctrl+C")

        # Add a separator and more actions
        menu.addSeparator()

        # Add "Open With" submenu
        open_with_menu = menu.addMenu("Open With...")
        open_with_notepad = open_with_menu.addAction("Notepad")
        open_with_vscode = open_with_menu.addAction("VS Code")
        open_with_default = open_with_menu.addAction("Default Editor")

        # connect actions
        open_file.triggered.connect(lambda: self._open_file(path))
        open_folder.triggered.connect(lambda: self._open_folder(path))
        copy_path.triggered.connect(lambda: self._copy_path(path))

        # Connect "Open With" actions
        open_with_notepad.triggered.connect(lambda: self._open_with(path, "notepad"))
        open_with_vscode.triggered.connect(lambda: self._open_with(path, "code"))
        open_with_default.triggered.connect(lambda: self._open_file(path))

        menu.exec(self.results_table.viewport().mapToGlobal(pos))

    def _on_search_start(self) -> None:
        """Initialize search timer and UI state when search starts"""
        logger.info("Search started from FileSearchDialog.")
        self.search_started.emit("", "", {})

        # Enable/disable buttons
        self.search_button.setEnabled(False)
        self.search_button.setStyleSheet(
            "font-weight: bold; background-color: green; color: white; border: 2px solid darkgreen;"
            if self.search_button.isEnabled()
            else "font-weight: bold; background-color: lightgray; color: darkgray; border: 2px solid gray;"
        )
        self.stop_button.setEnabled(True)
        self.stop_button.setStyleSheet(
            "font-weight: bold; background-color: red; color: white; border: 2px solid darkred;"
            if self.stop_button.isEnabled()
            else "font-weight: bold; background-color: lightgray; color: darkgray; border: 2px solid gray;"
        )

    def _on_search_complete(self) -> None:
        """Update UI state when search completes"""
        logger.info("Search completed successfully.")
        self.search_stopped.emit()

        # Ensure the status label is updated correctly when search completes
        result_count = self.results_table.rowCount()

        if result_count > 0:
            self.stats_label.setText(f"Found {result_count} results")
        else:
            self.stats_label.setText("No results found")

        # Reset buttons
        self.search_button.setEnabled(True)
        self.search_button.setStyleSheet(
            "font-weight: bold; background-color: green; color: white; border: 2px solid darkgreen;"
        )
        self.stop_button.setEnabled(False)
        self.stop_button.setStyleSheet(
            "font-weight: bold; background-color: lightgray; color: darkgray; border: 2px solid gray;"
        )

        # Focus on filter input if we have results
        if result_count > 0:
            self.filter_input.setFocus()

        logger.debug(f"Search complete with {result_count} results.")

    def _open_file(self, path: str) -> None:
        """open file in default application"""
        if path and os.path.exists(path):
            platform_specific_open(path)
        else:
            logger.warning(f"Cannot open file: {path} (file does not exist)")

    def _open_folder(self, path: str) -> None:
        """open containing folder"""
        folder = os.path.dirname(path)
        if folder and os.path.exists(folder):
            platform_specific_open(folder)
        else:
            logger.warning(f"Cannot open folder: {folder} (folder does not exist)")

    def _copy_path(self, path: str) -> None:
        """copy path to clipboard"""
        QApplication.clipboard().setText(path)

    def _open_with(self, path: str, program: str) -> None:
        """open file with specified program"""
        output: list[str] = []
        try:
            if os.name == "nt":  # Windows
                if program == "paint":
                    subprocess.Popen(["paint.exe", path])
                elif program == "gimp":
                    subprocess.Popen(["gimp.exe", path])
                elif program == "photoshop":
                    subprocess.Popen(["photoshop.exe", path])
                elif program == "aseprite":
                    subprocess.Popen(["aseprite.exe", path])
                else:
                    self._open_file(path)
            else:  # Unix-like
                if program == "gimp":
                    subprocess.Popen(["gimp.exe", path])
                elif program == "aseprite":
                    subprocess.Popen(["aseprite.exe", path])
                else:
                    self._open_file(path)
        except Exception as e:
            logger.error(f"Error opening file with {program}: {e}")
            logger.debug(f"Application output:\n{"\n".join(output)}")
            # Fallback to default opener
            self._open_file(path)

    def keyPressEvent(self, event: QKeyEvent) -> None:  # type: ignore ### reportIncompatibleMethodOverride
        """Handle keyboard shortcuts"""
        # Get currently selected row
        selected_rows = self.results_table.selectedItems()
        if not selected_rows:
            super().keyPressEvent(event)
            return

        # Find the path in the selected row
        row = selected_rows[0].row()
        path_item = self.results_table.item(row, 2)
        if not path_item:
            super().keyPressEvent(event)
            return

        path = path_item.text()

        # Handle keyboard shortcuts
        if event.key() == Qt.Key.Key_Return:
            self._open_file(path)
        elif (
            event.key() == Qt.Key.Key_C
            and event.modifiers() == Qt.KeyboardModifier.ControlModifier
        ):
            self._copy_path(path)
        elif (
            event.key() == Qt.Key.Key_O
            and event.modifiers() == Qt.KeyboardModifier.ControlModifier
        ):
            self._open_folder(path)
        else:
            super().keyPressEvent(event)

    def update_stats(self, text: str) -> None:
        """Update the statistics label with the given text

        Args:
            text: The text to display in the statistics label
        """
        self.stats_label.setText(text)

        # If this is a "Found X results" message, update the status label too
        if text.startswith("Found ") and " results" in text:
            self._on_search_complete()

    @Slot(str, str, str, object, object)
    def add_result(
        self, mod_name: str, file_name: str, path: str,
        replaced_by_mod_name: object, replaces_mod_name: object
    ) -> None:
        """Add a search result to the table with improved performance and error handling."""
        if not isinstance(replaced_by_mod_name, OrderedSet) or not isinstance(replaces_mod_name, OrderedSet):
            return
        try:
            # Batch insertion for better performance
            current_row = self.results_table.rowCount()
            batch_size = 10  # Increased batch size for efficiency

            if current_row % batch_size == 0:
                self.results_table.setSortingEnabled(False)
                self.results_table.setUpdatesEnabled(False)

            # Insert new row
            row = current_row
            self.results_table.insertRow(row)

            replaced_by_any = False
            replaces_any = False
            if replaced_by_mod_name is not None and len(replaced_by_mod_name) > 0:
                replaced_by_any = True
            if replaces_mod_name is not None and len(replaces_mod_name) > 0:
                replaces_any = True

            # Determine status icon
            status_icon: QIcon = ModListIcons.none_used_icon()
            if replaced_by_any and replaces_any:
                status_icon = ModListIcons.replaces_and_replaced_by_icon()
            elif replaced_by_any:
                status_icon = ModListIcons.replaced_by_icon()
            elif replaces_any:
                status_icon = ModListIcons.replaces_icon()

            # Create table items
            status_item = QTableWidgetItem(status_icon, "")
            mod_item = QTableWidgetItem(mod_name)
            file_item = QTableWidgetItem(file_name)
            path_item = QTableWidgetItem(path)
            preview_item = QTableWidgetItem("<img_thumbnail>")

            # Set tooltips and formatting
            status_tooltip: str = ""

            if replaced_by_any:
                assert replaced_by_mod_name is not None
                status_tooltip += f"Replaced by:\n{"\n".join(replaced_by_mod_name)}"
            if replaces_any:
                if replaced_by_any:
                    status_tooltip += "\n"
                assert replaces_mod_name is not None
                status_tooltip += f"Replaces:\n{"\n".join(replaces_mod_name)}"

            if status_tooltip == "":
                status_tooltip = "Does not replace any texture."

            status_item.setToolTip(status_tooltip)
            mod_item.setToolTip(f"Mod: {mod_name}")
            file_item.setToolTip(f"File: {file_name}")
            path_item.setToolTip(f"Path: {path}")
            preview_item.setFont(QFont("Courier New", 9))
            preview_item.setToolTip("Double-click to open file")
            preview_item.setFont(QFont("Courier New", 9))

            # Add items to table
            self.results_table.setItem(row, 0, status_item)
            self.results_table.setItem(row, 1, mod_item)
            self.results_table.setItem(row, 2, file_item)
            self.results_table.setItem(row, 3, path_item)
            self.results_table.setItem(row, 4, preview_item)

            if replaces_any:
                self._set_color_to_row(row, QColor(0, 255, 0))
            elif replaced_by_any:
                self._set_color_to_row(row, QColor(255, 0, 0))

            # Re-enable updates and sorting at batch boundaries
            if (
                current_row % batch_size == batch_size - 1
                or current_row == self.results_table.rowCount() - 1
            ):
                self.results_table.setUpdatesEnabled(True)
                self.results_table.setSortingEnabled(True)

        except Exception as e:
            logger.error(f"Error adding result: {e}")
            self.results_table.setUpdatesEnabled(True)

    def _set_color_to_row(self, row_index: int, color: QColor) -> None:
        for i in range(self.results_table.columnCount()):
            self.results_table.item(row_index, i).setBackground(color)

    def clear_results(self) -> None:
        """clear all results from the table"""
        self.results_table.setRowCount(0)

    def update_progress(self, current: int, total: int) -> None:
        """Update progress bar and related UI elements.

        Args:
            current (int): Current progress value.
            total (int): Maximum progress value.
        """
        if self.progress_bar.maximum() != total:
            self.progress_bar.setMaximum(total)
        if self.progress_bar.value() != current:
            self.progress_bar.setValue(current)


    def _show_recent_searches(self) -> None:
        """Show recent searches menu"""
        if not self._recent_searches:
            return

        menu = QMenu(self)

        # Add recent searches to menu
        for search in self._recent_searches:
            action = menu.addAction(search)
            action.triggered.connect(
                lambda checked=False, text=search: self._use_recent_search(text)
            )

        # Add a separator and clear action
        if self._recent_searches:
            menu.addSeparator()
            clear_action = menu.addAction("Clear Recent Searches")
            clear_action.triggered.connect(self._clear_recent_searches)

        # Show menu below the button
        menu.exec(
            self.recent_searches_button.mapToGlobal(
                self.recent_searches_button.rect().bottomLeft()
            )
        )

    def _use_recent_search(self, text: str) -> None:
        """Use a recent search"""
        self.filter_input.setText(text)

    def _clear_recent_searches(self) -> None:
        """Clear recent searches"""
        self._recent_searches.clear()
        self._save_recent_searches()

    def _on_cell_double_clicked(self, row: int, column: int) -> None:
        """Handle double-click on a cell"""
        logger.debug(f"Cell double-clicked at row {row}, column {column}.")
        if row >= 0:
            path_item = self.results_table.item(row, 2)
            if path_item is not None:
                self._open_file(path_item.text())

    def add_recent_search(self, search_text: str) -> None:
        """Add a search to recent searches"""
        if not search_text or search_text.isspace():
            return

        # Remove if already exists (to move it to the top)
        if search_text in self._recent_searches:
            self._recent_searches.remove(search_text)

        # Add to the beginning of the list
        self._recent_searches.insert(0, search_text)

        # Limit the number of recent searches
        if len(self._recent_searches) > self._max_recent_searches:
            self._recent_searches = self._recent_searches[: self._max_recent_searches]

        # Save recent searches
        self._save_recent_searches()

    def _save_recent_searches(self) -> None:
        """Save recent searches to recent_searches.json in the app storage folder."""
        app_info = AppInfo()
        recent_searches_file = app_info.app_storage_folder / "recent_searches.json"

        try:
            with open(recent_searches_file, "w", encoding="utf-8") as f:
                json.dump(self._recent_searches, f, ensure_ascii=False, indent=4)
        except Exception as e:
            logger.error(f"Failed to save recent searches: {e}")

    def _load_recent_searches(self) -> None:
        """Load recent searches from recent_searches.json in the app storage folder."""
        app_info = AppInfo()
        recent_searches_file = app_info.app_storage_folder / "recent_searches.json"

        if recent_searches_file.exists():
            try:
                with open(recent_searches_file, "r", encoding="utf-8") as f:
                    self._recent_searches = json.load(f)
            except Exception as e:
                logger.error(f"Failed to load recent searches: {e}")

    def _on_filter_changed(self, text: str) -> None:
        """Handle filter text changes"""
        filter_text = text.lower()
        visible_rows = 0
        total_rows = self.results_table.rowCount()

        for row in range(total_rows):
            show_row = False
            for col in range(self.results_table.columnCount()):
                item = self.results_table.item(row, col)
                if item is not None and filter_text in item.text().lower():
                    show_row = True
                    break

            self.results_table.setRowHidden(row, not show_row)
            if show_row:
                visible_rows += 1

        # Update the stats label to show filter results
        if text:
            self.update_stats(f"Filter: {visible_rows} of {total_rows} results visible")
        elif total_rows > 0:
            self.update_stats(f"Found {total_rows} results")
        else:
            self.update_stats("Ready to search")

    def set_search_paths(self, paths: list[str]) -> None:
        """set the search paths"""
        self._search_paths = paths

    def get_search_options(self) -> dict[str, Any]:
        """Get current search options as a dictionary, including exclude options."""

        return {
            "recursive": True,  # Always do recursive search
            "filter_text": self.filter_input.text(),
        }


class ModListIcons:
    """A class to create icons for the Texture Helper Dialog."""

    _data_path: Path = AppInfo().theme_data_folder / "default-icons"
    _replaced_by_icon_path: str = str(_data_path / "replaced_by_icon.png")
    _replaces_icon_path: str = str(_data_path / "replaces_icon.png")
    _replaces_and_replaced_by_icon_path: str = str(_data_path / "replaces_and_replaced_by_icon.png")
    _none_used_icon_path: str = str(_data_path / "none_used_icon.png")

    _replaced_by_icon: QIcon | None = None
    _replaces_icon: QIcon | None = None
    _replaces_and_replaced_by_icon: QIcon | None = None
    _none_used_icon: QIcon | None = None

    @classmethod
    def replaced_by_icon(cls) -> QIcon:
        """Gets an icon for the mods that have a texture that is replaced by another mod."""
        if cls._replaced_by_icon is None:
            cls._replaced_by_icon = QIcon(cls._replaced_by_icon_path)
        return cls._replaced_by_icon

    @classmethod
    def replaces_icon(cls) -> QIcon:
        """Gets an icon for the mods that replaces another mod's texture."""
        if cls._replaces_icon is None:
            cls._replaces_icon = QIcon(cls._replaces_icon_path)
        return cls._replaces_icon

    @classmethod
    def replaces_and_replaced_by_icon(cls) -> QIcon:
        """
        Gets an icon for the mods that replaces another mod's texture as well has a texture that is
        replaced by another mod.
        """
        if cls._replaces_and_replaced_by_icon is None:
            cls._replaces_and_replaced_by_icon = QIcon(cls._replaces_and_replaced_by_icon_path)
        return cls._replaces_and_replaced_by_icon

    @classmethod
    def none_used_icon(cls) -> QIcon:
        """Gets an icon for the mods that have no affected textures."""
        if cls._replaces_and_replaced_by_icon is None:
            cls._replaces_and_replaced_by_icon = QIcon(cls._replaces_and_replaced_by_icon_path)
        return cls._replaces_and_replaced_by_icon
