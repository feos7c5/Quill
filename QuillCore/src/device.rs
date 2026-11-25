//! Gerätedienste über Remote Pairing.
//!
//! Quill läuft auf demselben iPhone, das es steuert. Den Weg zu den eigenen
//! Gerätediensten öffnet LocalDevVPN: Unter `10.7.0.1:49152` antwortet dann der
//! Remote-Pairing-Dienst des iPhones. Darüber baut der Kern einen TLS-PSK-Tunnel
//! mit einem eigenen TCP-Stack auf und erreicht so RSD, AFC, Installation und Lockdown.

use std::ffi::{CString, c_char, c_void};
use std::net::SocketAddr;
use std::path::Path;
use std::time::Duration;

use idevice::RsdService;
use idevice::installation_proxy::InstallationProxyClient;
use idevice::lockdown::LockdownClient;
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native};
use idevice::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio::time::timeout;

use crate::{Context, CoreResult, read_opt, read_str};

/// Standardadresse des Remote-Pairing-Dienstes über LocalDevVPN.
pub const DEFAULT_ADDRESS: &str = "10.7.0.1:49152";
const HOST_NAME: &str = "Quill";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);

/// Fortschritt an Swift: Anteil 0…1 und kurzer Text.
pub type ProgressCallback = extern "C" fn(context: *mut c_void, fraction: f64, message: *const c_char);

pub struct Progress {
    callback: Option<ProgressCallback>,
    context: Context,
}

impl Progress {
    pub fn new(callback: Option<ProgressCallback>, context: Context) -> Self {
        Self { callback, context }
    }

    pub fn report(&self, fraction: f64, message: &str) {
        if let Some(cb) = self.callback {
            let text = CString::new(message.replace('\0', "")).unwrap_or_default();
            cb(self.context.ptr(), fraction.clamp(0.0, 1.0), text.as_ptr());
        }
    }
}

/// Wohin und mit welcher Identität verbunden wird.
pub struct Target {
    pairing: Vec<u8>,
    address: SocketAddr,
}

impl Target {
    /// # Safety
    /// `pairing_path` muss eine gültige Zeichenkette sein, `address` darf NULL sein.
    pub unsafe fn read(pairing_path: *const c_char, address: *const c_char) -> CoreResult<Self> {
        let path = unsafe { read_str(pairing_path, "Pairing-Datei") }?;
        let pairing = std::fs::read(&path).map_err(|_| "Keine Pairing-Datei vorhanden. Bitte zuerst koppeln.".to_string())?;
        let address = unsafe { read_opt(address) }.unwrap_or_else(|| DEFAULT_ADDRESS.into());
        let address = address
            .parse()
            .map_err(|_| format!("Ungültige Geräteadresse: {address}"))?;
        Ok(Self { pairing, address })
    }

    #[cfg(test)]
    pub fn new(pairing: Vec<u8>, address: SocketAddr) -> Self {
        Self { pairing, address }
    }
}

/// Eine offene Verbindung zu den Gerätediensten.
struct Session {
    adapter: AdapterHandle,
    handshake: RsdHandshake,
}

