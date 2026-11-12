/* SPDX-License-Identifier: MIT */

// Left half: forwards the dashboard messages the Mac app writes (see dashboard_protocol.h) to the
// right half's dashboard characteristic over the existing split connection.

#include <errno.h>
#include <string.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/util.h>

#include "dashboard_protocol.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#define QUEUE_LENGTH 48
#define STACK_SIZE 1024
// Writes block while the Bluetooth TX buffers are taken; the HID and split threads share them and
// must win.
#define PRIORITY K_LOWEST_APPLICATION_THREAD_PRIO
#define DISCOVERY_RETRY K_SECONDS(5)
// A write command spends this much of the ATT MTU on its opcode and handle.
#define WRITE_OVERHEAD 3

struct relay_msg {
    uint16_t len;
    uint8_t data[DASHBOARD_MAX_MESSAGE];
};

K_MSGQ_DEFINE(dashboard_relay_msgq, sizeof(struct relay_msg), QUEUE_LENGTH, 2);

static K_THREAD_STACK_DEFINE(relay_stack, STACK_SIZE);
static struct k_work_q relay_q;

// Set when a message from the Mac may not have reached the right half. The Mac's next write
// request then fails, and the Mac answers any failure by sending its next frame whole.
static atomic_t resync;

static K_MUTEX_DEFINE(link_lock);
static struct bt_conn *split_conn; // the connection to the right half, referenced while set
static uint16_t link_handle;       // the right half's characteristic value handle; 0 until found
static bool mtu_requested;         // the ATT MTU may be exchanged only once per connection
static bool gatt_busy;             // the stack owns mtu_params or discover_params

static struct bt_gatt_exchange_params mtu_params;
static struct bt_gatt_discover_params discover_params;

static struct bt_uuid_128 mac_service_uuid = BT_UUID_INIT_128(DASHBOARD_MAC_SERVICE_UUID);
static struct bt_uuid_128 mac_chrc_uuid = BT_UUID_INIT_128(DASHBOARD_MAC_CHRC_UUID);
static const struct bt_uuid_128 right_chrc_uuid = BT_UUID_INIT_128(DASHBOARD_SPLIT_CHRC_UUID);

static void setup_link(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(setup_work, setup_link);

static bool right_half_ready(void) {
    k_mutex_lock(&link_lock, K_FOREVER);
    bool ready = link_handle != 0;
    k_mutex_unlock(&link_lock);
    return ready;
}

static struct bt_conn *ready_link(uint16_t *handle) {
    k_mutex_lock(&link_lock, K_FOREVER);
    struct bt_conn *conn = link_handle != 0 ? bt_conn_ref(split_conn) : NULL;
    *handle = link_handle;
    k_mutex_unlock(&link_lock);
    return conn;
}

static int relay(const struct relay_msg *msg) {
    uint16_t handle;
    struct bt_conn *conn = ready_link(&handle);
    if (conn == NULL) {
        return -ENOTCONN;
    }

    int err = 0;
    int max = bt_gatt_get_mtu(conn) - WRITE_OVERHEAD;
    if (msg->len <= max) {
        err = bt_gatt_write_without_response(conn, handle, msg->data, msg->len, false);
    } else if (max <= DASHBOARD_HEADER_SIZE) {
        err = -ENOTCONN;
    } else {
        // Only DATA outgrows the smallest ATT MTU (23), and it splits at any byte.
        uint8_t chunk[DASHBOARD_MAX_MESSAGE] = {DASHBOARD_MSG_DATA};
        uint16_t offset = sys_get_le16(msg->data + 1);
        uint16_t count = msg->len - DASHBOARD_HEADER_SIZE;
        uint16_t step = max - DASHBOARD_HEADER_SIZE;
        for (uint16_t done = 0; done < count && err == 0; done += step) {
            uint16_t n = MIN(step, count - done);
            sys_put_le16(offset + done, chunk + 1);
            memcpy(chunk + DASHBOARD_HEADER_SIZE, msg->data + DASHBOARD_HEADER_SIZE + done, n);
            err = bt_gatt_write_without_response(conn, handle, chunk, DASHBOARD_HEADER_SIZE + n,
                                                 false);
        }
    }

    bt_conn_unref(conn);
    return err;
}

static void relay_messages(struct k_work *work) {
    struct relay_msg msg;
    while (k_msgq_get(&dashboard_relay_msgq, &msg, K_NO_WAIT) == 0) {
        int err = relay(&msg);
        if (err) {
            LOG_DBG("Dashboard message dropped: %d", err);
            atomic_set(&resync, 1);
        }
    }
}
static K_WORK_DEFINE(relay_work, relay_messages);

static ssize_t write_message(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len, uint16_t offset, uint8_t flags) {
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len > DASHBOARD_MAX_MESSAGE) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }
    if (!dashboard_message_valid(buf, len)) {
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }

    if (!right_half_ready()) {
        atomic_set(&resync, 1);
        return len;
    }
    // A write without response cannot carry the error, so only a request consumes the flag.
    if (!(flags & BT_GATT_WRITE_FLAG_CMD) && atomic_cas(&resync, 1, 0)) {
        return BT_GATT_ERR(BT_ATT_ERR_UNLIKELY);
    }

    struct relay_msg msg = {.len = len};
    memcpy(msg.data, buf, len);
    if (k_msgq_put(&dashboard_relay_msgq, &msg, K_NO_WAIT) != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_RESOURCES);
    }
    k_work_submit_to_queue(&relay_q, &relay_work);
    return len;
}

