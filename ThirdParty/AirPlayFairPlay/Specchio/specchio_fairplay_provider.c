/*
 * Specchio AirPlay FairPlay provider adapter.
 *
 * This file exposes Specchio's stateless C ABI and delegates the FairPlay
 * operations to the vendored UxPlay implementation.
 */

#include <os/log.h>
#include <stdint.h>
#include <stddef.h>

#include "fairplay.h"

enum {
    specchio_setup_request_bytes = 16,
    specchio_setup_response_bytes = 142,
    specchio_key_message_request_bytes = 164,
    specchio_key_message_response_bytes = 32,
    specchio_encrypted_key_bytes = 72,
    specchio_decrypted_key_bytes = 16,
    specchio_supported_fairplay_version = 3,
    specchio_max_setup_mode = 3
};

static os_log_t
specchio_fairplay_log(void)
{
    static os_log_t log;
    if (log == NULL) {
        log = os_log_create("com.alexintosh.Specchio", "AirPlayFairPlayProvider");
    }
    return log;
}

static int
specchio_validate_buffers(
    const char *operation,
    const uint8_t *input,
    unsigned long input_length,
    unsigned long expected_input_length,
    uint8_t *output,
    unsigned long *output_length,
    unsigned long expected_output_length
)
{
    if (input == NULL) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=%{public}s_BAD_INPUT_POINTER expectedBytes=%{public}lu", operation, expected_input_length);
        return -10;
    }
    if (output == NULL || output_length == NULL) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=%{public}s_BAD_OUTPUT_POINTER", operation);
        return -11;
    }
    if (input_length != expected_input_length) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=%{public}s_BAD_INPUT_LENGTH actual=%{public}lu expected=%{public}lu", operation, input_length, expected_input_length);
        return -12;
    }
    if (*output_length < expected_output_length) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=%{public}s_OUTPUT_TOO_SMALL actual=%{public}lu expected=%{public}lu", operation, *output_length, expected_output_length);
        return -13;
    }
    if (input[4] != specchio_supported_fairplay_version) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=%{public}s_UNSUPPORTED_VERSION actual=%{public}u expected=%{public}u", operation, input[4], specchio_supported_fairplay_version);
        return -14;
    }

    os_log_info(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=%{public}s_VALIDATED inputBytes=%{public}lu outputCapacity=%{public}lu", operation, input_length, *output_length);
    return 0;
}

static fairplay_t *
specchio_create_context(const char *operation)
{
    fairplay_t *context = fairplay_init(NULL);
    if (context == NULL) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=%{public}s_CONTEXT_FAILED", operation);
        return NULL;
    }

    os_log_info(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=%{public}s_CONTEXT_CREATED", operation);
    return context;
}

int
specchio_airplay_fairplay_setup_reply(
    const uint8_t *request,
    unsigned long request_length,
    uint8_t *response,
    unsigned long *response_length
)
{
    const unsigned int mode = request_length > 14 && request != NULL ? request[14] : 255;
    const unsigned long output_capacity = response_length != NULL ? *response_length : 0;
    os_log_info(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=SETUP_ENTER requestBytes=%{public}lu outputCapacity=%{public}lu mode=%{public}u", request_length, output_capacity, mode);

    int validation_status = specchio_validate_buffers(
        "SETUP",
        request,
        request_length,
        specchio_setup_request_bytes,
        response,
        response_length,
        specchio_setup_response_bytes
    );
    if (validation_status != 0) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=SETUP_VALIDATION_FAILED status=%{public}d", validation_status);
        return validation_status;
    }
    if (mode > specchio_max_setup_mode) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=SETUP_UNSUPPORTED_MODE mode=%{public}u max=%{public}u", mode, specchio_max_setup_mode);
        return -15;
    }

    fairplay_t *context = specchio_create_context("SETUP");
    if (context == NULL) {
        return -20;
    }

    const int upstream_status = fairplay_setup(context, request, response);
    fairplay_destroy(context);

    if (upstream_status != 0) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=SETUP_UPSTREAM_FAILED status=%{public}d", upstream_status);
        return -30;
    }

    *response_length = specchio_setup_response_bytes;
    os_log_info(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=SETUP_OK responseBytes=%{public}lu", *response_length);
    return 0;
}

