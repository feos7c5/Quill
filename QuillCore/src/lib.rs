//! QuillCore: Gerätekanal und Apple-Account für Quill.
//!
//! Die Swift-Seite spricht ausschließlich über die `sc_*`-Funktionen in dieser Datei
//! mit dem Kern. Jede Funktion, die Arbeit verrichtet, blockiert den aufrufenden
//! Thread und liefert JSON zurück:
//!
//! ```json
//! {"ok": true,  "data": { ... }}
//! {"ok": false, "error": "Lesbare Fehlermeldung"}
//! ```
//!
//! Zurückgegebene Zeichenketten gibt Swift mit [`sc_string_free`] frei. Swift ruft
//! blockierende Funktionen nie auf dem Main-Thread auf.

use std::ffi::{CStr, CString, c_char, c_void};
use std::path::PathBuf;
use std::sync::OnceLock;

use serde::Serialize;
use serde_json::{Value, json};

mod account;
mod crypto;
mod device;
mod pairing;
mod profile;
mod storage;

pub use account::TwoFactorCallback;
pub use device::ProgressCallback;

// MARK: - Laufzeit

fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("quill-core")
            .build()
            .expect("Tokio runtime could not start")
    })
}

/// Basisverzeichnis für alles, was der Kern selbst ablegt (Anisette-Zustand, Account-Schlüssel, Protokoll).
fn data_dir() -> Option<PathBuf> {
    DATA_DIR.get().cloned()
}

static DATA_DIR: OnceLock<PathBuf> = OnceLock::new();

/// Fehler des Kerns. `message` ist ein fester englischer Satz, den die App über ihren
/// Sprachkatalog übersetzt; `detail` ist technischer Zusatz (z. B. die Originalmeldung von iOS).
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct CoreError {
    pub message: String,
    pub detail: Option<String>,
}

impl CoreError {
    pub fn new(message: impl Into<String>) -> Self {
        Self { message: message.into(), detail: None }
    }

    pub fn with(message: impl Into<String>, detail: impl std::fmt::Display) -> Self {
        Self { message: message.into(), detail: Some(detail.to_string()) }
    }
}

impl From<&str> for CoreError {
    fn from(message: &str) -> Self {
        Self::new(message)
    }
}

impl From<String> for CoreError {
    fn from(message: String) -> Self {
        Self::new(message)
    }
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.detail {
            Some(detail) => write!(f, "{} ({detail})", self.message),
            None => f.write_str(&self.message),
        }
    }
}

pub(crate) type CoreResult<T> = Result<T, CoreError>;

fn ok<T: Serialize>(value: T) -> *mut c_char {
    into_c(json!({ "ok": true, "data": value }))
}

fn fail(error: impl Into<CoreError>) -> *mut c_char {
    let error = error.into();
    into_c(json!({ "ok": false, "error": error.message, "detail": error.detail }))
}

fn respond<T: Serialize>(result: CoreResult<T>) -> *mut c_char {
    match result {
        Ok(value) => ok(value),
        Err(error) => fail(error),
    }
}

fn into_c(value: Value) -> *mut c_char {
    let text = value.to_string().replace('\0', "");
    CString::new(text).expect("NUL bytes were removed").into_raw()
}

/// Liest eine C-Zeichenkette. NULL oder ungültiges UTF-8 ergibt einen Fehler.
///
/// # Safety
/// `ptr` muss NULL sein oder auf eine gültige, NUL-terminierte Zeichenkette zeigen.
unsafe fn read_str(ptr: *const c_char, what: &str) -> CoreResult<String> {
    if ptr.is_null() {
        return Err(CoreError::with("Invalid input from the app.", format!("{what} missing")));
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| CoreError::with("Invalid input from the app.", format!("{what} is not valid UTF-8")))
}

/// Wie [`read_str`], aber NULL oder leer ergibt `None`.
///
/// # Safety
/// Wie [`read_str`].
unsafe fn read_opt(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(str::to_owned)
        .filter(|s| !s.is_empty())
}

/// Zeiger, die über `await`-Grenzen hinweg an Swift zurückgereicht werden.
#[derive(Clone, Copy)]
pub(crate) struct Context(*mut c_void);
unsafe impl Send for Context {}
unsafe impl Sync for Context {}

impl Context {
    /// Über eine Methode statt über das Feld, damit Closures den ganzen (Send-)Wert einfangen.
    pub(crate) fn ptr(self) -> *mut c_void {
        self.0
    }
}

// MARK: - Allgemein

