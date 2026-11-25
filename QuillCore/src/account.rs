//! Apple-Account: Anmeldung mit 2FA, Team, Gerät, App-IDs, Zertifikat, Signieren.
//!
//! Die Arbeit macht isideload. Dieser Teil hält die Sitzung, vermittelt den zweiten
//! Faktor an Swift und übersetzt Ergebnisse in JSON.

use std::ffi::{CString, c_char, c_void};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use isideload::anisette::remote_v3::{DEFAULT_ANISETTE_V3_URL, RemoteV3AnisetteProvider};
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::dev::app_ids::AppIdsApi;
use isideload::dev::certificates::CertificatesApi;
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::devices::DevicesApi;
use isideload::dev::teams::{DeveloperTeam, TeamsApi};
use isideload::sideload::builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior};
use isideload::sideload::cert_identity::CertificateIdentity;
use isideload::sideload::{SideloaderBuilder, TeamSelection};
use isideload::util::callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox};
use rootcause::prelude::*;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::oneshot;

use crate::device::Progress;
use crate::storage::FileStorage;
use crate::{Context, CoreError, CoreResult};

/// Name, unter dem das Entwicklungszertifikat bei Apple erscheint.
/// Muss gleich bleiben, sonst findet Quill sein eigenes Zertifikat nicht wieder.
const MACHINE_NAME: &str = "Quill";
/// So lange wartet die Anmeldung auf den zweiten Faktor.
const TWO_FACTOR_WAIT: Duration = Duration::from_secs(600);

/// Swift erfährt hierüber, dass Apple einen zweiten Faktor verlangt. `params_json`:
/// `{"sms": bool, "unknown": bool, "last_error": str|null, "numbers": [{"id", "number"}], "selected_number_id"}`.
pub type TwoFactorCallback = extern "C" fn(context: *mut c_void, params_json: *const c_char);

struct Account {
    email: String,
    name: Option<String>,
    session: DeveloperSession,
    teams: Vec<DeveloperTeam>,
    team: Option<DeveloperTeam>,
    data_dir: PathBuf,
}

fn account() -> &'static tokio::sync::Mutex<Option<Account>> {
    static ACCOUNT: OnceLock<tokio::sync::Mutex<Option<Account>>> = OnceLock::new();
    ACCOUNT.get_or_init(|| tokio::sync::Mutex::new(None))
}

fn pending_two_factor() -> &'static Mutex<Option<oneshot::Sender<String>>> {
    static PENDING: OnceLock<Mutex<Option<oneshot::Sender<String>>>> = OnceLock::new();
    PENDING.get_or_init(|| Mutex::new(None))
}

fn account_storage(dir: &std::path::Path) -> FileStorage {
    FileStorage::new(dir.join("account"))
}

fn anisette_storage(dir: &std::path::Path) -> FileStorage {
    FileStorage::new(dir.join("anisette"))
}

const NO_CODE: &str = "No verification code was entered.";
const CANCELLED: &str = "Sign-in was cancelled.";

fn message(report: impl std::fmt::Display) -> CoreError {
    let text = report.to_string();
    let lower = text.to_lowercase();
    if lower.contains("-22406") || lower.contains("incorrect") && lower.contains("password") {
        return CoreError::new("The Apple ID or password is incorrect.");
    }
    if lower.contains("-20209") || lower.contains("locked") {
        return CoreError::new("This Apple ID is locked. Unlock it at iforgot.apple.com.");
    }
    if text.contains(NO_CODE) {
        return CoreError::new(NO_CODE);
    }
    if text.contains(CANCELLED) {
        return CoreError::new(CANCELLED);
    }
    if lower.contains("anisette") {
        return CoreError::with("The anisette server did not respond as expected. Check its address in Settings.", text);
    }
    CoreError::with("Apple reported an error.", text)
}

// MARK: - Anmeldung

