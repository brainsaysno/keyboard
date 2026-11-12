/* SPDX-License-Identifier: MIT */

#define DT_DRV_COMPAT zmk_behavior_shift_scroll

#include <errno.h>
#include <zephyr/device.h>
#include <drivers/behavior.h>
#include <dt-bindings/zmk/modifiers.h>
#include <dt-bindings/zmk/hid_usage_pages.h>
#include <zmk/behavior.h>
#include <zmk/endpoints.h>
#include <zmk/hid.h>

#define SHIFT_MASK (MOD_LSFT | MOD_RSFT)

struct shift_scroll_config {
    struct zmk_behavior_binding bindings[2];
};

struct shift_scroll_data {
    bool active;
    bool scrolling;
};

// Keep Shift masked until the last scrolling key is released.
static unsigned int scrolling_keys;

static void sync_shift_mask(void) {
    int changed = scrolling_keys ? zmk_hid_masked_modifiers_set(SHIFT_MASK)
                                 : zmk_hid_masked_modifiers_clear();
    if (changed > 0) {
        // Unlike a keyboard key, &msc does not send a keyboard report. Flush the
        // modifier change before scrolling, and restore held Shift afterwards.
        zmk_endpoints_send_report(HID_USAGE_KEY);
    }
}

static int shift_scroll_pressed(struct zmk_behavior_binding *binding,
                                struct zmk_behavior_binding_event event) {
    const struct device *dev = zmk_behavior_get_binding(binding->behavior_dev);
    const struct shift_scroll_config *cfg = dev->config;
    struct shift_scroll_data *data = dev->data;

    if (data->active) {
        return -ENOTSUP;
    }

    data->active = true;
    data->scrolling = (zmk_hid_get_explicit_mods() & SHIFT_MASK) != 0;
    if (data->scrolling) {
        scrolling_keys++;
        sync_shift_mask();
    }

    struct zmk_behavior_binding child = cfg->bindings[data->scrolling ? 1 : 0];
    int ret = zmk_behavior_invoke_binding(&child, event, true);
    if (ret < 0) {
        if (data->scrolling) {
            scrolling_keys--;
            sync_shift_mask();
        }
        data->active = false;
    }
    return ret;
}

static int shift_scroll_released(struct zmk_behavior_binding *binding,
                                 struct zmk_behavior_binding_event event) {
    const struct device *dev = zmk_behavior_get_binding(binding->behavior_dev);
    const struct shift_scroll_config *cfg = dev->config;
    struct shift_scroll_data *data = dev->data;

    if (!data->active) {
        return -ENOTSUP;
    }

    // Release the behavior chosen at key-down, even if Shift changed meanwhile.
    struct zmk_behavior_binding child = cfg->bindings[data->scrolling ? 1 : 0];
    int ret = zmk_behavior_invoke_binding(&child, event, false);
    if (data->scrolling) {
        scrolling_keys--;
        sync_shift_mask();
    }
    data->active = false;
    return ret;
}

static const struct behavior_driver_api shift_scroll_api = {
    .binding_pressed = shift_scroll_pressed,
    .binding_released = shift_scroll_released,
#if IS_ENABLED(CONFIG_ZMK_BEHAVIOR_METADATA)
    .get_parameter_metadata = zmk_behavior_get_empty_param_metadata,
#endif
};

#define CHILD_BINDING(n, idx)                                                                       \
    {                                                                                             \
        .behavior_dev = DEVICE_DT_NAME(DT_INST_PHANDLE_BY_IDX(n, bindings, idx)),                   \
        .param1 = DT_INST_PHA_BY_IDX(n, bindings, idx, param1),                                     \
    }

#define SHIFT_SCROLL_INST(n)                                                                       \
    BUILD_ASSERT(DT_INST_PROP_LEN(n, bindings) == 2, "Expected movement and scrolling bindings"); \
    static const struct shift_scroll_config shift_scroll_config_##n = {                           \
        .bindings = {CHILD_BINDING(n, 0), CHILD_BINDING(n, 1)},                                     \
    };                                                                                            \
    static struct shift_scroll_data shift_scroll_data_##n;                                        \
    BEHAVIOR_DT_INST_DEFINE(n, NULL, NULL, &shift_scroll_data_##n, &shift_scroll_config_##n,         \
                           POST_KERNEL, CONFIG_KERNEL_INIT_PRIORITY_DEFAULT, &shift_scroll_api);

DT_INST_FOREACH_STATUS_OKAY(SHIFT_SCROLL_INST)
