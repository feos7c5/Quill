// QuillCore: C-Schnittstelle des Rust-Kerns. Siehe QuillCore/src/lib.rs.
// Alle Funktionen, die char* liefern, geben JSON zurück: {"ok":true,"data":…} oder {"ok":false,"error":"…"}.
// Rückgabewerte mit sc_string_free freigeben. Blockierende Funktionen nie auf dem Main-Thread aufrufen.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*sc_progress_cb)(void *context, double fraction, const char *message);
typedef void (*sc_two_factor_cb)(void *context, const char *params_json);

char *sc_init(const char *data_dir);
void sc_string_free(char *ptr);

// Kopplung (iOS 27)
char *sc_pair_start(const char *host_name, const char *output_path);
char *sc_pair_snapshot(void);
void sc_pair_cancel(void);
/// Selbsttest: spielt über 127.0.0.1 ein iPhone nach. Eine Kopplung muss laufen.
char *sc_pair_selftest(unsigned int show_seconds);

// Gerätedienste (address NULL = "10.7.0.1:49152")
char *sc_device_info(const char *pairing_path, const char *address);
char *sc_device_install(const char *pairing_path, const char *address, const char *package_path,
                        sc_progress_cb progress, void *context);
char *sc_device_uninstall(const char *pairing_path, const char *address, const char *bundle_id);
char *sc_device_apps(const char *pairing_path, const char *address);

// Apple-Account
char *sc_account_login(const char *email, const char *password, const char *anisette_url,
                       sc_two_factor_cb two_factor, void *context);
char *sc_account_two_factor_respond(const char *response_json);
char *sc_account_status(void);
char *sc_account_select_team(const char *team_id);
char *sc_account_register_device(const char *udid, const char *name);
char *sc_account_sign(const char *app_path, const char *options_json, sc_progress_cb progress, void *context);
char *sc_account_app_ids(void);
char *sc_account_certificates(void);
char *sc_account_revoke_certificate(const char *serial);
char *sc_account_export_p12(const char *password);
char *sc_account_logout(void);
char *sc_account_forget(void);

// Zertifikate ohne Account
char *sc_csr_create(const char *common_name, const char *email);
char *sc_p12_build(const char *certificate_der_b64, const char *key_pkcs8_b64, const char *password);
char *sc_p12_rewrap(const char *p12_b64, const char *old_password, const char *new_password);
char *sc_p12_inspect(const char *p12_b64, const char *password);
char *sc_certificate_inspect(const char *certificate_der_b64);

/// Signiert ein Konfigurationsprofil (Base64) mit einer .p12 (leer = eigene Identität):
/// {"profile": "<CMS, Base64>", "developer_certificate": bool}.
char *sc_profile_sign(const char *profile, const char *p12, const char *password);

#ifdef __cplusplus
}
#endif