/// Initialisiert den Kern. Einmal beim App-Start aufrufen.
///
/// `data_dir` ist ein privates Verzeichnis (Application Support), in dem der Kern
/// Anisette-Zustand, Account-Schlüssel und sein Protokoll ablegt.
///
/// # Safety
/// `data_dir` muss eine gültige, NUL-terminierte Zeichenkette sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_init(data_dir: *const c_char) -> *mut c_char {
    let dir = match unsafe { read_str(data_dir, "data directory") } {
        Ok(d) => PathBuf::from(d),
        Err(e) => return fail(e),
    };
    if let Err(e) = storage::ensure_private_dir(&dir) {
        return fail(CoreError::with("The data folder cannot be used.", e));
    }
    let _ = DATA_DIR.set(dir.clone());
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
    storage::init_logging(&dir);
    let _ = runtime();
    ok(json!({ "version": env!("CARGO_PKG_VERSION") }))
}

/// Gibt eine vom Kern gelieferte Zeichenkette frei.
///
/// # Safety
/// `ptr` muss NULL sein oder von einer `sc_*`-Funktion stammen und darf danach nicht mehr benutzt werden.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { CString::from_raw(ptr) });
    }
}

// MARK: - Kopplung (iOS 27: das iPhone koppelt sich mit Quill als Host)

/// Öffnet den Port für die Kopplung und liefert, was Swift per Bonjour veröffentlichen muss:
/// `{"port", "service_type", "name", "txt": {...}}`.
///
/// Danach wartet der Kern im Hintergrund auf das iPhone. Den Fortschritt liefert
/// [`sc_pair_snapshot`]. Bei Erfolg schreibt der Kern die Pairing-Datei nach `output_path`.
///
/// # Safety
/// Beide Zeiger müssen gültige, NUL-terminierte Zeichenketten sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_pair_start(host_name: *const c_char, output_path: *const c_char) -> *mut c_char {
    let result = (|| {
        let name = unsafe { read_str(host_name, "host name") }?;
        let output = PathBuf::from(unsafe { read_str(output_path, "output path") }?);
        pairing::start(name, output)
    })();
    respond(result)
}

/// Aktueller Stand der Kopplung: `{"phase", "message", "pin", "peer", "running"}`.
#[unsafe(no_mangle)]
pub extern "C" fn sc_pair_snapshot() -> *mut c_char {
    ok(pairing::snapshot())
}

/// Bricht eine laufende Kopplung ab.
#[unsafe(no_mangle)]
pub extern "C" fn sc_pair_cancel() {
    pairing::cancel();
}

// MARK: - Gerätedienste über den Tunnel

/// Prüft die Pairing-Datei gegen das Gerät und liest Geräteinformationen:
/// `{"udid", "name", "model", "product_version", "developer_mode"}`.
///
/// `address` ist `host:port` des Remote-Pairing-Dienstes, über LocalDevVPN `10.7.0.1:49152`.
///
/// # Safety
/// Alle Zeiger müssen gültige, NUL-terminierte Zeichenketten sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_device_info(pairing_path: *const c_char, address: *const c_char) -> *mut c_char {
    let result = (|| {
        let target = unsafe { device::Target::read(pairing_path, address) }?;
        runtime().block_on(device::info(&target))
    })();
    respond(result)
}

/// Installiert eine signierte `.ipa` oder einen signierten `.app`-Ordner.
/// Ein `.app`-Ordner wird als Upgrade installiert, die Daten der App bleiben erhalten.
///
/// # Safety
/// Alle Zeichenketten-Zeiger müssen gültig sein. `context` wird unverändert an `progress` übergeben.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_device_install(
    pairing_path: *const c_char,
    address: *const c_char,
    package_path: *const c_char,
    progress: Option<ProgressCallback>,
    context: *mut c_void,
) -> *mut c_char {
    let result = (|| {
        let target = unsafe { device::Target::read(pairing_path, address) }?;
        let package = PathBuf::from(unsafe { read_str(package_path, "package path") }?);
        let reporter = device::Progress::new(progress, Context(context));
        runtime().block_on(device::install(&target, &package, &reporter))
    })();
    respond(result)
}

/// Deinstalliert eine App.
///
/// # Safety
/// Alle Zeiger müssen gültige, NUL-terminierte Zeichenketten sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_device_uninstall(
    pairing_path: *const c_char,
    address: *const c_char,
    bundle_id: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let target = unsafe { device::Target::read(pairing_path, address) }?;
        let bundle_id = unsafe { read_str(bundle_id, "bundle ID") }?;
        runtime().block_on(device::uninstall(&target, &bundle_id))
    })();
    respond(result)
}

