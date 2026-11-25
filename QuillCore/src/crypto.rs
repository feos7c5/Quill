//! CSR erzeugen, .p12 bauen, umverschlüsseln und lesen.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use p12_keystore::{KeyStore, KeyStoreEntry, Pkcs12ImportPolicy, PrivateKeyChain};
use rsa::RsaPrivateKey;
use rsa::pkcs8::{DecodePrivateKey, EncodePrivateKey};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use x509_cert::Certificate;
use x509_cert::der::{Decode, Encode};

use crate::{CoreError, CoreResult};

fn decode(b64: &str, what: &str) -> CoreResult<Vec<u8>> {
    B64.decode(b64.trim()).map_err(|_| CoreError::with("Invalid input from the app.", format!("{what} is not valid Base64")))
}

/// RSA-2048-Schlüssel plus CSR (PEM) für developer.apple.com.
pub fn create_csr(common_name: &str, email: Option<&str>) -> CoreResult<Value> {
    let mut rng = rand::thread_rng();
    let key = RsaPrivateKey::new(&mut rng, 2048).map_err(|e| CoreError::with("The key could not be created.", e))?;
    let pkcs8 = key.to_pkcs8_der().map_err(|e| CoreError::with("The key could not be created.", e))?;

    let der = rustls_pki_types::PrivatePkcs8KeyDer::from(pkcs8.as_bytes().to_vec());
    let key_pair = rcgen::KeyPair::from_pkcs8_der_and_sign_algo(&der, &rcgen::PKCS_RSA_SHA256)
        .map_err(|e| CoreError::with("The key could not be created.", e))?;

    let mut params = rcgen::CertificateParams::default();
    let mut dn = rcgen::DistinguishedName::new();
    dn.push(rcgen::DnType::CommonName, common_name);
    if let Some(email) = email {
        // OID 1.2.840.113549.1.9.1 (emailAddress), wie der Zertifikatsassistent von macOS.
        dn.push(rcgen::DnType::CustomDnType(vec![1, 2, 840, 113549, 1, 9, 1]), email);
    }
    params.distinguished_name = dn;
    let csr = params
        .serialize_request(&key_pair)
        .map_err(|e| format!("CSR: {e}"))?
        .pem()
        .map_err(|e| format!("CSR: {e}"))?;

    Ok(json!({
        "csr_pem": csr,
        "key_pkcs8": B64.encode(pkcs8.as_bytes()),
    }))
}

/// Verbindet Zertifikat (DER) und privaten Schlüssel (PKCS#8) zu einer .p12.
pub fn build_p12(certificate_der_b64: &str, key_pkcs8_b64: &str, password: &str) -> CoreResult<Value> {
    let cert_der = decode(certificate_der_b64, "certificate")?;
    let key_der = decode(key_pkcs8_b64, "key")?;

    // Passen Zertifikat und Schlüssel zusammen?
    let certificate = Certificate::from_der(&cert_der).map_err(|_| CoreError::new("The file is not a valid certificate."))?;
    let key = RsaPrivateKey::from_pkcs8_der(&key_der).map_err(|_| CoreError::new("The saved key is damaged."))?;
    let public = rsa::pkcs8::EncodePublicKey::to_public_key_der(&key.to_public_key()).map_err(|e| e.to_string())?;
    let cert_public = certificate
        .tbs_certificate
        .subject_public_key_info
        .to_der()
        .map_err(|e| e.to_string())?;
    if public.as_bytes() != cert_public.as_slice() {
        return Err("This certificate does not belong to the generated CSR.".into());
    }

    let p12 = write_p12(&cert_der, &key_der, password)?;
    Ok(json!({ "p12": B64.encode(p12) }))
}

fn write_p12(cert_der: &[u8], key_der: &[u8], password: &str) -> CoreResult<Vec<u8>> {
    let cert = p12_keystore::Certificate::from_der(cert_der).map_err(|e| CoreError::with("The .p12 file could not be created.", format!("{e:?}")))?;
    let key = p12_keystore::PrivateKey::from_der(key_der).map_err(|e| CoreError::with("The .p12 file could not be created.", format!("{e:?}")))?;
    let local_key_id = Sha256::digest(key_der)[..8].to_vec();
    let chain = PrivateKeyChain::new(local_key_id, key, vec![cert]);
    let mut store = KeyStore::new();
    store.add_entry("quill", KeyStoreEntry::PrivateKeyChain(chain));
    store.writer(password).write().map_err(|e| CoreError::with("The .p12 file could not be created.", format!("{e:?}")))
}

