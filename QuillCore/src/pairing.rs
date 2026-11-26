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

use crate::{CoreError, CoreResult, storage};

/// So lange bleibt der Port offen, danach gilt die Kopplung als abgebrochen.
const SESSION: Duration = Duration::from_secs(300);
/// Modellkennung, die iOS als Rechner anzeigt. iOS erwartet hier einen Mac.
const HOST_MODEL: &str = "Mac17,7";

struct State {
    snapshot: Value,
    cancel: Option<Arc<AtomicBool>>,
    running: bool,
    port: Option<u16>,
}

fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(|| {
        Mutex::new(State {
            snapshot: json!({ "phase": "idle", "message": "Ready.", "detail": null, "pin": null, "peer": null }),
            cancel: None,
            running: false,
            port: None,
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
    s.snapshot["detail"] = Value::Null;
    s.snapshot["pin"] = pin.map(Value::String).unwrap_or(Value::Null);
}

fn finish(phase: &str, message: impl Into<CoreError>, peer: Option<Value>) {
    let error = message.into();
    let mut s = lock();
    s.snapshot["phase"] = phase.into();
    s.snapshot["message"] = error.message.into();
    s.snapshot["detail"] = error.detail.map(Value::String).unwrap_or(Value::Null);
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
        return Err("Pairing is already running.".into());
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
        "message": "Waiting for the iPhone to select Quill in Settings.",
        "detail": null,
        "pin": null,
        "peer": null,
    });
    s.running = true;
    s.port = Some(port);
    s.cancel = Some(cancel.clone());
    drop(s);

    let spawned = std::thread::Builder::new().name("quill-pairing".into()).spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(rt) => rt,
            Err(e) => return finish("error", CoreError::with("Pairing could not start.", e), None),
        };
        rt.block_on(async move {
            tokio::select! {
                result = timeout(SESSION, accept(listener, file, info, output)) => match result {
                    Ok(Ok(peer)) => finish("paired", "Paired.", Some(peer)),
                    Ok(Err(e)) => finish("error", e, None),
                    Err(_) => finish("error", "Pairing stopped after five minutes. Start again.", None),
                },
                _ = cancelled(cancel) => finish("stopped", "Pairing cancelled.", None),
            }
        });
    });
    if let Err(e) = spawned {
        finish("error", CoreError::with("Pairing could not start.", &e), None);
        return Err(CoreError::with("Pairing could not start.", e));
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
            let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).map_err(port_error)?;
            socket
                .bind(&std::net::SocketAddr::from(([0, 0, 0, 0], 0)).into())
                .map_err(port_error)?;
            socket
        }
    };
    socket.set_nonblocking(true).map_err(port_error)?;
    socket.listen(4).map_err(port_error)?;
    Ok(socket.into())
}

fn port_error(e: std::io::Error) -> CoreError {
    CoreError::with("The network port for pairing could not be opened.", e)
}

async fn cancelled(flag: Arc<AtomicBool>) {
    while !flag.load(Ordering::Relaxed) {
        sleep(Duration::from_millis(100)).await;
    }
}