/// Listet die vom Nutzer installierten Apps: `[{"bundle_id", "name", "version", "signer"}]`.
///
/// # Safety
/// Alle Zeiger müssen gültige, NUL-terminierte Zeichenketten sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_device_apps(pairing_path: *const c_char, address: *const c_char) -> *mut c_char {
    let result = (|| {
        let target = unsafe { device::Target::read(pairing_path, address) }?;
        runtime().block_on(device::user_apps(&target))
    })();
    respond(result)
}

// MARK: - Apple-Account

/// Meldet sich bei Apple an. Blockiert, bis die Anmeldung fertig ist oder scheitert.
///
/// Verlangt Apple einen zweiten Faktor, ruft der Kern `two_factor` mit einer JSON-Beschreibung
/// auf und wartet, bis Swift [`sc_account_two_factor_respond`] aufruft.
///
/// # Safety
/// `email` und `password` müssen gültige Zeichenketten sein, `anisette_url` darf NULL sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_account_login(
    email: *const c_char,
    password: *const c_char,
    anisette_url: *const c_char,
    two_factor: Option<TwoFactorCallback>,
    context: *mut c_void,
) -> *mut c_char {
    let result = (|| {
        let email = unsafe { read_str(email, "Apple ID") }?;
        let password = unsafe { read_str(password, "password") }?;
        let anisette = unsafe { read_opt(anisette_url) };
        let dir = data_dir().ok_or(CoreError::new("The core is not initialized."))?;
        runtime().block_on(account::login(dir, email, password, anisette, two_factor, Context(context)))
    })();
    respond(result)
}

/// Antwort auf eine 2FA-Anfrage, als JSON:
/// `{"code":"123456"}`, `{"sms":1}`, `{"devices":true}`, `{"resend":true}` oder `{"abort":true}`.
///
/// # Safety
/// `response` muss eine gültige Zeichenkette sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_account_two_factor_respond(response: *const c_char) -> *mut c_char {
    let result = unsafe { read_str(response, "response") }.and_then(|r| account::two_factor_respond(&r));
    respond(result)
}

/// Stand der Anmeldung: `{"logged_in", "email", "name", "team", "teams"}`.
#[unsafe(no_mangle)]
pub extern "C" fn sc_account_status() -> *mut c_char {
    respond(runtime().block_on(account::status()))
}

/// Wählt das Team, mit dem signiert wird.
///
/// # Safety
/// `team_id` muss eine gültige Zeichenkette sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_account_select_team(team_id: *const c_char) -> *mut c_char {
    let result = unsafe { read_str(team_id, "team ID") }.and_then(|t| runtime().block_on(account::select_team(t)));
    respond(result)
}

/// Registriert das Gerät beim Team, falls nötig.
///
/// # Safety
/// Beide Zeiger müssen gültige Zeichenketten sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_account_register_device(udid: *const c_char, name: *const c_char) -> *mut c_char {
    let result = (|| {
        let udid = unsafe { read_str(udid, "UDID") }?;
        let name = unsafe { read_str(name, "device name") }?;
        runtime().block_on(account::register_device(udid, name))
    })();
    respond(result)
}

/// Signiert einen `.app`-Ordner oder eine `.ipa` mit dem Account-Zertifikat.
///
/// `options` ist JSON: `{"increased_memory_limit": bool, "register_extensions": bool}`.
/// Ergebnis: `{"app_path", "bundle_id", "special"}`. `app_path` zeigt auf den signierten `.app`-Ordner.
///
/// # Safety
/// Zeichenketten-Zeiger müssen gültig sein. `context` geht unverändert an `progress`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_account_sign(
    app_path: *const c_char,
    options: *const c_char,
    progress: Option<ProgressCallback>,
    context: *mut c_void,
) -> *mut c_char {
    let result = (|| {
        let path = PathBuf::from(unsafe { read_str(app_path, "app path") }?);
        let options = unsafe { read_opt(options) }.unwrap_or_else(|| "{}".into());
        let options: account::SignOptions =
            serde_json::from_str(&options).map_err(|e| CoreError::with("Invalid input from the app.", e))?;
        let reporter = device::Progress::new(progress, Context(context));
        runtime().block_on(account::sign(path, options, &reporter))
    })();
    respond(result)
}

/// Freie und belegte App-IDs des Teams: `{"available", "max", "app_ids": [...]}`.
#[unsafe(no_mangle)]
pub extern "C" fn sc_account_app_ids() -> *mut c_char {
    respond(runtime().block_on(account::app_ids()))
}

/// Entwicklungszertifikate des Teams: `[{"serial", "name", "machine_name", "expires"}]`.
#[unsafe(no_mangle)]
pub extern "C" fn sc_account_certificates() -> *mut c_char {
    respond(runtime().block_on(account::certificates()))
}

