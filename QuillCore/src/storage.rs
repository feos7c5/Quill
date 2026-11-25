//! Dateiablage für isideload (Anisette-Zustand, Account-Schlüssel) und Protokoll.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use isideload::util::storage::SideloadingStorage;
use rootcause::prelude::*;

/// Legt ein Verzeichnis an, das nur der eigene Prozess lesen darf.
pub fn ensure_private_dir(path: &Path) -> std::io::Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

/// Schreibt atomar mit Rechten 0600.
pub fn write_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let pending = path.with_extension("pending");
    {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&pending)?;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        file.write_all(data)?;
        file.sync_all()?;
    }
    fs::rename(pending, path)
}

/// Ein Schlüssel-Wert-Speicher als Dateien. Schlüssel von isideload enthalten `/`,
/// deshalb wird jeder Schlüssel hex-kodiert zum Dateinamen.
pub struct FileStorage {
    dir: PathBuf,
    lock: Mutex<()>,
}

impl FileStorage {
    pub fn new(dir: PathBuf) -> Self {
        let _ = ensure_private_dir(&dir);
        Self { dir, lock: Mutex::new(()) }
    }

    fn path(&self, key: &str) -> PathBuf {
        self.dir.join(format!("{}.val", hex::encode(key.as_bytes())))
    }

    /// Entfernt alle gespeicherten Werte.
    pub fn clear(&self) -> std::io::Result<()> {
        let _guard = self.lock.lock().unwrap_or_else(|p| p.into_inner());
        if self.dir.exists() {
            fs::remove_dir_all(&self.dir)?;
        }
        ensure_private_dir(&self.dir)
    }
}

impl SideloadingStorage for FileStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        let _guard = self.lock.lock().unwrap_or_else(|p| p.into_inner());
        write_private(&self.path(key), value.as_bytes())
            .map_err(|e| report!("Saving {key} failed: {e}"))?;
        Ok(())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        let _guard = self.lock.lock().unwrap_or_else(|p| p.into_inner());
        match fs::read_to_string(self.path(key)) {
            Ok(value) if value.is_empty() => Ok(None),
            Ok(value) => Ok(Some(value)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(report!("Reading {key} failed: {e}")),
        }
    }

    fn delete(&self, key: &str) -> Result<(), Report> {
        let _guard = self.lock.lock().unwrap_or_else(|p| p.into_inner());
        match fs::remove_file(self.path(key)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(report!("Deleting {key} failed: {e}")),
        }
    }
}

/// Schreibt das Protokoll des Kerns nach `<dir>/core.log` (wird beim Start gekürzt).
/// Passwörter und Codes werden nie protokolliert; isideload protokolliert keine Zugangsdaten.
pub fn init_logging(dir: &Path) {
    let path = dir.join("core.log");
    let file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path);
    let Ok(file) = file else { return };
    let _ = tracing_subscriber::fmt()
        .with_writer(Mutex::new(file))
        .with_ansi(false)
        .with_target(false)
        .with_max_level(tracing::Level::INFO)
        .try_init();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stores_keys_with_slashes_privately() {
        let dir = tempfile::tempdir().unwrap();
        let storage = FileStorage::new(dir.path().join("s"));
        storage.store("abc/key", "wert").unwrap();
        assert_eq!(storage.retrieve("abc/key").unwrap().as_deref(), Some("wert"));
        let file = storage.path("abc/key");
        assert_eq!(fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        storage.store_data("bin", &[1, 2, 3]).unwrap();
        assert_eq!(storage.retrieve_data("bin").unwrap(), Some(vec![1, 2, 3]));
        storage.delete("abc/key").unwrap();
        assert_eq!(storage.retrieve("abc/key").unwrap(), None);
        storage.clear().unwrap();
        assert_eq!(storage.retrieve_data("bin").unwrap(), None);
    }
}
