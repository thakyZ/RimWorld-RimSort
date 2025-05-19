"""This is a module to control what gets output in the texture helper window."""

import os
from typing import Any, Literal, Optional, Union

from loguru import logger
from psutil import Process
from PySide6.QtCore import QObject, QThread, QTimer, Signal

from app.controllers.settings_controller import SettingsController
from app.models.search_result import SearchResult
from app.models.settings import Settings
from app.utils import metadata
from app.utils.file_search import FileSearch
from app.utils.metadata import MetadataManager
from app.utils.mod_utils import get_mod_paths_from_uuids
from app.utils.ordered_set import OrderedSet
from app.views.dialogue import show_warning
from app.views.mods_panel import ModsPanel
from app.views.texture_helper_dialog import TextureHelperDialog


class HelperWorker(QThread):
    """worker thread for the texture helper"""

    result_found = Signal(str, str, str, object, object)  # mod_name, file_name, path, replaced_by_mod_name, replaces_mod_name
    progress = Signal(int, int)  # current, total
    stats = Signal(str)  # statistics text
    finished = Signal()
    error = Signal(str)

    def __init__(
        self,
        root_paths: list[str],
        options: dict[str, Any],
        active_mod_ids: Optional[OrderedSet[str]] = None,
    ) -> None:
        """
        Initialize search worker

        Parameters:
        - root_paths: List of paths to search in
        - options: Search options
        - active_mod_ids: Set of mod IDs to use for filtering
          For active mods search, this should be active mod IDs
          For inactive mods search, this should be inactive mod IDs
        """
        super().__init__()
        self.root_paths: list[str] = root_paths
        self.options: dict[str, Any] = options
        self.active_mod_ids: Optional[OrderedSet[str]] = active_mod_ids
        self.searcher = FileSearch()
        self.processed_files: int = 0
        self.found_files: int = 0
        self.memory_monitor_timer = QTimer()
        self.memory_monitor_timer.timeout.connect(self._check_memory_usage)
        self.memory_monitor_timer.start(30000)  # Check every 30 seconds

        # Memory monitoring
        self.memory_check_interval: int = 100  # Check memory usage every 100 files
        self.memory_warning_threshold: float = 0.85  # 85% of available memory
        self.last_memory_check: int = 0
        self.memory_warning_shown: bool = False

        # Set thread priority to lower to avoid UI freezing
        if not self.isRunning():
            logger.warning("Thread is not running. Skipping priority setting.")
            return
        self.setPriority(QThread.Priority.LowPriority)

    def _check_memory_usage(self) -> bool:
        """
        Check current memory usage and emit a warning if it's too high.
        Returns True if memory usage is acceptable, False if it's too high.
        """
        try:
            process = Process()
            memory_info = process.memory_info()
            memory_percent = process.memory_percent()

            logger.debug(
                f"Memory usage: {memory_info.rss / (1024 * 1024):.1f} MB ({memory_percent:.1f}%)"
            )

            if (
                memory_percent > self.memory_warning_threshold
                and not self.memory_warning_shown
            ):
                logger.warning(
                    f"High memory usage detected: {memory_percent:.1f}%. Consider optimizing the search."
                )
                self.memory_warning_shown = True

            return memory_percent <= self.memory_warning_threshold
        except Exception as e:
            logger.error(f"Error checking memory usage: {e}")
            return True

    def _should_process_mod(self, mod_path: str) -> bool:
        """
        Check if mod should be processed based on active/inactive filter

        Parameters:
        - mod_path: Path to the mod folder

        Returns:
        - True if the mod should be processed, False otherwise
        """
        # If we're directly searching in specific mod folders and no mod_ids provided,
        # we can skip the filtering since the paths are already filtered
        if self.active_mod_ids is None:
            return False

        # get mod ID from folder name
        mod_id: str = os.path.basename(mod_path)
        if self.active_mod_ids is None:
            return False
        return mod_id in self.active_mod_ids

    def get_mod_name_from_pfid(self, pfid: Union[str, int, None]) -> str:
        """
        Get a mod's name from its PublishedFileID.

        Args:
            pfid: The PublishedFileID to lookup (str, int or None)

        Returns:
            str: The mod name or "Unknown Mod" if not found
        """
        if not pfid:
            return f"{pfid}"

        pfid_str = str(pfid)
        if not pfid_str.isdigit():
            return f"{pfid_str}"

        _metadata = self._get_mod_metadata(pfid_str)
        if not isinstance(metadata, dict):
            return f"{pfid_str}"

        name = _metadata.get("name") or _metadata.get("steamName")
        return repr(name) if name else f"{pfid_str}"

    def _get_mod_metadata(self, pfid: str) -> dict[str, Any]:
        """
        Helper method to get metadata for a mod by PublishedFileID.
        Checks both internal and external metadata sources.

        Args:
            pfid: The PublishedFileID to lookup
        Returns:
            Dictionary containing metadata or empty dict if not found
        """
        try:
            if not hasattr(self, "metadata_manager"):
                self.metadata_manager = MetadataManager.instance()

            # First check internal local metadata
            if hasattr(self.metadata_manager, "internal_local_metadata"):
                for (
                    _,
                    _metadata,
                ) in self.metadata_manager.internal_local_metadata.items():
                    if (
                        _metadata
                        and isinstance(_metadata, dict)
                        and _metadata.get("publishedfileid") == pfid
                    ):
                        return _metadata

            # Then check external steam metadata if available
            if hasattr(self.metadata_manager, "external_steam_metadata"):
                steam_metadata = getattr(
                    self.metadata_manager, "external_steam_metadata", {}
                )
                if isinstance(steam_metadata, dict):
                    return steam_metadata.get(pfid, {})

            return {}
        except Exception as e:
            logger.error(f"Metadata lookup failed: {str(e)}")
            return {}

    def _should_exclude(self, file_path: str) -> bool:
        """Check if a file or directory should be excluded based on exclude_options."""

        # Skip Textures folders
        if "Textures" in file_path and file_path.endswith(".png"):
            return False

        return True

    def run(self) -> None:
        try:
            logger.info(f"Search options: {self.options}")
            logger.info(f"Search paths: {self.root_paths}")

            # Initialize counters
            self.processed_files = 0
            self.found_files = 0

            # Start with an estimate and reset timer
            logger.info("Starting search...")
            self.stats.emit("Starting search...")

            algorithm: Literal["standard search"] = "standard search"

            # Map algorithm display names to method names
            algorithm_map = {
                "standard search": "standard_search",
            }

            # Get method name from the map or convert from display name
            method_name = algorithm_map.get(algorithm, algorithm.replace(" ", "_"))

            # Check if the method exists
            if not hasattr(self.searcher, method_name):
                logger.warning(
                    f"Search method {method_name} not found, falling back to simple_search"
                )
                method_name = "simple_search"

            search_method = getattr(self.searcher, method_name)
            logger.info(f"Using search method: {algorithm} ({method_name})")

            self.files_cached: OrderedSet[tuple[str, str, str]] = OrderedSet()
            filtered_root_paths = [root_path for root_path in self.root_paths if self._should_process_mod(root_path)]
            total_progress: int = len(filtered_root_paths)
            # update the total progress really quick

            mod_name: str = ""
            file_name: str = ""
            path: str = ""

            # Perform the search
            for index, root_path in enumerate(filtered_root_paths):
                self.stats.emit(f"Searching in: {root_path}")
                current_found_items: int = 0

                for result in search_method("", [root_path], self.options):
                    mod_name, file_name, path = result
                    if self._should_exclude(path):
                        continue
                    self.stats.emit(f"Searching in: {root_path} | Found {current_found_items} items")
                    current_found_items += 1
                    self.files_cached.append((mod_name, file_name, path))

                # update total progress avaliable
                self.progress.emit(index, total_progress)

            total_progress = len(self.files_cached)

            for index, item in enumerate(self.files_cached):
                self.stats.emit(f"Determining replaces of and by: {item[0]}")
                replaced_by_mods: OrderedSet[str] = OrderedSet([
                    entry[0] for entry in self.files_cached.after(item) if (
                        entry[0] != item[0] and entry[1] == item[1] and entry[2] == item[2]
                    )])
                replaces_mods: OrderedSet[str] = OrderedSet([
                    entry[0] for entry in self.files_cached.before(item) if (
                        entry[0] != item[0] and entry[1] == item[1] and entry[2] == item[2]
                    )])
                self.result_found.emit(mod_name, file_name, path, replaced_by_mods, replaces_mods)
                self.progress.emit(index, total_progress)

            self.finished.emit()
            self.stats.emit("Search complete")

        except Exception as e:
            logger.error(f"Unexpected error during search: {e}")
            self.error.emit(str(e))