int
specchio_airplay_fairplay_key_message_reply(
    const uint8_t *request,
    unsigned long request_length,
    uint8_t *response,
    unsigned long *response_length
)
{
    const unsigned long output_capacity = response_length != NULL ? *response_length : 0;
    os_log_info(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=KEY_MESSAGE_ENTER requestBytes=%{public}lu outputCapacity=%{public}lu", request_length, output_capacity);

    int validation_status = specchio_validate_buffers(
        "KEY_MESSAGE",
        request,
        request_length,
        specchio_key_message_request_bytes,
        response,
        response_length,
        specchio_key_message_response_bytes
    );
    if (validation_status != 0) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=KEY_MESSAGE_VALIDATION_FAILED status=%{public}d", validation_status);
        return validation_status;
    }

    fairplay_t *context = specchio_create_context("KEY_MESSAGE");
    if (context == NULL) {
        return -20;
    }

    const int upstream_status = fairplay_handshake(context, request, response);
    fairplay_destroy(context);

    if (upstream_status != 0) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=KEY_MESSAGE_UPSTREAM_FAILED status=%{public}d", upstream_status);
        return -31;
    }

    *response_length = specchio_key_message_response_bytes;
    os_log_info(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=KEY_MESSAGE_OK responseBytes=%{public}lu", *response_length);
    return 0;
}

int
specchio_airplay_fairplay_decrypt_key(
    const uint8_t *key_message,
    unsigned long key_message_length,
    const uint8_t *encrypted_key,
    unsigned long encrypted_key_length,
    uint8_t *output,
    unsigned long *output_length
)
{
    const unsigned long output_capacity = output_length != NULL ? *output_length : 0;
    os_log_info(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=DECRYPT_ENTER keyMessageBytes=%{public}lu encryptedKeyBytes=%{public}lu outputCapacity=%{public}lu", key_message_length, encrypted_key_length, output_capacity);

    int validation_status = specchio_validate_buffers(
        "DECRYPT_KEY_MESSAGE",
        key_message,
        key_message_length,
        specchio_key_message_request_bytes,
        output,
        output_length,
        specchio_decrypted_key_bytes
    );
    if (validation_status != 0) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=DECRYPT_KEY_MESSAGE_VALIDATION_FAILED status=%{public}d", validation_status);
        return validation_status;
    }
    if (encrypted_key == NULL) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=DECRYPT_BAD_ENCRYPTED_KEY_POINTER");
        return -16;
    }
    if (encrypted_key_length != specchio_encrypted_key_bytes) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=DECRYPT_BAD_ENCRYPTED_KEY_LENGTH actual=%{public}lu expected=%{public}u", encrypted_key_length, specchio_encrypted_key_bytes);
        return -17;
    }

    fairplay_t *context = specchio_create_context("DECRYPT");
    if (context == NULL) {
        return -20;
    }

    uint8_t handshake_response[specchio_key_message_response_bytes];
    int upstream_status = fairplay_handshake(context, key_message, handshake_response);
    if (upstream_status != 0) {
        fairplay_destroy(context);
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=DECRYPT_HANDSHAKE_FAILED status=%{public}d", upstream_status);
        return -31;
    }

    upstream_status = fairplay_decrypt(context, encrypted_key, output);
    fairplay_destroy(context);

    if (upstream_status != 0) {
        os_log_error(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=DECRYPT_UPSTREAM_FAILED status=%{public}d", upstream_status);
        return -32;
    }

    *output_length = specchio_decrypted_key_bytes;
    os_log_info(specchio_fairplay_log(), "[AirPlayFairPlayProviderC] branch=DECRYPT_OK outputBytes=%{public}lu", *output_length);
    return 0;
}