BT_GATT_SERVICE_DEFINE(dashboard_mac_svc, BT_GATT_PRIMARY_SERVICE(&mac_service_uuid),
                       BT_GATT_CHARACTERISTIC(&mac_chrc_uuid.uuid,
                                              BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                                              BT_GATT_PERM_WRITE_ENCRYPT, NULL, write_message,
                                              NULL));

static uint8_t discovered(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                          struct bt_gatt_discover_params *params) {
    bool found = false;
    bool retry = false;

    k_mutex_lock(&link_lock, K_FOREVER);
    gatt_busy = false;
    if (conn == split_conn) {
        if (attr != NULL) {
            link_handle = ((const struct bt_gatt_chrc *)attr->user_data)->value_handle;
            found = true;
        } else {
            retry = true;
        }
    }
    k_mutex_unlock(&link_lock);

    if (found) {
        LOG_INF("Dashboard relay ready, ATT MTU %u", bt_gatt_get_mtu(conn));
    } else if (retry) {
        LOG_WRN("Dashboard characteristic not found on the right half");
        k_work_reschedule_for_queue(&relay_q, &setup_work, DISCOVERY_RETRY);
    }
    return BT_GATT_ITER_STOP;
}

static void mtu_exchanged(struct bt_conn *conn, uint8_t err,
                          struct bt_gatt_exchange_params *params) {
    if (err) {
        LOG_WRN("Dashboard relay MTU exchange failed: %u", err);
    }

    k_mutex_lock(&link_lock, K_FOREVER);
    gatt_busy = false;
    k_mutex_unlock(&link_lock);
    k_work_reschedule_for_queue(&relay_q, &setup_work, K_NO_WAIT);
}

// Exchanges the MTU, then finds the right half's characteristic. ZMK's split client shares the
// connection; the stack queues its ATT requests and ours.
static void setup_link(struct k_work *work) {
    k_mutex_lock(&link_lock, K_FOREVER);
    struct bt_conn *conn =
        split_conn != NULL && link_handle == 0 && !gatt_busy ? bt_conn_ref(split_conn) : NULL;
    bool exchange = conn != NULL && !mtu_requested;
    if (conn != NULL) {
        gatt_busy = true;
        mtu_requested = true;
    }
    k_mutex_unlock(&link_lock);

    if (conn == NULL) {
        return;
    }

    int err;
    if (exchange) {
        mtu_params.func = mtu_exchanged;
        err = bt_gatt_exchange_mtu(conn, &mtu_params);
        if (err == 0) {
            bt_conn_unref(conn);
            return;
        }
        if (err != -EALREADY) {
            LOG_WRN("Dashboard relay MTU exchange not sent: %d", err);
        }
    }

    discover_params.uuid = &right_chrc_uuid.uuid;
    discover_params.func = discovered;
    discover_params.start_handle = BT_ATT_FIRST_ATTRIBUTE_HANDLE;
    discover_params.end_handle = BT_ATT_LAST_ATTRIBUTE_HANDLE;
    discover_params.type = BT_GATT_DISCOVER_CHARACTERISTIC;
    err = bt_gatt_discover(conn, &discover_params);
    if (err) {
        LOG_WRN("Dashboard relay discovery not sent: %d", err);
        k_mutex_lock(&link_lock, K_FOREVER);
        gatt_busy = false;
        k_mutex_unlock(&link_lock);
        k_work_reschedule_for_queue(&relay_q, &setup_work, DISCOVERY_RETRY);
    }
    bt_conn_unref(conn);
}

// This half is the central only toward the right half; the Mac connects to it as a peripheral.
static bool is_split_link(struct bt_conn *conn) {
    struct bt_conn_info info;
    return bt_conn_get_info(conn, &info) == 0 && info.type == BT_CONN_TYPE_LE &&
           info.role == BT_CONN_ROLE_CENTRAL;
}

static void security_changed(struct bt_conn *conn, bt_security_t level,
                             enum bt_security_err err) {
    if (err != BT_SECURITY_ERR_SUCCESS || level < BT_SECURITY_L2 || !is_split_link(conn)) {
        return;
    }

    bool start = false;
    k_mutex_lock(&link_lock, K_FOREVER);
    if (split_conn == NULL) {
        split_conn = bt_conn_ref(conn);
        link_handle = 0;
        mtu_requested = false;
        start = true;
    }
    k_mutex_unlock(&link_lock);

    if (start) {
        k_work_reschedule_for_queue(&relay_q, &setup_work, K_NO_WAIT);
    }
}

static void disconnected(struct bt_conn *conn, uint8_t reason) {
    struct bt_conn *old = NULL;

    k_mutex_lock(&link_lock, K_FOREVER);
    if (conn == split_conn) {
        old = split_conn;
        split_conn = NULL;
        link_handle = 0;
    }
    k_mutex_unlock(&link_lock);

    if (old != NULL) {
        k_work_cancel_delayable(&setup_work);
        // A right half that rebooted lost its buffers.
        atomic_set(&resync, 1);
        bt_conn_unref(old);
    }
}

BT_CONN_CB_DEFINE(dashboard_relay_conn_cb) = {
    .disconnected = disconnected,
    .security_changed = security_changed,
};

static int dashboard_relay_init(void) {
    static const struct k_work_queue_config config = {.name = "dashboard relay"};
    k_work_queue_start(&relay_q, relay_stack, K_THREAD_STACK_SIZEOF(relay_stack), PRIORITY,
                       &config);
    return 0;
}

SYS_INIT(dashboard_relay_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
