//! Kopplung ab iOS 27: Quill tritt als „pairable host“ auf.
//!
//! Ablauf: Der Kern öffnet einen TCP-Port, Swift veröffentlicht ihn per Bonjour als
//! `_remotepairing-pairable-host._tcp`. In Einstellungen → Datenschutz & Sicherheit →
//! Entwicklermodus wählt der Nutzer Quill aus, iOS verbindet sich mit dem Port und
//! fordert einen Code an. Der Kern erzeugt ihn, Swift zeigt ihn an, der Nutzer tippt
//! ihn in den Einstellungen ein. Danach entsteht eine Remote-Pairing-Datei.

use std::net::{Ipv6Addr, SocketAddrV6};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use idevice::remote_pairing::{PAIRABLE_HOST_SERVICE_TYPE, PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::time::{sleep, timeout};

use crate::{CoreResult, storage};

/// So lange bleibt der Port offen, danach gilt die Kopplung als abgebrochen.
const SESSION: Duration = Duration::from_secs(300);
/// Modellkennung, die iOS als Rechner anzeigt. iOS erwartet hier einen Mac.
const HOST_MODEL: &str = "Mac17,7";

struct State {
    snapshot: Value,
    cancel: Option<Arc<AtomicBool>>,
    running: bool,
}

fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(|| {
        Mutex::new(State {
            snapshot: json!({ "phase": "idle", "message": "Bereit.", "pin": null, "peer": null }),
            cancel: None,
            running: false,
        })
    })
}

fn lock() -> std::sync::MutexGuard<'static, State> {
    state().lock().unwrap_or_else(|p| p.into_inner())
}

fn update(phase: &str, message: &str, pin: Option<String>) {
    let mut s = lock();
    s.snapshot["phase"] = phase.into();
    s.snapshot["message"] = message.into();
    s.snapshot["pin"] = pin.map(Value::String).unwrap_or(Value::Null);
}

fn finish(phase: &str, message: impl Into<String>, peer: Option<Value>) {
    let mut s = lock();
    s.snapshot["phase"] = phase.into();
    s.snapshot["message"] = message.into().into();
    s.snapshot["pin"] = Value::Null;
    if let Some(peer) = peer {
        s.snapshot["peer"] = peer;
    }
    s.running = false;
    s.cancel = None;
}

pub fn snapshot() -> Value {
    let s = lock();
    let mut value = s.snapshot.clone();
    value["running"] = s.running.into();
    value
}

pub fn cancel() {
    if let Some(flag) = &lock().cancel {
        flag.store(true, Ordering::Relaxed);
    }
}

pub fn start(host_name: String, output: PathBuf) -> CoreResult<Value> {
    let mut s = lock();
    if s.running {
        return Err("Eine Kopplung läuft bereits.".into());
    }

    let listener = bind_listener()?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();

    // Jede Kopplung bekommt eine neue Host-Identität. Eine alte Pairing-Datei
    // bleibt bis zum Erfolg unangetastet.
    let file = RpPairingFile::generate(&format!("Quill-{}", uuid::Uuid::new_v4()));
    let info = PairableHostInfo::generate(host_name.clone(), HOST_MODEL);
    let txt: serde_json::Map<String, Value> = info
        .mdns_txt_records(&file.identifier)
        .into_iter()
        .map(|(k, v)| (k, Value::String(v)))
        .collect();
    let service_type = PAIRABLE_HOST_SERVICE_TYPE.trim_end_matches("local.").to_string();
    let advert = json!({
        "port": port,
        "name": file.identifier,
        "service_type": service_type,
        "txt": txt,
    });

    let cancel = Arc::new(AtomicBool::new(false));
    s.snapshot = json!({
        "phase": "listening",
        "message": "Warte darauf, dass das iPhone Quill in den Einstellungen auswählt.",
        "pin": null,
        "peer": null,
    });
    s.running = true;
    s.cancel = Some(cancel.clone());
    drop(s);

    let spawned = std::thread::Builder::new().name("quill-pairing".into()).spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(rt) => rt,
            Err(e) => return finish("error", format!("Laufzeit: {e}"), None),
        };
        rt.block_on(async move {
            tokio::select! {
                result = timeout(SESSION, accept(listener, file, info, output)) => match result {
                    Ok(Ok(peer)) => finish("paired", "Gekoppelt.", Some(peer)),
                    Ok(Err(e)) => finish("error", e, None),
                    Err(_) => finish("error", "Nach fünf Minuten abgebrochen. Bitte erneut starten.", None),
                },
                _ = cancelled(cancel) => finish("stopped", "Kopplung abgebrochen.", None),
            }
        });
    });
    if let Err(e) = spawned {
        finish("error", format!("Hintergrund-Thread: {e}"), None);
        return Err(e.to_string());
    }
    Ok(advert)
}