async fn accept(
    listener: std::net::TcpListener,
    file: RpPairingFile,
    info: PairableHostInfo,
    output: PathBuf,
) -> CoreResult<Value> {
    let listener = TcpListener::from_std(listener).map_err(port_error)?;

    // Wie Husk: Jede Verbindung sofort bedienen. iOS öffnet beim Auswählen in den Einstellungen
    // mitunter Verbindungen, die nie etwas senden; würde Quill nur die erste annehmen, käme der
    // eigentliche Kopplungsversuch nie an und kein Code erschiene.
    let pin_shown = Arc::new(AtomicBool::new(false));
    let mut attempts = tokio::task::JoinSet::new();
    let (file, peer) = loop {
        tokio::select! {
            connection = listener.accept() => {
                let (stream, address) = connection.map_err(port_error)?;
                tracing::info!("pairing: connection from {address}");
                if !pin_shown.load(Ordering::SeqCst) {
                    update("connected", "iPhone connected, pairing…", None);
                }
                let mut attempt_file = file.clone();
                let info = info.clone();
                let pin_shown = pin_shown.clone();
                attempts.spawn(async move {
                    let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info);
                    let peer = host
                        .accept(&mut attempt_file, |pin| {
                            pin_shown.store(true, Ordering::SeqCst);
                            update("pin", "Enter this code in Settings.", Some(pin));
                            async {}
                        })
                        .await?;
                    Ok::<_, idevice::IdeviceError>((attempt_file, peer))
                });
            }
            Some(done) = attempts.join_next() => match done {
                Ok(Ok(paired)) => break paired,
                // Scheitert ein Versuch vor dem Code, war es nicht der Kopplungsversuch: weiter warten.
                Ok(Err(e)) if !pin_shown.load(Ordering::SeqCst) => {
                    tracing::info!("pairing: connection ended before the code step: {e}");
                    update("listening", "Waiting for the iPhone to select Quill in Settings.", None);
                }
                Ok(Err(e)) => return Err(CoreError::with("Pairing failed.", e)),
                Err(e) => return Err(CoreError::with("Pairing failed.", e)),
            },
        }
    };
    if file.alt_irk().map(<[u8]>::len) != Some(16) || peer.remotepairing_udid.is_empty() {
        return Err("The iPhone did not provide a complete pairing identity. Nothing was saved.".into());
    }
    storage::write_private(&output, &file.to_bytes()).map_err(|e| CoreError::with("The pairing file could not be saved.", e))?;
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

        // Ein Gegenüber, das kein Remote Pairing spricht, beendet die Sitzung nicht:
        // Quill wartet weiter auf den echten Kopplungsversuch (wie Husk).
        let port = advert["port"].as_u64().unwrap();
        let silent = std::net::TcpStream::connect(format!("127.0.0.1:{port}")).unwrap();
        let mut stream = std::net::TcpStream::connect(format!("127.0.0.1:{port}")).unwrap();
        std::io::Write::write_all(&mut stream, b"not pairing").unwrap();
        drop(stream);
        let deadline = Instant::now() + Duration::from_secs(5);
        while snapshot()["phase"] != "listening" {
            assert!(Instant::now() < deadline, "Kopplung wartet nicht weiter");
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(lock().running);
        drop(silent);

        cancel();
        wait_finished();
        assert_eq!(snapshot()["phase"], "stopped");
        assert!(!output.exists());
    }

    /// Spielt die Einstellungen eines iPhones nach: erst eine stumme Verbindung, dann der echte
    /// Kopplungsversuch mit dem Code, den Quill anzeigt. Am Ende muss eine Pairing-Datei entstehen.
    #[test]
    fn pairs_with_simulated_iphone() {
        use idevice::remote_pairing::{RemotePairingClient, RpPairingSocketProvider};
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("pairing.plist");
        wait_finished();
        let advert = start("Quill Test".into(), output.clone()).unwrap();
        let port = advert["port"].as_u64().unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let result = runtime.block_on(async {
            timeout(Duration::from_secs(20), async {
                let _silent = tokio::net::TcpStream::connect(format!("127.0.0.1:{port}")).await.unwrap();
                let stream = tokio::net::TcpStream::connect(format!("127.0.0.1:{port}")).await.unwrap();
                let mut socket = RpPairingSocket::new(stream);
                socket
                    .send_plain(
                        json!({"request":{"_0":{"handshake":{"_0":{
                            "hostOptions":{"attemptPairVerify":false}, "wireProtocolVersion":26
                        }}}}}),
                        0,
                    )
                    .await
                    .unwrap();
                socket.recv_plain().await.unwrap();
                let mut client = RemotePairingClient::new(socket, "Simuliertes iPhone");
                let mut file = RpPairingFile::generate("Simuliertes iPhone");
                client
                    .pair(&mut file, || async {
                        // Wie ein Mensch: den Code ablesen, den Quill gerade anzeigt.
                        assert_eq!(snapshot()["phase"], "pin");
                        snapshot()["pin"].as_str().unwrap().to_owned()
                    })
                    .await
                    .map_err(|e| format!("{e:?}"))
            })
            .await
            .expect("Kopplung hängt")
        });
        wait_finished();
        // Der nachgespielte Client ist kein iPhone und schickt keine UDID mit. Kommt Quill bis zu
        // dieser Stelle, waren Code-Anzeige und Code-Prüfung (SRP) erfolgreich.
        assert!(result.is_err());
        let detail = snapshot()["detail"].as_str().unwrap_or_default().to_owned();
        assert!(detail.contains("remotepairing_udid"), "{}", snapshot());
        assert!(!output.exists());
    }
}
