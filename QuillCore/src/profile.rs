//! Signiert Konfigurationsprofile (CMS/PKCS#7, SignedData mit eingebettetem Inhalt).
//!
//! iOS 27 lehnt unsignierte Profile mit „Profile Service“ (UDID-Abfrage) mit „Ein unbekannter
//! Fehler“ ab, bevor es die Rückmeldeadresse aufruft. ESign liefert dasselbe Profil für
//! http://127.0.0.1 signiert aus; Quill signiert deshalb ebenfalls.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use cms::builder::{SignedDataBuilder, SignerInfoBuilder};
use cms::cert::{CertificateChoices, IssuerAndSerialNumber};
use cms::content_info::ContentInfo;
use cms::signed_data::{EncapsulatedContentInfo, SignerIdentifier};
use rsa::RsaPrivateKey;
use rsa::pkcs1v15::{Signature, SigningKey};
use rsa::pkcs8::{DecodePrivateKey, EncodePrivateKey};
use serde_json::{Value, json};
use sha2::Sha256;
use std::path::Path;
use x509_cert::Certificate;
use x509_cert::der::asn1::OctetString;
use x509_cert::der::{Any, Decode, Encode, oid::db::rfc5911, oid::db::rfc5912};
use x509_cert::spki::AlgorithmIdentifierOwned;

use crate::{CoreError, CoreResult, storage};

const FAILED: &str = "The profile could not be signed.";

fn err(e: impl std::fmt::Display) -> CoreError {
    CoreError::with(FAILED, e.to_string())
}

/// Eigene, dauerhaft gespeicherte Signier-Identität für Profile (RSA-2048, selbst signiert).
fn identity(dir: &Path) -> CoreResult<(Vec<u8>, Vec<u8>)> {
    let cert_path = dir.join("profile-signer.cer");
    let key_path = dir.join("profile-signer.key");
    if let (Ok(cert), Ok(key)) = (std::fs::read(&cert_path), std::fs::read(&key_path)) {
        return Ok((cert, key));
    }
    let key = RsaPrivateKey::new(&mut rand::thread_rng(), 2048).map_err(err)?;
    let key_der = key.to_pkcs8_der().map_err(err)?.as_bytes().to_vec();
    let pkcs8 = rustls_pki_types::PrivatePkcs8KeyDer::from(key_der.clone());
    let pair = rcgen::KeyPair::from_pkcs8_der_and_sign_algo(&pkcs8, &rcgen::PKCS_RSA_SHA256).map_err(err)?;
    let mut params = rcgen::CertificateParams::default();
    let mut dn = rcgen::DistinguishedName::new();
    dn.push(rcgen::DnType::CommonName, "Quill");
    dn.push(rcgen::DnType::OrganizationName, "Quill");
    params.distinguished_name = dn;
    params.not_before = rcgen::date_time_ymd(2025, 1, 1);
    params.not_after = rcgen::date_time_ymd(2045, 1, 1);
    params.key_usages = vec![rcgen::KeyUsagePurpose::DigitalSignature];
    let cert = params.self_signed(&pair).map_err(err)?;
    let cert_der = cert.der().to_vec();
    storage::write_private(&cert_path, &cert_der).map_err(err)?;
    storage::write_private(&key_path, &key_der).map_err(err)?;
    Ok((cert_der, key_der))
}

pub fn sign(dir: &Path, profile: &[u8]) -> CoreResult<Vec<u8>> {
    let (cert_der, key_der) = identity(dir)?;
    let cert = Certificate::from_der(&cert_der).map_err(err)?;
    let key = RsaPrivateKey::from_pkcs8_der(&key_der).map_err(err)?;
    let signer = SigningKey::<Sha256>::new(key);

    let content = EncapsulatedContentInfo {
        econtent_type: rfc5911::ID_DATA,
        econtent: Some(Any::encode_from(&OctetString::new(profile.to_vec()).map_err(err)?).map_err(err)?),
    };
    let digest = AlgorithmIdentifierOwned { oid: rfc5912::ID_SHA_256, parameters: None };
    let sid = SignerIdentifier::IssuerAndSerialNumber(IssuerAndSerialNumber {
        issuer: cert.tbs_certificate.issuer.clone(),
        serial_number: cert.tbs_certificate.serial_number.clone(),
    });
    let info = SignerInfoBuilder::new(&signer, sid, digest.clone(), &content, None).map_err(err)?;
    let signed: ContentInfo = SignedDataBuilder::new(&content)
        .add_digest_algorithm(digest)
        .map_err(err)?
        .add_certificate(CertificateChoices::Certificate(cert))
        .map_err(err)?
        .add_signer_info::<SigningKey<Sha256>, Signature>(info)
        .map_err(err)?
        .build()
        .map_err(err)?;
    signed.to_der().map_err(err)
}

pub fn sign_b64(dir: &Path, profile_b64: &str) -> CoreResult<Value> {
    let profile = B64
        .decode(profile_b64.trim())
        .map_err(|_| CoreError::with("Invalid input from the app.", "profile is not valid Base64"))?;
    Ok(json!({ "profile": B64.encode(sign(dir, &profile)?) }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signs_and_reuses_identity() {
        let dir = tempfile::tempdir().unwrap();
        let profile = b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>";
        let first = sign(dir.path(), profile).unwrap();
        let second = sign(dir.path(), profile).unwrap();
        assert!(dir.path().join("profile-signer.cer").exists());
        // Gleiche Identität: dasselbe Zertifikat steckt in beiden Signaturen.
        let cert = std::fs::read(dir.path().join("profile-signer.cer")).unwrap();
        let find = |hay: &[u8]| hay.windows(cert.len()).any(|w| w == cert.as_slice());
        assert!(find(&first) && find(&second));
        let _ = first;
    }
}