pub async fn login(
    data_dir: PathBuf,
    email: String,
    password: String,
    anisette_url: Option<String>,
    callback: Option<TwoFactorCallback>,
    context: Context,
) -> CoreResult<Value> {
    let url = anisette_url.unwrap_or_else(|| DEFAULT_ANISETTE_V3_URL.to_string());
    let provider = RemoteV3AnisetteProvider::new(&url, Box::new(anisette_storage(&data_dir)), "0".to_string())
        .map_err(message)?;

    let two_factor = move |params: TwoFactorCallbackParams| {
        let receiver = {
            let (sender, receiver) = oneshot::channel::<String>();
            *pending_two_factor().lock().unwrap_or_else(|p| p.into_inner()) = Some(sender);
            receiver
        };
        let payload = json!({
            "sms": params.sms,
            "unknown": params.unknown,
            "last_error": params.last_error,
            "selected_number_id": params.selected_number_id,
            "numbers": params.numbers.iter().map(|n| json!({
                "id": n.id,
                "number": n.number_with_dial_code,
            })).collect::<Vec<_>>(),
        });
        if let Some(cb) = callback {
            let text = CString::new(payload.to_string()).unwrap_or_default();
            cb(context.ptr(), text.as_ptr());
        }
        async move {
            let answer = tokio::time::timeout(TWO_FACTOR_WAIT, receiver)
                .await
                .map_err(|_| report!("{NO_CODE}"))?
                .map_err(|_| report!("{CANCELLED}"))?;
            parse_two_factor(&answer)
        }
    };

    let mut apple = AppleAccount::builder(&email)
        .anisette_provider(provider)
        .login(&password, two_factor)
        .await
        .map_err(message)?;
    *pending_two_factor().lock().unwrap_or_else(|p| p.into_inner()) = None;

    let name = apple.get_name().ok().map(|(first, last)| format!("{first} {last}").trim().to_string());
    let mut session = DeveloperSession::from_account(&mut apple).await.map_err(message)?;
    let teams = session.list_teams().await.map_err(message)?;
    let team = if teams.len() == 1 { teams.first().cloned() } else { None };

    let mut guard = account().lock().await;
    *guard = Some(Account { email, name, session, teams, team, data_dir });
    Ok(status_of(guard.as_ref()))
}

fn parse_two_factor(answer: &str) -> Result<TwoFactorCallbackResponse, Report> {
    let value: Value = serde_json::from_str(answer).map_err(|e| report!("Invalid response: {e}"))?;
    if let Some(code) = value.get("code").and_then(Value::as_str) {
        return Ok(TwoFactorCallbackResponse::SubmitCode(code.trim().to_string()));
    }
    if let Some(id) = value.get("sms").and_then(Value::as_u64) {
        return Ok(TwoFactorCallbackResponse::SendSms(id as u32));
    }
    if value.get("devices").and_then(Value::as_bool) == Some(true) {
        return Ok(TwoFactorCallbackResponse::SendToDevices);
    }
    if value.get("resend").and_then(Value::as_bool) == Some(true) {
        return Ok(TwoFactorCallbackResponse::ResendCode);
    }
    Ok(TwoFactorCallbackResponse::Abort)
}

pub fn two_factor_respond(answer: &str) -> CoreResult<Value> {
    let sender = pending_two_factor()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .take()
        .ok_or(CoreError::new("No sign-in is waiting for a code."))?;
    sender
        .send(answer.to_string())
        .map_err(|_| CoreError::new("The sign-in is no longer waiting."))?;
    Ok(json!({ "accepted": true }))
}

fn team_json(team: &DeveloperTeam) -> Value {
    json!({
        "id": team.team_id,
        "name": team.name,
        "type": team.r#type,
        "status": team.status,
    })
}

fn status_of(account: Option<&Account>) -> Value {
    match account {
        None => json!({ "logged_in": false }),
        Some(a) => json!({
            "logged_in": true,
            "email": a.email,
            "name": a.name,
            "team": a.team.as_ref().map(team_json),
            "teams": a.teams.iter().map(team_json).collect::<Vec<_>>(),
        }),
    }
}

pub async fn status() -> CoreResult<Value> {
    Ok(status_of(account().lock().await.as_ref()))
}