class TextureHelperController(QObject):
    """
    Controller class for managing file search functionality.

    This class handles user interactions from the file search dialog,
    manages the search worker thread, and updates the UI with search results.

    Signals:
        search_results_updated (): Emitted when the search results are updated.
    """

    # define signals
    search_results_updated = Signal()

    def __init__(
        self,
        settings: Settings,
        settings_controller: SettingsController,
        dialog: TextureHelperDialog,
        active_mod_ids: Optional[OrderedSet[str]] = None,
    ) -> None:
        """
        Initialize the FileSearchController.

        Args:
            settings (Settings): Application settings instance.
            settings_controller (SettingsController): Controller for settings management.
            dialog (TextureHelperDialog): The file search dialog UI component.
            active_mod_ids (Optional[Set[str]]): Set of active mod IDs for filtering.
        """
        super().__init__()
        self.settings = settings
        self.dialog = dialog
        self.settings_controller = settings_controller
        self.mods_panel = ModsPanel(
            settings_controller=self.settings_controller,
        )
        self.active_mod_ids = (
            active_mod_ids or OrderedSet()
        )  # This is used for the controller, not the worker
        self.search_results: list[SearchResult] = []
        self.helper_worker: Optional[HelperWorker] = None
        self.searcher = FileSearch()
        # Initialize MetadataManager
        self.metadata_manager = metadata.MetadataManager.instance()

        # connect signals
        self.dialog.search_button.clicked.connect(self._on_search_clicked)
        self.dialog.stop_button.clicked.connect(self._on_stop_clicked)
        self.dialog.filter_input.returnPressed.connect(self._on_search_clicked)

    def set_active_mod_ids(self, active_mod_ids: OrderedSet[str]) -> None:
        """
        Update the list of active mod IDs used for filtering searches.

        Args:
            active_mod_ids (Set[str]): Set of active mod IDs.
        """
        self.active_mod_ids = active_mod_ids

    def get_search_paths(self) -> list[str]:
        """
        Get the list of search paths from the dialog's search options.

        Returns:
            List[str]: List of directory paths to search.
        """
        return self.dialog.get_search_options().get("paths", [])

    def get_filter_text(self) -> str:
        """
        Get the current search text from the dialog input.

        Returns:
            str: The search text entered by the user.
        """
        return self.dialog.filter_input.text()

    def clear_results(self) -> None:
        """
        Clear the current search results and notify listeners.
        """
        self.search_results.clear()
        self.search_results_updated.emit()

    def update_results(self) -> None:
        """
        Notify listeners that the search results have been updated.
        """
        self.search_results_updated.emit()

    def _setup_helper_worker(
        self,
        root_paths: list[str],
        options: dict[str, Any],
        active_mod_ids: OrderedSet[str],
    ) -> HelperWorker:
        """
        Set up and configure a new SearchWorker thread.

        Args:
            root_paths (List[str]): List of directory paths to search.
            pattern (str): The search pattern.
            options (Dict[str, Any]): Search options and flags.
            active_mod_ids (OrderedSet[str]): Set of mod IDs for filtering.
            scope (str): Search scope ("active mods", "inactive mods", "all mods", etc.).

        Returns:
            SearchWorker: Configured search worker instance.
        """
        if self.helper_worker is not None:
            # Properly clean up the previous worker
            try:
                self.helper_worker.quit()
                if not self.helper_worker.wait(1000):  # Wait up to 1 second
                    self.helper_worker.terminate()
            except Exception as e:
                logger.warning(f"Error cleaning up previous search worker: {e}")

        # Log search parameters
        logger.info(f"Search options: {options}")

        # Create and configure the worker
        worker = HelperWorker(root_paths, options, active_mod_ids)

        # Connect signals
        worker.result_found.connect(self.dialog.add_result)
        worker.progress.connect(self.dialog.update_progress)
        worker.stats.connect(self.dialog.update_stats)
        worker.finished.connect(self._on_search_finished)
        worker.error.connect(self._on_search_error)

        # Update UI to show search is starting
        self.dialog.update_stats("Preparing search...")

        return worker

    def _on_search_start(self) -> None:
        """Clear filter and reset UI when a new search starts."""
        self.dialog.filter_input.clear()  # Clear the filter input
        self.dialog.clear_results()  # Clear previous results
        self.dialog.update_stats("Starting new search...")

    def _on_search_clicked(self) -> None:
        """
        Handle the search button click event.

        Disables the search button, enables the stop button, collects search options,
        determines search scope and paths, and starts the search worker.
        """
        self._on_search_start()
        self.dialog.search_button.setEnabled(False)
        self.dialog.search_button.setStyleSheet(
            "font-weight: bold; background-color: transparent;"
        )
        self.dialog.stop_button.setEnabled(True)
        self.dialog.stop_button.setStyleSheet(
            "font-weight: bold; background-color: red;"
        )

        options = self.dialog.get_search_options()
        filter_text = self.dialog.filter_input.text()

        # Add to recent searches
        self.dialog.add_recent_search(filter_text)

        # Set search paths based on the active scope
        root_paths = []
        mod_ids_for_search: OrderedSet[str] = OrderedSet()

        # For active mods, we'll use get_active_mods_paths() directly
        # This is just for collecting mod IDs for other purposes
        # Get active mod IDs by extracting folder names from active mod paths
        active_paths = self.get_active_mods_paths()
        for path in active_paths:
            mod_id = os.path.basename(path)
            mod_ids_for_search.add(mod_id)

        # Get direct paths to active mod folders
        logger.info("Searching in active mods")
        root_paths = self.get_active_mods_paths()
        logger.info(f"Found {len(root_paths)} active mod paths")
        if not root_paths:
            # Show error if no active mods found
            show_warning(
                title="Active Mods Error",
                text="No active mods found",
            )
            self._on_search_finished()
            return

        # Update the options with the new paths
        options["paths"] = root_paths
        options["simple"] = True

        if not root_paths:
            self.location_not_set()
            return
        # For active/inactive mods, we're already searching in specific mod folders
        # so we don't need to filter by mod ID
        root_paths_list = (
            list(root_paths) if not isinstance(root_paths, list) else root_paths
        )

        # Log the search paths
        logger.info(f"Searching in {len(root_paths_list)} paths: {root_paths_list}")

        # Start the search worker
        # Pass mod_ids_for_search for active/inactive mods to enable filtering
        self._start_helper_worker(
            root_paths_list, options, mod_ids_for_search
        )

    def _start_helper_worker(
        self,
        root_paths: list[str],
        options: dict[str, Any],
        active_mod_ids: OrderedSet[str],
    ) -> None:
        """
        Start a new search worker thread to perform the search.

        Args:
            root_paths (List[str]): List of directory paths to search.
            search_text (str): The search text or pattern.
            options (Dict[str, Any]): Search options and flags.
            mod_ids (Optional[Set[str]]): Set of mod IDs for filtering.
            scope (str): Search scope ("active mods", "inactive mods", "all mods", etc.).
        """
        self.searcher = FileSearch()

        # Update the dialog's search paths
        self.dialog.set_search_paths(root_paths)
        self.dialog.clear_results()

        worker = self._setup_helper_worker(root_paths, options, active_mod_ids)
        worker.start()
        self.helper_worker = worker

    def all_mods_path(self) -> list[str]:
        """
        Get paths to all mod folders (local and workshop).

        Returns:
            List[str]: List of absolute paths to mod folders.
        """
        active_mods = self.get_active_mods_paths()

        # Combine active and inactive mod paths
        root_paths = active_mods

        # Log the combined paths for debugging
        logger.info(
            f"All mods paths: {len(root_paths)} paths found (active)"
        )

        return root_paths

    def _get_mod_paths_from_uuids(self, uuids: list[str]) -> list[str]:
        """
        Helper method to get mod paths from a list of UUIDs.

        Args:
            uuids (List[str]): List of mod UUID strings.

        Returns:
            List[str]: List of mod folder paths corresponding to the UUIDs.
        """
        # Get direct paths to the mods instead of just mod IDs
        mod_paths = []

        for uuid in uuids:
            # Check if the mod is in local metadata
            if uuid in self.metadata_manager.internal_local_metadata:
                mod_path = self.metadata_manager.internal_local_metadata[uuid]["path"]
                if os.path.isdir(mod_path):
                    mod_paths.append(mod_path)
                    logger.debug(f"Added mod path: {mod_path}")

        logger.info(f"Found {len(mod_paths)} mod paths from {len(uuids)} UUIDs")
        return mod_paths

    def get_specific_mod_paths(self, mod_ids: set[str]) -> list[str]:
        """
        Get direct paths to specific mods based on their IDs.

        Args:
            mod_ids (set[str]): Set of mod IDs.

        Returns:
            List[str]: List of mod folder paths for the specified mod IDs.
        """
        if not mod_ids:
            return []

        instance = self.settings.instances[self.settings.current_instance]
        specific_paths = []

        # Check local folder
        if instance.local_folder and instance.local_folder != "":
            local_folder = os.path.abspath(instance.local_folder)
            for mod_id in mod_ids:
                mod_path = os.path.join(local_folder, mod_id)
                if os.path.isdir(mod_path):
                    specific_paths.append(mod_path)

        # Check workshop folder
        if instance.workshop_folder and instance.workshop_folder != "":
            workshop_folder = os.path.abspath(instance.workshop_folder)
            for mod_id in mod_ids:
                mod_path = os.path.join(workshop_folder, mod_id)
                if os.path.isdir(mod_path):
                    specific_paths.append(mod_path)

        return specific_paths

    def get_active_mods_paths(self) -> list[str]:
        """
        Get direct paths to active mod folders only.

        Returns:
            List[str]: List of active mod folder paths.
        """
        # Use metadata.get_mods_from_list to get active mod UUIDs
        instance = self.settings.instances[self.settings.current_instance]
        mod_list_path = os.path.join(instance.config_folder, "ModsConfig.xml")
        active_uuids, _, _, _ = metadata.get_mods_from_list(mod_list_path)
        logger.info(f"Getting paths for {len(active_uuids)} active mods from mod list")
        return get_mod_paths_from_uuids(active_uuids)

    def _on_stop_clicked(self) -> None:
        """
        Handle the stop button click event.

        Stops the search worker thread if it is running, updates the UI accordingly,
        and resets the UI state.
        """
        if self.helper_worker and self.helper_worker.isRunning():
            # Disable the stop button to prevent multiple clicks
            self.dialog.stop_button.setEnabled(False)

            # Update the UI to show search is stopping
            self.dialog.update_stats("Stopping search...")

            # Set the stop flag in the searcher
            self.searcher.stop_search()

            # Terminate the worker thread immediately
            self.helper_worker.terminate()

            # Update the UI to show search has stopped
            self.dialog.update_stats("Search stopped by user")

        # Reset the UI
        self._on_search_finished()

    def _on_search_finished(self) -> None:
        """
        Handle completion of the filter.

        Resets the UI buttons to their default enabled/disabled states.
        """
        # Reset buttons
        self.dialog.search_button.setEnabled(True)
        self.dialog.search_button.setStyleSheet(
            "font-weight: bold; background-color: green;"
        )
        self.dialog.stop_button.setEnabled(False)
        self.dialog.stop_button.setStyleSheet(
            "font-weight: bold; background-color: transparent;"
        )

    def _on_search_error(self, error_msg: str) -> None:
        """
        Handle errors that occur during the filter.

        Displays a warning dialog with the error message and resets the UI.
        Provides more detailed error information and potential solutions.

        Args:
            error_msg (str): The error message to display.
        """
        # Check for common error patterns and provide helpful messages
        if "regex" in error_msg.lower():
            show_warning(
                title="Regular Expression Error",
                text="There was an error with your regular expression pattern.",
                information=f"{error_msg}\n\nTry simplifying your pattern or check for syntax errors.",
            )
        elif "permission" in error_msg.lower() or "access" in error_msg.lower():
            show_warning(
                title="File Access Error",
                text="RimSort doesn't have permission to access some files.",
                information=f"{error_msg}\n\nTry running RimSort with administrator privileges or check folder permissions.",
            )
        elif "memory" in error_msg.lower():
            show_warning(
                title="Memory Error",
                text="RimSort ran out of memory while searching.",
                information=f"{error_msg}\n\nTry searching in smaller batches or use the 'streaming search' method for very large files.",
            )
        else:
            show_warning(
                title="Search Error",
                text="An error occurred during the search.",
                information=f"{error_msg}\n\nPlease check your settings and try again.",
            )

        # Update the stats label to show the error
        self.dialog.update_stats(f"Filter failed: {error_msg[:100]}...")

        # Reset the UI
        self._on_search_finished()

    def _on_filter_changed(self, text: str) -> None:
        """
        Handle changes to the filter text input with debounce.

        Args:
            text (str): The current filter text.
        """
        if not hasattr(self, "_filter_timer"):
            self._filter_timer = QTimer()
            self._filter_timer.setSingleShot(True)
            self._filter_timer.timeout.connect(self._apply_filter)

        self._filter_text = text.lower()
        self._filter_timer.start(
            200
        )  # Reduced debounce to 200 ms for more responsiveness

    def _apply_filter(self) -> None:
        """
        Apply the current filter text to the results table.

        Hides rows that do not match the filter text and updates the stats label.
        """
        filter_text = self._filter_text
        logger.debug(f"Applying filter with text: '{filter_text}'")
        logger.debug(f"Total rows: {self.dialog.results_table.rowCount()}")

        visible_rows = 0
        for row in range(self.dialog.results_table.rowCount()):
            show_row = False
            for col in range(self.dialog.results_table.columnCount()):
                item = self.dialog.results_table.item(row, col)
                if item is not None:
                    item_text = item.text().lower()
                    if filter_text in item_text:
                        show_row = True
                        break

            self.dialog.results_table.setRowHidden(row, not show_row)
            if show_row:
                visible_rows += 1

        # Update the stats label to show filter results
        self.dialog.update_stats(
            f"Filter: {visible_rows} of {self.dialog.results_table.rowCount()} results visible"
        )

        logger.debug(
            f"Filter complete - Visible rows: {visible_rows}/{self.dialog.results_table.rowCount()}"
        )

    def location_not_set(self) -> None:
        """
        Handle the case when no valid search location is set.

        Displays a warning dialog informing the user to configure game folders in settings.
        """
        show_warning(
            title="Location Not Set",
            text="No valid search location is available for the selected scope. Please configure your game folders in the settings.",
        )
