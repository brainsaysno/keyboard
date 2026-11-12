/* SPDX-License-Identifier: MIT */

// Right half: shows the dashboard frame the left half relays from the Mac app (see
// dashboard_protocol.h), or the "no data" screen from dashboard_stale.c while the Mac is silent.

#include <string.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/crc.h>
#include <zephyr/sys/util.h>
#include <lvgl.h>
#include <zmk/display.h>
#include <zmk/display/status_screen.h>

#include "dashboard_protocol.h"
#include "dashboard_stale.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

// The panel's own orientation; the frame is portrait, rotated 90 degrees clockwise onto it.
#define PANEL_WIDTH DASHBOARD_HEIGHT
#define PANEL_HEIGHT DASHBOARD_WIDTH

// Only the GATT write callback touches the back buffer, and ATT writes are handled one at a time.
static uint8_t back[DASHBOARD_FRAME_SIZE];

// Handed from the GATT write callback to the display thread.
static K_MUTEX_DEFINE(front_lock);
static uint8_t front[DASHBOARD_FRAME_SIZE];
static bool presented;       // a frame was presented since boot
static int64_t presented_at; // k_uptime_get() of the last matching PRESENT

// Display thread only.
static lv_color_t panel_buf[PANEL_WIDTH * PANEL_HEIGHT];
static lv_obj_t *canvas;

static void refresh(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(refresh_work, refresh);

static void show(const uint8_t *frame) {
    static uint8_t shown[DASHBOARD_FRAME_SIZE];
    static bool drawn;

    if (drawn && memcmp(shown, frame, sizeof(shown)) == 0) {
        return;
    }
    memcpy(shown, frame, sizeof(shown));
    drawn = true;

    for (int y = 0; y < DASHBOARD_HEIGHT; y++) {
        const uint8_t *row = frame + y * DASHBOARD_STRIDE;
        for (int x = 0; x < DASHBOARD_WIDTH; x++) {
            bool black = row[x >> 3] & (0x80 >> (x & 7));
            panel_buf[x * PANEL_WIDTH + (PANEL_WIDTH - 1 - y)] =
                black ? lv_color_black() : lv_color_white();
        }
    }
    lv_obj_invalidate(canvas);
}

static void refresh(struct k_work *work) {
    static uint8_t frame[DASHBOARD_FRAME_SIZE];

    if (canvas == NULL) {
        return;
    }

    k_mutex_lock(&front_lock, K_FOREVER);
    bool any = presented;
    int64_t silence = k_uptime_get() - presented_at;
    bool fresh = any && silence < DASHBOARD_FRESH_MS;
    if (fresh) {
        memcpy(frame, front, sizeof(frame));
    }
    k_mutex_unlock(&front_lock);

    // k_work_schedule leaves an earlier run requested by present() in place.
    if (!any) {
        dashboard_stale_render(frame, true, 0);
    } else if (fresh) {
        k_work_schedule_for_queue(zmk_display_work_q(), &refresh_work,
                                  K_MSEC(DASHBOARD_FRESH_MS - silence));
    } else {
        int64_t mins = silence / DASHBOARD_STALE_STEP_MS;
        dashboard_stale_render(frame, false, (uint32_t)MIN(mins, UINT32_MAX));
        k_work_schedule_for_queue(zmk_display_work_q(), &refresh_work,
                                  K_MSEC((mins + 1) * DASHBOARD_STALE_STEP_MS - silence));
    }
    show(frame);
}

static void present(uint16_t crc) {
    if (crc16_itu_t(0xFFFF, back, sizeof(back)) != crc) {
        // Some DATA was lost; the Mac's next full frame repairs the back buffer.
        LOG_DBG("Dashboard frame CRC mismatch");
        return;
    }

    int64_t now = k_uptime_get();
    k_mutex_lock(&front_lock, K_FOREVER);
    bool changed = !presented || memcmp(front, back, sizeof(front)) != 0;
    // A heartbeat (same frame again) only has to replace the "no data" screen if it is up.
    bool redraw = changed || now - presented_at >= DASHBOARD_FRESH_MS;
    if (changed) {
        memcpy(front, back, sizeof(front));
        presented = true;
    }
    presented_at = now;
    k_mutex_unlock(&front_lock);

    if (redraw) {
        k_work_reschedule_for_queue(zmk_display_work_q(), &refresh_work, K_NO_WAIT);
    }
}

static ssize_t write_message(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len, uint16_t offset, uint8_t flags) {
    const uint8_t *msg = buf;

    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (!dashboard_message_valid(msg, len)) {
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }

    if (msg[0] == DASHBOARD_MSG_DATA) {
        memcpy(back + sys_get_le16(msg + 1), msg + DASHBOARD_HEADER_SIZE,
               len - DASHBOARD_HEADER_SIZE);
    } else {
        present(sys_get_le16(msg + 1));
    }
    return len;
}

static struct bt_uuid_128 service_uuid = BT_UUID_INIT_128(DASHBOARD_SPLIT_SERVICE_UUID);
static struct bt_uuid_128 chrc_uuid = BT_UUID_INIT_128(DASHBOARD_SPLIT_CHRC_UUID);

BT_GATT_SERVICE_DEFINE(dashboard_split_svc, BT_GATT_PRIMARY_SERVICE(&service_uuid),
                       BT_GATT_CHARACTERISTIC(&chrc_uuid.uuid,
                                              BT_GATT_CHRC_WRITE_WITHOUT_RESP | BT_GATT_CHRC_WRITE,
                                              BT_GATT_PERM_WRITE_ENCRYPT, NULL, write_message,
                                              NULL));

lv_obj_t *zmk_display_status_screen(void) {
    lv_obj_t *screen = lv_obj_create(NULL);

    canvas = lv_canvas_create(screen);
    lv_canvas_set_buffer(canvas, panel_buf, PANEL_WIDTH, PANEL_HEIGHT, LV_IMG_CF_TRUE_COLOR);
    lv_obj_align(canvas, LV_ALIGN_TOP_LEFT, 0, 0);

    refresh(NULL);
    return screen;
}