pub async fn select_team(team_id: String) -> CoreResult<Value> {
    let mut guard = account().lock().await;
    let a = guard.as_mut().ok_or(CoreError::new("Not signed in. Sign in with your Apple ID."))?;
    let team = a
        .teams
        .iter()
        .find(|t| t.team_id == team_id)
        .cloned()
        .ok_or(CoreError::new("This team does not exist in the account."))?;
    a.team = Some(team);
    Ok(status_of(Some(a)))
}

/// Holt die angemeldete Sitzung samt Team oder liefert einen verständlichen Fehler.
async fn with_team<T>(
    work: impl AsyncFnOnce(&mut Account, DeveloperTeam) -> CoreResult<T>,
) -> CoreResult<T> {
    let mut guard = account().lock().await;
    let a = guard.as_mut().ok_or(CoreError::new("Not signed in. Sign in with your Apple ID."))?;
    let team = a.team.clone().ok_or(CoreError::new("Choose a team first."))?;
    work(a, team).await
}

pub async fn register_device(udid: String, name: String) -> CoreResult<Value> {
    with_team(async |a, team| {
        a.session
            .ensure_device_registered(&team, &name, &udid, None)
            .await
            .map_err(message)?;
        Ok(json!({ "registered": true }))
    })
    .await
}

// MARK: - Signieren

#[derive(Deserialize, Default)]
pub struct SignOptions {
    #[serde(default)]
    pub increased_memory_limit: bool,
    /// true: jede Erweiterung bekommt eine eigene App-ID (wie Xcode).
    /// false: Erweiterungen nutzen das Profil der Haupt-App und sparen App-IDs.
    #[serde(default = "default_true")]
    pub register_extensions: bool,
}

fn default_true() -> bool {
    true
}

pub async fn sign(app_path: PathBuf, options: SignOptions, progress: &Progress) -> CoreResult<Value> {
    with_team(async |a, team| {
        progress.report(0.02, "Preparing certificate and app IDs…");
        let behavior = if options.register_extensions {
            ExtensionsBehavior::RegisterAll
        } else {
            ExtensionsBehavior::ReuseMain
        };
        let mut sideloader = SideloaderBuilder::<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>::new(
            a.session.clone(),
            a.email.clone(),
        )
        .team_selection(TeamSelection::First)
        .max_certs_behavior(MaxCertsBehavior::Error)
        .extensions_behavior(ExtensionsBehaviorSelection::Fixed(behavior))
        .storage(Box::new(account_storage(&a.data_dir)))
        .machine_name(MACHINE_NAME.to_string())
        .delete_app_after_install(false)
        .build();

        let (signed, special) = sideloader
            .sign_app(
                app_path,
                Some(team),
                options.increased_memory_limit,
                Some(|fraction: f32| async move {
                    progress.report(f64::from(fraction), "Signing…");
                }),
                None,
                None,
            )
            .await
            .map_err(|e| explain_sign_error(message(e)))?;

        let bundle_id = plist::Value::from_file(signed.join("Info.plist"))
            .ok()
            .and_then(|v| v.as_dictionary().and_then(|d| d.get("CFBundleIdentifier")).and_then(|v| v.as_string()).map(str::to_owned));
        progress.report(1.0, "Signed.");
        Ok(json!({
            "app_path": signed.to_string_lossy(),
            "bundle_id": bundle_id,
            "special": special.map(|s| s.to_string()),
        }))
    })
    .await
}

fn explain_sign_error(error: CoreError) -> CoreError {
    let text = error.detail.clone().unwrap_or_else(|| error.message.clone());
    let lower = text.to_lowercase();
    if lower.contains("not enough available app ids") {
        return CoreError::with(
            "No app IDs left. Free accounts get only a few new app IDs per week. Remove extensions or try again later.",
            text,
        );
    }
    if lower.contains("maximum") && lower.contains("certificate") {
        return CoreError::with(
            "There are too many development certificates. Revoke one under Certificates at Apple and try again.",
            text,
        );
    }
    error
}

// MARK: - Übersicht und Verwaltung

pub async fn app_ids() -> CoreResult<Value> {
    with_team(async |a, team| {
        let response = a.session.list_app_ids(&team, None).await.map_err(message)?;
        Ok(json!({
            "available": response.available_quantity,
            "max": response.max_quantity,
            "app_ids": response.app_ids.iter().map(|id| json!({
                "identifier": id.identifier,
                "name": id.name,
                "expires": id.expiration_date.map(|d| std::time::SystemTime::from(d).duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)),
            })).collect::<Vec<_>>(),
        }))
    })
    .await
}

