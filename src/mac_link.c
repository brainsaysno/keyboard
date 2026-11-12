/* SPDX-License-Identifier: MIT */

// Left half: receives text slots from the Mac companion app over a custom GATT service and
// relays them to the right half's display (see mac_link_protocol.h).

#include <string.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>
#include <zmk/behavior.h>
#include <zmk/split/central.h>

#include "mac_link_protocol.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

// The right half is the only split peripheral.
#define PERIPHERAL_SOURCE 0
// The split link silently drops writes once its buffers fill, so relay messages are paced.
#define RELAY_INTERVAL K_MSEC(25)
#define RELAY_QUEUE_LENGTH 64
#define HEADER_LENGTH 3

struct relay_msg {
    uint8_t position;
    uint32_t param1;
    uint32_t param2;
};

K_MSGQ_DEFINE(relay_msgq, sizeof(struct relay_msg), RELAY_QUEUE_LENGTH, 4);

static void relay_next(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(relay_work, relay_next);

static void relay_next(struct k_work *work) {
    struct relay_msg msg;
    if (k_msgq_get(&relay_msgq, &msg, K_NO_WAIT) != 0) {
        return;
    }

    struct zmk_behavior_binding binding = {
        .behavior_dev = MAC_LINK_BEHAVIOR_NAME,
        .param1 = msg.param1,
        .param2 = msg.param2,
    };
    struct zmk_behavior_binding_event event = {
        .position = msg.position,
        .timestamp = k_uptime_get(),
    };
    int err = zmk_split_central_invoke_behavior(PERIPHERAL_SOURCE, &binding, event, true);
    if (err) {
        LOG_WRN("Mac link relay failed: %d", err);
    }

    if (k_msgq_num_used_get(&relay_msgq) > 0) {
        k_work_schedule(&relay_work, RELAY_INTERVAL);
    }
}

static ssize_t write_text(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *buf,
                          uint16_t len, uint16_t offset, uint8_t flags) {
    const uint8_t *data = buf;

    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len < HEADER_LENGTH) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint8_t slot = data[0];
    uint8_t text_offset = data[1];
    uint8_t total = data[2];
    uint16_t count = len - HEADER_LENGTH;
    if (slot >= MAC_LINK_SLOT_COUNT || total > MAC_LINK_MAX_TEXT || text_offset + count > total) {
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }

    // Queue a chunk whole or not at all: the right half drops a text with a missing piece.
    // An empty text still needs one message so the slot gets cleared.
    uint16_t messages = MAX(1, DIV_ROUND_UP(count, MAC_LINK_RELAY_CHUNK));
    if (k_msgq_num_free_get(&relay_msgq) < messages) {
        return BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_RESOURCES);
    }

    uint16_t sent = 0;
    do {
        uint8_t n = MIN(count - sent, MAC_LINK_RELAY_CHUNK);
        uint8_t bytes[MAC_LINK_RELAY_CHUNK] = {0};
        memcpy(bytes, data + HEADER_LENGTH + sent, n);

        struct relay_msg msg = {
            .position = slot | (n << 4),
            .param1 = (uint32_t)(text_offset + sent) | ((uint32_t)total << 8) |
                      ((uint32_t)bytes[0] << 16) | ((uint32_t)bytes[1] << 24),
            .param2 = (uint32_t)bytes[2] | ((uint32_t)bytes[3] << 8) | ((uint32_t)bytes[4] << 16) |
                      ((uint32_t)bytes[5] << 24),
        };
        k_msgq_put(&relay_msgq, &msg, K_NO_WAIT);
        sent += n;
    } while (sent < count);

    k_work_schedule(&relay_work, K_NO_WAIT);
    return len;
}

static struct bt_uuid_128 service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x8f2a1c40, 0x6d3b, 0x4b8e, 0x9c71, 0x5e0a3b9d1f60));
static struct bt_uuid_128 text_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x8f2a1c41, 0x6d3b, 0x4b8e, 0x9c71, 0x5e0a3b9d1f60));

BT_GATT_SERVICE_DEFINE(mac_link_svc, BT_GATT_PRIMARY_SERVICE(&service_uuid),
                       BT_GATT_CHARACTERISTIC(&text_uuid.uuid,
                                              BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                                              BT_GATT_PERM_WRITE_ENCRYPT, NULL, write_text, NULL));
