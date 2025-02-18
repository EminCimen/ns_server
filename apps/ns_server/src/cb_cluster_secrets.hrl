-ifndef(_CLUSTER_SECRETS__HRL_).
-define(_CLUSTER_SECRETS__HRL_,).

-define(CHRONICLE_SECRETS_KEY, cluster_secrets).
-define(CHRONICLE_NEXT_ID_KEY, cluster_secrets_next_id).
-define(CHRONICLE_DEK_COUNTERS_KEY, cluster_dek_counters).
-define(CHRONICLE_ENCR_AT_REST_SETTINGS_KEY, encr_at_rest_settings).
-define(GENERATED_KEY_TYPE, 'auto-generated-aes-key-256').
-define(AWSKMS_KEY_TYPE, 'awskms-aes-key-256').
-define(ENVELOP_CIPHER, aes_256_gcm).
-define(SECRET_ID_NOT_SET, -1).
-define(ACTIVE_KEY_FILENAME, "active_key").
-define(NULL_DEK, null_dek_id).

-endif.