pub async fn certificates() -> CoreResult<Value> {
    with_team(async |a, team| {
        let certs = a.session.list_ios_certs(&team).await.map_err(message)?;
        Ok(Value::Array(
            certs
                .iter()
                .map(|c| {
                    json!({
                        "serial": c.serial_number,
                        "name": c.name,
                        "machine_name": c.machine_name,
                        "status": c.status,
                        "is_quill": c.machine_name.as_deref() == Some(MACHINE_NAME),
                        "expires": c.expiration_date.map(|d| std::time::SystemTime::from(d).duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)),
                    })
                })
                .collect(),
        ))
    })
    .await
}

pub async fn revoke(serial: String) -> CoreResult<Value> {
    with_team(async |a, team| {
        a.session
            .revoke_development_cert(&team, &serial, None)
            .await
            .map_err(message)?;
        Ok(json!({ "revoked": true }))
    })
    .await
}

/// Liefert das Account-Zertifikat als .p12. Gibt es noch keines für Quill,
/// legt Apple eines an (wie beim ersten Signieren).
pub async fn export_p12(password: String) -> CoreResult<Value> {
    with_team(async |a, team| {
        let storage = account_storage(&a.data_dir);
        let identity = CertificateIdentity::retrieve(
            MACHINE_NAME,
            &a.email,
            &mut a.session,
            &team,
            &storage,
            &MaxCertsBehavior::<MaxCertsCallbackBox>::Error,
        )
        .await
        .map_err(|e| explain_sign_error(message(e)))?;
        let p12 = identity.as_p12(&password).await.map_err(message)?;
        use base64::Engine as _;
        Ok(json!({
            "p12": base64::engine::general_purpose::STANDARD.encode(p12),
            "serial": identity.get_serial_number(),
            "machine_id": identity.machine_id,
        }))
    })
    .await
}

pub async fn logout() -> CoreResult<Value> {
    *account().lock().await = None;
    *pending_two_factor().lock().unwrap_or_else(|p| p.into_inner()) = None;
    Ok(json!({ "logged_in": false }))
}

pub async fn forget() -> CoreResult<Value> {
    let dir = {
        let mut guard = account().lock().await;
        let dir = guard.as_ref().map(|a| a.data_dir.clone());
        *guard = None;
        dir
    };
    let dir = dir.or_else(crate::data_dir).ok_or(CoreError::new("The core is not initialized."))?;
    account_storage(&dir).clear().map_err(|e| CoreError::with("Saved sign-in data could not be deleted.", e))?;
    anisette_storage(&dir).clear().map_err(|e| CoreError::with("Saved sign-in data could not be deleted.", e))?;
    Ok(json!({ "logged_in": false }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_two_factor_answers() {
        assert!(matches!(parse_two_factor(r#"{"code":" 123456 "}"#).unwrap(), TwoFactorCallbackResponse::SubmitCode(c) if c == "123456"));
        assert!(matches!(parse_two_factor(r#"{"sms":2}"#).unwrap(), TwoFactorCallbackResponse::SendSms(2)));
        assert!(matches!(parse_two_factor(r#"{"devices":true}"#).unwrap(), TwoFactorCallbackResponse::SendToDevices));
        assert!(matches!(parse_two_factor(r#"{"resend":true}"#).unwrap(), TwoFactorCallbackResponse::ResendCode));
        assert!(matches!(parse_two_factor(r#"{"abort":true}"#).unwrap(), TwoFactorCallbackResponse::Abort));
    }

    #[test]
    fn respond_without_pending_login_fails() {
        assert!(two_factor_respond(r#"{"code":"1"}"#).is_err());
    }

    #[test]
    fn calls_without_login_explain() {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let error = rt.block_on(app_ids()).unwrap_err();
        assert!(error.message.contains("Not signed in"), "{error}");
        assert_eq!(rt.block_on(status()).unwrap()["logged_in"], false);
    }
}