fn open(p12_b64: &str, password: &str) -> CoreResult<(Vec<u8>, Vec<u8>)> {
    let data = decode(p12_b64, ".p12")?;
    let store = KeyStore::from_pkcs12(&data, password, Pkcs12ImportPolicy::Relaxed)
        .map_err(|_| CoreError::new("The password is wrong or the .p12 file is damaged."))?;
    let (_, chain) = store
        .private_key_chain()
        .ok_or(CoreError::new("The .p12 file contains no private key."))?;
    let cert = chain.certs().first().ok_or(CoreError::new("The .p12 file contains no certificate."))?;
    Ok((cert.as_der().to_vec(), chain.key().as_der().to_vec()))
}

pub fn rewrap_p12(p12_b64: &str, old_password: &str, new_password: &str) -> CoreResult<Value> {
    let (cert, key) = open(p12_b64, old_password)?;
    let p12 = write_p12(&cert, &key, new_password)?;
    Ok(json!({ "p12": B64.encode(p12) }))
}

pub fn inspect_p12(p12_b64: &str, password: &str) -> CoreResult<Value> {
    let (cert_der, _) = open(p12_b64, password)?;
    describe_certificate(&cert_der)
}

/// Liest ein einzelnes Zertifikat (DER, Base64).
pub fn inspect_certificate(der_b64: &str) -> CoreResult<Value> {
    describe_certificate(&decode(der_b64, "certificate")?)
}

fn describe_certificate(cert_der: &[u8]) -> CoreResult<Value> {
    let certificate = Certificate::from_der(cert_der).map_err(|_| CoreError::new("The file is not a valid certificate."))?;
    let tbs = &certificate.tbs_certificate;

    let mut common_name = None;
    let mut team_id = None;
    let mut organization = None;
    for rdn in tbs.subject.0.iter() {
        for atv in rdn.0.iter() {
            let value = std::str::from_utf8(atv.value.value()).ok().map(str::to_owned);
            match atv.oid.to_string().as_str() {
                "2.5.4.3" => common_name = value,
                "2.5.4.11" => team_id = value,
                "2.5.4.10" => organization = value,
                _ => {}
            }
        }
    }
    let not_after = tbs.validity.not_after.to_unix_duration().as_secs();
    let serial = hex::encode_upper(tbs.serial_number.as_bytes()).trim_start_matches('0').to_string();

    Ok(json!({
        "subject": tbs.subject.to_string(),
        "common_name": common_name,
        "team_id": team_id,
        "organization": organization,
        "serial": serial,
        "not_after": not_after,
        "certificate_der": B64.encode(cert_der),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Selbstsigniertes Zertifikat zum Schlüssel einer CSR, als Ersatz für Apples Antwort.
    fn self_signed(key_b64: &str) -> String {
        let der = rustls_pki_types::PrivatePkcs8KeyDer::from(B64.decode(key_b64).unwrap());
        let key = rcgen::KeyPair::from_pkcs8_der_and_sign_algo(&der, &rcgen::PKCS_RSA_SHA256).unwrap();
        let mut params = rcgen::CertificateParams::default();
        let mut dn = rcgen::DistinguishedName::new();
        dn.push(rcgen::DnType::CommonName, "Apple Development: Test");
        dn.push(rcgen::DnType::OrganizationalUnitName, "ABCDE12345");
        params.distinguished_name = dn;
        let cert = params.self_signed(&key).unwrap();
        B64.encode(cert.der())
    }

    #[test]
    fn csr_to_p12_roundtrip() {
        let csr = create_csr("Quill Test", Some("test@example.com")).unwrap();
        assert!(csr["csr_pem"].as_str().unwrap().contains("BEGIN CERTIFICATE REQUEST"));
        let key = csr["key_pkcs8"].as_str().unwrap();
        let cert = self_signed(key);

        let p12 = build_p12(&cert, key, "geheim").unwrap();
        let p12 = p12["p12"].as_str().unwrap();
        let info = inspect_p12(p12, "geheim").unwrap();
        assert_eq!(info["common_name"], "Apple Development: Test");
        assert_eq!(info["team_id"], "ABCDE12345");
        assert!(inspect_p12(p12, "falsch").is_err());
        let single = inspect_certificate(&cert).unwrap();
        assert_eq!(single["team_id"], "ABCDE12345");
        assert!(inspect_certificate("AAAA").is_err());

        let rewrapped = rewrap_p12(p12, "geheim", "").unwrap();
        let info = inspect_p12(rewrapped["p12"].as_str().unwrap(), "").unwrap();
        assert_eq!(info["team_id"], "ABCDE12345");
    }

    #[test]
    fn rejects_certificate_for_other_key() {
        let first = create_csr("A", None).unwrap();
        let second = create_csr("B", None).unwrap();
        let cert = self_signed(first["key_pkcs8"].as_str().unwrap());
        let error = build_p12(&cert, second["key_pkcs8"].as_str().unwrap(), "").unwrap_err();
        assert!(error.message.contains("does not belong"), "{error}");
    }
}