/// IPv6-Socket, der auch IPv4 annimmt: iOS verbindet sich über die Adresse, die
/// Bonjour für dieses Gerät meldet, und das kann beides sein. Ohne IPv6 nur IPv4.
fn bind_listener() -> CoreResult<std::net::TcpListener> {
    use socket2::{Domain, Protocol, Socket, Type};
    let dual = || -> std::io::Result<Socket> {
        let socket = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP))?;
        socket.set_only_v6(false)?;
        socket.bind(&SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0).into())?;
        Ok(socket)
    };
    let socket = match dual() {
        Ok(socket) => socket,
        Err(_) => {
            let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).map_err(|e| format!("Socket: {e}"))?;
            socket
                .bind(&std::net::SocketAddr::from(([0, 0, 0, 0], 0)).into())
                .map_err(|e| format!("Port konnte nicht geöffnet werden: {e}"))?;
            socket
        }
    };
    socket.set_nonblocking(true).map_err(|e| format!("Socket: {e}"))?;
    socket.listen(4).map_err(|e| format!("Port konnte nicht geöffnet werden: {e}"))?;
    Ok(socket.into())
}

async fn cancelled(flag: Arc<AtomicBool>) {
    while !flag.load(Ordering::Relaxed) {
        sleep(Duration::from_millis(100)).await;
    }
}

async fn accept(
    listener: std::net::TcpListener,
    mut file: RpPairingFile,
    info: PairableHostInfo,
    output: PathBuf,
) -> Result<Value, String> {
    let listener = TcpListener::from_std(listener).map_err(|e| e.to_string())?;
    let (stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
    update("connected", "iPhone verbunden, Kopplung läuft.", None);

    let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info);
    let peer = host
        .accept(&mut file, |pin| async move {
            update("pin", "Diesen Code in den Einstellungen eingeben.", Some(pin));
        })
        .await
        .map_err(|e| format!("Kopplung fehlgeschlagen: {e}"))?;

    if file.alt_irk().map(<[u8]>::len) != Some(16) || peer.remotepairing_udid.is_empty() {
        return Err("Das iPhone hat keine vollständige Kopplungs-Identität geliefert. Es wurde nichts gespeichert.".into());
    }
    storage::write_private(&output, &file.to_bytes()).map_err(|e| format!("Pairing-Datei: {e}"))?;
    Ok(json!({
        "udid": peer.remotepairing_udid,
        "name": peer.name,
        "model": peer.model,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn wait_finished() {
        let deadline = Instant::now() + Duration::from_secs(5);
        while lock().running {
            assert!(Instant::now() < deadline, "Kopplung endet nicht");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn advertises_and_cancels_without_writing() {
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("pairing.plist");
        let advert = start("Quill Test".into(), output.clone()).unwrap();
        assert!(advert["port"].as_u64().unwrap() > 0);
        assert_eq!(advert["service_type"], "_remotepairing-pairable-host._tcp.");
        assert!(advert["txt"].as_object().unwrap().len() > 2);
        assert!(start("noch einmal".into(), output.clone()).is_err());

        // Ein Gegenüber, das kein Remote Pairing spricht, beendet die Sitzung mit Fehler.
        let port = advert["port"].as_u64().unwrap();
        let mut stream = std::net::TcpStream::connect(format!("127.0.0.1:{port}")).unwrap();
        std::io::Write::write_all(&mut stream, b"kein pairing").unwrap();
        drop(stream);
        wait_finished();
        assert_eq!(snapshot()["phase"], "error");
        assert!(!output.exists());

        start("Quill Test".into(), output.clone()).unwrap();
        cancel();
        wait_finished();
        assert_eq!(snapshot()["phase"], "stopped");
        assert!(!output.exists());
    }
}