/// Widerruft ein Entwicklungszertifikat.
///
/// # Safety
/// `serial` muss eine gültige Zeichenkette sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_account_revoke_certificate(serial: *const c_char) -> *mut c_char {
    let result = unsafe { read_str(serial, "serial number") }.and_then(|s| runtime().block_on(account::revoke(s)));
    respond(result)
}

/// Exportiert das Account-Zertifikat als .p12: `{"p12", "serial", "machine_id"}` (`p12` in Base64).
/// Legt kein neues Zertifikat an; fehlt eines, kommt ein Fehler.
///
/// # Safety
/// `password` muss eine gültige Zeichenkette sein (leer ist erlaubt).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_account_export_p12(password: *const c_char) -> *mut c_char {
    let result = unsafe { read_str(password, "password") }.and_then(|p| runtime().block_on(account::export_p12(p)));
    respond(result)
}

/// Meldet ab und löscht den Sitzungszustand im Speicher. Der Account-Schlüssel bleibt,
/// damit das Zertifikat beim nächsten Anmelden weiter passt.
#[unsafe(no_mangle)]
pub extern "C" fn sc_account_logout() -> *mut c_char {
    respond(runtime().block_on(account::logout()))
}

/// Löscht zusätzlich den gespeicherten Account-Schlüssel und den Anisette-Zustand.
#[unsafe(no_mangle)]
pub extern "C" fn sc_account_forget() -> *mut c_char {
    respond(runtime().block_on(account::forget()))
}

// MARK: - Zertifikate ohne Account

/// Erzeugt einen RSA-2048-Schlüssel und eine CSR: `{"csr_pem", "key_pkcs8"}` (`key_pkcs8` in Base64).
///
/// # Safety
/// `common_name` muss eine gültige Zeichenkette sein, `email` darf NULL sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_csr_create(common_name: *const c_char, email: *const c_char) -> *mut c_char {
    let result = (|| {
        let name = unsafe { read_str(common_name, "name") }?;
        let email = unsafe { read_opt(email) };
        crypto::create_csr(&name, email.as_deref())
    })();
    respond(result)
}

/// Baut aus Zertifikat (DER, Base64) und privatem Schlüssel (PKCS#8, Base64) eine .p12: `{"p12"}`.
///
/// # Safety
/// Alle Zeiger müssen gültige Zeichenketten sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_p12_build(
    certificate_der: *const c_char,
    key_pkcs8: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let cert = unsafe { read_str(certificate_der, "certificate") }?;
        let key = unsafe { read_str(key_pkcs8, "key") }?;
        let password = unsafe { read_str(password, "password") }?;
        crypto::build_p12(&cert, &key, &password)
    })();
    respond(result)
}

/// Verschlüsselt eine .p12 mit neuem Passwort: `{"p12"}`.
///
/// # Safety
/// Alle Zeiger müssen gültige Zeichenketten sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_p12_rewrap(
    p12: *const c_char,
    old_password: *const c_char,
    new_password: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let p12 = unsafe { read_str(p12, ".p12") }?;
        let old = unsafe { read_str(old_password, "old password") }?;
        let new = unsafe { read_str(new_password, "new password") }?;
        crypto::rewrap_p12(&p12, &old, &new)
    })();
    respond(result)
}

/// Prüft eine .p12 und liest das Zertifikat: `{"subject", "common_name", "team_id", "serial", "not_after", "certificate_der"}`.
///
/// # Safety
/// Beide Zeiger müssen gültige Zeichenketten sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_p12_inspect(p12: *const c_char, password: *const c_char) -> *mut c_char {
    let result = (|| {
        let p12 = unsafe { read_str(p12, ".p12") }?;
        let password = unsafe { read_str(password, "password") }?;
        crypto::inspect_p12(&p12, &password)
    })();
    respond(result)
}

/// Liest ein Zertifikat (DER, Base64): `{"subject", "common_name", "team_id", "organization", "serial", "not_after", "certificate_der"}`.
///
/// # Safety
/// `certificate_der` muss eine gültige Zeichenkette sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_certificate_inspect(certificate_der: *const c_char) -> *mut c_char {
    let result = unsafe { read_str(certificate_der, "certificate") }.and_then(|c| crypto::inspect_certificate(&c));
    respond(result)
}

/// Signiert ein Konfigurationsprofil (XML, Base64) mit Quills eigener Profil-Identität:
/// `{"profile": "<CMS, Base64>"}`.
///
/// # Safety
/// `profile` muss eine gültige Zeichenkette sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_profile_sign(profile: *const c_char) -> *mut c_char {
    let result = (|| {
        let profile = unsafe { read_str(profile, "profile") }?;
        let dir = data_dir().ok_or(CoreError::new("The core is not initialized."))?;
        profile::sign_b64(&dir, &profile)
    })();
    respond(result)
}