async fn connect(target: &Target) -> CoreResult<Session> {
    let mut pairing = RpPairingFile::from_bytes(&target.pairing)
        .map_err(|e| format!("Die Pairing-Datei ist ungültig: {e}"))?;

    let stream = timeout(CONNECT_TIMEOUT, TcpStream::connect(target.address))
        .await
        .map_err(|_| vpn_hint("Zeitüberschreitung"))?
        .map_err(|e| vpn_hint(&e.to_string()))?;

    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), HOST_NAME);
    client
        .attempt_pair_verify()
        .await
        .map_err(|e| format!("Das iPhone antwortet nicht wie erwartet: {e}"))?;
    // Nur prüfen, nie neu koppeln: Eine neue Kopplung braucht den Code-Dialog.
    client
        .validate_pairing(&mut pairing)
        .await
        .map_err(|_| "Das iPhone erkennt die Kopplung nicht mehr. Bitte neu koppeln.".to_string())?;

    let tunnel_port = client
        .create_tcp_listener()
        .await
        .map_err(|e| format!("Tunnel konnte nicht geöffnet werden: {e}"))?;
    let mut tunnel_address = target.address;
    tunnel_address.set_port(tunnel_port);
    let tunnel_stream = timeout(CONNECT_TIMEOUT, TcpStream::connect(tunnel_address))
        .await
        .map_err(|_| "Tunnel: Zeitüberschreitung.".to_string())?
        .map_err(|e| format!("Tunnel: {e}"))?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, client.encryption_key())
        .await
        .map_err(|e| format!("Tunnel-Verschlüsselung: {e}"))?;

    let client_ip = tunnel.info.client_address.parse().map_err(|e| format!("Tunnel: {e}"))?;
    let server_ip = tunnel.info.server_address.parse().map_err(|e| format!("Tunnel: {e}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    adapter.set_mss(mtu.clamp(1280, 8192) - 60);
    let mut adapter = adapter.to_async_handle();
    let rsd = adapter.connect(rsd_port).await.map_err(|e| format!("RSD: {e}"))?;
    let handshake = RsdHandshake::new(rsd).await.map_err(|e| format!("RSD: {e}"))?;
    Ok(Session { adapter, handshake })
}

fn vpn_hint(detail: &str) -> String {
    format!(
        "Das iPhone ist über LocalDevVPN nicht erreichbar ({detail}). LocalDevVPN öffnen, verbinden und erneut versuchen."
    )
}

pub async fn info(target: &Target) -> CoreResult<Value> {
    let mut session = connect(target).await?;
    let mut lockdown = LockdownClient::connect_rsd(&mut session.adapter, &mut session.handshake)
        .await
        .map_err(|e| format!("Lockdown: {e}"))?;

    async fn text(lockdown: &mut LockdownClient, key: &str) -> Option<String> {
        lockdown
            .get_value(Some(key), None)
            .await
            .ok()
            .and_then(|v| v.as_string().map(str::to_owned))
    }

    let udid = text(&mut lockdown, "UniqueDeviceID").await;
    let name = text(&mut lockdown, "DeviceName").await;
    let model = text(&mut lockdown, "ProductType").await;
    let version = text(&mut lockdown, "ProductVersion").await;
    let developer_mode = lockdown
        .get_value(Some("DeveloperModeStatus"), Some("com.apple.security.mac.amfi"))
        .await
        .ok()
        .and_then(|v| v.as_boolean());

    // Nach erfolgreicher Prüfung liefert auch der RSD-Handshake die UDID.
    let udid = udid.or_else(|| {
        session
            .handshake
            .properties
            .get("UniqueDeviceID")
            .and_then(|v| v.as_string())
            .map(str::to_owned)
    });

    Ok(json!({
        "udid": udid,
        "name": name,
        "model": model,
        "product_version": version,
        "developer_mode": developer_mode,
    }))
}

pub async fn install(target: &Target, package: &Path, progress: &Progress) -> CoreResult<Value> {
    if !package.exists() {
        return Err("Das signierte Paket fehlt.".into());
    }
    progress.report(0.02, "Verbinde mit dem iPhone …");
    let mut session = connect(target).await?;
    progress.report(0.05, "Übertrage …");

    // idevice meldet 0–100; der Upload-Anteil läuft vorher ohne eigene Meldung.
    let result = idevice::utils::installation::install_package_with_callback_rsd(
        &mut session.adapter,
        &mut session.handshake,
        package,
        Some(plist::Value::Dictionary(
            [("PackageType".to_string(), plist::Value::String("Developer".into()))]
                .into_iter()
                .collect(),
        )),
        |(percent, ()): (u64, ())| async move {
            progress.report(0.1 + 0.9 * (percent as f64 / 100.0), "Installiere …");
        },
        (),
    )
    .await;

    match result {
        Ok(()) => {
            progress.report(1.0, "Installiert.");
            Ok(json!({ "installed": true }))
        }
        Err(e) => Err(explain_install_error(&e.to_string())),
    }
}

/// Übersetzt häufige Fehler der Installation in verständliche Hinweise.
fn explain_install_error(raw: &str) -> String {
    let lower = raw.to_lowercase();
    let hint = if lower.contains("maximum number of apps") || lower.contains("applicationverificationfailed") && lower.contains("limit") {
        "Mit einem kostenlosen Account sind höchstens drei Apps gleichzeitig aktiv. Eine App entfernen und erneut versuchen."
    } else if lower.contains("developer mode") || lower.contains("developermode") {
        "Der Entwicklermodus ist aus. Einstellungen → Datenschutz & Sicherheit → Entwicklermodus einschalten."
    } else if lower.contains("profile") && (lower.contains("expired") || lower.contains("not valid")) {
        "Das Provisioning Profile ist abgelaufen oder passt nicht zum Gerät."
    } else if lower.contains("signature") || lower.contains("codesign") {
        "Die Signatur wird nicht akzeptiert. Zertifikat und Profil prüfen."
    } else {
        ""
    };
    if hint.is_empty() {
        format!("Installation fehlgeschlagen: {raw}")
    } else {
        format!("{hint} ({raw})")
    }
}

pub async fn uninstall(target: &Target, bundle_id: &str) -> CoreResult<Value> {
    let mut session = connect(target).await?;
    let mut proxy = InstallationProxyClient::connect_rsd(&mut session.adapter, &mut session.handshake)
        .await
        .map_err(|e| format!("Installationsdienst: {e}"))?;
    proxy
        .uninstall(bundle_id, None)
        .await
        .map_err(|e| format!("Deinstallation fehlgeschlagen: {e}"))?;
    Ok(json!({ "removed": true }))
}

pub async fn user_apps(target: &Target) -> CoreResult<Value> {
    let mut session = connect(target).await?;
    let mut proxy = InstallationProxyClient::connect_rsd(&mut session.adapter, &mut session.handshake)
        .await
        .map_err(|e| format!("Installationsdienst: {e}"))?;
    let apps = proxy
        .get_apps(Some("User"), None)
        .await
        .map_err(|e| format!("App-Liste: {e}"))?;

    let mut list: Vec<Value> = apps
        .into_iter()
        .map(|(bundle_id, info)| {
            let dict = info.as_dictionary();
            let field = |key: &str| {
                dict.and_then(|d| d.get(key))
                    .and_then(|v| v.as_string())
                    .map(str::to_owned)
            };
            json!({
                "bundle_id": bundle_id,
                "name": field("CFBundleDisplayName").or_else(|| field("CFBundleName")),
                "version": field("CFBundleShortVersionString"),
                "signer": field("SignerIdentity"),
            })
        })
        .collect();
    list.sort_by(|a, b| a["bundle_id"].as_str().cmp(&b["bundle_id"].as_str()));
    Ok(Value::Array(list))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unreachable_device_explains_vpn() {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let pairing = RpPairingFile::generate("test").to_bytes();
        // Port 9 auf localhost ist geschlossen: schneller Verbindungsfehler.
        let target = Target::new(pairing, "127.0.0.1:9".parse().unwrap());
        let error = rt.block_on(info(&target)).unwrap_err();
        assert!(error.contains("LocalDevVPN"), "{error}");
    }

    #[test]
    fn rejects_garbage_pairing_file() {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let target = Target::new(b"kaputt".to_vec(), "127.0.0.1:9".parse().unwrap());
        let error = rt.block_on(info(&target)).unwrap_err();
        assert!(error.contains("ungültig"), "{error}");
    }

    #[test]
    fn install_error_hints() {
        assert!(explain_install_error("ApplicationVerificationFailed: maximum number of apps").contains("drei Apps"));
        assert!(explain_install_error("whatever").starts_with("Installation fehlgeschlagen"));
    }
}
