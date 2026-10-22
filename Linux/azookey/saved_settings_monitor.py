"""Observe atomic settings saves without reading or creating the document."""
from pathlib import Path

from gi.repository import Gio, GLib


class SavedSettingsMonitor:
    def __init__(self, path, *, changed, unavailable):
        self.path = Path(path).absolute()
        self.changed = changed
        self.unavailable = unavailable
        self.monitor = None
        self.directory = None
        self.closed = False
        self._watch_existing_parent()

    def _watch_existing_parent(self, *, force=False):
        directory = self.path.parent
        while not directory.is_dir() and directory != directory.parent:
            directory = directory.parent
        if directory == self.directory and not force:
            return
        replacement = Gio.File.new_for_path(str(directory)).monitor_directory(
            Gio.FileMonitorFlags.WATCH_MOVES, None,
        )
        previous, self.monitor = self.monitor, replacement
        self.directory = directory
        replacement.connect("changed", self._changed)
        if previous is not None:
            previous.cancel()

    def _changed(self, monitor, file, other_file, event):
        if self.closed or monitor is not self.monitor:
            return
        paths = {Path(value.get_path()) for value in (file, other_file)
                 if value is not None and value.get_path() is not None}
        if not paths.intersection({self.path, *self.path.parents}):
            return
        # Watching the parent catches rename-based saves. If it did not exist
        # at startup, follow its creation without creating a settings directory.
        replaced_directory = self.directory in paths and event in (
            Gio.FileMonitorEvent.DELETED, Gio.FileMonitorEvent.MOVED_OUT, Gio.FileMonitorEvent.UNMOUNTED,
        )
        try:
            self._watch_existing_parent(force=replaced_directory)
        except (OSError, GLib.Error):
            self.unavailable()
        self.changed()

    def close(self):
        self.closed = True
        if self.monitor is not None:
            self.monitor.cancel()
            self.monitor = None
